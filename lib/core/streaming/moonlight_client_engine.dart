import 'dart:async';
import 'dart:convert';

import '../../app/secret_store.dart';
import '../gamestream/client_identity.dart';
import '../gamestream/gamestream_client.dart';
import '../platform/android_bridge.dart';
import 'streaming_engine.dart';

class MemorySecretStore implements SecretStore {
  final m = <String, String>{};
  @override
  Future<String?> read(String key) async => m[key];
  @override
  Future<void> write(String key, String value) async => m[key] = value;
  @override
  Future<void> delete(String key) async => m.remove(key);
}

/// Primary client engine: speaks the Moonlight/GameStream protocol to
/// Sunshine.
///
/// * Control plane (serverinfo, PIN pairing, app list, launch/quit) is
///   implemented natively in Dart ([GameStreamClient]).
/// * Media plane (RTSP + ENet control + RTP video/audio + input) is handed to
///   the Moonlight Android app (moonlight-common-c + MediaCodec), launched via
///   its exported ShortcutTrampoline activity. Moonlight must be paired with
///   the same Sunshine host once; AktifDesk forwards that PIN to the PC.
class MoonlightClientEngine extends ClientStreamingEngine with EngineStatusMixin {
  MoonlightClientEngine({SecretStore? store, this.transportFactory})
      : store = store ?? PlatformSecretStore();

  final SecretStore store;
  final GameStreamTransport Function(ClientIdentity id)? transportFactory;
  ClientIdentity? _identity;
  final _clients = <String, GameStreamClient>{};

  @override
  String get id => 'moonlight';
  @override
  String get displayName => 'Moonlight (GameStream)';
  @override
  int get priority => 0;

  @override
  Future<EngineAvailability> probe() async {
    if (!AndroidBridge.supported) {
      return const EngineAvailability.no('Moonlight akışı yalnızca Android\'de');
    }
    final pkg = await AndroidBridge.moonlightPackage();
    if (pkg == null) {
      return const EngineAvailability.no(
          'Moonlight uygulaması yüklü değil (video çözme için gerekli)');
    }
    return const EngineAvailability.yes();
  }

  Future<ClientIdentity> identity() async {
    if (_identity != null) return _identity!;
    final saved = await store.read('gs.identity');
    if (saved != null) {
      return _identity = ClientIdentity.fromJson(
          (jsonDecode(saved) as Map).cast<String, Object?>());
    }
    final id = await ClientIdentity.generate();
    await store.write('gs.identity', jsonEncode(id.toJson()));
    return _identity = id;
  }

  Future<GameStreamClient> clientFor(String host) async {
    final existing = _clients[host];
    if (existing != null) return existing;
    final id = await identity();
    final certB64 = await store.read('gs.servercert.$host');
    final c = GameStreamClient(
      host: host,
      identity: id,
      transport: transportFactory?.call(id),
      serverCertDer: certB64 == null ? null : base64Decode(certB64),
    );
    return _clients[host] = c;
  }

  Future<ServerInfo> serverInfo(String host) async => (await clientFor(host)).serverInfo();

  @override
  Future<bool> isPaired(String host) async {
    if (await store.read('gs.servercert.$host') == null) return false;
    try {
      return (await serverInfo(host)).paired;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> pair(String host, {required FutureOr<void> Function(String pin) onPin}) async {
    setStatus(EngineState.preparing, 'Eşleştiriliyor');
    final c = await clientFor(host);
    try {
      final der = await c.pair(onPin: onPin);
      await store.write('gs.servercert.$host', base64Encode(der));
      setStatus(EngineState.ready, 'Eşleşti');
    } catch (e) {
      setStatus(EngineState.error, '$e');
      rethrow;
    }
  }

  Future<List<GameStreamApp>> apps(String host) async => (await clientFor(host)).appList();

  @override
  Future<void> startStream(StreamTarget target) async {
    setStatus(EngineState.preparing, 'Moonlight başlatılıyor');
    final info = await serverInfo(target.host);
    final ok = await AndroidBridge.launchMoonlight(
      pcUuid: info.uuid,
      pcName: info.hostname,
      appId: target.appId,
      appName: target.appName,
    );
    if (!ok) {
      setStatus(EngineState.error, 'Moonlight açılamadı');
      throw StateError('Moonlight açılamadı');
    }
    setStatus(EngineState.streaming, 'Moonlight\'ta yayınlanıyor');
  }

  @override
  Future<void> stopStream() async {
    for (final c in _clients.values) {
      try {
        await c.quitApp();
      } catch (_) {}
    }
    setStatus(EngineState.idle);
  }

  Future<void> unpair(String host) async {
    await store.delete('gs.servercert.$host');
    _clients.remove(host)?.close();
  }

  @override
  Future<void> dispose() async {
    for (final c in _clients.values) {
      c.close();
    }
    await closeStatus();
  }
}
