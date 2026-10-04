// Moonlight / GameStream protocol client (control plane) in pure Dart:
// server discovery info, PIN pairing, app list, launch/resume/quit.
//
// The media plane (RTSP/ENet/RTP video+audio+input) is handled by the
// Moonlight engine on the device (see MoonlightClientEngine), because it
// needs native hardware decoding.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'client_identity.dart';
import 'pairing_crypto.dart';

class GameStreamException implements Exception {
  GameStreamException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'GameStreamException(${statusCode ?? '-'}): $message';
}

/// Low-level request hook (lets tests plug in a fake Sunshine).
abstract class GameStreamTransport {
  Future<String> get(Uri uri, {required bool https, Duration? timeout});
  void close();
}

class IoGameStreamTransport implements GameStreamTransport {
  IoGameStreamTransport(this.identity, {this.pinnedServerCertDer});
  final ClientIdentity identity;

  /// Server certificate (from pairing). HTTPS requests are only accepted if
  /// the server presents exactly this certificate.
  Uint8List? pinnedServerCertDer;
  HttpClient? _plain;
  HttpClient? _tls;

  HttpClient get _plainClient => _plain ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);

  HttpClient get _tlsClient {
    if (_tls != null) return _tls!;
    final ctx = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certPem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
    return _tls = HttpClient(context: ctx)
      ..connectionTimeout = const Duration(seconds: 5)
      ..badCertificateCallback = (cert, host, port) {
        final pinned = pinnedServerCertDer;
        if (pinned == null) return false;
        final der = cert.der;
        if (der.length != pinned.length) return false;
        for (var i = 0; i < der.length; i++) {
          if (der[i] != pinned[i]) return false;
        }
        return true;
      };
  }

  @override
  Future<String> get(Uri uri, {required bool https, Duration? timeout}) async {
    final client = https ? _tlsClient : _plainClient;
    final t = timeout ?? const Duration(seconds: 10);
    try {
      final req = await client.getUrl(uri).timeout(t);
      final res = await req.close().timeout(t);
      final body = await res.transform(utf8.decoder).join().timeout(t);
      if (res.statusCode != 200) {
        throw GameStreamException('HTTP ${res.statusCode}', statusCode: res.statusCode);
      }
      return body;
    } on SocketException catch (e) {
      throw GameStreamException('Bağlantı hatası: ${e.message}');
    } on HandshakeException catch (e) {
      throw GameStreamException('TLS hatası: $e');
    } on TimeoutException {
      throw GameStreamException('Zaman aşımı');
    }
  }

  @override
  void close() {
    _plain?.close(force: true);
    _tls?.close(force: true);
  }
}

class ServerInfo {
  ServerInfo(this.fields);
  final Map<String, String> fields;
  String get hostname => fields['hostname'] ?? '?';
  String get uuid => fields['uniqueid'] ?? '';
  String get appVersion => fields['appversion'] ?? '';
  String? get gfeVersion => fields['GfeVersion'];
  bool get paired => fields['PairStatus'] == '1';
  int get currentGame => int.tryParse(fields['currentgame'] ?? '0') ?? 0;
  int get httpsPort => int.tryParse(fields['HttpsPort'] ?? '') ?? 47984;
  String? get mac => fields['mac'];
  String? get state => fields['state'];
  bool get isSunshine => fields.containsKey('SunshineVersion') ||
      (gfeVersion?.contains('3.23.0.74') ?? false) ||
      appVersion.startsWith('7.1.4');
}

class GameStreamApp {
  GameStreamApp({required this.id, required this.title, this.hdr = false});
  final int id;
  final String title;
  final bool hdr;
}

class LaunchResult {
  LaunchResult({required this.sessionUrl, required this.riKey, required this.riKeyId});
  final String sessionUrl;
  final Uint8List riKey;
  final int riKeyId;
}

class StreamSettings {
  const StreamSettings({
    this.width = 1920,
    this.height = 1080,
    this.fps = 60,
    this.playAudioOnHost = false,
    this.surroundAudioInfo = 196610, // stereo
    this.hdr = false,
  });
  final int width, height, fps;
  final bool playAudioOnHost;
  final int surroundAudioInfo;
  final bool hdr;
}

enum PairingStep { serverCert, clientChallenge, serverChallenge, clientSecret, httpsChallenge, done }

class GameStreamClient {
  GameStreamClient({
    required this.host,
    required this.identity,
    this.httpPort = 47989,
    this.httpsPort = 47984,
    this.deviceName = 'roth',
    GameStreamTransport? transport,
    Uint8List? serverCertDer,
    Random? random,
  })  : _rng = random ?? Random.secure(),
        _serverCertDer = serverCertDer {
    this.transport = transport ??
        IoGameStreamTransport(identity, pinnedServerCertDer: serverCertDer);
  }

