import 'afk_status.dart';

/// Platform hooks used by [AfkScheduler]. Kept tiny so the scheduler logic can
/// be unit-tested with a fake.
abstract class KeepAwakeBackend {
  /// Human readable backend name (shown in the UI).
  String get name;

  /// Whether this backend can actually keep the machine awake.
  bool get isSupported;

  /// Hold the "system + display required" state until [release] is called.
  /// Safe to call repeatedly (re-asserts the state). Throws on failure.
  Future<void> acquire();

  /// Release whatever [acquire] holds. Must be idempotent and never throw.
  Future<void> release();

  /// Send one harmless keep-awake input. Throws on failure.
  Future<void> sendKeepAliveInput(KeepAwakeMethod method);
}

/// Backend for platforms where we cannot (or need not) do anything.
class NoopKeepAwakeBackend implements KeepAwakeBackend {
  const NoopKeepAwakeBackend();
  @override
  String get name => 'Desteklenmiyor';
  @override
  bool get isSupported => false;
  @override
  Future<void> acquire() async =>
      throw UnsupportedError('Bu platformda AFK modu desteklenmiyor');
  @override
  Future<void> release() async {}
  @override
  Future<void> sendKeepAliveInput(KeepAwakeMethod method) async =>
      throw UnsupportedError('Bu platformda AFK modu desteklenmiyor');
}
