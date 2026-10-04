import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/afk/afk_status.dart';
import '../format.dart';

/// AFK status indicator + controls, shared by the PC and phone UIs.
class AfkStatusCard extends StatefulWidget {
  const AfkStatusCard({
    super.key,
    required this.status,
    required this.onToggle,
    this.onPingNow,
    this.onMethodChanged,
    this.remote = false,
    this.connected = true,
    this.lastSyncAt,
    this.busy = false,
  });

  final AfkStatus? status;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onPingNow;
  final ValueChanged<KeepAwakeMethod>? onMethodChanged;

  /// True on the phone (status mirrored from the PC).
  final bool remote;
  final bool connected;
  final DateTime? lastSyncAt;
  final bool busy;

  @override
  State<AfkStatusCard> createState() => _AfkStatusCardState();
}

class _AfkStatusCardState extends State<AfkStatusCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Re-render every second so "last ping x sn önce" stays live.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  (Color, IconData, String) _indicator(AfkStatus? s, ColorScheme cs) {
    if (widget.remote && !widget.connected) {
      return (Colors.grey, Icons.cloud_off, 'PC bağlantısı yok');
    }
    if (s == null) return (Colors.grey, Icons.help_outline, 'Bilinmiyor');
    return switch (s.phase) {
      AfkPhase.off => (Colors.grey, Icons.bedtime_outlined, 'AFK kapalı'),
      AfkPhase.starting => (Colors.blue, Icons.hourglass_top, 'Başlatılıyor…'),
      AfkPhase.active => (Colors.green, Icons.check_circle, 'AFK aktif — PC uyanık'),
      AfkPhase.degraded => (Colors.orange, Icons.warning_amber, 'Giriş gönderilemiyor, tekrar deneniyor'),
      AfkPhase.error => (cs.error, Icons.error, 'Uyku engeli alınamadı, tekrar deneniyor'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.status;
    final cs = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final (color, icon, label) = _indicator(s, cs);
    final enabled = s?.enabled ?? false;
    final canControl = widget.onToggle != null && (!widget.remote || widget.connected) && !widget.busy;

    // A ping overdue by > 1 interval + 30s means something is wrong.
    final overdue = s != null &&
        s.enabled &&
        s.lastPingAt != null &&
        now.difference(s.lastPingAt!) > s.interval + const Duration(seconds: 30);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              _Pulse(color: color, active: s?.phase == AfkPhase.active && (!widget.remote || widget.connected)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('AFK modu', style: Theme.of(context).textTheme.titleMedium),
                  Row(children: [
                    Icon(icon, size: 16, color: color),
                    const SizedBox(width: 4),
                    Flexible(child: Text(label, key: const Key('afk-label'), style: TextStyle(color: color))),
                  ]),
                ]),
              ),
              if (widget.busy) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              Switch(
                key: const Key('afk-switch'),
                value: enabled,
                onChanged: canControl ? widget.onToggle : null,
              ),
            ]),
            const Divider(height: 24),
            _row(context, 'Son ping',
                s?.lastPingAt == null
                    ? '—'
                    : '${clockTime(s!.lastPingAt!)}  (${ago(s.lastPingAt!, now)})'
                        '${s.lastPingOk == false ? '  ✗ başarısız' : ''}',
                key: const Key('afk-last-ping'),
                warn: overdue || s?.lastPingOk == false),
            if (enabled && s?.nextPingAt != null)
              _row(context, 'Sonraki ping', '${clockTime(s!.nextPingAt!)}  (${inTime(s.nextPingAt!, now)})'),
            _row(context, 'Uyku engeli',
                s?.executionStateHeld == true ? 'Tutuluyor (sistem + ekran)' : 'Yok'),
            _row(context, 'Toplam ping', '${s?.pingCount ?? 0}'
                '${(s?.consecutiveFailures ?? 0) > 0 ? '  •  ardışık hata: ${s!.consecutiveFailures}' : ''}'),
            if (s?.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(s!.lastError!, style: TextStyle(color: cs.error, fontSize: 12)),
              ),
            if (widget.remote && widget.lastSyncAt != null)
              _row(context, 'PC\'den son güncelleme', ago(widget.lastSyncAt!, now)),
            if (widget.remote && !widget.connected && enabled)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Bağlantı kopsa da AFK PC üzerinde çalışmaya devam eder.',
                    style: TextStyle(fontSize: 12)),
              ),
            const SizedBox(height: 8),
            Row(children: [
              if (widget.onMethodChanged != null)
                Expanded(
                  child: DropdownButton<KeepAwakeMethod>(
                    isExpanded: true,
                    value: s?.method ?? KeepAwakeMethod.both,
                    items: [
                      for (final m in KeepAwakeMethod.values)
                        DropdownMenuItem(value: m, child: Text(m.label)),
                    ],
                    onChanged: canControl ? (m) => widget.onMethodChanged!(m!) : null,
                  ),
                ),
              const SizedBox(width: 8),
              if (widget.onPingNow != null)
                OutlinedButton.icon(
                  onPressed: canControl && enabled ? widget.onPingNow : null,
                  icon: const Icon(Icons.touch_app, size: 18),
                  label: const Text('Şimdi ping'),
                ),
            ]),
            Text('Her ${s?.interval.inMinutes ?? 2} dakikada zararsız bir giriş gönderilir; '
                'oyun ve Windows boşta/AFK sayaçları sıfırlanır.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String k, String v, {Key? key, bool warn = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 150, child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(
              child: Text(v,
                  key: key,
                  style: warn ? TextStyle(color: Theme.of(context).colorScheme.error) : null)),
        ]),
      );
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.color, required this.active});
  final Color color;
  final bool active;
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didUpdateWidget(covariant _Pulse old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  void _sync() {
    if (widget.active && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: widget.active ? 0.6 * _c.value : 0),
                blurRadius: 10,
                spreadRadius: 3 * _c.value,
              )
            ],
          ),
        ),
      );
}