  final String host;
  final ClientIdentity identity;
  final int httpPort;
  int httpsPort;
  final String deviceName;
  late final GameStreamTransport transport;
  final Random _rng;
  Uint8List? _serverCertDer;

  Uint8List? get serverCertDer => _serverCertDer;

  String _uuid() => List.generate(16, (_) => _rng.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  static String hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List unhex(String s) {
    final t = s.trim();
    if (t.length.isOdd) throw const FormatException('odd hex');
    return Uint8List.fromList([
      for (var i = 0; i < t.length; i += 2) int.parse(t.substring(i, i + 2), radix: 16)
    ]);
  }

  Uri _uri(String path, Map<String, String> q, {required bool https}) => Uri(
        scheme: https ? 'https' : 'http',
        host: host,
        port: https ? httpsPort : httpPort,
        path: path,
        queryParameters: {'uniqueid': identity.uniqueId, 'uuid': _uuid(), ...q},
      );

  /// Performs a request and returns the children of `<root>` as a map of
  /// first-occurrence text values, throwing on non-200 status_code.
  Future<XmlElement> _call(String path, Map<String, String> q,
      {required bool https, Duration? timeout}) async {
    final body = await transport.get(_uri(path, q, https: https),
        https: https, timeout: timeout);
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(body);
    } on XmlException catch (e) {
      throw GameStreamException('Geçersiz XML: ${e.message}');
    }
    final root = doc.rootElement;
    final code = int.tryParse(root.getAttribute('status_code') ?? '200') ?? 200;
    if (code != 200) {
      throw GameStreamException(root.getAttribute('status_message') ?? 'Hata $code',
          statusCode: code);
    }
    return root;
  }

  static Map<String, String> _fields(XmlElement root) {
    final m = <String, String>{};
    for (final c in root.childElements) {
      m.putIfAbsent(c.name.local, () => c.innerText);
    }
    return m;
  }

  Future<ServerInfo> serverInfo() async {
    XmlElement root;
    if (_serverCertDer != null) {
      try {
        root = await _call('/serverinfo', const {}, https: true);
        return ServerInfo(_fields(root));
      } on GameStreamException {
        // fall back to plain HTTP (e.g. we were unpaired on the host)
      }
    }
    root = await _call('/serverinfo', const {}, https: false);
    final info = ServerInfo(_fields(root));
    httpsPort = info.httpsPort;
    return info;
  }

  /// Full GameStream PIN pairing. [onPin] is called with the PIN right
  /// before the server starts waiting for it, so the caller can show it or
  /// forward it to the host (AktifDesk PC app submits it to Sunshine's
  /// /api/pin automatically).
  Future<Uint8List> pair({
    String? pin,
    FutureOr<void> Function(String pin)? onPin,
    void Function(PairingStep step)? onStep,
    Duration pinTimeout = const Duration(minutes: 3),
  }) async {
    final thePin = pin ?? _rng.nextInt(10000).toString().padLeft(4, '0');
    final salt = randomBytes(16, _rng);
    final key = pairingAesKey(salt, thePin);
    Future<Map<String, String>> step(Map<String, String> q,
        {bool https = false, Duration? timeout}) async {
      final f = _fields(await _call('/pair',
          {'devicename': deviceName, 'updateState': '1', ...q},
          https: https, timeout: timeout));
      if (f['paired'] != '1') {
        throw GameStreamException('Eşleştirme reddedildi (yanlış PIN veya iptal)');
      }
      return f;
    }

    try {
      onStep?.call(PairingStep.serverCert);
      final certFuture = step({
        'phrase': 'getservercert',
        'salt': hex(salt),
        'clientcert': hex(utf8.encode(identity.certPem)),
      }, timeout: pinTimeout);
      if (onPin != null) {
        // Fire-and-forget: the server request above blocks until the PIN is
        // entered, so we must not await it before delivering the PIN.
        unawaited(Future.sync(() => onPin(thePin)).catchError((_) {}));
      }
      final r1 = await certFuture;
      final plain = r1['plaincert'];
      if (plain == null || plain.isEmpty) {
        throw GameStreamException('Sunucu zaten başka bir eşleştirmede');
      }
      final serverCert = X509Info.fromPem(utf8.decode(unhex(plain)));

      onStep?.call(PairingStep.clientChallenge);
      final clientChallenge = randomBytes(16, _rng);
      final r2 = await step({'clientchallenge': hex(aesEcbEncrypt(key, clientChallenge))});
      final dec = aesEcbDecrypt(key, unhex(r2['challengeresponse'] ?? ''));
      if (dec.length < 48) throw GameStreamException('Kısa challengeresponse');
      final serverResponse = Uint8List.sublistView(dec, 0, 32);
      final serverChallenge = Uint8List.sublistView(dec, 32, 48);

      onStep?.call(PairingStep.serverChallenge);
      final clientSecret = randomBytes(16, _rng);
      final challengeHash =
          sha256([...serverChallenge, ...identity.cert.signature, ...clientSecret]);
      final r3 = await step({'serverchallengeresp': hex(aesEcbEncrypt(key, challengeHash))});
      final ps = unhex(r3['pairingsecret'] ?? '');
      if (ps.length <= 16) throw GameStreamException('Kısa pairingsecret');
      final serverSecret = Uint8List.sublistView(ps, 0, 16);
      final serverSig = Uint8List.sublistView(ps, 16);
      if (!rsaSha256Verify(serverCert.publicKey, serverSecret, serverSig)) {
        throw GameStreamException('Sunucu imzası doğrulanamadı (MITM?)');
      }
      final expected =
          sha256([...clientChallenge, ...serverCert.signature, ...serverSecret]);
      if (!_eq(expected, serverResponse)) {
        throw GameStreamException('Yanlış PIN');
      }

      onStep?.call(PairingStep.clientSecret);
      final sig = rsaSha256Sign(identity.privateKey, clientSecret);
      await step({'clientpairingsecret': hex([...clientSecret, ...sig])});

      onStep?.call(PairingStep.httpsChallenge);
      _setServerCert(serverCert.der);
      await step({'phrase': 'pairchallenge'}, https: true);
      onStep?.call(PairingStep.done);
      return serverCert.der;
    } catch (e) {
      try {
        await _call('/unpair', const {}, https: false);
      } catch (_) {}
      rethrow;
    }
  }

