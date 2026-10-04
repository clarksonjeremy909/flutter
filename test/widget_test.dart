import 'package:aktifdesk/core/afk/afk_status.dart';
import 'package:aktifdesk/ui/widgets/afk_status_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(Widget w) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: w)));

void main() {
  testWidgets('AFK card shows active state and last ping', (t) async {
    final now = DateTime.now();
    bool? toggled;
    await t.pumpWidget(wrap(AfkStatusCard(
      status: AfkStatus(
        phase: AfkPhase.active,
        method: KeepAwakeMethod.both,
        interval: const Duration(minutes: 2),
        executionStateHeld: true,
        lastPingAt: now.subtract(const Duration(seconds: 30)),
        lastPingOk: true,
        nextPingAt: now.add(const Duration(seconds: 90)),
        pingCount: 4,
      ),
      onToggle: (v) => toggled = v,
      onPingNow: () {},
      onMethodChanged: (_) {},
    )));
    expect(find.text('AFK aktif — PC uyanık'), findsOneWidget);
    expect(find.textContaining('30 sn önce'), findsOneWidget);
    expect(find.text('Tutuluyor (sistem + ekran)'), findsOneWidget);
    await t.tap(find.byKey(const Key('afk-switch')));
    expect(toggled, isFalse);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('remote card shows disconnected state and disables switch', (t) async {
    await t.pumpWidget(wrap(AfkStatusCard(
      status: AfkStatus.initial().copyWith(phase: AfkPhase.active),
      remote: true,
      connected: false,
      onToggle: (_) {},
    )));
    expect(find.text('PC bağlantısı yok'), findsOneWidget);
    expect(find.textContaining('çalışmaya devam eder'), findsOneWidget);
    final sw = t.widget<Switch>(find.byKey(const Key('afk-switch')));
    expect(sw.onChanged, isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('overdue ping is highlighted', (t) async {
    final now = DateTime.now();
    await t.pumpWidget(wrap(AfkStatusCard(
      status: AfkStatus(
        phase: AfkPhase.active,
        method: KeepAwakeMethod.f15Key,
        interval: const Duration(minutes: 2),
        lastPingAt: now.subtract(const Duration(minutes: 5)),
        lastPingOk: true,
      ),
      onToggle: (_) {},
    )));
    final txt = t.widget<Text>(find.byKey(const Key('afk-last-ping')));
    expect(txt.style?.color, isNotNull);
    await t.pumpWidget(const SizedBox());
  });
}
