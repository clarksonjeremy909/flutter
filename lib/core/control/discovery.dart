import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'control_protocol.dart';

/// LAN discovery without mDNS: small JSON datagrams on UDP
/// [ControlProtocol.discoveryPort].
///
/// * query  (PC -> broadcast / sweep): `{ad:"q", n, ch}` where
///   `ch = HMAC(code, "q|n")`, or `{ad:"q", n, id, pc}` to find an already
///   paired phone by its device id.
/// * reply  (phone -> PC, unicast): `{ad:"r", n, id, name, port, h}` where
///   `h = HMAC(code-or-pair-key, "r|n|id|port")`, so the PC knows the answer
///   really comes from the phone that shows the code.
/// * beacon (phone -> broadcast, every 2 s): `{ad:"b", id, name, port, s, ch}`
///   with `ch = HMAC(code, "b|s")`. Lets a PC that is passively listening
///   find the phone even when its own queries can't reach it.
///
/// No code is ever sent in clear text in discovery packets.
const _magic = 'ad';

Map<String, Object?>? _decode(List<int> data) {
  if (data.length > 2048) return null;
  try {
    final m = jsonDecode(utf8.decode(data));
    return m is Map ? m.cast<String, Object?>() : null;
  } catch (_) {
    return null;
  }
}

List<int> _encode(Map<String, Object?> m) => utf8.encode(jsonEncode(m));

bool _isPrivate(InternetAddress a) {
  final b = a.rawAddress;
  if (b.length != 4) return false;
  return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
}

/// Local private IPv4 addresses of this machine.
Future<List<InternetAddress>> localLanAddresses() async {
  try {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final i in ifs)
        for (final a in i.addresses)
          if (!a.isLoopback && _isPrivate(a)) a,
    ];
  } catch (_) {
    return const [];
  }
}

int _toInt(List<int> b) => (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];

