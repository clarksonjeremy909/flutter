import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'control_protocol.dart';
import 'discovery.dart';
import 'pc_control_agent.dart';

/// This PC's identity towards phones.
class PcIdentity {
  const PcIdentity({required this.id, required this.name});
  final String id;
  final String name;
}

/// A phone this PC has paired with.
class PairedPhone {
  const PairedPhone({required this.id, required this.name, required this.key});
  final String id;
  final String name;
  final String key;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'key': key};
  factory PairedPhone.fromJson(Map<String, Object?> j) =>
      PairedPhone(id: '${j['id']}', name: '${j['name'] ?? 'Telefon'}', key: '${j['key']}');
}

class PairingFailure implements Exception {
  PairingFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

enum PairStage { idle, searching, connecting, success, failed }

class PairResult {
  const PairResult({required this.phone, required this.socket, required this.address});
  final PairedPhone phone;
  final WebSocket socket;
  final String address;
}

Future<WebSocket> connectToPhone(
  String host,
  int port,
  PcIdentity pc, {
  required String token,
  String? pairKey,
  Duration timeout = const Duration(seconds: 8),
}) => WebSocket.connect(
  'ws://$host:$port${ControlProtocol.path}',
  headers: {
    ControlProtocol.tokenHeader: token,
    ControlProtocol.pcIdHeader: pc.id,
    ControlProtocol.pcNameHeader: Uri.encodeComponent(pc.name),
    ControlProtocol.pairKeyHeader: ?pairKey,
  },
).timeout(timeout);

/// PC side of "type the code from the phone": find the phone showing [code]
/// on the LAN and open the control socket. No IP address involved.
Future<PairResult> pairWithCode({
  required String code,
  required PcIdentity pc,
  PcDiscovery? discovery,
  void Function(PairStage stage, String? detail)? onStage,
  Duration searchTimeout = const Duration(seconds: 12),
}) async {
  final norm = PairingCode.normalize(code);
  if (norm.length != PairingCode.length) {
    throw PairingFailure('Kod ${PairingCode.length} haneli olmalı');
  }
  onStage?.call(PairStage.searching, null);
  final found = await (discovery ?? PcDiscovery()).findByCode(norm, timeout: searchTimeout);
  if (found == null) {
    throw PairingFailure(
      'Bu kodu gösteren bir telefon bulunamadı. Kodu ve telefonla PC\'nin '
      'aynı Wi-Fi ağında olduğunu kontrol edin.',
    );
  }
  onStage?.call(PairStage.connecting, found.name);
  final key = randomToken(32);
  try {
    final ws = await connectToPhone(
      found.address.address,
      found.port,
      pc,
      token: norm,
      pairKey: key,
    );
    return PairResult(
      phone: PairedPhone(id: found.id, name: found.name, key: key),
      socket: ws,
      address: found.address.address,
    );
  } on WebSocketException catch (e) {
    if ('$e'.contains('401')) {
      throw PairingFailure('Telefon kodu reddetti (kod yenilenmiş olabilir)');
    }
    throw PairingFailure('Telefona bağlanılamadı: ${e.message}');
  } on TimeoutException {
    throw PairingFailure('Telefona bağlanırken zaman aşımı');
  } on SocketException catch (e) {
    throw PairingFailure('Telefona bağlanılamadı: ${e.message}');
  }
}

enum PhoneLinkState { searching, connecting, connected, rejected, stopped }

/// Keeps a paired phone connected: rediscovers it by device id on the LAN
/// (its IP may change) and reconnects with the long-term key.
class PhoneLink {
  PhoneLink({
    required this.phone,
    required this.pc,
    required this.agent,
    PcDiscovery? discovery,
    this.retryDelay = const Duration(seconds: 2),
    this.searchTimeout = const Duration(seconds: 10),
  }) : discovery = discovery ?? PcDiscovery();

  final PairedPhone phone;
  final PcIdentity pc;
  final PcControlAgent agent;
  final PcDiscovery discovery;
  final Duration retryDelay;
  final Duration searchTimeout;

  PhoneLinkState state = PhoneLinkState.searching;
  String? address;
  String? lastError;
  bool _stopped = false;
  bool _running = false;
  WebSocket? _ws;
  Completer<void>? _sleep;

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  void _set(PhoneLinkState s) {
    state = s;
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> _pause(Duration d) async {
    if (_stopped) return;
    final c = _sleep = Completer<void>();
    final t = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    await c.future;
    t.cancel();
  }

  /// Start the keep-connected loop, optionally adopting a socket that was
  /// just opened by [pairWithCode].
  void start({WebSocket? adopt, String? adoptAddress}) {
    if (_running) return;
    _running = true;
    unawaited(_run(adopt, adoptAddress));
  }

  Future<void> _run(WebSocket? first, String? firstAddress) async {
    var ws = first;
    if (first != null) address = firstAddress;
    var misses = 0;
    while (!_stopped) {
      if (ws == null) {
        _set(PhoneLinkState.searching);
        final found = await discovery.findPaired(
          deviceId: phone.id,
          pcId: pc.id,
          key: phone.key,
          timeout: searchTimeout,
        );
        if (_stopped) break;
        if (found == null) {
          misses++;
          await _pause(Duration(seconds: min(20, 2 * misses)));
          continue;
        }
        _set(PhoneLinkState.connecting);
        try {
          ws = await connectToPhone(found.address.address, found.port, pc, token: phone.key);
          address = found.address.address;
        } catch (e) {
          final rejected = '$e'.contains('401');
          lastError = rejected ? 'Telefon bu PC\'yi tanımıyor — yeniden eşleştirin' : '$e';
          _set(rejected ? PhoneLinkState.rejected : PhoneLinkState.searching);
          await _pause(Duration(seconds: rejected ? 30 : 5));
          continue;
        }
        if (_stopped) {
          await ws.close();
          break;
        }
      }
      misses = 0;
      lastError = null;
      _ws = ws;
      _set(PhoneLinkState.connected);
      await agent.attach(ws, peer: address ?? '?');
      _ws = null;
      ws = null;
      await _pause(retryDelay);
    }
    _set(PhoneLinkState.stopped);
  }

  Future<void> stop() async {
    _stopped = true;
    final s = _sleep;
    if (s != null && !s.isCompleted) s.complete();
    await _ws?.close(WebSocketStatus.goingAway);
    _ws = null;
    _set(PhoneLinkState.stopped);
    await _changes.close();
  }
}
