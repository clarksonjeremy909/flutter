import 'dart:async';
import 'dart:io';

import 'package:aktifdesk/core/afk/afk_scheduler.dart';
import 'package:aktifdesk/core/afk/afk_status.dart';
import 'package:aktifdesk/core/control/control_client.dart';
import 'package:aktifdesk/core/control/control_server.dart';
import 'package:flutter_test/flutter_test.dart';

import '../afk/fake_backend.dart';

class FakeHooks implements HostSunshineHooks {
  final pins = <String>[];
  final _c = StreamController<Map<String, Object?>>.broadcast();
  @override
  Stream<Map<String, Object?>> get changes => _c.stream;
  @override
  Future<void> prepare() async {}
  @override
  Future<Map<String, Object?>> status() async => {'runState': 'running'};
  @override
  Future<bool> submitPin(String pin, {required String clientName, String? clientAddress}) async {
    pins.add('$pin/$clientName');
    return pin == '1234';
  }
}

Future<void> until(bool Function() cond) async {
  for (var i = 0; i < 200 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(cond(), isTrue);
}

void main() {
  late FakeKeepAwakeBackend backend;
  late AfkScheduler afk;
  late ControlServer server;
  late FakeHooks hooks;

  setUp(() async {
    backend = FakeKeepAwakeBackend();
    afk = AfkScheduler(backend: backend);
    hooks = FakeHooks();
    server = ControlServer(
        afk: afk, token: 'secret-123', sunshine: hooks, port: 0,
        address: InternetAddress.loopbackIPv4, hostName: 'Test PC');
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    await afk.dispose();
  });

  test('phone toggles AFK on PC and mirrors live status', () async {
    final c = ControlClient(host: '127.0.0.1', port: server.boundPort!, token: 'secret-123');
    await c.connect();
    await until(() => c.afkStatus != null && c.hostName == 'Test PC');
    expect(c.afkStatus!.phase, AfkPhase.off);
    expect(c.sunshineStatus?['runState'], 'running');

    await c.setAfk(true, method: KeepAwakeMethod.f15Key);
    await until(() => c.afkStatus!.phase == AfkPhase.active);
    expect(backend.held, isTrue);
    expect(c.afkStatus!.lastPingAt, isNotNull);
    expect(c.afkStatus!.method, KeepAwakeMethod.f15Key);

    await c.pingAfkNow();
    await until(() => c.afkStatus!.pingCount == 2);

    await c.setAfk(false);
    await until(() => c.afkStatus!.phase == AfkPhase.off);
    expect(backend.held, isFalse);
    await c.close();
  });

  test('PIN is forwarded to Sunshine hooks', () async {
    final c = ControlClient(host: '127.0.0.1', port: server.boundPort!, token: 'secret-123');
    await c.connect();
    await until(() => c.connection == ControlConnection.connected);
    expect(await c.submitSunshinePin('1234', name: 'Telefonum'), isTrue);
    expect(await c.submitSunshinePin('9999', name: 'Telefonum'), isFalse);
    expect(hooks.pins, ['1234/Telefonum', '9999/Telefonum']);
    await c.close();
  });

  test('wrong token is rejected', () async {
    final c = ControlClient(host: '127.0.0.1', port: server.boundPort!, token: 'nope');
    await c.connect();
    expect(c.connection, ControlConnection.unauthorized, reason: c.lastError);
    await c.close();
  });

  test('AFK keeps running on PC when phone disconnects', () async {
    final c = ControlClient(host: '127.0.0.1', port: server.boundPort!, token: 'secret-123');
    await c.connect();
    await until(() => c.connection == ControlConnection.connected);
    await c.setAfk(true);
    await c.close();
    await until(() => server.connectedClients == 0);
    expect(afk.status.phase, AfkPhase.active);
    expect(backend.held, isTrue);
  });
}
