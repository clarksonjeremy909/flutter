import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';

import 'afk_status.dart';
import 'keep_awake_backend.dart';

/// Keeps the host awake while enabled:
///
/// * holds the execution state via [KeepAwakeBackend.acquire] (on Windows:
///   `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED |
///   ES_DISPLAY_REQUIRED)`) and re-asserts it on every cycle,
/// * every [interval] (default 2 minutes) sends one harmless keep-awake input
///   so game / Windows idle (AFK) timers reset,
/// * retries failures with exponential backoff (capped at [interval]),
/// * survives sleep/resume and wall-clock jumps because it polls the clock
///   with a short [checkEvery] heartbeat instead of trusting one long timer,
/// * releases everything cleanly on [disable] / [dispose], even if a cycle was
///   in flight when disabling.
///
/// All timing goes through `package:clock` and `dart:async` timers so it can be
/// driven deterministically by `fake_async` in tests.
class AfkScheduler {
  AfkScheduler({
    required this.backend,
    Duration interval = const Duration(minutes: 2),
    KeepAwakeMethod method = KeepAwakeMethod.both,
    this.checkEvery = const Duration(seconds: 5),
    this.retryDelay = const Duration(seconds: 15),
  })  : assert(interval > Duration.zero),
        _status = AfkStatus.initial(method: method, interval: interval);

  final KeepAwakeBackend backend;

  /// Heartbeat granularity. A ping is never later than `interval + checkEvery`.
  final Duration checkEvery;

  /// First retry delay after a failure; doubles per consecutive failure.
  final Duration retryDelay;

  final _controller = StreamController<AfkStatus>.broadcast();
  AfkStatus _status;
  Timer? _heartbeat;
  DateTime? _nextDue;
  bool _cycleRunning = false;
  bool _disposed = false;

  /// Incremented on every enable/disable; stale async work compares against it.
  int _generation = 0;

  /// Serialises enable/disable/pingNow so they never interleave.
  Future<void> _ops = Future.value();

  AfkStatus get status => _status;
  Stream<AfkStatus> get statusStream => _controller.stream;
  bool get enabled => _status.enabled;

  Future<T> _serial<T>(Future<T> Function() op) {
    final result = _ops.then((_) => op());
    _ops = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Turn AFK mode on (or update [method]/[interval] if already on).
  /// Performs the first acquire + ping immediately.
  Future<void> enable({KeepAwakeMethod? method, Duration? interval}) =>
      _serial(() async {
        if (_disposed) throw StateError('AfkScheduler disposed');
        if (interval != null && interval <= Duration.zero) {
          throw ArgumentError.value(interval, 'interval', 'must be positive');
        }
        if (_status.enabled) {
          _emit(_status.copyWith(method: method, interval: interval));
          if (interval != null && _status.lastPingAt != null) {
            _schedule(_status.lastPingAt!.add(interval));
          }
          return;
        }
        _generation++;
        _emit(_status.copyWith(
          phase: AfkPhase.starting,
          method: method,
          interval: interval,
          enabledAt: clock.now(),
          consecutiveFailures: 0,
          clearError: true,
        ));
        _heartbeat?.cancel();
        _heartbeat = Timer.periodic(checkEvery, (_) => _onHeartbeat());
        await _runCycle();
      });

  /// Turn AFK mode off and release the execution state. Idempotent.
  Future<void> disable() => _serial(_disableNow);

  Future<void> _disableNow() async {
    _generation++;
    _heartbeat?.cancel();
    _heartbeat = null;
    _nextDue = null;
    final wasHeld = _status.executionStateHeld || _status.enabled;
    if (wasHeld) {
      await _safeRelease();
    }
    if (_status.enabled || _status.executionStateHeld) {
      _emit(_status.copyWith(
        phase: AfkPhase.off,
        executionStateHeld: false,
        clearNextPing: true,
        clearEnabledAt: true,
        consecutiveFailures: 0,
      ));
    }
  }

  /// Change the keep-awake method without toggling AFK on/off.
  Future<void> setMethod(KeepAwakeMethod method) => _serial(() async {
        if (_status.method != method) _emit(_status.copyWith(method: method));
      });

  /// Force an immediate cycle (re-assert + input) while enabled.
  Future<void> pingNow() => _serial(() async {
        if (!_status.enabled) return;
        await _runCycle();
      });

  Future<void> dispose() async {
    if (_disposed) return;
    await disable();
    _disposed = true;
    await _controller.close();
  }

  void _onHeartbeat() {
    if (!_status.enabled || _cycleRunning || _nextDue == null) return;
    final now = clock.now();
    // Wall clock jumped backwards (or interval shortened): don't wait forever.
    final maxAhead = _status.interval + checkEvery;
    if (_nextDue!.difference(now) > maxAhead) {
      _schedule(now.add(_status.interval));
      return;
    }
    if (!now.isBefore(_nextDue!)) {
      // Run through the serial queue so it never overlaps enable/disable.
      unawaited(_serial(() async {
        if (_status.enabled) await _runCycle();
      }));
    }
  }

  Future<void> _runCycle() async {
    if (_cycleRunning) return;
    _cycleRunning = true;
    final gen = _generation;
    try {
      // 1) (Re-)assert the execution state every cycle.
      try {
        await backend.acquire();
      } catch (e) {
        if (gen != _generation) return;
        final failures = _status.consecutiveFailures + 1;
        final next = clock.now().add(_backoff(failures));
        _schedule(next);
        _emit(_status.copyWith(
          phase: AfkPhase.error,
          executionStateHeld: false,
          consecutiveFailures: failures,
          lastError: 'Uyku engeli alınamadı: $e',
          nextPingAt: next,
        ));
        return;
      }
      if (gen != _generation) {
        // Disabled while acquiring: undo so nothing stays held.
        await _safeRelease();
        return;
      }

      // 2) Harmless input so idle/AFK timers reset.
      final method = _status.method;
      Object? inputError;
      try {
        await backend.sendKeepAliveInput(method);
      } catch (e) {
        inputError = e;
      }
      if (gen != _generation) return;

      final now = clock.now();
      if (inputError == null) {
        final next = now.add(_status.interval);
        _schedule(next);
        _emit(_status.copyWith(
          phase: AfkPhase.active,
          executionStateHeld: true,
          lastPingAt: now,
          lastPingOk: true,
          nextPingAt: next,
          pingCount: _status.pingCount + 1,
          consecutiveFailures: 0,
          clearError: true,
        ));
      } else {
        final failures = _status.consecutiveFailures + 1;
        final next = now.add(_backoff(failures));
        _schedule(next);
        _emit(_status.copyWith(
          phase: AfkPhase.degraded,
          executionStateHeld: true,
          lastPingAt: now,
          lastPingOk: false,
          nextPingAt: next,
          consecutiveFailures: failures,
          lastError: 'Giriş gönderilemedi: $inputError',
        ));
      }
    } finally {
      _cycleRunning = false;
    }
  }

  Duration _backoff(int failures) {
    final factor = math.pow(2, math.min(failures - 1, 16)).toInt();
    final d = retryDelay * factor;
    return d < _status.interval ? d : _status.interval;
  }

  void _schedule(DateTime due) => _nextDue = due;

  Future<void> _safeRelease() async {
    try {
      await backend.release();
    } catch (_) {
      // release() must never break disabling.
    }
  }

  void _emit(AfkStatus s) {
    _status = s;
    if (!_controller.isClosed) _controller.add(s);
  }
}
