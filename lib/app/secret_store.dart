import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cross-platform secret store.
///
/// On Android (and other non-Windows targets) secrets go through
/// flutter_secure_storage (EncryptedSharedPreferences / Android Keystore).
///
/// On Windows AktifDesk stores secrets (LAN control-channel code, Sunshine
/// Web UI password) in SharedPreferences under the `secret.` prefix. That file
/// lives in the current user's profile (%APPDATA%) and is NOT encrypted; it is
/// protected only by the profile's NTFS permissions. This keeps the Windows
/// host free of runtime dependencies on the secure-storage plugin. Moving the
/// Windows path to DPAPI is tracked as a TODO in README.md.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecretStore implements SecretStore {
  PlatformSecretStore([SharedPreferences? prefs]) : _prefs = prefs;

  SharedPreferences? _prefs;
  static const _secure = FlutterSecureStorage();
  static const _prefix = 'secret.';

  Future<SharedPreferences> get _p async => _prefs ??= await SharedPreferences.getInstance();

  bool get _useSecure => !Platform.isWindows;

  @override
  Future<String?> read(String key) async {
    if (_useSecure) return _secure.read(key: key);
    return (await _p).getString('$_prefix$key');
  }

  @override
  Future<void> write(String key, String value) async {
    if (_useSecure) {
      await _secure.write(key: key, value: value);
    } else {
      await (await _p).setString('$_prefix$key', value);
    }
  }

  @override
  Future<void> delete(String key) async {
    if (_useSecure) {
      await _secure.delete(key: key);
    } else {
      await (await _p).remove('$_prefix$key');
    }
  }
}

/// Encode a map for SharedPreferences string storage.
String encodeMap(Map<String, Object?> m) => jsonEncode(m);
Map<String, Object?> decodeMap(String s) =>
    (jsonDecode(s) as Map).cast<String, Object?>();