  void _setServerCert(Uint8List der) {
    _serverCertDer = der;
    final t = transport;
    if (t is IoGameStreamTransport) t.pinnedServerCertDer = der;
  }

  Future<List<GameStreamApp>> appList() async {
    final root = await _call('/applist', const {}, https: true);
    return [
      for (final a in root.findElements('App'))
        GameStreamApp(
          id: int.tryParse(a.getElement('ID')?.innerText ?? '') ?? 0,
          title: a.getElement('AppTitle')?.innerText ?? '?',
          hdr: a.getElement('IsHdrSupported')?.innerText == '1',
        ),
    ];
  }

  Map<String, String> _streamParams(StreamSettings s, Uint8List riKey, int riKeyId) => {
        'mode': '${s.width}x${s.height}x${s.fps}',
        'additionalStates': '1',
        'sops': '1',
        'rikey': hex(riKey),
        'rikeyid': '$riKeyId',
        'localAudioPlayMode': s.playAudioOnHost ? '1' : '0',
        'surroundAudioInfo': '${s.surroundAudioInfo}',
        'remoteControllersBitmap': '1',
        'gcmap': '1',
        if (s.hdr) 'hdrMode': '1',
      };

  Future<LaunchResult> launch(int appId, {StreamSettings settings = const StreamSettings()}) async {
    final riKey = randomBytes(16, _rng);
    final riKeyId = _rng.nextInt(1 << 31);
    final f = _fields(await _call('/launch',
        {'appid': '$appId', ..._streamParams(settings, riKey, riKeyId)},
        https: true, timeout: const Duration(seconds: 30)));
    final url = f['sessionUrl0'];
    if (f['gamesession'] == '0' || url == null) {
      throw GameStreamException('Uygulama başlatılamadı');
    }
    return LaunchResult(sessionUrl: url, riKey: riKey, riKeyId: riKeyId);
  }

  Future<LaunchResult> resume({StreamSettings settings = const StreamSettings()}) async {
    final riKey = randomBytes(16, _rng);
    final riKeyId = _rng.nextInt(1 << 31);
    final f = _fields(await _call('/resume', _streamParams(settings, riKey, riKeyId),
        https: true, timeout: const Duration(seconds: 30)));
    final url = f['sessionUrl0'];
    if (f['resume'] == '0' || url == null) {
      throw GameStreamException('Oturum sürdürülemedi');
    }
    return LaunchResult(sessionUrl: url, riKey: riKey, riKeyId: riKeyId);
  }

  Future<void> quitApp() async {
    final f = _fields(await _call('/cancel', const {}, https: true));
    if (f['cancel'] == '0') throw GameStreamException('Uygulama kapatılamadı');
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a[i] ^ b[i];
    }
    return r == 0;
  }

  void close() => transport.close();
}
