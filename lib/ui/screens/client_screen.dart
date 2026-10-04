import 'package:flutter/material.dart';

import '../../app/client_controller.dart';
import '../../core/control/control_client.dart';
import '../../core/control/control_protocol.dart';
import '../../core/platform/android_bridge.dart';
import '../widgets/afk_status_card.dart';

class ClientScreen extends StatefulWidget {
  const ClientScreen({super.key, required this.c});
  final ClientController c;
  @override
  State<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends State<ClientScreen> {
  ClientController get c => widget.c;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final connected = c.connection == ControlConnection.connected;
          return Scaffold(
            appBar: AppBar(
              title: Text(c.control?.hostName ?? 'AktifDesk'),
              actions: [
                _ConnChip(state: c.connection),
                IconButton(
                    tooltip: 'Bağlantı ayarları',
                    onPressed: () => _editConnection(context),
                    icon: const Icon(Icons.settings)),
              ],
            ),
            body: RefreshIndicator(
              onRefresh: c.refreshStream,
              child: ListView(padding: const EdgeInsets.all(12), children: [
                if (c.host.isEmpty)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.link),
                      title: const Text('PC\'ye bağlan'),
                      subtitle: const Text('PC uygulamasındaki adresi ve bağlantı kodunu girin'),
                      onTap: () => _editConnection(context),
                    ),
                  ),
                if (c.message != null)
                  Card(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: ListTile(
                      dense: true,
                      title: Text(c.message!),
                      trailing: IconButton(
                          onPressed: () => setState(() => c.message = null),
                          icon: const Icon(Icons.close)),
                    ),
                  ),
                AfkStatusCard(
                  status: c.afkStatus,
                  remote: true,
                  connected: connected,
                  lastSyncAt: c.control?.lastMessageAt,
                  busy: c.afkBusy,
                  onToggle: c.setAfk,
                  onPingNow: c.pingAfk,
                  onMethodChanged: c.setAfkMethod,
                ),
                SwitchListTile(
                  title: const Text('AFK açıkken telefon ekranını açık tut'),
                  value: c.keepScreenOnWithAfk,
                  onChanged: c.setKeepScreenOn,
                ),
                _streamCard(context),
              ]),
            ),
          );
        },
      );

  Widget _streamCard(BuildContext context) {
    final info = c.serverInfo;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Oyun yayını (Moonlight / Sunshine)', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(info == null
              ? 'Sunshine bulunamadı (PC\'de "Başlat ve yapılandır"a basın)'
              : '${info.hostname} • Sunshine ${info.appVersion} • ${c.paired ? 'eşleşmiş' : 'eşleşmemiş'}'),
          Text('Motor: ${c.engine?.displayName ?? 'yok'}',
              style: const TextStyle(fontSize: 12)),
          for (final e in c.skippedEngines.entries)
            Text('• ${e.key}: ${e.value}', style: const TextStyle(fontSize: 12)),
          if (c.moonlightPackage == null && AndroidBridge.supported)
            TextButton.icon(
                onPressed: AndroidBridge.openMoonlightStore,
                icon: const Icon(Icons.download),
                label: const Text('Moonlight\'ı yükle (video çözme için)')),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
                onPressed: c.connection == ControlConnection.connected ? c.prepareHost : null,
                icon: const Icon(Icons.wb_sunny_outlined),
                label: const Text('PC\'de Sunshine\'ı hazırla')),
            if (!c.paired)
              FilledButton.icon(
                  onPressed: c.busy || info == null ? null : c.pair,
                  icon: const Icon(Icons.link),
                  label: const Text('Eşleştir (otomatik PIN)')),
            if (c.paired)
              FilledButton.icon(
                  onPressed: () => c.launch(null),
                  icon: const Icon(Icons.desktop_windows),
                  label: const Text('Masaüstü')),
          ]),
          if (c.pairingPin != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('PIN: ${c.pairingPin}  — PC\'ye otomatik gönderiliyor…',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          if (c.apps.isNotEmpty) const Divider(height: 24),
          for (final a in c.apps)
            ListTile(
              leading: const Icon(Icons.sports_esports),
              title: Text(a.title),
              subtitle: a.hdr ? const Text('HDR') : null,
              trailing: const Icon(Icons.play_arrow),
              onTap: () => c.launch(a),
            ),
          if (c.paired)
            TextButton(onPressed: c.quitApp, child: const Text('Çalışan uygulamayı kapat')),
          const Divider(height: 24),
          const Text('Moonlight uygulamasının kendi eşleştirmesi: Moonlight\'ta PC\'yi ekleyin, '
              'gösterdiği PIN\'i buraya girin; PC\'ye iletilir.', style: TextStyle(fontSize: 12)),
          _MoonlightPinRow(onSubmit: c.forwardMoonlightPin),
        ]),
      ),
    );
  }

  Future<void> _editConnection(BuildContext context) async {
    final h = TextEditingController(text: c.host);
    final p = TextEditingController(text: '${c.port}');
    final t = TextEditingController(text: c.token);
    final n = TextEditingController(text: c.deviceName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('PC bağlantısı'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: h, decoration: const InputDecoration(labelText: 'PC adresi (ör. 192.168.1.20)')),
            TextField(
                controller: p,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Port')),
            TextField(controller: t, decoration: const InputDecoration(labelText: 'Bağlantı kodu')),
            TextField(controller: n, decoration: const InputDecoration(labelText: 'Bu cihazın adı')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Bağlan')),
        ],
      ),
    );
    if (ok == true) {
      await c.saveConnection(h.text, int.tryParse(p.text) ?? ControlProtocol.defaultPort, t.text, n.text);
    }
  }
}

class _ConnChip extends StatelessWidget {
  const _ConnChip({required this.state});
  final ControlConnection state;
  @override
  Widget build(BuildContext context) {
    final (c, t) = switch (state) {
      ControlConnection.connected => (Colors.green, 'Bağlı'),
      ControlConnection.connecting => (Colors.blue, 'Bağlanıyor'),
      ControlConnection.unauthorized => (Colors.red, 'Kod hatalı'),
      ControlConnection.disconnected => (Colors.grey, 'Bağlı değil'),
    };
    return Chip(avatar: CircleAvatar(backgroundColor: c, radius: 6), label: Text(t));
  }
}

class _MoonlightPinRow extends StatefulWidget {
  const _MoonlightPinRow({required this.onSubmit});
  final Future<bool> Function(String) onSubmit;
  @override
  State<_MoonlightPinRow> createState() => _MoonlightPinRowState();
}

class _MoonlightPinRowState extends State<_MoonlightPinRow> {
  final _pin = TextEditingController();
  @override
  Widget build(BuildContext context) => Row(children: [
        SizedBox(
          width: 110,
          child: TextField(
              controller: _pin,
              maxLength: 4,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'PIN', counterText: '')),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
            onPressed: () async {
              await widget.onSubmit(_pin.text);
              _pin.clear();
            },
            child: const Text('PC\'ye gönder')),
        const Spacer(),
        if (AndroidBridge.supported)
          TextButton(onPressed: AndroidBridge.openMoonlight, child: const Text('Moonlight\'ı aç')),
      ]);
}
