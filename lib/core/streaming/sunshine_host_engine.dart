import 'dart:io';

import '../sunshine/sunshine_host.dart';
import 'streaming_engine.dart';

/// Primary host engine: a real Sunshine instance managed by AktifDesk.
class SunshineHostEngine extends HostStreamingEngine with EngineStatusMixin {
  SunshineHostEngine(this.manager);
  final SunshineHostManager manager;

  @override
  String get id => 'sunshine';
  @override
  String get displayName => 'Sunshine (GameStream/Moonlight)';
  @override
  int get priority => 0;

  @override
  Future<EngineAvailability> probe() async {
    if (!Platform.isWindows) {
      return const EngineAvailability.no('Sunshine yönetimi yalnızca Windows\'ta');
    }
    final s = await manager.status();
    if (s.runState == SunshineRunState.notInstalled) {
      return EngineAvailability.no(s.message ?? 'Sunshine kurulu değil');
    }
    return const EngineAvailability.yes();
  }

  @override
  Future<void> prepareHost() async {
    setStatus(EngineState.preparing, 'Sunshine başlatılıyor');
    try {
      var s = await manager.start();
      if (!s.apiReachable) {
        setStatus(EngineState.error, s.message ?? 'Sunshine API yanıt vermiyor');
        return;
      }
      if (s.apiAuthOk) {
        final via = await manager.applyConfig(restart: false);
        setStatus(EngineState.ready, 'Hazır (ayarlar: $via)');
      } else {
        setStatus(EngineState.error, s.message);
      }
    } catch (e) {
      setStatus(EngineState.error, '$e');
    }
  }

  @override
  Future<void> stopHost() async {
    await manager.stop();
    setStatus(EngineState.idle, 'Durduruldu');
  }

  @override
  Future<bool> approvePairing(String pin, {required String clientName, String? clientAddress}) =>
      manager.submitPairingPin(pin, clientName: clientName, clientAddress: clientAddress);

  @override
  Future<void> dispose() => closeStatus();
}
