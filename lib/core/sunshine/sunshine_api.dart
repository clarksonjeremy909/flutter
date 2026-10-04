import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

class SunshineApiException implements Exception {
  SunshineApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  bool get unauthorized => statusCode == 401;
  @override
  String toString() =>
      'SunshineApiException(${statusCode ?? '-'}): $message';
}

class SunshinePendingPairing {
  SunshinePendingPairing({required this.id, required this.name, this.address});
  final String id;
  final String name;
  final String? address;
}

class SunshineClientInfo {
  SunshineClientInfo({required this.uuid, required this.name});
  final String uuid;
  final String name;
}

class SunshineApp {
  SunshineApp({required this.index, required this.name, this.raw = const {}});
  final int index;
  final String name;
  final Map<String, Object?> raw;
}

/// Client for Sunshine's config/Web UI REST API (default
/// `https://localhost:47990`). Uses HTTP Basic auth with the Web UI
/// credentials.
///
/// Sunshine serves a self-signed certificate. We only accept it for loopback
/// hosts, and pin it trust-on-first-use via [pinnedCertSha256] /
/// [onCertificatePinned] so a different certificate is rejected later.
class SunshineApi {
  SunshineApi({
    Uri? baseUri,
    required this.username,
    required this.password,
    this.pinnedCertSha256,
    this.onCertificatePinned,
    this.timeout = const Duration(seconds: 8),
    HttpClient? httpClient,
  }) : baseUri = baseUri ?? Uri.parse('https://localhost:47990') {
    _http = httpClient ?? HttpClient();
    _http.connectionTimeout = timeout;
    _http.badCertificateCallback = _acceptCert;
  }

  final Uri baseUri;
  final String username;
  final String password;
  String? pinnedCertSha256;
  final void Function(String sha256Hex)? onCertificatePinned;
  final Duration timeout;
  late final HttpClient _http;
  String? _csrfToken;

  static bool isLoopback(String host) =>
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host == '[::1]';

  bool _acceptCert(X509Certificate cert, String host, int port) {
    if (!isLoopback(host)) return false;
    final fp = crypto.sha256.convert(cert.der).toString();
    if (pinnedCertSha256 == null) {
      pinnedCertSha256 = fp;
      onCertificatePinned?.call(fp);
      return true;
    }
    return pinnedCertSha256 == fp;
  }

  String get _auth =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  Future<Object?> _request(String method, String path,
      {Object? body, bool needsCsrf = false}) async {
    final uri = baseUri.resolve(path);
    try {
      final req = await _http.openUrl(method, uri).timeout(timeout);
      req.headers.set(HttpHeaders.authorizationHeader, _auth);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (needsCsrf) {
        final token = await _csrf();
        if (token != null) req.headers.set('X-CSRF-Token', token);
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(
          // PIN submission blocks until the Moonlight handshake finishes.
          path.startsWith('/api/pin') ? timeout * 4 : timeout);
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) {
        throw SunshineApiException('Kullanıcı adı/parola hatalı',
            statusCode: 401);
      }
      if (res.statusCode >= 400) {
        throw SunshineApiException(
            text.isEmpty ? 'HTTP ${res.statusCode}' : text,
            statusCode: res.statusCode);
      }
      if (text.isEmpty) return null;
      try {
        return jsonDecode(text);
      } on FormatException {
        return text;
      }
    } on SunshineApiException {
      rethrow;
    } on HandshakeException catch (e) {
      throw SunshineApiException('TLS hatası (sertifika değişmiş olabilir): $e');
    } on SocketException catch (e) {
      throw SunshineApiException('Sunshine API erişilemiyor: ${e.message}');
    } on TimeoutException {
      throw SunshineApiException('Sunshine API zaman aşımı');
    }
  }

  /// Newer Sunshine builds expose a CSRF token endpoint. Requests without
  /// Origin/Referer (like ours) are accepted without it, but we send it when
  /// available for forward compatibility.
  Future<String?> _csrf() async {
    if (_csrfToken != null) return _csrfToken;
    try {
      final r = await _request('GET', '/api/csrf-token');
      if (r is Map && r['csrf_token'] is String) {
        _csrfToken = r['csrf_token'] as String;
      } else if (r is Map && r['token'] is String) {
        _csrfToken = r['token'] as String;
      }
    } catch (_) {}
    return _csrfToken;
  }

