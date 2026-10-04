/// Shared AFK (keep-awake) status model.
///
/// The same model is rendered on the PC (where the scheduler runs) and on the
/// phone (which receives it over the control channel), so it is JSON
/// serialisable and contains only plain values.
library;

/// How the scheduler keeps the PC "active".
enum KeepAwakeMethod {
  /// Zero-distance relative mouse move via SendInput.
  mouseJiggle,

  /// F15 key down/up via SendInput (no app binds F15 by default).
  f15Key,

  /// Both of the above (default; most robust against game idle timers).
  both;

  static KeepAwakeMethod parse(String? v) =>
      KeepAwakeMethod.values.firstWhere((m) => m.name == v,
          orElse: () => KeepAwakeMethod.both);

  String get label => switch (this) {
        KeepAwakeMethod.mouseJiggle => 'Sıfır mesafe fare hareketi',
        KeepAwakeMethod.f15Key => 'F15 tuşu',
        KeepAwakeMethod.both => 'Fare + F15',
      };
}

enum AfkPhase {
  /// AFK mode is off; nothing is held.
  off,

  /// Enabling: acquiring the execution state / sending the first ping.
  starting,

  /// Execution state held and pings succeeding.
  active,

  /// Enabled, execution state held, but the last ping(s) failed. Retrying.
  degraded,

  /// Enabled but the execution state could not be acquired. Retrying.
  error;

  static AfkPhase parse(String? v) =>
      AfkPhase.values.firstWhere((p) => p.name == v, orElse: () => AfkPhase.off);
}

class AfkStatus {
  const AfkStatus({
    required this.phase,
    required this.method,
    required this.interval,
    this.executionStateHeld = false,
    this.lastPingAt,
    this.lastPingOk,
    this.nextPingAt,
    this.pingCount = 0,
    this.consecutiveFailures = 0,
    this.lastError,
    this.enabledAt,
  });

  factory AfkStatus.initial({
    KeepAwakeMethod method = KeepAwakeMethod.both,
    Duration interval = const Duration(minutes: 2),
  }) =>
      AfkStatus(phase: AfkPhase.off, method: method, interval: interval);

  final AfkPhase phase;
  final KeepAwakeMethod method;
  final Duration interval;

  /// True while SetThreadExecutionState(ES_CONTINUOUS|...) is in effect.
  final bool executionStateHeld;
  final DateTime? lastPingAt;
  final bool? lastPingOk;
  final DateTime? nextPingAt;
  final int pingCount;
  final int consecutiveFailures;
  final String? lastError;
  final DateTime? enabledAt;

  bool get enabled => phase != AfkPhase.off;

  AfkStatus copyWith({
    AfkPhase? phase,
    KeepAwakeMethod? method,
    Duration? interval,
    bool? executionStateHeld,
    DateTime? lastPingAt,
    bool? lastPingOk,
    DateTime? nextPingAt,
    bool clearNextPing = false,
    int? pingCount,
    int? consecutiveFailures,
    String? lastError,
    bool clearError = false,
    DateTime? enabledAt,
    bool clearEnabledAt = false,
  }) =>
      AfkStatus(
        phase: phase ?? this.phase,
        method: method ?? this.method,
        interval: interval ?? this.interval,
        executionStateHeld: executionStateHeld ?? this.executionStateHeld,
        lastPingAt: lastPingAt ?? this.lastPingAt,
        lastPingOk: lastPingOk ?? this.lastPingOk,
        nextPingAt: clearNextPing ? null : (nextPingAt ?? this.nextPingAt),
        pingCount: pingCount ?? this.pingCount,
        consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
        lastError: clearError ? null : (lastError ?? this.lastError),
        enabledAt: clearEnabledAt ? null : (enabledAt ?? this.enabledAt),
      );

  Map<String, Object?> toJson() => {
        'phase': phase.name,
        'method': method.name,
        'intervalMs': interval.inMilliseconds,
        'executionStateHeld': executionStateHeld,
        'lastPingAt': lastPingAt?.toUtc().toIso8601String(),
        'lastPingOk': lastPingOk,
        'nextPingAt': nextPingAt?.toUtc().toIso8601String(),
        'pingCount': pingCount,
        'consecutiveFailures': consecutiveFailures,
        'lastError': lastError,
        'enabledAt': enabledAt?.toUtc().toIso8601String(),
      };

  factory AfkStatus.fromJson(Map<String, Object?> j) {
    DateTime? ts(Object? v) =>
        v is String ? DateTime.tryParse(v)?.toLocal() : null;
    return AfkStatus(
      phase: AfkPhase.parse(j['phase'] as String?),
      method: KeepAwakeMethod.parse(j['method'] as String?),
      interval: Duration(milliseconds: (j['intervalMs'] as num?)?.toInt() ?? 120000),
      executionStateHeld: j['executionStateHeld'] == true,
      lastPingAt: ts(j['lastPingAt']),
      lastPingOk: j['lastPingOk'] as bool?,
      nextPingAt: ts(j['nextPingAt']),
      pingCount: (j['pingCount'] as num?)?.toInt() ?? 0,
      consecutiveFailures: (j['consecutiveFailures'] as num?)?.toInt() ?? 0,
      lastError: j['lastError'] as String?,
      enabledAt: ts(j['enabledAt']),
    );
  }

  @override
  String toString() => 'AfkStatus(${toJson()})';
}
