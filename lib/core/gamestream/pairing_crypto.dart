// Crypto primitives of the GameStream pairing handshake (as implemented by
// Sunshine / Moonlight, "gen 7+" = SHA-256 variant).
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

import 'der.dart';

Uint8List sha256(List<int> data) =>
    Uint8List.fromList(crypto.sha256.convert(data).bytes);

Uint8List randomBytes(int n, [Random? rng]) {
  final r = rng ?? Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

/// AES-128 key = first 16 bytes of SHA-256(salt || pin).
Uint8List pairingAesKey(Uint8List salt, String pin) =>
    Uint8List.sublistView(sha256([...salt, ...pin.codeUnits]), 0, 16);

Uint8List _aesEcb(Uint8List key, Uint8List data, bool encrypt) {
  if (data.length % 16 != 0) {
    // GameStream pads with zeros to the block size.
    data = Uint8List.fromList([...data, ...List.filled(16 - data.length % 16, 0)]);
  }
  final c = ECBBlockCipher(AESEngine())..init(encrypt, KeyParameter(key));
  final out = Uint8List(data.length);
  for (var off = 0; off < data.length; off += 16) {
    c.processBlock(data, off, out, off);
  }
  return out;
}

Uint8List aesEcbEncrypt(Uint8List key, Uint8List data) => _aesEcb(key, data, true);
Uint8List aesEcbDecrypt(Uint8List key, Uint8List data) => _aesEcb(key, data, false);

Uint8List rsaSha256Sign(RSAPrivateKey key, Uint8List data) {
  final s = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(key));
  return s.generateSignature(data).bytes;
}

bool rsaSha256Verify(RSAPublicKey key, Uint8List data, Uint8List signature) {
  final s = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(false, PublicKeyParameter<RSAPublicKey>(key));
  try {
    return s.verifySignature(data, RSASignature(signature));
  } catch (_) {
    return false;
  }
}

/// Parsed X.509 certificate pieces needed for pairing.
class X509Info {
  X509Info(this.der, this.signature, this.publicKey);
  final Uint8List der;

  /// The certificate's signatureValue (what Sunshine calls `signature(x509)`).
  final Uint8List signature;
  final RSAPublicKey publicKey;

  factory X509Info.fromPem(String pem) => X509Info.fromDer(pemDecode(pem));

  factory X509Info.fromDer(Uint8List der) {
    final cert = DerNode.parse(der).children;
    final tbs = cert[0].children;
    final sig = cert[2].bitStringBytes;
    // tbs: [0]version? serial sigAlg issuer validity subject spki ...
    final start = tbs[0].tag == 0xa0 ? 1 : 0;
    final spki = tbs[start + 5].children;
    final rsa = DerNode.parse(spki[1].bitStringBytes).children;
    return X509Info(der, Uint8List.fromList(sig),
        RSAPublicKey(rsa[0].asBigInt, rsa[1].asBigInt));
  }
}
