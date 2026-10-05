import 'dart:async';
import 'dart:io';

import 'package:aktifdesk/core/afk/afk_scheduler.dart';
import 'package:aktifdesk/core/afk/afk_status.dart';
import 'package:aktifdesk/core/control/control_protocol.dart';
import 'package:aktifdesk/core/control/discovery.dart';
import 'package:aktifdesk/core/control/pc_control_agent.dart';
import 'package:aktifdesk/core/control/pc_link.dart';
import 'package:aktifdesk/core/control/phone_control_server.dart';
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
  for (var i = 0; i < 300 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(cond(), isTrue);
}

Future<int> freeUdpPort() async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  s.close();
  return p;
}

const pc = PcIdentity(id: 'pc-1', name: 'Test PC');

void main() {
  late FakeKeepAwakeBackend backend;
  late AfkScheduler afk;
  late PcControlAgent agent;
  late FakeHooks hooks;
  late PhoneControlServer phone;
  late PcDiscovery discovery;
  final links = <PhoneLink>[];

  setUp(() async {
    backend = FakeKeepAwakeBackend();
    afk = AfkScheduler(backend: backend);
    hooks = FakeHooks();
    agent = PcControlAgent(afk: afk, sunshine: hooks, hostName: 'Test PC')..start();
    phone = PhoneControlServer(
      deviceId: 'phone-1',
      deviceName: 'Test Telefon',
      port: 0,
      address: InternetAddress.loopbackIPv4,
      discoveryPort: 0,
      beaconTargets: const [],
      initialCode: '123456',
    );
    await phone.start();
    discovery = PcDiscovery(
      port: phone.advertiser!.boundPort!,
      targets: [InternetAddress.loopbackIPv4],
      listenForBeacons: false,
      queryInterval: const Duration(milliseconds: 100),
    );
  });

  tearDown(() async {
    for (final l in links) {
      await l.stop();
    }
    links.clear();
    await phone.close();
    await agent.stop();
    await afk.dispose();
  });

  Future<PairResult> pairAndLink() async {
    final r = await pairWithCode(
        code: '123 456', pc: pc, discovery: discovery, searchTimeout: const Duration(seconds: 3));
    final l = PhoneLink(phone: r.phone, pc: pc, agent: agent, discovery: discovery);
    links.add(l);
    l.start(adopt: r.socket, adoptAddress: r.address);
    await until(() =>
        phone.connection == ControlConnection.connected &&
        phone.afkStatus != null &&
        phone.hostName == 'Test PC');
    return r;
  }

  group('PairingCode', () {
    test('generates 6 digits, normalizes and formats', () {
      final c = PairingCode.generate();
      expect(c, matches(RegExp(r'^\d{6}$')));
      expect(PairingCode.normalize(' 482-913 '), '482913');
      expect(PairingCode.format('482913'), '482 913');
      expect(PairingCode.isValid('48291'), isFalse);
    });
  });

  test('PC finds the phone by code only (no address) and pairs', () async {
    final events = <PairingEvent>[];
    final sub = phone.pairings.listen(events.add);
    final stages = <PairStage>[];
    final r = await pairWithCode(
      code: '123456',
      pc: pc,
      discovery: discovery,
      onStage: (s, _) => stages.add(s),
      searchTimeout: const Duration(seconds: 3),
    );
    expect(r.phone.id, 'phone-1');
    expect(r.phone.name, 'Test Telefon');
    expect(stages, [PairStage.searching, PairStage.connecting]);
    final l = PhoneLink(phone: r.phone, pc: pc, agent: agent, discovery: discovery);
    links.add(l);
    l.start(adopt: r.socket, adoptAddress: r.address);
    await until(() => phone.connection == ControlConnection.connected && events.isNotEmpty);
    expect(events.single.pc.id, 'pc-1');
    expect(events.single.pc.key, r.phone.key);
    expect(phone.pairedPcs.map((p) => p.name), ['Test PC']);
    expect(phone.code, isNot('123456'), reason: 'pairing codes are one-time');
    expect(phone.peerAddress, '127.0.0.1');
    await sub.cancel();
  });

  test('wrong code: no phone answers', () async {
    await expectLater(
      pairWithCode(
          code: '000000', pc: pc, discovery: discovery, searchTimeout: const Duration(milliseconds: 600)),
      throwsA(isA<PairingFailure>()),
    );
    expect(phone.connection, ControlConnection.waiting);
    expect(phone.pairedPcs, isEmpty);
  });

  test('wrong code on the socket is rejected and rotates the code after 5 tries', () async {
    for (var i = 0; i < 5; i++) {
      await expectLater(
        connectToPhone('127.0.0.1', phone.boundPort!, pc, token: '99999$i', pairKey: randomToken()),
        throwsA(isA<WebSocketException>()),
      );
    }
    expect(phone.code, isNot('123456'));
    expect(phone.connection, ControlConnection.waiting);
  });

  test('phone toggles AFK on PC and mirrors live status', () async {
    await pairAndLink();
    expect(phone.afkStatus!.phase, AfkPhase.off);
    expect(phone.sunshineStatus?['runState'], 'running');

    await phone.setAfk(true, method: KeepAwakeMethod.f15Key);
    await until(() => phone.afkStatus!.phase == AfkPhase.active);
    expect(backend.held, isTrue);
    expect(phone.afkStatus!.lastPingAt, isNotNull);
    expect(phone.afkStatus!.method, KeepAwakeMethod.f15Key);

    await phone.pingAfkNow();
    await until(() => phone.afkStatus!.pingCount == 2);

    await phone.setAfk(false);
    await until(() => phone.afkStatus!.phase == AfkPhase.off);
    expect(backend.held, isFalse);
  });

  test('PIN is forwarded to Sunshine hooks', () async {
    await pairAndLink();
    expect(await phone.submitSunshinePin('1234', name: 'Telefonum'), isTrue);
    expect(await phone.submitSunshinePin('9999', name: 'Telefonum'), isFalse);
    expect(hooks.pins, ['1234/Telefonum', '9999/Telefonum']);
  });

  test('paired PC reconnects automatically with its key (no code)', () async {
    final r = await pairAndLink();
    await links.removeLast().stop();
    await until(() => phone.connection == ControlConnection.waiting);

    final l = PhoneLink(phone: r.phone, pc: pc, agent: agent, discovery: discovery);
    links.add(l);
    l.start();
    await until(() => l.state == PhoneLinkState.connected);
    await until(() => phone.connection == ControlConnection.connected);
    expect(phone.connectedPcId, 'pc-1');
  });

  test('forgotten PC is rejected on reconnect', () async {
    final r = await pairAndLink();
    await links.removeLast().stop();
    phone.forgetPc('pc-1');
    await expectLater(
      connectToPhone('127.0.0.1', phone.boundPort!, pc, token: r.phone.key),
      throwsA(isA<WebSocketException>()),
    );
  });

  test('AFK keeps running on PC when phone disconnects', () async {
    await pairAndLink();
    await phone.setAfk(true);
    await until(() => afk.status.phase == AfkPhase.active);
    await links.removeLast().stop();
    await until(() => agent.connectedClients == 0);
    expect(afk.status.phase, AfkPhase.active);
    expect(backend.held, isTrue);
  });

  test('PC also finds the phone from its broadcast beacon', () async {
    final beaconPort = await freeUdpPort();
    final adv = PhoneAdvertiser(
      deviceId: 'phone-2',
      deviceName: 'Beacon Telefon',
      wsPort: 47100,
      code: '654321',
      port: 0,
      beaconPort: beaconPort,
      beaconTargets: [InternetAddress.loopbackIPv4],
      beaconInterval: const Duration(milliseconds: 100),
    );
    await adv.start();
    final d = PcDiscovery(
      targets: const [], // no active queries: beacon only
      beaconListenPort: beaconPort,
    );
    final found = await d.findByCode('654321', timeout: const Duration(seconds: 3));
    expect(found?.id, 'phone-2');
    expect(found?.port, 47100);
    expect(await d.findByCode('111111', timeout: const Duration(milliseconds: 400)), isNull);
    adv.stop();
  });
}
