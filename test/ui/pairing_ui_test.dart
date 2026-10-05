import 'package:aktifdesk/core/control/pc_link.dart';
import 'package:aktifdesk/ui/screens/phone_onboarding.dart';
import 'package:aktifdesk/ui/widgets/pair_code_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget app(Widget w) => MaterialApp(home: w);

void main() {
  testWidgets('Android welcome: AktifDesk / Hoş geldin / Devam et', (t) async {
    var continued = false;
    await t.pumpWidget(app(WelcomeView(onContinue: () => continued = true)));
    expect(find.text('AktifDesk'), findsOneWidget);
    expect(find.text('Hoş geldin'), findsOneWidget);
    await t.tap(find.text('Devam et'));
    expect(continued, isTrue);
  });

  testWidgets('Android shows the big pairing code and no address field', (t) async {
    await t.pumpWidget(app(const PairingCodeView(code: '482913')));
    expect(find.text('Eşleştirme kodun'), findsOneWidget);
    expect(find.text('482 913'), findsOneWidget);
    expect(find.text('Bunu PC\'deki cihazına gir'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('Android success screen', (t) async {
    var done = false;
    await t.pumpWidget(app(PairedSuccessView(pcName: 'OYUN-PC', onContinue: () => done = true)));
    expect(find.text('Şu an izinleri aldık'), findsOneWidget);
    expect(find.text('Telefondan PC\'yi yönetebilirsin'), findsOneWidget);
    expect(find.text('OYUN-PC'), findsOneWidget);
    await t.tap(find.text('Devam et'));
    expect(done, isTrue);
  });

  testWidgets('PC form: only a code field + Eşleştir, digits only', (t) async {
    String? submitted;
    await t.pumpWidget(
      app(
        Scaffold(
          body: PairCodeForm(
            onPair: (c) async {
              submitted = c;
              return true;
            },
          ),
        ),
      ),
    );
    expect(find.byType(TextField), findsOneWidget, reason: 'no IP/port fields');
    expect(find.text('Eşleştirme kodunu gir'), findsOneWidget);
    expect(find.text('Eşleştir'), findsOneWidget);

    ButtonStyleButton button() => t.widget<ButtonStyleButton>(find.byKey(const Key('pair-button')));
    expect(button().onPressed, isNull);

    await t.enterText(find.byKey(const Key('pair-code-field')), '48a29-13');
    await t.pump();
    expect(find.text('482913'), findsOneWidget);
    expect(button().onPressed, isNotNull);
    await t.tap(find.text('Eşleştir'));
    await t.pump();
    expect(submitted, '482913');
  });

  testWidgets('PC form shows progress and errors', (t) async {
    await t.pumpWidget(
      app(
        Scaffold(
          body: PairCodeForm(
            onPair: (_) async => false,
            stage: PairStage.searching,
            message: 'Telefon aranıyor…',
          ),
        ),
      ),
    );
    expect(find.text('Telefon aranıyor…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
