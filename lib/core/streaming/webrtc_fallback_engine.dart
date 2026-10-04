import 'dart:async';

import 'streaming_engine.dart';

/// Pluggable media backend for the WebRTC fallback (e.g. flutter_webrtc).
/// Not bundled by default to keep the primary Sunshine/Moonlight path lean;
/// provide an implementation to enable the fallback.
abstract class WebRtcMediaBackend {
  Future<void> startHostCapture();
  Future<void> connectToHost(String host);
  Future<void> stop();
}

/// Fallback engine used only when Sunshine/Moonlight is unavailable.
class WebRtcHostEngine extends HostStreamingEngine with EngineStatusMixin {
  WebRtcHostEngine({this.backend});
  final WebRtcMediaBackend? backend;
  @override
  String get id => 'webrtc';
  @override
  String get displayName => 'WebRTC (yedek)';
  @override
  int get priority => 100;

  @override
  Future<EngineAvailability> probe() async => backend == null
      ? const EngineAvailability.no('WebRTC medya arka ucu bu derlemede yok')
      : const EngineAvailability.yes();

  @override
  Future<void> prepareHost() async {
    await backend!.startHostCapture();
    setStatus(EngineState.ready, 'WebRTC yayın hazır');
  }

  @override
  Future<void> stopHost() async {
    await backend?.stop();
    setStatus(EngineState.idle);
  }

  @override
  Future<bool> approvePairing(String pin, {required String clientName, String? clientAddress}) async =>
      true; // WebRTC path is authorised by the control-channel token.

  @override
  Future<void> dispose() => closeStatus();
}

class WebRtcClientEngine extends ClientStreamingEngine with EngineStatusMixin {
  WebRtcClientEngine({this.backend});
  final WebRtcMediaBackend? backend;
  @override
  String get id => 'webrtc';
  @override
  String get displayName => 'WebRTC (yedek)';
  @override
  int get priority => 100;

  @override
  Future<EngineAvailability> probe() async => backend == null
      ? const EngineAvailability.no('WebRTC medya arka ucu bu derlemede yok')
      : const EngineAvailability.yes();

  @override
  Future<void> pair(String host, {required FutureOr<void> Function(String pin) onPin}) async {}
  @override
  Future<bool> isPaired(String host) async => true;
  @override
  Future<void> startStream(StreamTarget target) async {
    setStatus(EngineState.preparing);
    await backend!.connectToHost(target.host);
    setStatus(EngineState.streaming);
  }

  @override
  Future<void> stopStream() async {
    await backend?.stop();
    setStatus(EngineState.idle);
  }

  @override
  Future<void> dispose() => closeStatus();
}
