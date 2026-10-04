import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aktifdesk/core/gamestream/client_identity.dart';
import 'package:aktifdesk/core/gamestream/gamestream_client.dart';
import 'package:aktifdesk/core/gamestream/pairing_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

String _hex(List<int> b) => GameStreamClient.hex(b);
Uint8List _unhex(String s) => GameStreamClient.unhex(s);

/// Server half of the GameStream pairing protocol, mirroring Sunshine's
/// nvhttp.cpp, used to verify our client end-to-end.
class FakeSunshine implements GameStreamTransport {
  FakeSunshine(this.serverId, this.hostPin);
  final ClientIdentity serverId;
  final String hostPin; // PIN the "user" types on the host
  String? pinFromClient;
  Uint8List? key, serverSecret, serverChallenge, clientHash;
  X509Info? clientCert;
  bool paired = false;
  final calls = <String>[];

  String ok(Map<String, String> f) =>
      '<root status_code="200">${f.entries.map((e) => '<${e.key}>${e.value}</${e.key}>').join()}</root>';

  @override
  Future<String> get(Uri uri, {required bool https, Duration? timeout}) async {
    final q = uri.queryParameters;
    calls.add('${https ? 'https' : 'http'}:${uri.path}:${q['phrase'] ?? q.keys.lastWhere((k) => k != 'uuid' && k != 'uniqueid' && k != 'devicename' && k != 'updateState', orElse: () => '')}');
    if (uri.path == '/unpair') {
      paired = false;
      return ok({});
    }
    if (uri.path == '/serverinfo') {
      return ok({'hostname': 'PC', 'uniqueid': 'abc', 'appversion': '7.1.431.-1', 'PairStatus': paired && https ? '1' : '0', 'HttpsPort': '47984'});
    }
    if (uri.path != '/pair') return '<root status_code="404"/>';
    if (q['phrase'] == 'getservercert') {
      clientCert = X509Info.fromPem(utf8.decode(_unhex(q['clientcert']!)));
      key = pairingAesKey(_unhex(q['salt']!), hostPin);
      return ok({'paired': '1', 'plaincert': _hex(utf8.encode(serverId.certPem))});
    }
    if (q.containsKey('clientchallenge')) {
      final ch = aesEcbDecrypt(key!, _unhex(q['clientchallenge']!));
      serverSecret = randomBytes(16);
      serverChallenge = randomBytes(16);
      final hash = sha256([...ch, ...serverId.cert.signature, ...serverSecret!]);
      return ok({'paired': '1', 'challengeresponse': _hex(aesEcbEncrypt(key!, Uint8List.fromList([...hash, ...serverChallenge!])))});
    }
    if (q.containsKey('serverchallengeresp')) {
      clientHash = aesEcbDecrypt(key!, _unhex(q['serverchallengeresp']!));
      final sig = rsaSha256Sign(serverId.privateKey, serverSecret!);
      return ok({'paired': '1', 'pairingsecret': _hex([...serverSecret!, ...sig])});
    }
    if (q.containsKey('clientpairingsecret')) {
      final b = _unhex(q['clientpairingsecret']!);
      final secret = Uint8List.sublistView(b, 0, 16);
      final sig = Uint8List.sublistView(b, 16);
      final hash = sha256([...serverChallenge!, ...clientCert!.signature, ...secret]);
      final same = _hex(hash) == _hex(clientHash!);
      final verify = rsaSha256Verify(clientCert!.publicKey, secret, sig);
      paired = same && verify;
      return ok({'paired': paired ? '1' : '0'});
    }
    if (q['phrase'] == 'pairchallenge') {
      return ok({'paired': (https && paired) ? '1' : '0'});
    }
    return '<root status_code="400"/>';
  }

  @override
  void close() {}
}

void main() {
  late ClientIdentity client, server;
  setUpAll(() {
    client = ClientIdentity.fromJson(ClientIdentity.generateSyncForTest());
    server = ClientIdentity.fromJson(ClientIdentity.generateSyncForTest());
  });

  test('generated identity: cert parses and signature verifies', () {
    final c = client.cert;
    expect(c.signature, isNotEmpty);
    final data = Uint8List.fromList([1, 2, 3]);
    final sig = rsaSha256Sign(client.privateKey, data);
    expect(rsaSha256Verify(c.publicKey, data, sig), isTrue);
    expect(client.uniqueId, hasLength(16));
  });

  test('generated cert/key are accepted by openssl and dart:io TLS', () async {
    final ctx = SecurityContext(withTrustedRoots: false);
    ctx.useCertificateChainBytes(utf8.encode(client.certPem));
    ctx.usePrivateKeyBytes(utf8.encode(client.privateKeyPem));
    final which = await Process.run('which', ['openssl']);
    if (which.exitCode != 0) return;
    final dir = await Directory.systemTemp.createTemp('gs');
    final f = File('${dir.path}/c.pem')..writeAsStringSync(client.certPem);
    final r = await Process.run('openssl', ['verify', '-CAfile', f.path, f.path]);
    expect(r.stdout.toString(), contains('OK'), reason: '${r.stderr}');
    await dir.delete(recursive: true);
  });

  test('AES-ECB round trip and key derivation', () {
    final key = pairingAesKey(Uint8List(16), '1234');
    expect(key, hasLength(16));
    final data = randomBytes(48);
    expect(aesEcbDecrypt(key, aesEcbEncrypt(key, data)), data);
  });

  test('full pairing handshake against fake Sunshine succeeds', () async {
    final fake = FakeSunshine(server, '4821');
    final gs = GameStreamClient(host: 'pc', identity: client, transport: fake);
    String? shown;
    final steps = <PairingStep>[];
    final der = await gs.pair(pin: '4821', onPin: (p) => shown = p, onStep: steps.add);
    expect(shown, '4821');
    expect(fake.paired, isTrue);
    expect(der, server.cert.der);
    expect(gs.serverCertDer, server.cert.der);
    expect(steps.last, PairingStep.done);
    expect(fake.calls.last, 'https:/pair:pairchallenge');
  });

  test('wrong PIN is detected and the client unpairs', () async {
    final fake = FakeSunshine(server, '0000');
    final gs = GameStreamClient(host: 'pc', identity: client, transport: fake);
    await expectLater(gs.pair(pin: '4821'), throwsA(isA<GameStreamException>()));
    expect(fake.paired, isFalse);
    expect(fake.calls.last, contains('/unpair'));
  });

  test('generated PIN is 4 digits', () async {
    final fake = FakeSunshine(server, 'xxxx');
    final gs = GameStreamClient(host: 'pc', identity: client, transport: fake);
    String? pin;
    await expectLater(gs.pair(onPin: (p) => pin = p), throwsA(anything));
    expect(pin, matches(RegExp(r'^\d{4}$')));
  });

  test('serverinfo parsing', () async {
    final fake = FakeSunshine(server, '1');
    final gs = GameStreamClient(host: 'pc', identity: client, transport: fake);
    final info = await gs.serverInfo();
    expect(info.hostname, 'PC');
    expect(info.paired, isFalse);
    expect(info.httpsPort, 47984);
  });
}
