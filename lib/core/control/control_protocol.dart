import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Phone <-> PC control channel (LAN WebSocket, JSON messages).
///
/// Since v1.1 the **phone hosts** the control channel and the PC connects to
/// it — the user never types an IP address:
///
/// 1. The phone shows a 6-digit pairing code, listens on UDP
///    [discoveryPort] and periodically broadcasts a beacon.
/// 2. On the PC the user types that code. The PC broadcasts discovery queries
///    (plus a /24 unicast sweep as a fallback) carrying an HMAC of the code;
///    only the phone showing that code answers, with its WebSocket port.
/// 3. The PC opens `ws://<phone>:<port>/aktifdesk` with the code in
///    [tokenHeader] and a fresh random long-term key in [pairKeyHeader].
///    The phone stores that key, so later the PC reconnects automatically
///    (discovery by device id + key auth) without a new code.
///
/// Message semantics are unchanged from v1.0: the PC pushes `hello`,
/// `afk.status`, `sunshine.status`; the phone sends requests with an `id`
/// and gets a `result` reply.
class ControlProtocol {
  static const version = 2;
  static const defaultPort = 47100; // phone WebSocket (TCP), falls back to ephemeral
  static const discoveryPort = 47101; // phone UDP discovery listener
  static const path = '/aktifdesk';

  static const tokenHeader = 'X-AktifDesk-Token';
  static const pcIdHeader = 'X-AktifDesk-Pc-Id';
  static const pcNameHeader = 'X-AktifDesk-Pc-Name';
  static const pairKeyHeader = 'X-AktifDesk-Pair-Key';

  // PC -> phone
  static const hello = 'hello';
  static const afkStatus = 'afk.status';
  static const sunshineStatus = 'sunshine.status';
  static const result = 'result';

  // phone -> PC
  static const afkSet = 'afk.set';
  static const afkPing = 'afk.ping';
  static const sunshinePin = 'sunshine.pin';
  static const sunshinePrepare = 'sunshine.prepare';
  static const statusGet = 'status.get';
}

/// 6-digit numeric pairing codes shown on the phone and typed on the PC.
class PairingCode {
  static const length = 6;

  static String generate([Random? random]) {
    final r = random ?? Random.secure();
    return List.generate(length, (_) => r.nextInt(10)).join();
  }

  /// Strips spaces, dashes etc. (`"482 913"` -> `"482913"`).
  static String normalize(String input) => input.replaceAll(RegExp(r'[^0-9]'), '');

  static bool isValid(String input) => normalize(input).length == length;

  /// `"482913"` -> `"482 913"` for display.
  static String format(String code) =>
      code.length == length ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
}

/// Truncated hex HMAC-SHA256, used for discovery proofs.
String hmacHex(String secret, String message, {int length = 16}) {
  final d = Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(message));
  return d.toString().substring(0, length);
}

String randomToken([int bytes = 32]) {
  final r = Random.secure();
  return base64Url.encode(List<int>.generate(bytes, (_) => r.nextInt(256))).replaceAll('=', '');
}

bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}
