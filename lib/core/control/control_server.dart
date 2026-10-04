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

/// Runs on the PC. Lets the phone toggle AFK mode, see its live status, and
/// forward Moonlight pairing PINs to Sunshine.
class ControlServer {
  ControlServer({
    required this.afk,
    required this.token,
    this.sunshine,
    this.hostName = 'AktifDesk PC',
    this.port = ControlProtocol.defaultPort,
    this.address,
  });

  final AfkScheduler afk;
  String token;
  final HostSunshineHooks? sunshine;
  final String hostName;
  final int port;
  final InternetAddress? address;

  HttpServer? _server;
  final _clients = <WebSocket, String>{};
  StreamSubscription<AfkStatus>? _afkSub;
  StreamSubscription<Map<String, Object?>>? _sunSub;

  int get connectedClients => _clients.length;
  int? get boundPort => _server?.port;
  final _clientCount = StreamController<int>.broadcast();
  Stream<int> get clientCountStream => _clientCount.stream;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port, shared: true);
    _server!.listen(_handle, onError: (_) {});
    _afkSub = afk.statusStream.listen(
        (s) => _broadcast({'type': ControlProtocol.afkStatus, 'status': s.toJson()}));
    _sunSub = sunshine?.changes.listen(
        (s) => _broadcast({'type': ControlProtocol.sunshineStatus, 'status': s}));
  }

  Future<void> stop() async {
    await _afkSub?.cancel();
    await _sunSub?.cancel();
    for (final ws in _clients.keys.toList()) {
      await ws.close(WebSocketStatus.goingAway);
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.uri.path != ControlProtocol.path ||
        !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final given = req.headers.value(ControlProtocol.tokenHeader) ?? '';
    if (!constantTimeEquals(given, token)) {
      req.response.statusCode = HttpStatus.unauthorized;
      await req.response.close();
      return;
    }
    final peer = req.connectionInfo?.remoteAddress.address ?? '?';
    final ws = await WebSocketTransformer.upgrade(req);
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
      unawaited(sunshine!.status().then((s) =>
          _send(ws, {'type': ControlProtocol.sunshineStatus, 'status': s}),
          onError: (_) {}));
    }
    ws.listen(
      (data) => _onMessage(ws, peer, data),
      onDone: () {
        _clients.remove(ws);
        _clientCount.add(_clients.length);
      },
      onError: (_) {
        _clients.remove(ws);
        _clientCount.add(_clients.length);
      },
      cancelOnError: true,
    );
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
              method: msg['method'] == null
                  ? null
                  : KeepAwakeMethod.parse(msg['method'] as String),
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
          final ok = await s.submitPin('${msg['pin']}',
              clientName: '${msg['name'] ?? 'Telefon'}', clientAddress: peer);
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
