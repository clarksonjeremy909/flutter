import 'dart:async';
import 'dart:ffi';

import 'package:aktifdesk/core/afk/afk_scheduler.dart';
import 'package:aktifdesk/core/afk/afk_status.dart';
import 'package:aktifdesk/core/afk/windows_keep_awake_backend.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_backend.dart';

void main() {
  late FakeKeepAwakeBackend backend;
  setUp(() => backend = FakeKeepAwakeBackend());

  AfkScheduler make({Duration interval = const Duration(minutes: 2)}) =>
      AfkScheduler(
        backend: backend,
        interval: interval,
        checkEvery: const Duration(seconds: 5),
        retryDelay: const Duration(seconds: 15),
      );

  test('starts off and holds nothing', () {
    final s = make();
    expect(s.status.phase, AfkPhase.off);
    expect(s.status.executionStateHeld, isFalse);
    expect(backend.calls, isEmpty);
  });

  test('enable acquires execution state and pings immediately', () {
    fakeAsync((async) {
      final s = make();
      s.enable();
      async.flushMicrotasks();
      expect(backend.calls, ['acquire', 'input']);
      expect(backend.held, isTrue);
      expect(s.status.phase, AfkPhase.active);
      expect(s.status.executionStateHeld, isTrue);
      expect(s.status.pingCount, 1);
      expect(s.status.lastPingOk, isTrue);
      expect(s.status.lastPingAt, clock.now());
      expect(s.status.nextPingAt, clock.now().add(const Duration(minutes: 2)));
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('pings every 2 minutes (within heartbeat granularity)', () {
    fakeAsync((async) {
      final start = clock.now();
      final s = make();
      s.enable();
      async.elapse(const Duration(minutes: 10, seconds: 1));
      expect(backend.inputTimes.length, 6); // t=0,2,4,6,8,10
      for (var i = 0; i < backend.inputTimes.length; i++) {
        final offset = backend.inputTimes[i].difference(start);
        expect(offset, greaterThanOrEqualTo(Duration(minutes: 2 * i)));
        expect(offset,
            lessThanOrEqualTo(Duration(minutes: 2 * i, seconds: 5 * i)));
      }
      // Never two pings closer than the interval.
      for (var i = 1; i < backend.inputTimes.length; i++) {
        expect(backend.inputTimes[i].difference(backend.inputTimes[i - 1]),
            greaterThanOrEqualTo(const Duration(minutes: 2)));
      }
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('re-asserts execution state on every cycle', () {
    fakeAsync((async) {
      final s = make();
      s.enable();
      async.elapse(const Duration(minutes: 4, seconds: 10));
      expect(backend.calls.where((c) => c == 'acquire').length, 3);
      expect(backend.calls, ['acquire', 'input', 'acquire', 'input', 'acquire', 'input']);
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('disable releases cleanly and stops pinging', () {
    fakeAsync((async) {
      final s = make();
      s.enable();
      async.elapse(const Duration(minutes: 3));
      final pingsBefore = backend.inputTimes.length;
      s.disable();
      async.flushMicrotasks();
      expect(backend.calls.last, 'release');
      expect(backend.held, isFalse);
      expect(s.status.phase, AfkPhase.off);
      expect(s.status.executionStateHeld, isFalse);
      expect(s.status.nextPingAt, isNull);
      // Last ping time stays visible after disabling.
      expect(s.status.lastPingAt, isNotNull);
      async.elapse(const Duration(minutes: 20));
      expect(backend.inputTimes.length, pingsBefore);
      expect(async.periodicTimerCount, 0);
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('disable is idempotent and does not release when never enabled', () {
    fakeAsync((async) {
      final s = make();
      s.disable();
      s.disable();
      async.flushMicrotasks();
      expect(backend.calls, isEmpty);
      s.enable();
      async.flushMicrotasks();
      s.disable();
      s.disable();
      async.flushMicrotasks();
      expect(backend.calls.where((c) => c == 'release').length, 1);
    });
  });

  test('enable twice does not double-acquire or start a second timer', () {
    fakeAsync((async) {
      final s = make();
      s.enable();
      s.enable();
      async.flushMicrotasks();
      expect(backend.calls, ['acquire', 'input']);
      expect(async.periodicTimerCount, 1);
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('input failure -> degraded, retried with backoff, recovers', () {
    fakeAsync((async) {
      backend.failInputTimes = 2;
      final s = make();
      s.enable();
      async.flushMicrotasks();
      expect(s.status.phase, AfkPhase.degraded);
      expect(s.status.lastPingOk, isFalse);
      expect(s.status.consecutiveFailures, 1);
      expect(s.status.executionStateHeld, isTrue); // still holding sleep block
      expect(s.status.lastError, contains('Giriş'));

      async.elapse(const Duration(seconds: 15)); // 1st retry after 15s
      expect(s.status.consecutiveFailures, 2);
      async.elapse(const Duration(seconds: 35)); // 2nd retry 30s later
      expect(s.status.phase, AfkPhase.active);
      expect(s.status.consecutiveFailures, 0);
      expect(s.status.lastError, isNull);
      expect(s.status.pingCount, 1);
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('backoff is capped at the interval', () {
    fakeAsync((async) {
      backend.failInputTimes = 1000;
      final s = make();
      s.enable();
      async.elapse(const Duration(minutes: 30));
      final gaps = <Duration>[];
      final inputs = backend.calls.where((c) => c == 'input').length;
      expect(inputs, greaterThan(5));
      // nextPingAt - lastPingAt never exceeds the interval.
      gaps.add(s.status.nextPingAt!.difference(s.status.lastPingAt!));
      expect(gaps.single, lessThanOrEqualTo(const Duration(minutes: 2)));
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('acquire failure -> error phase, retried, then active', () {
    fakeAsync((async) {
      backend.failAcquireTimes = 1;
      final s = make();
      s.enable();
      async.flushMicrotasks();
      expect(s.status.phase, AfkPhase.error);
      expect(s.status.executionStateHeld, isFalse);
      expect(backend.calls, ['acquire']); // no input without the state held
      async.elapse(const Duration(seconds: 20));
      expect(s.status.phase, AfkPhase.active);
      expect(s.status.executionStateHeld, isTrue);
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('disable during an in-flight acquire still ends released', () {
    fakeAsync((async) {
      backend.acquireGate = Completer<void>();
      final s = make();
      s.enable();
      async.flushMicrotasks();
      expect(s.status.phase, AfkPhase.starting);
      s.disable(); // queued behind enable
      async.flushMicrotasks();
      backend.acquireGate!.complete();
      async.flushMicrotasks();
      expect(backend.held, isFalse);
      expect(s.status.phase, AfkPhase.off);
      expect(backend.calls.last, 'release');
      async.elapse(const Duration(minutes: 10));
      expect(backend.inputTimes.length, lessThanOrEqualTo(1));
      expect(backend.held, isFalse);
    });
  });

  test('wake from sleep: one catch-up ping, no burst', () {
    var offset = Duration.zero;
    fakeAsync((async) {
      withClock(Clock(() => async.getClock(DateTime(2026)).now().add(offset)),
          () {
        final s = make();
        s.enable();
        async.flushMicrotasks();
        expect(backend.inputTimes.length, 1);
        // Machine slept for 1h: wall clock jumps, timers did not run.
        offset = const Duration(hours: 1);
        async.elapse(const Duration(seconds: 5)); // first heartbeat after wake
        expect(backend.inputTimes.length, 2);
        async.elapse(const Duration(seconds: 30));
        expect(backend.inputTimes.length, 2); // no burst of missed pings
        expect(s.status.phase, AfkPhase.active);
        s.dispose();
        async.flushMicrotasks();
      });
    });
  });

  test('long run: ~30 pings per hour', () {
    fakeAsync((async) {
      final s = make();
      s.enable();
      async.elapse(const Duration(hours: 1));
      expect(backend.inputTimes.length, inInclusiveRange(29, 31));
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('wall clock jumping backwards does not stall pings', () {
    var offset = Duration.zero;
    fakeAsync((async) {
      withClock(Clock(() => async.getClock(DateTime(2026)).now().add(offset)),
          () {
        final s = make();
        s.enable();
        async.flushMicrotasks();
        offset = const Duration(hours: -3); // clock set back 3h
        async.elapse(const Duration(minutes: 5));
        // At most interval+checkEvery to resync, then normal pings.
        expect(backend.inputTimes.length, greaterThanOrEqualTo(2));
        s.dispose();
        async.flushMicrotasks();
      });
    });
  });

  test('pingNow forces an immediate cycle and reschedules', () {
    fakeAsync((async) {
      final s = make();
      s.enable();
      async.elapse(const Duration(minutes: 1));
      s.pingNow();
      async.flushMicrotasks();
      expect(backend.inputTimes.length, 2);
      expect(s.status.nextPingAt,
          clock.now().add(const Duration(minutes: 2)));
      async.elapse(const Duration(minutes: 1, seconds: 30));
      expect(backend.inputTimes.length, 2); // old schedule was replaced
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('pingNow while disabled does nothing', () {
    fakeAsync((async) {
      final s = make();
      s.pingNow();
      async.flushMicrotasks();
      expect(backend.calls, isEmpty);
    });
  });

  test('method and interval can be changed while enabled', () {
    fakeAsync((async) {
      final s = make();
      s.enable(method: KeepAwakeMethod.f15Key);
      async.flushMicrotasks();
      expect(backend.inputMethods.single, KeepAwakeMethod.f15Key);
      s.enable(
          method: KeepAwakeMethod.mouseJiggle,
          interval: const Duration(seconds: 30));
      async.elapse(const Duration(seconds: 36));
      expect(backend.inputMethods.last, KeepAwakeMethod.mouseJiggle);
      expect(s.status.interval, const Duration(seconds: 30));
      expect(backend.calls.where((c) => c == 'acquire').length, 2);
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('status stream emits phases in order', () {
    fakeAsync((async) {
      final s = make();
      final phases = <AfkPhase>[];
      s.statusStream.listen((st) => phases.add(st.phase));
      s.enable();
      async.flushMicrotasks();
      s.disable();
      async.flushMicrotasks();
      expect(phases, [AfkPhase.starting, AfkPhase.active, AfkPhase.off]);
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('dispose releases and rejects further enable', () {
    fakeAsync((async) {
      final s = make();
      s.enable();
      async.flushMicrotasks();
      s.dispose();
      async.flushMicrotasks();
      expect(backend.held, isFalse);
      Object? err;
      s.enable().catchError((Object e) => err = e);
      async.flushMicrotasks();
      expect(err, isA<StateError>());
    });
  });

  test('setMethod while off keeps AFK off and holds nothing', () {
    fakeAsync((async) {
      final s = make();
      s.setMethod(KeepAwakeMethod.f15Key);
      async.flushMicrotasks();
      expect(s.status.method, KeepAwakeMethod.f15Key);
      expect(s.status.phase, AfkPhase.off);
      expect(backend.calls, isEmpty);
      s.enable();
      async.flushMicrotasks();
      expect(backend.inputMethods.single, KeepAwakeMethod.f15Key);
      s.dispose();
      async.flushMicrotasks();
    });
  });

  test('Win32 INPUT struct has native layout', () {
    // 40 bytes on 64-bit (type + pad + 32-byte union), 28 on 32-bit.
    expect(sizeOf<INPUT>(), sizeOf<IntPtr>() == 8 ? 40 : 28);
  });

  test('AfkStatus JSON round-trip', () {
    final st = AfkStatus(
      phase: AfkPhase.degraded,
      method: KeepAwakeMethod.f15Key,
      interval: const Duration(minutes: 2),
      executionStateHeld: true,
      lastPingAt: DateTime.utc(2026, 10, 5, 1, 2, 3).toLocal(),
      lastPingOk: false,
      nextPingAt: DateTime.utc(2026, 10, 5, 1, 2, 18).toLocal(),
      pingCount: 7,
      consecutiveFailures: 1,
      lastError: 'x',
    );
    final back = AfkStatus.fromJson(st.toJson());
    expect(back.toJson(), st.toJson());
  });
}