  /// Returns true if the API answers with valid credentials.
  Future<bool> ping() async {
    await getConfig();
    return true;
  }

  Future<Map<String, Object?>> getConfig() async {
    final r = await _request('GET', '/api/config');
    if (r is Map) return r.cast<String, Object?>();
    throw SunshineApiException('Beklenmeyen /api/config yanıtı');
  }

  /// Sunshine's POST /api/config REPLACES the whole config file with the
  /// posted keys, so this merges [updates] into the current config first.
  Future<void> updateConfig(Map<String, String?> updates) async {
    final current = await getConfig();
    // Drop read-only/meta fields Sunshine adds to the GET response.
    const meta = {'status', 'platform', 'version', 'restart_supported'};
    final merged = <String, Object?>{
      for (final e in current.entries)
        if (!meta.contains(e.key)) e.key: e.value,
    };
    updates.forEach((k, v) => v == null ? merged.remove(k) : merged[k] = v);
    await _request('POST', '/api/config', body: merged, needsCsrf: true);
  }

  Future<List<SunshineApp>> getApps() async {
    final r = await _request('GET', '/api/apps');
    final apps = (r is Map ? r['apps'] : null) as List? ?? const [];
    return [
      for (var i = 0; i < apps.length; i++)
        SunshineApp(
            index: i,
            name: (apps[i] as Map)['name']?.toString() ?? 'App $i',
            raw: (apps[i] as Map).cast<String, Object?>()),
    ];
  }

  Future<List<SunshineClientInfo>> getClients() async {
    final r = await _request('GET', '/api/clients/list');
    final list = (r is Map ? r['named_certs'] : null) as List? ?? const [];
    return [
      for (final c in list.cast<Map>())
        SunshineClientInfo(
            uuid: c['uuid']?.toString() ?? '', name: c['name']?.toString() ?? '?'),
    ];
  }

  Future<void> unpair(String uuid) =>
      _request('POST', '/api/clients/unpair', body: {'uuid': uuid}, needsCsrf: true);

  /// Pending Moonlight pairing requests (newer Sunshine). Older builds don't
  /// have this endpoint; returns an empty list then.
  Future<List<SunshinePendingPairing>> pendingPairings() async {
    try {
      final r = await _request('GET', '/api/pin');
      final list = (r is Map ? r['pairings'] : null) as List? ?? const [];
      return [
        for (final p in list.cast<Map>())
          SunshinePendingPairing(
            id: p['id'].toString(),
            name: p['name']?.toString() ?? '',
            address: p['address']?.toString(),
          ),
      ];
    } on SunshineApiException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 405 || e.statusCode == 400) {
        return const [];
      }
      rethrow;
    }
  }

  /// Submit the 4-digit PIN shown by the Moonlight client.
  ///
  /// Newer Sunshine requires the `pairing_id` of the pending request; if
  /// [pairingId] is null we pick the newest pending request (optionally
  /// matching [clientAddress]). Older Sunshine only takes `pin` + `name`.
  Future<bool> submitPin(String pin,
      {required String clientName,
      String? pairingId,
      String? clientAddress}) async {
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      throw ArgumentError.value(pin, 'pin', 'PIN 4 haneli olmalı');
    }
    final name = clientName.trim().isEmpty ? 'AktifDesk' : clientName.trim();
    var id = pairingId;
    if (id == null) {
      final pending = await pendingPairings();
      if (pending.isNotEmpty) {
        final match = clientAddress == null
            ? null
            : pending.where((p) => p.address?.contains(clientAddress) ?? false);
        id = (match != null && match.isNotEmpty ? match.last : pending.last).id;
      }
    }
    final body = <String, Object?>{'pin': pin, 'name': name};
    if (id != null) body['pairing_id'] = id;
    final r = await _request('POST', '/api/pin', body: body, needsCsrf: true);
    if (r is Map) return r['status'] == true || r['status'] == 'true';
    return false;
  }

  Future<void> closeApp() =>
      _request('POST', '/api/apps/close', body: const {}, needsCsrf: true);

  Future<void> restart() async {
    try {
      await _request('POST', '/api/restart', body: const {}, needsCsrf: true);
    } on SunshineApiException catch (e) {
      // Sunshine drops the connection while restarting; that's success.
      if (e.statusCode != null) rethrow;
    }
  }

  void close() => _http.close(force: true);
}
