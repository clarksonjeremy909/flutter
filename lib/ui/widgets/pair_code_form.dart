import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/control/control_protocol.dart';
import '../../core/control/pc_link.dart';

/// PC side: "Eşleştirme kodunu gir" + "Eşleştir". The PC finds the phone
/// that shows this code on the LAN — there is no address field.
class PairCodeForm extends StatefulWidget {
  const PairCodeForm({super.key, required this.onPair, this.stage = PairStage.idle, this.message});

  final Future<bool> Function(String code) onPair;
  final PairStage stage;
  final String? message;

  @override
  State<PairCodeForm> createState() => _PairCodeFormState();
}

class _PairCodeFormState extends State<PairCodeForm> {
  final _code = TextEditingController();

  bool get _busy => widget.stage == PairStage.searching || widget.stage == PairStage.connecting;

  Future<void> _submit() async {
    if (_busy || !PairingCode.isValid(_code.text)) return;
    final ok = await widget.onPair(_code.text);
    if (ok && mounted) _code.clear();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = switch (widget.stage) {
      PairStage.failed => t.colorScheme.error,
      PairStage.success => Colors.green,
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('pair-code-field'),
          controller: _code,
          enabled: !_busy,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: PairingCode.length,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(PairingCode.length),
          ],
          style: t.textTheme.headlineMedium?.copyWith(
            letterSpacing: 8,
            fontWeight: FontWeight.bold,
          ),
          decoration: const InputDecoration(
            labelText: 'Eşleştirme kodunu gir',
            hintText: '••••••',
            counterText: '',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('pair-button'),
          onPressed: _busy || !PairingCode.isValid(_code.text) ? null : _submit,
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.link),
          label: const Text('Eşleştir', style: TextStyle(fontSize: 16)),
        ),
        if (widget.message != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              widget.message!,
              key: const Key('pair-message'),
              textAlign: TextAlign.center,
              style: TextStyle(color: color),
            ),
          ),
      ],
    );
  }
}
