import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';

import '../afk/afk_status.dart';
import 'control_protocol.dart';
import 'discovery.dart';

/// Phone-side connection state.
enum ControlConnection {
  /// Server not running (e.g. could not bind).
  stopped,

  /// Advertising on the LAN, waiting for the PC to connect.
  waiting,

  /// A PC is connected.
  connected,
}

class ControlException implements Exception {
  ControlException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A PC this phone has paired with (long-term key, set by the PC).
class PairedPc {
  const PairedPc({required this.id, required this.name, required this.key});
  final String id;
  final String name;
  final String key;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'key': key};
  factory PairedPc.fromJson(Map<String, Object?> j) =>
      PairedPc(id: '${j['id']}', name: '${j['name'] ?? 'PC'}', key: '${j['key']}');
}

/// Emitted when a PC successfully pairs using the code.
class PairingEvent {
  const PairingEvent(this.pc, this.address);
  final PairedPc pc;
  final String address;
}

/// Runs on the phone. Hosts the control WebSocket, advertises itself on the
/// LAN, authenticates the PC (pairing code or long-term key) and mirrors the
/// PC's AFK / Sunshine status. Requests (AFK toggle, PIN forwarding…) flow
/// from the phone to the PC over the PC-initiated socket.
class PhoneControlServer {
  PhoneControlServer({
    required this.deviceId,
    required this.deviceName,
    Iterable<PairedPc> pairedPcs = const [],
    this.port = ControlProtocol.defaultPort,
    this.address,
    this.discoveryPort = ControlProtocol.discoveryPort,
    this.beaconPort = ControlProtocol.discoveryPort,
    this.beaconTargets,
    this.maxFailedAttempts = 5,
    this.requestTimeout = const Duration(seconds: 45),
    String? initialCode,
  }) : _code = initialCode ?? PairingCode.generate() {
    for (final p in pairedPcs) {
      _paired[p.id] = p;
    }
  }

  final String deviceId;
  String deviceName;
  final int port;
  final InternetAddress? address;
  final int discoveryPort;
  final int beaconPort;
  final List<InternetAddress>? beaconTargets;
  final int maxFailedAttempts;
  final Duration requestTimeout;

  final _paired = <String, PairedPc>{};
  String _code;
  int _failed = 0;

  HttpServer? _server;
  PhoneAdvertiser? advertiser;
  WebSocket? _ws;
  String? _pcId;
  int _nextId = 1;
  final _pending = <int, Completer<Map<String, Object?>>>{};

  ControlConnection _conn = ControlConnection.stopped;
  AfkStatus? _afk;
  Map<String, Object?>? _sunshine;
  String? hostName;
  String? peerAddress;
  DateTime? lastMessageAt;
  String? lastError;

  final _changes = StreamController<void>.broadcast();
  final _pairings = StreamController<PairingEvent>.broadcast();

  Stream<void> get changes => _changes.stream;
  Stream<PairingEvent> get pairings => _pairings.stream;
  ControlConnection get connection => _conn;
  AfkStatus? get afkStatus => _afk;
  Map<String, Object?>? get sunshineStatus => _sunshine;
  String get code => _code;
  List<PairedPc> get pairedPcs => _paired.values.toList();
  int? get boundPort => _server?.port;
  String? get connectedPcId => _pcId;

