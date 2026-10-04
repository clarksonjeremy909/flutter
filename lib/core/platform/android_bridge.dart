import 'dart:io';

import 'package:flutter/services.dart';

/// Android-only native helpers (see MainActivity.kt).
class AndroidBridge {
  static const _ch = MethodChannel('aktifdesk/native');

  static bool get supported => Platform.isAndroid;

  /// Installed Moonlight package (com.limelight / .debug / root), or null.
  static Future<String?> moonlightPackage() async {
    if (!supported) return null;
    return _ch.invokeMethod<String>('moonlightPackage');
  }

  /// Start a stream in Moonlight for an already-paired host/app.
  static Future<bool> launchMoonlight({
    required String pcUuid,
    String? pcName,
    int? appId,
    String? appName,
  }) async {
    if (!supported) return false;
    return await _ch.invokeMethod<bool>('launchMoonlight', {
          'uuid': pcUuid,
          'pcName': pcName,
          'appId': appId?.toString(),
          'appName': appName,
        }) ??
        false;
  }

  static Future<void> openMoonlight() async {
    if (!supported) return;
    await _ch.invokeMethod('openMoonlight');
  }

  static Future<void> openMoonlightStore() async {
    if (!supported) return;
    await _ch.invokeMethod('openStore', {'package': 'com.limelight'});
  }

  /// Keep the phone screen on (used while remotely holding AFK mode).
  static Future<void> setKeepScreenOn(bool on) async {
    if (!supported) return;
    await _ch.invokeMethod('keepScreenOn', {'on': on});
  }
}
