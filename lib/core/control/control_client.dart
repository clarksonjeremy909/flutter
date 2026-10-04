import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';

import '../afk/afk_status.dart';
import 'control_protocol.dart';

enum ControlConnection { disconnected, connecting, connected, unauthorized }

class ControlException implements Exception {
  ControlException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Runs on the phone. Keeps a resilient connection to the PC (auto-reconnect
/// with backoff) and mirrors the PC's AFK / Sunshine status.
class ControlClient {
  ControlClient({
    required this.host,
    required this.token,
    this.port = ControlProtocol.defaultPort,
    this.requestTimeout = const Duration(seconds: 45),
  });

  final String host;
  final int port;
  final String token;
  final Duration requestTimeout;

  WebSocket? _ws;
  bool _closed = false;
  int _nextId = 1;
  int _attempt = 0;
  Timer? _reconnect;
  final _pending = <int, Completer<Map<String, Object?>>>{};

  ControlConnection _conn = ControlConnection.disconnected;
  AfkStatus? _afk;
  Map<String, Object?>? _sunshine;
  String? hostName;
  DateTime? lastMessageAt;
  String? lastError;

  final _changes = StreamController<void>.broadcast();

  /// Fires whenever connection state or mirrored status changes.
  Stream<void> get changes => _changes.stream;
  ControlConnection get connection => _conn;
  AfkStatus? get afkStatus => _afk;
  Map<String, Object?>? get sunshineStatus => _sunshine;

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> connect() async {
    _closed = false;
    if (_conn == ControlConnection.connecting || _conn == ControlConnection.connected) {
      return;
    }
    _conn = ControlConnection.connecting;
    _notify();
    try {
      final ws = await WebSocket.connect(
        'ws://$host:$port${ControlProtocol.path}',
        headers: {ControlProtocol.tokenHeader: token},
      ).timeout(const Duration(seconds: 6));
      ws.pingInterval = const Duration(seconds: 10);
      _ws = ws;
      _attempt = 0;
      _conn = ControlConnection.connected;
      lastError = null;
      _notify();
      ws.listen(_onData, onDone: _onClosed, onError: (_) => _onClosed(), cancelOnError: true);
    } on WebSocketException catch (e) {
      final unauthorized = '$e'.contains('401');
      lastError = unauthorized ? 'Bağlantı kodu hatalı' : e.message;
      _conn = unauthorized ? ControlConnection.unauthorized : ControlConnection.disconnected;
      _notify();
      if (!unauthorized) _scheduleReconnect();
    } catch (e) {
      lastError = '$e';
      _conn = ControlConnection.disconnected;
      _notify();
      _scheduleReconnect();
    }
  }

  void _onData(Object? data) {
    lastMessageAt = clock.now();
    Map<String, Object?> m;
    try {
      m = (jsonDecode(data as String) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    switch (m['type']) {
      case ControlProtocol.hello:
        hostName = m['host'] as String?;
      case ControlProtocol.afkStatus:
        _afk = AfkStatus.fromJson((m['status'] as Map).cast<String, Object?>());
      case ControlProtocol.sunshineStatus:
        _sunshine = (m['status'] as Map).cast<String, Object?>();
      case ControlProtocol.result:
        final c = _pending.remove((m['id'] as num?)?.toInt());
        if (c != null && !c.isCompleted) {
          m['ok'] == true
              ? c.complete(m)
              : c.completeError(ControlException('${m['error'] ?? 'Hata'}'));
        }
    }
    _notify();
  }

  void _onClosed() {
    _ws = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(ControlException('Bağlantı koptu'));
    }
    _pending.clear();
    if (_conn != ControlConnection.unauthorized) {
      _conn = ControlConnection.disconnected;
    }
    _notify();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _reconnect?.cancel();
    final secs = min(30, pow(2, min(_attempt, 5)).toInt());
    _attempt++;
    _reconnect = Timer(Duration(seconds: secs), connect);
  }

  Future<Map<String, Object?>> request(String type, [Map<String, Object?> body = const {}]) {
    final ws = _ws;
    if (ws == null || _conn != ControlConnection.connected) {
      return Future.error(ControlException('PC\'ye bağlı değil'));
    }
    final id = _nextId++;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    ws.add(jsonEncode({'type': type, 'id': id, ...body}));
    return c.future.timeout(requestTimeout, onTimeout: () {
      _pending.remove(id);
      throw ControlException('Yanıt zaman aşımı');
    });
  }

  Future<void> setAfk(bool enabled, {KeepAwakeMethod? method, Duration? interval}) =>
      request(ControlProtocol.afkSet, {
        'enabled': enabled,
        if (method != null) 'method': method.name,
        if (interval != null) 'intervalSec': interval.inSeconds,
      });

  Future<void> pingAfkNow() => request(ControlProtocol.afkPing);

  Future<bool> submitSunshinePin(String pin, {required String name}) async {
    try {
      await request(ControlProtocol.sunshinePin, {'pin': pin, 'name': name});
      return true;
    } on ControlException {
      return false;
    }
  }

  Future<void> prepareSunshine() => request(ControlProtocol.sunshinePrepare);

  Future<void> close() async {
    _closed = true;
    _reconnect?.cancel();
    await _ws?.close();
    _ws = null;
    _conn = ControlConnection.disconnected;
    await _changes.close();
  }
}