  /// Rename this phone (shown on the PC, sent in discovery replies).
  void rename(String v) {
    deviceName = v;
    advertiser?.deviceName = v;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> start() async {
    if (_server != null) return;
    final bindTo = address ?? InternetAddress.anyIPv4;
    HttpServer s;
    try {
      s = await HttpServer.bind(bindTo, port);
    } on SocketException {
      s = await HttpServer.bind(bindTo, 0); // port busy: advertise an ephemeral one
    }
    _server = s;
    s.listen(_handle, onError: (_) {});
    final adv = PhoneAdvertiser(
      deviceId: deviceId,
      deviceName: deviceName,
      wsPort: s.port,
      code: _code,
      keyForPc: (id) => _paired[id]?.key,
      port: discoveryPort,
      beaconPort: beaconPort,
      beaconTargets: beaconTargets,
    );
    advertiser = adv;
    await adv.start();
    lastError = adv.lastError;
    _conn = ControlConnection.waiting;
    _notify();
  }

  /// New one-time pairing code (after use, on demand, or after too many
  /// wrong attempts).
  String regenerateCode() {
    _code = PairingCode.generate();
    _failed = 0;
    advertiser?.code = _code;
    _notify();
    return _code;
  }

  void forgetPc(String id) {
    _paired.remove(id);
    if (_pcId == id) unawaited(_ws?.close(WebSocketStatus.policyViolation));
    _notify();
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.uri.path != ControlProtocol.path || !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final token = req.headers.value(ControlProtocol.tokenHeader) ?? '';
    final pcId = req.headers.value(ControlProtocol.pcIdHeader) ?? '';
    final pcName = Uri.decodeComponent(req.headers.value(ControlProtocol.pcNameHeader) ?? 'PC');
    final newKey = req.headers.value(ControlProtocol.pairKeyHeader);

    final known = _paired[pcId];
    final byKey = known != null && constantTimeEquals(token, known.key);
    final byCode =
        !byKey &&
        pcId.isNotEmpty &&
        newKey != null &&
        newKey.length >= 32 &&
        constantTimeEquals(PairingCode.normalize(token), _code);
    if (!byKey && !byCode) {
      if (++_failed >= maxFailedAttempts) {
        regenerateCode();
        lastError = 'Çok fazla hatalı deneme — yeni kod üretildi';
        _notify();
      }
      req.response.statusCode = HttpStatus.unauthorized;
      await req.response.close();
      return;
    }
    // One PC at a time; a stale socket from the same PC or an explicit new
    // pairing replaces it, another paired PC is told to back off.
    if (_ws != null && byKey && _pcId != pcId) {
      req.response.statusCode = HttpStatus.conflict;
      await req.response.close();
      return;
    }
    final peer = req.connectionInfo?.remoteAddress.address ?? '?';
    final ws = await WebSocketTransformer.upgrade(req);
    ws.pingInterval = const Duration(seconds: 10);
    final old = _ws;
    _ws = ws;
    if (old != null) {
      _failPending('Bağlantı yenilendi');
      unawaited(old.close(WebSocketStatus.goingAway));
    }
    _pcId = pcId;
    hostName = pcName;
    peerAddress = peer;
    _failed = 0;
    _conn = ControlConnection.connected;
    lastError = null;
    if (byCode) {
      final pc = PairedPc(id: pcId, name: pcName, key: newKey);
      _paired[pcId] = pc;
      regenerateCode(); // codes are one-time
      if (!_pairings.isClosed) _pairings.add(PairingEvent(pc, peer));
    }
    _notify();
    ws.listen(
      _onData,
      onDone: () => _onClosed(ws),
      onError: (_) => _onClosed(ws),
      cancelOnError: true,
    );
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
        hostName = (m['host'] as String?) ?? hostName;
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

  void _failPending(String why) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(ControlException(why));
    }
    _pending.clear();
  }

  void _onClosed(WebSocket ws) {
    if (!identical(ws, _ws)) return;
    _ws = null;
    _pcId = null;
    _failPending('Bağlantı koptu');
    if (_conn == ControlConnection.connected) _conn = ControlConnection.waiting;
    _notify();
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
    return c.future.timeout(
      requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw ControlException('Yanıt zaman aşımı');
      },
    );
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
    advertiser?.stop();
    advertiser = null;
    _failPending('Kapatıldı');
    await _ws?.close(WebSocketStatus.goingAway);
    _ws = null;
    await _server?.close(force: true);
    _server = null;
    _conn = ControlConnection.stopped;
    await _changes.close();
    await _pairings.close();
  }
}
