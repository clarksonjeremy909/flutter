import 'package:flutter/material.dart';

import '../../app/host_controller.dart';
import '../../core/control/pc_link.dart';
import '../../core/sunshine/sunshine_config.dart';
import '../../core/sunshine/sunshine_host.dart';
import '../widgets/afk_status_card.dart';
import '../widgets/pair_code_form.dart';

class HostScreen extends StatefulWidget {
  const HostScreen({super.key, required this.c});
  final HostController c;
  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  HostController get c => widget.c;
  late final _exe = TextEditingController(text: c.sunshine.configuredExePath ?? '');
  late final _user = TextEditingController(text: c.sunshine.username);
  final _pass = TextEditingController();
  late final _name = TextEditingController(text: c.sunshine.settings.hostName);
  late final _port = TextEditingController(text: '${c.sunshine.settings.port}');
  final _pin = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => c.showDashboard ? _dashboard(context) : _pairingPage(context),
    );
  }

  /// First run: just "Aktif Desk", the code field and "Eşleştir".
  Widget _pairingPage(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Aktif Desk')),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Icon(Icons.phone_android, size: 72, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 12),
                Text('Aktif Desk',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('Telefondaki AktifDesk uygulamasında görünen kodu gir.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 24),
                PairCodeForm(onPair: c.pairWithPhone, stage: c.pairStage, message: c.pairMessage),
                const SizedBox(height: 24),
                TextButton(
                    onPressed: c.openDashboard,
                    child: const Text('Eşleştirmeden devam et (Sunshine ayarları)')),
              ]),
            ),
          ),
        ),
      );

  Widget _dashboard(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Aktif Desk'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Chip(
                avatar: Icon(Icons.phone_android,
                    color: c.phoneCount > 0 ? Colors.green : Colors.grey, size: 18),
                label: Text(c.phoneCount > 0 ? '${c.phoneCount} telefon bağlı' : 'Telefon yok'),
              ),
            ),
          ],
        ),
        body: LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth > 900;
          final left = [
            AfkStatusCard(
              status: c.afk.status,
              onToggle: c.setAfk,
              onPingNow: c.afk.pingNow,
              onMethodChanged: c.setAfkMethod,
            ),
            _phoneCard(context),
          ];
          final right = [_sunshineCard(context), _pairingCard(context)];
          return SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              if (c.lastMessage != null)
                MaterialBanner(
                  content: Text(c.lastMessage!),
                  actions: [
                    TextButton(
                        onPressed: () => setState(() => c.lastMessage = null),
                        child: const Text('Kapat'))
                  ],
                ),
              wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: Column(children: left)),
                      Expanded(child: Column(children: right)),
                    ])
                  : Column(children: [...left, ...right]),
            ]),
          );
        }),
      );

  Widget _phoneCard(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Telefonlar', style: Theme.of(context).textTheme.titleMedium),
            if (c.pairedPhones.isEmpty) const Text('Henüz eşleşmiş telefon yok.'),
            for (final p in c.pairedPhones)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.phone_android,
                    color: c.links[p.id]?.state == PhoneLinkState.connected ? Colors.green : Colors.grey),
                title: Text(p.name),
                subtitle: Text(switch (c.links[p.id]?.state) {
                  PhoneLinkState.connected => 'Bağlı',
                  PhoneLinkState.connecting => 'Bağlanıyor…',
                  PhoneLinkState.rejected =>
                    c.links[p.id]?.lastError ?? 'Telefon reddetti — yeniden eşleştirin',
                  PhoneLinkState.stopped => 'Durdu',
                  _ => 'Aranıyor… (telefonda AktifDesk açık olmalı)',
                }),
                trailing: IconButton(
                    tooltip: 'Eşleştirmeyi kaldır',
                    onPressed: () => c.unpairPhone(p.id),
                    icon: const Icon(Icons.link_off)),
              ),
            const Divider(height: 24),
            Text('Yeni telefon eşleştir', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            PairCodeForm(onPair: c.pairWithPhone, stage: c.pairStage, message: c.pairMessage),
            const SizedBox(height: 8),
            const Text('Telefon ve PC aynı Wi-Fi/LAN ağında olmalı. Adres girmen gerekmez; '
                'PC, koddaki telefonu ağda kendisi bulur.',
                style: TextStyle(fontSize: 12)),
          ]),
        ),
      );

  Widget _sunshineCard(BuildContext context) {
    final s = c.sunshineStatus;
    final (color, text) = switch (s?.runState) {
      SunshineRunState.running when s!.apiAuthOk => (Colors.green, 'Çalışıyor${s.version != null ? ' (v${s.version})' : ''}'),
      SunshineRunState.running => (Colors.orange, 'Çalışıyor — API kimlik doğrulaması yok'),
      SunshineRunState.stopped => (Colors.grey, 'Durdu'),
      SunshineRunState.notInstalled => (Colors.red, 'Kurulu değil'),
      _ => (Colors.grey, 'Kontrol ediliyor…'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.wb_sunny, color: color),
            const SizedBox(width: 8),
            Expanded(
                child: Text('Sunshine yayın sunucusu: $text',
                    style: Theme.of(context).textTheme.titleMedium)),
            if (c.busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          if (s?.message != null) Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(s!.message!, style: const TextStyle(fontSize: 12)),
          ),
          if (s?.exePath != null) Text('Konum: ${s!.exePath}', style: const TextStyle(fontSize: 12)),
          if (s?.serviceInstalled == true) const Text('Windows hizmeti: SunshineService', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _exe,
                decoration: const InputDecoration(
                    labelText: 'sunshine.exe yolu (boş = otomatik bul)',
                    hintText: r'C:\Program Files\Sunshine\sunshine.exe'),
              ),
            ),
            TextButton(onPressed: () => c.saveExePath(_exe.text), child: const Text('Kaydet')),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
                onPressed: c.busy ? null : c.startHost,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Başlat ve yapılandır')),
            OutlinedButton.icon(
                onPressed: c.busy ? null : c.stopHost,
                icon: const Icon(Icons.stop),
                label: const Text('Durdur')),
            OutlinedButton.icon(
                onPressed: c.refreshSunshine, icon: const Icon(Icons.refresh), label: const Text('Yenile')),
          ]),
          if (c.activeEngine != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Motor: ${c.activeEngine!.displayName}'
                  '${c.skippedEngines.isNotEmpty ? ' (atlanan: ${c.skippedEngines.entries.map((e) => '${e.key}: ${e.value}').join('; ')})' : ''}',
                  style: const TextStyle(fontSize: 12)),
            ),
          const Divider(height: 24),
          Text('Web UI kimlik bilgileri (https://localhost:${c.sunshine.settings.webUiPort})',
              style: Theme.of(context).textTheme.titleSmall),
          Row(children: [
            Expanded(child: TextField(controller: _user, decoration: const InputDecoration(labelText: 'Kullanıcı'))),
            const SizedBox(width: 8),
            Expanded(
                child: TextField(
                    controller: _pass,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Parola'))),
          ]),
          Wrap(spacing: 8, children: [
            TextButton(
                onPressed: () => c.saveCredentials(_user.text, _pass.text),
                child: const Text('Mevcut bilgileri kullan')),
            TextButton(
                onPressed: () => c.saveCredentials(_user.text, _pass.text, applyToSunshine: true),
                child: const Text('Sunshine\'a yeni bilgi ata (--creds)')),
          ]),
          const Divider(height: 24),
          Text('Yayın ayarları (sunshine.conf)', style: Theme.of(context).textTheme.titleSmall),
          Row(children: [
            Expanded(child: TextField(controller: _name, decoration: const InputDecoration(labelText: 'Sunucu adı'))),
            const SizedBox(width: 8),
            SizedBox(
                width: 120,
                child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'))),
          ]),
          TextButton(
            onPressed: () => c.saveSettings(SunshineManagedSettings(
              hostName: _name.text.trim().isEmpty ? 'AktifDesk' : _name.text.trim(),
              port: int.tryParse(_port.text) ?? 47989,
            )),
            child: const Text('Ayarları uygula'),
          ),
        ]),
      ),
    );
  }

  Widget _pairingCard(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Moonlight eşleştirme', style: Theme.of(context).textTheme.titleMedium),
            const Text('AktifDesk telefon uygulaması PIN\'i otomatik iletir. Başka bir Moonlight '
                'istemcisi için gösterdiği 4 haneli PIN\'i buraya girin.',
                style: TextStyle(fontSize: 12)),
            for (final p in c.pendingPairings)
              ListTile(
                dense: true,
                leading: const Icon(Icons.hourglass_empty),
                title: Text('Bekleyen: ${p.name.isEmpty ? 'istemci' : p.name}'),
                subtitle: Text(p.address ?? p.id),
              ),
            Row(children: [
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _pin,
                  maxLength: 4,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'PIN', counterText: ''),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: () {
                    c.approvePin(_pin.text,
                        pairingId: c.pendingPairings.isEmpty ? null : c.pendingPairings.last.id);
                    _pin.clear();
                  },
                  child: const Text('Onayla')),
            ]),
            const SizedBox(height: 8),
            Text('Eşleşmiş istemciler', style: Theme.of(context).textTheme.titleSmall),
            if (c.pairedClients.isEmpty) const Text('—'),
            for (final pc in c.pairedClients)
              ListTile(
                dense: true,
                leading: const Icon(Icons.devices),
                title: Text(pc.name),
                trailing: IconButton(
                    tooltip: 'Eşleştirmeyi kaldır',
                    onPressed: () => c.unpairClient(pc.uuid),
                    icon: const Icon(Icons.link_off)),
              ),
          ]),
        ),
      );
}
