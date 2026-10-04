import 'dart:async';

import 'package:aktifdesk/core/afk/afk_status.dart';
import 'package:aktifdesk/core/afk/keep_awake_backend.dart';
import 'package:clock/clock.dart';

class FakeKeepAwakeBackend implements KeepAwakeBackend {
  final List<String> calls = [];
  final List<DateTime> inputTimes = [];
  final List<KeepAwakeMethod> inputMethods = [];
  bool held = false;
  int failAcquireTimes = 0;
  int failInputTimes = 0;
  Completer<void>? acquireGate;

  @override
  String get name => 'fake';
  @override
  bool get isSupported => true;

  @override
  Future<void> acquire() async {
    calls.add('acquire');
    if (acquireGate != null) await acquireGate!.future;
    if (failAcquireTimes > 0) {
      failAcquireTimes--;
      throw StateError('acquire failed');
    }
    held = true;
  }

  @override
  Future<void> release() async {
    calls.add('release');
    held = false;
  }

  @override
  Future<void> sendKeepAliveInput(KeepAwakeMethod method) async {
    calls.add('input');
    if (failInputTimes > 0) {
      failInputTimes--;
      throw StateError('input failed');
    }
    inputTimes.add(clock.now());
    inputMethods.add(method);
  }
}
