import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app/client_controller.dart';
import 'app/host_controller.dart';
import 'ui/screens/client_screen.dart';
import 'ui/screens/host_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final isHost = Platform.isWindows ||
      const bool.fromEnvironment('AKTIFDESK_HOST', defaultValue: false);
  if (isHost) {
    final c = HostController();
    await c.init();
    runApp(AktifDeskApp(home: _HostShell(c: c)));
  } else {
    final c = ClientController();
    await c.init();
    runApp(AktifDeskApp(home: ClientScreen(c: c)));
  }
}

class AktifDeskApp extends StatelessWidget {
  const AktifDeskApp({super.key, required this.home});
  final Widget home;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AktifDesk',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
        home: home,
      );
}

/// Ensures AFK is released (SetThreadExecutionState cleared) when the window
/// is closed or the app exits.
class _HostShell extends StatefulWidget {
  const _HostShell({required this.c});
  final HostController c;
  @override
  State<_HostShell> createState() => _HostShellState();
}

class _HostShellState extends State<_HostShell> {
  late final AppLifecycleListener _l = AppLifecycleListener(
    onExitRequested: () async {
      await widget.c.shutdown();
      return AppExitResponse.exit;
    },
    onDetach: () => widget.c.shutdown(),
  );

  @override
  void initState() {
    super.initState();
    _l.hashCode; // instantiate listener
  }

  @override
  void dispose() {
    _l.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HostScreen(c: widget.c);
}
