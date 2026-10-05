import 'package:flutter/material.dart';

import '../../app/client_controller.dart';
import '../../core/control/control_protocol.dart';
import '../../core/control/phone_control_server.dart';
import 'client_screen.dart';

/// Phone root: Welcome → pairing code → success → dashboard.
class PhoneShell extends StatelessWidget {
  const PhoneShell({super.key, required this.c});
  final ClientController c;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final Widget page = switch (c.stage) {
        PhoneStage.welcome => WelcomeView(onContinue: c.continueFromWelcome),
        PhoneStage.code => PairingCodeView(
          code: c.pairingCode,
          serviceRunning: c.connection != ControlConnection.stopped,
          error: c.message,
          onNewCode: c.newCode,
          onBack: c.pairedPcs.isEmpty ? null : c.openDashboard,
        ),
        PhoneStage.success => PairedSuccessView(
          pcName: c.lastPairedPc?.name ?? c.control.hostName,
          onContinue: c.openDashboard,
        ),
        PhoneStage.dashboard => ClientScreen(c: c),
      };
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: KeyedSubtree(key: ValueKey(c.stage), child: page),
      );
    },
  );
}

class WelcomeView extends StatelessWidget {
  const WelcomeView({super.key, required this.onContinue});
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              const Spacer(),
              Icon(Icons.desktop_windows_rounded, size: 88, color: t.colorScheme.primary),
              const SizedBox(height: 24),
              Text(
                'AktifDesk',
                style: t.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('Hoş geldin', style: t.textTheme.headlineSmall),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('welcome-continue'),
                  onPressed: onContinue,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: const Text('Devam et', style: TextStyle(fontSize: 18)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PairingCodeView extends StatelessWidget {
  const PairingCodeView({
    super.key,
    required this.code,
    this.serviceRunning = true,
    this.error,
    this.onNewCode,
    this.onBack,
  });

  final String code;
  final bool serviceRunning;
  final String? error;
  final VoidCallback? onNewCode;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('AktifDesk'),
        leading: onBack == null
            ? null
            : IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              const Spacer(),
              Text('Eşleştirme kodun', style: t.textTheme.titleLarge),
              const SizedBox(height: 16),
              FittedBox(
                child: Text(
                  PairingCode.format(code),
                  key: const Key('pairing-code'),
                  style: t.textTheme.displayLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 6,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Bunu PC\'deki cihazına gir',
                textAlign: TextAlign.center,
                style: t.textTheme.titleMedium,
              ),
              const SizedBox(height: 32),
              if (serviceRunning)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text('PC bekleniyor…', style: t.textTheme.bodyMedium),
                  ],
                )
              else
                Text('Bağlantı servisi çalışmıyor', style: TextStyle(color: t.colorScheme.error)),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.colorScheme.error),
                  ),
                ),
              const Spacer(),
              Text(
                'Telefon ve PC aynı Wi-Fi ağında olmalı.',
                textAlign: TextAlign.center,
                style: t.textTheme.bodySmall,
              ),
              if (onNewCode != null)
                TextButton.icon(
                  onPressed: onNewCode,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Yeni kod'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class PairedSuccessView extends StatelessWidget {
  const PairedSuccessView({super.key, this.pcName, required this.onContinue});
  final String? pcName;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              const Spacer(),
              const Icon(Icons.check_circle_rounded, size: 96, color: Colors.green),
              const SizedBox(height: 24),
              Text(
                'Şu an izinleri aldık',
                textAlign: TextAlign.center,
                style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Telefondan PC\'yi yönetebilirsin',
                textAlign: TextAlign.center,
                style: t.textTheme.titleMedium,
              ),
              if (pcName != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Chip(avatar: const Icon(Icons.computer, size: 18), label: Text(pcName!)),
                ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('success-continue'),
                  onPressed: onContinue,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: const Text('Devam et', style: TextStyle(fontSize: 18)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