InternetAddress _fromInt(int v) => InternetAddress.fromRawAddress(
  Uint8List.fromList([(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255]),
);

int _mask(int prefix) => prefix <= 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;

/// Interface prefix length when the OS reports it, else assume /24.
int _prefixOf(InternetAddress a) {
  final p = a is InterfaceAddress ? a.prefixLength : 24;
  return (p <= 0 || p > 32) ? 24 : p;
}

/// 255.255.255.255 plus the directed broadcast of every LAN interface
/// (Windows only sends the limited broadcast on one interface).
Future<List<InternetAddress>> lanBroadcastTargets() async {
  final out = <String>{'255.255.255.255'};
  for (final a in await localLanAddresses()) {
    final ip = _toInt(a.rawAddress);
    for (final p in {_prefixOf(a), 24}) {
      if (p >= 31) continue;
      out.add(_fromInt((ip & _mask(p)) | (~_mask(p) & 0xFFFFFFFF)).address);
    }
  }
  return [for (final s in out) InternetAddress(s)];
}

/// Every host of each local subnet, capped at a /24 around this machine
/// (fallback when routers/APs drop broadcasts).
Future<List<InternetAddress>> lanSweepTargets() async {
  final own = <int>{};
  final hosts = <int>{};
  for (final a in await localLanAddresses()) {
    final ip = _toInt(a.rawAddress);
    own.add(ip);
    final p = _prefixOf(a) < 24 ? 24 : _prefixOf(a);
    if (p >= 31) continue;
    final net = ip & _mask(p);
    final size = 1 << (32 - p);
    for (var h = 1; h < size - 1; h++) {
      hosts.add(net + h);
    }
  }
  return [
    for (final h in hosts)
      if (!own.contains(h)) _fromInt(h),
  ];
}

/// Runs on the phone: answers PC queries and broadcasts beacons.
class PhoneAdvertiser {
  PhoneAdvertiser({
    required this.deviceId,
    required this.deviceName,
    required this.wsPort,
    this.code,
    this.keyForPc,
    this.port = ControlProtocol.discoveryPort,
    this.beaconPort = ControlProtocol.discoveryPort,
    this.beaconInterval = const Duration(seconds: 2),
    this.beaconTargets,
  });

  final String deviceId;
  String deviceName;
  int wsPort;

  /// Current pairing code (null = not accepting new PCs).
  String? code;

  /// Long-term key for an already paired PC id (reconnect discovery).
  String? Function(String pcId)? keyForPc;

  final int port;
  final int beaconPort;
  final Duration beaconInterval;

  /// Override beacon destinations (tests). Default: LAN broadcast addresses.
  final List<InternetAddress>? beaconTargets;

  RawDatagramSocket? _sock;
  Timer? _beacon;
  List<InternetAddress>? _cachedTargets;
  DateTime _targetsAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? lastError;

  int? get boundPort => _sock?.port;
  bool get running => _sock != null;

  Future<void> start() async {
    if (_sock != null) return;
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
      s.broadcastEnabled = true;
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = s.receive()) != null) {
          _onDatagram(s, d!);
        }
      }, onError: (_) {});
      _sock = s;
      lastError = null;
    } catch (e) {
      lastError = 'UDP $port açılamadı: $e';
    }
    _beacon = Timer.periodic(beaconInterval, (_) => sendBeacon());
    unawaited(sendBeacon());
  }

  void _onDatagram(RawDatagramSocket s, Datagram d) {
    final m = _decode(d.data);
    if (m == null || m[_magic] != 'q') return;
    final n = m['n'];
    if (n is! String || n.isEmpty || n.length > 64) return;
    String? secret;
    final ch = m['ch'];
    final c = code;
    if (ch is String && c != null && constantTimeEquals(ch, hmacHex(c, 'q|$n'))) {
      secret = c;
    } else if (m['id'] == deviceId && m['pc'] is String) {
      secret = keyForPc?.call(m['pc'] as String);
    }
    if (secret == null) return;
    try {
      s.send(
        _encode({
          _magic: 'r',
          'v': ControlProtocol.version,
          'n': n,
          'id': deviceId,
          'name': deviceName,
          'port': wsPort,
          'h': hmacHex(secret, 'r|$n|$deviceId|$wsPort'),
        }),
        d.address,
        d.port,
      );
    } catch (_) {}
  }

  Future<void> sendBeacon() async {
    final s = _sock;
    if (s == null) return;
    var targets = beaconTargets ?? _cachedTargets;
    if (targets == null || DateTime.now().difference(_targetsAt) > const Duration(seconds: 30)) {
      targets = beaconTargets ?? await lanBroadcastTargets();
      _cachedTargets = targets;
      _targetsAt = DateTime.now();
    }
    final salt = randomToken(8);
    final c = code;
    final data = _encode({
      _magic: 'b',
      'v': ControlProtocol.version,
      'id': deviceId,
      'name': deviceName,
      'port': wsPort,
      's': salt,
      if (c != null) 'ch': hmacHex(c, 'b|$salt'),
    });
    for (final t in targets) {
      try {
        s.send(data, t, beaconPort);
      } catch (_) {}
    }
  }

  void stop() {
    _beacon?.cancel();
    _beacon = null;
    _sock?.close();
    _sock = null;
  }
}

class DiscoveredPhone {
  const DiscoveredPhone({
    required this.address,
    required this.port,
    required this.id,
    required this.name,
  });
  final InternetAddress address;
  final int port;
  final String id;
  final String name;

  @override
  String toString() => '$name (${address.address}:$port)';
}

/// Runs on the PC: finds the phone that shows a code (or a paired phone).
class PcDiscovery {
  PcDiscovery({
    this.port = ControlProtocol.discoveryPort,
    this.beaconListenPort = ControlProtocol.discoveryPort,
    this.listenForBeacons = true,
    this.sweep = true,
    this.queryInterval = const Duration(milliseconds: 800),
    this.targets,
  });

