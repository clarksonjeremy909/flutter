/// Phone <-> PC control channel (LAN WebSocket, JSON messages).
///
/// Auth: the PC shows a connection code; the phone sends it in the
/// `X-AktifDesk-Token` header. Every request carries an `id` and gets a
/// `result` reply. The PC pushes `afk.status` / `sunshine.status` whenever
/// they change (and on connect).
class ControlProtocol {
  static const version = 1;
  static const defaultPort = 47100;
  static const path = '/aktifdesk';
  static const tokenHeader = 'X-AktifDesk-Token';

  // server -> client
  static const hello = 'hello';
  static const afkStatus = 'afk.status';
  static const sunshineStatus = 'sunshine.status';
  static const result = 'result';

  // client -> server
  static const afkSet = 'afk.set';
  static const afkPing = 'afk.ping';
  static const sunshinePin = 'sunshine.pin';
  static const sunshinePrepare = 'sunshine.prepare';
  static const statusGet = 'status.get';
}

bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}
