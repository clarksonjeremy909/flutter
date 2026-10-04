import 'dart:async';

/// Availability of an engine on this device/host.
class EngineAvailability {
  const EngineAvailability(this.available, {this.reason});
  const EngineAvailability.yes() : this(true);
  const EngineAvailability.no(String reason) : this(false, reason: reason);
  final bool available;
  final String? reason;
}

enum EngineState { idle, preparing, ready, streaming, error }

class EngineStatus {
  const EngineStatus(this.state, {this.message});
  final EngineState state;
  final String? message;
}

/// Common surface of every streaming engine. The app talks only to this
/// interface; Sunshine/Moonlight is primary, WebRTC is the fallback.
abstract class StreamingEngine {
  String get id;
  String get displayName;

  /// Lower = preferred.
  int get priority;

  Future<EngineAvailability> probe();
  Stream<EngineStatus> get statusStream;
  EngineStatus get status;
  Future<void> dispose();
}

/// Host (PC) side: makes the machine streamable.
abstract class HostStreamingEngine extends StreamingEngine {
  /// Ensure the host service is running and configured.
  Future<void> prepareHost();
  Future<void> stopHost();

  /// Approve a client pairing request with the PIN it displays.
  Future<bool> approvePairing(String pin, {required String clientName, String? clientAddress});
}

class StreamTarget {
  const StreamTarget({required this.host, this.appId, this.appName, this.width = 1920, this.height = 1080, this.fps = 60});
  final String host;
  final int? appId;
  final String? appName;
  final int width, height, fps;
}

/// Client (phone/tablet) side.
abstract class ClientStreamingEngine extends StreamingEngine {
  /// Pair with the host. [onPin] gets the PIN to show / forward.
  Future<void> pair(String host, {required FutureOr<void> Function(String pin) onPin});
  Future<bool> isPaired(String host);
  Future<void> startStream(StreamTarget target);
  Future<void> stopStream();
}

/// Picks the best available engine, falling back in priority order.
class EngineSelector<T extends StreamingEngine> {
  EngineSelector(List<T> engines)
      : engines = [...engines]..sort((a, b) => a.priority.compareTo(b.priority));
  final List<T> engines;

  /// Returns the first available engine and the reasons others were skipped.
  Future<(T?, Map<String, String>)> select({String? preferredId}) async {
    final skipped = <String, String>{};
    final ordered = [
      ...engines.where((e) => e.id == preferredId),
      ...engines.where((e) => e.id != preferredId),
    ];
    for (final e in ordered) {
      final a = await e.probe();
      if (a.available) return (e, skipped);
      skipped[e.id] = a.reason ?? 'kullanılamıyor';
    }
    return (null, skipped);
  }
}

/// Small helper for engines' status plumbing.
mixin EngineStatusMixin on StreamingEngine {
  final _ctrl = StreamController<EngineStatus>.broadcast();
  EngineStatus _status = const EngineStatus(EngineState.idle);
  @override
  Stream<EngineStatus> get statusStream => _ctrl.stream;
  @override
  EngineStatus get status => _status;
  void setStatus(EngineState s, [String? message]) {
    _status = EngineStatus(s, message: message);
    if (!_ctrl.isClosed) _ctrl.add(_status);
  }

  Future<void> closeStatus() => _ctrl.close();
}