  final int port;
  final int beaconListenPort;
  final bool listenForBeacons;
  final bool sweep;
  final Duration queryInterval;

  /// Override query destinations (tests). Default: LAN broadcast (+ sweep).
  final List<InternetAddress>? targets;

  Future<DiscoveredPhone?> findByCode(
    String code, {
    Duration timeout = const Duration(seconds: 12),
  }) => _find(code: PairingCode.normalize(code), timeout: timeout);

  Future<DiscoveredPhone?> findPaired({
    required String deviceId,
    required String pcId,
    required String key,
    Duration timeout = const Duration(seconds: 10),
  }) => _find(deviceId: deviceId, pcId: pcId, key: key, timeout: timeout);

  Future<DiscoveredPhone?> _find({
    String? code,
    String? deviceId,
    String? pcId,
    String? key,
    required Duration timeout,
  }) async {
    final done = Completer<DiscoveredPhone?>();
    final nonces = <String>{};
    final socks = <RawDatagramSocket>[];

    void handle(Datagram d) {
      if (done.isCompleted) return;
      final m = _decode(d.data);
      if (m == null) return;
      final id = m['id'];
      final port = (m['port'] as num?)?.toInt();
      if (id is! String || port == null || port <= 0 || port > 65535) return;
      final name = m['name'] is String ? m['name'] as String : 'Telefon';
      var ok = false;
      if (m[_magic] == 'r' && nonces.contains(m['n'])) {
        final secret = code ?? key;
        final h = m['h'];
        ok =
            secret != null &&
            h is String &&
            constantTimeEquals(h, hmacHex(secret, 'r|${m['n']}|$id|$port')) &&
            (deviceId == null || id == deviceId);
      } else if (m[_magic] == 'b') {
        final ch = m['ch'];
        final s = m['s'];
        if (code != null) {
          ok = ch is String && s is String && constantTimeEquals(ch, hmacHex(code, 'b|$s'));
        } else {
          // Unauthenticated hint only; the WebSocket key auth verifies it.
          ok = id == deviceId;
        }
      }
      if (ok) {
        done.complete(DiscoveredPhone(address: d.address, port: port, id: id, name: name));
      }
    }

    void listen(RawDatagramSocket s) {
      socks.add(s);
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = s.receive()) != null) {
          handle(d!);
        }
      }, onError: (_) {});
    }

    final q = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    q.broadcastEnabled = true;
    listen(q);
    if (listenForBeacons) {
      try {
        listen(
          await RawDatagramSocket.bind(
            InternetAddress.anyIPv4,
            beaconListenPort,
            reuseAddress: true,
          ),
        );
      } catch (_) {
        // Port busy / blocked: active queries still work.
      }
    }

    final bcast = targets ?? await lanBroadcastTargets();
    final sweepList = targets == null && sweep
        ? await lanSweepTargets()
        : const <InternetAddress>[];
    var round = 0;
    void sendRound() {
      if (done.isCompleted) return;
      final n = randomToken(12);
      nonces.add(n);
      final data = _encode({
        _magic: 'q',
        'v': ControlProtocol.version,
        'n': n,
        if (code != null) 'ch': hmacHex(code, 'q|$n'),
        'id': ?deviceId,
        'pc': ?pcId,
      });
      final dest = [...bcast, if (round % 3 == 1) ...sweepList];
      for (final t in dest) {
        try {
          q.send(data, t, port);
        } catch (_) {}
      }
      round++;
    }

    sendRound();
    final tick = Timer.periodic(queryInterval, (_) => sendRound());
    final limit = Timer(timeout, () {
      if (!done.isCompleted) done.complete(null);
    });
    try {
      return await done.future;
    } finally {
      tick.cancel();
      limit.cancel();
      for (final s in socks) {
        s.close();
      }
    }
  }
}
