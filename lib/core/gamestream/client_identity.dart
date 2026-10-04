import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'der.dart';
import 'pairing_crypto.dart';

/// The client's identity for GameStream: a 2048-bit RSA key and a
/// self-signed X.509 certificate (same shape Moonlight uses), plus a
/// stable unique id.
class ClientIdentity {
  ClientIdentity({
    required this.uniqueId,
    required this.certPem,
    required this.privateKeyPem,
  })  : cert = X509Info.fromPem(certPem),
        privateKey = _parsePkcs1(pemDecode(privateKeyPem));

  final String uniqueId;
  final String certPem;
  final String privateKeyPem;
  final X509Info cert;
  final RSAPrivateKey privateKey;

  Map<String, String> toJson() =>
      {'uniqueId': uniqueId, 'certPem': certPem, 'privateKeyPem': privateKeyPem};

  factory ClientIdentity.fromJson(Map<String, Object?> j) => ClientIdentity(
        uniqueId: j['uniqueId'] as String,
        certPem: j['certPem'] as String,
        privateKeyPem: j['privateKeyPem'] as String,
      );

  /// Generates a new identity in a background isolate (RSA keygen is slow).
  static Future<ClientIdentity> generate({String commonName = 'NVIDIA GameStream Client'}) async {
    final m = await Isolate.run(() => _generateSync(commonName));
    return ClientIdentity.fromJson(m);
  }

  static Map<String, String> generateSyncForTest({int bits = 1024}) =>
      _generateSync('NVIDIA GameStream Client', bits: bits);

  static Map<String, String> _generateSync(String cn, {int bits = 2048}) {
    final rnd = Random.secure();
    final seed = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
    final secure = FortunaRandom()..seed(KeyParameter(seed));
    final gen = RSAKeyGenerator()
      ..init(ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64), secure));
    final pair = gen.generateKeyPair();
    final pub = pair.publicKey;
    final priv = pair.privateKey;

    final sigAlg = Der.seq([Der.oid('1.2.840.113549.1.1.11'), Der.nul()]);
    final name = Der.seq([
      Der.set([
        Der.seq([Der.oid('2.5.4.3'), Der.utf8String(cn)])
      ])
    ]);
    final now = DateTime.now().toUtc();
    final spki = Der.seq([
      Der.seq([Der.oid('1.2.840.113549.1.1.1'), Der.nul()]),
      Der.bitString(Der.seq([Der.integer(pub.modulus!), Der.integer(pub.exponent!)])),
    ]);
    final serial = Der.bytesToBigInt(
        [0x01, ...List.generate(8, (_) => rnd.nextInt(256))]);
    final tbs = Der.seq([
      Der.explicit(0, Der.integer(BigInt.two)), // v3
      Der.integer(serial),
      sigAlg,
      name,
      Der.seq([
        Der.time(now.subtract(const Duration(days: 1))),
        Der.time(DateTime.utc(now.year + 20, now.month, 1)),
      ]),
      name,
      spki,
    ]);
    final sig = rsaSha256Sign(priv, tbs);
    final cert = Der.seq([tbs, sigAlg, Der.bitString(sig)]);

    final p = priv.p!, q = priv.q!, d = priv.privateExponent!;
    final pkcs1 = Der.seq([
      Der.integer(BigInt.zero),
      Der.integer(priv.modulus!),
      Der.integer(pub.exponent!),
      Der.integer(d),
      Der.integer(p),
      Der.integer(q),
      Der.integer(d % (p - BigInt.one)),
      Der.integer(d % (q - BigInt.one)),
      Der.integer(q.modInverse(p)),
    ]);
    final uid = List.generate(8, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return {
      'uniqueId': uid,
      'certPem': pemEncode('CERTIFICATE', cert),
      'privateKeyPem': pemEncode('RSA PRIVATE KEY', pkcs1),
    };
  }

  static RSAPrivateKey _parsePkcs1(Uint8List der) {
    final c = DerNode.parse(der).children;
    return RSAPrivateKey(c[1].asBigInt, c[3].asBigInt, c[4].asBigInt, c[5].asBigInt);
  }
}
