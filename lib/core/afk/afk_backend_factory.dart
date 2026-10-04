import 'dart:io';

import 'keep_awake_backend.dart';
import 'windows_keep_awake_backend.dart';

KeepAwakeBackend createPlatformKeepAwakeBackend() {
  if (Platform.isWindows) return WindowsKeepAwakeBackend();
  return const NoopKeepAwakeBackend();
}
