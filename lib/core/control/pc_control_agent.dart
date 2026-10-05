import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../afk/afk_scheduler.dart';
import '../afk/afk_status.dart';
import 'control_protocol.dart';

/// What the control server needs from the Sunshine side (decoupled for tests).
abstract class HostSunshineHooks {
  Future<Map<String, Object?>> status();
  Future<void> prepare();
  Future<bool> submitPin(String pin, {required String clientName, String? clientAddress});
  Stream<Map<String, Object?>> get changes;
}

/// Runs on the PC. Serves the control protocol on sockets the PC opened to
/// phones (see `PhoneLink`): lets the phone toggle AFK mode, see its live
/// status, and forward Moonlight pairing PINs to Sunshine.
class PcControlAgent {
  PcControlAgent({required this.afk, this.sunshine, this.hostName = 'AktifDesk PC'});

  final AfkScheduler afk;
  final HostSunshineHooks? sunshine;
  final String hostName;

  final _clients = <WebSocket, String>{};
  StreamSubscription<AfkStatus>? _afkSub;
  StreamSubscription<Map<String, Object?>>? _sunSub;
  bool _started = false;

  int get connectedClients => _clients.length;
  final _clientCount = StreamController<int>.broadcast();
  Stream<int> get clientCountStream => _clientCount.stream;

  void start() {
    if (_started) return;
    _started = true;
    _afkSub = afk.statusStream.listen(
      (s) => _broadcast({'type': ControlProtocol.afkStatus, 'status': s.toJson()}),
    );
    _sunSub = sunshine?.changes.listen(
      (s) => _broadcast({'type': ControlProtocol.sunshineStatus, 'status': s}),
    );
  }

  Future<void> stop() async {
    _started = false;
    await _afkSub?.cancel();
    await _sunSub?.cancel();
    for (final ws in _clients.keys.toList()) {
      await ws.close(WebSocketStatus.goingAway);
    }
    _clients.clear();
  }

  /// Serve an authenticated socket to a phone. Completes when it closes.
  Future<void> attach(WebSocket ws, {String peer = '?'}) {
    start();
    final closed = Completer<void>();
    ws.pingInterval = const Duration(seconds: 10);
    _clients[ws] = peer;
    _clientCount.add(_clients.length);
    _send(ws, {
      'type': ControlProtocol.hello,
      'version': ControlProtocol.version,
      'host': hostName,
    });
    _send(ws, {'type': ControlProtocol.afkStatus, 'status': afk.status.toJson()});
    if (sunshine != null) {
      unawaited(
        sunshine!.status().then(
          (s) => _send(ws, {'type': ControlProtocol.sunshineStatus, 'status': s}),
          onError: (_) {},
        ),
      );
    }
    void done() {
      if (_clients.remove(ws) != null) _clientCount.add(_clients.length);
      if (!closed.isCompleted) closed.complete();
    }

    ws.listen(
      (data) => _onMessage(ws, peer, data),
      onDone: done,
      onError: (_) => done(),
      cancelOnError: true,
    );
    return closed.future;
  }

  Future<void> _onMessage(WebSocket ws, String peer, Object? data) async {
    Map<String, Object?> msg;
    try {
      msg = (jsonDecode(data as String) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    final id = msg['id'];
    void reply(bool ok, [Object? error, Object? value]) => _send(ws, {
      'type': ControlProtocol.result,
      'id': id,
      'ok': ok,
      if (error != null) 'error': '$error',
      'value': ?value,
    });
    try {
      switch (msg['type']) {
        case ControlProtocol.afkSet:
          final enabled = msg['enabled'] == true;
          if (enabled) {
            final sec = (msg['intervalSec'] as num?)?.toInt();
            await afk.enable(
              method: msg['method'] == null ? null : KeepAwakeMethod.parse(msg['method'] as String),
              interval: sec == null ? null : Duration(seconds: sec.clamp(10, 3600)),
            );
          } else {
            await afk.disable();
          }
          reply(true, null, afk.status.toJson());
        case ControlProtocol.afkPing:
          await afk.pingNow();
          reply(true, null, afk.status.toJson());
        case ControlProtocol.statusGet:
          reply(true, null, {
            'afk': afk.status.toJson(),
            if (sunshine != null) 'sunshine': await sunshine!.status(),
          });
        case ControlProtocol.sunshinePin:
          final s = sunshine;
          if (s == null) throw StateError('Sunshine yönetimi kapalı');
          final ok = await s.submitPin(
            '${msg['pin']}',
            clientName: '${msg['name'] ?? 'Telefon'}',
            clientAddress: peer,
          );
          reply(ok, ok ? null : 'PIN reddedildi');
        case ControlProtocol.sunshinePrepare:
          final s = sunshine;
          if (s == null) throw StateError('Sunshine yönetimi kapalı');
          await s.prepare();
          reply(true, null, await s.status());
        default:
          reply(false, 'Bilinmeyen komut: ${msg['type']}');
      }
    } catch (e) {
      reply(false, e);
    }
  }

  void _send(WebSocket ws, Map<String, Object?> m) {
    try {
      ws.add(jsonEncode(m));
    } catch (_) {}
  }

  void _broadcast(Map<String, Object?> m) {
    for (final ws in _clients.keys.toList()) {
      _send(ws, m);
    }
  }
}
