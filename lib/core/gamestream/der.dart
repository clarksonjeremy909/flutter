// Minimal ASN.1 DER encoder/decoder: just enough for X.509 certificates and
// RSA keys used by GameStream (Moonlight) pairing.
import 'dart:convert';
import 'dart:typed_data';

class Der {
  static const tagInteger = 0x02;
  static const tagBitString = 0x03;
  static const tagOctetString = 0x04;
  static const tagNull = 0x05;
  static const tagOid = 0x06;
  static const tagUtf8String = 0x0c;
  static const tagUtcTime = 0x17;
  static const tagGeneralizedTime = 0x18;
  static const tagSequence = 0x30;
  static const tagSet = 0x31;

  static Uint8List _len(int n) {
    if (n < 0x80) return Uint8List.fromList([n]);
    final bytes = <int>[];
    var v = n;
    while (v > 0) {
      bytes.insert(0, v & 0xff);
      v >>= 8;
    }
    return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
  }

  static Uint8List tlv(int tag, List<int> value) =>
      Uint8List.fromList([tag, ..._len(value.length), ...value]);

  static Uint8List seq(List<List<int>> items) =>
      tlv(tagSequence, [for (final i in items) ...i]);
  static Uint8List set(List<List<int>> items) =>
      tlv(tagSet, [for (final i in items) ...i]);
  static Uint8List nul() => Uint8List.fromList([tagNull, 0]);
  static Uint8List explicit(int n, List<int> inner) => tlv(0xa0 | n, inner);
  static Uint8List utf8String(String s) => tlv(tagUtf8String, utf8.encode(s));
  static Uint8List bitString(List<int> bytes) => tlv(tagBitString, [0, ...bytes]);
  static Uint8List octetString(List<int> bytes) => tlv(tagOctetString, bytes);

  static Uint8List integer(BigInt v) {
    if (v.isNegative) throw ArgumentError('negative integers unsupported');
    var bytes = bigIntToBytes(v);
    if (bytes.isEmpty) bytes = Uint8List.fromList([0]);
    if (bytes[0] & 0x80 != 0) bytes = Uint8List.fromList([0, ...bytes]);
    return tlv(tagInteger, bytes);
  }

  static Uint8List oid(String dotted) {
    final parts = dotted.split('.').map(int.parse).toList();
    final out = <int>[parts[0] * 40 + parts[1]];
    for (final p in parts.skip(2)) {
      final stack = <int>[p & 0x7f];
      var v = p >> 7;
      while (v > 0) {
        stack.insert(0, 0x80 | (v & 0x7f));
        v >>= 7;
      }
      out.addAll(stack);
    }
    return tlv(tagOid, out);
  }

  static Uint8List time(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final body = '${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
    if (u.year >= 1950 && u.year < 2050) {
      return tlv(tagUtcTime, ascii.encode('${two(u.year % 100)}$body'));
    }
    return tlv(tagGeneralizedTime, ascii.encode('${u.year.toString().padLeft(4, '0')}$body'));
  }

  static Uint8List bigIntToBytes(BigInt v) {
    if (v == BigInt.zero) return Uint8List(0);
    final hex = v.toRadixString(16);
    final padded = hex.length.isOdd ? '0$hex' : hex;
    final out = Uint8List(padded.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(padded.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static BigInt bytesToBigInt(List<int> bytes) {
    var r = BigInt.zero;
    for (final b in bytes) {
      r = (r << 8) | BigInt.from(b);
    }
    return r;
  }
}

/// A decoded DER element.
class DerNode {
  DerNode(this.tag, this.value, this.encoded);
  final int tag;
  final Uint8List value;

  /// Full TLV bytes of this element.
  final Uint8List encoded;

  bool get constructed => tag & 0x20 != 0;

  List<DerNode> get children {
    final out = <DerNode>[];
    var off = 0;
    while (off < value.length) {
      final n = DerNode.parse(value, off);
      out.add(n);
      off += n.encoded.length;
    }
    return out;
  }

  BigInt get asBigInt => Der.bytesToBigInt(value);

  /// BIT STRING contents without the unused-bits prefix byte.
  Uint8List get bitStringBytes => Uint8List.sublistView(value, 1);

  static DerNode parse(Uint8List data, [int offset = 0]) {
    if (offset + 2 > data.length) throw const FormatException('DER: truncated');
    final tag = data[offset];
    var len = data[offset + 1];
    var hdr = 2;
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      if (n == 0 || n > 4) throw const FormatException('DER: bad length');
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | data[offset + 2 + i];
      }
      hdr += n;
    }
    final end = offset + hdr + len;
    if (end > data.length) throw const FormatException('DER: truncated value');
    return DerNode(tag, Uint8List.sublistView(data, offset + hdr, end),
        Uint8List.sublistView(data, offset, end));
  }
}

String pemEncode(String label, List<int> der) {
  final b64 = base64Encode(der);
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
  }
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

Uint8List pemDecode(String pem) {
  final body = pem
      .split(RegExp(r'\r?\n'))
      .where((l) => !l.startsWith('-----') && l.trim().isNotEmpty)
      .join();
  return base64Decode(body);
}
