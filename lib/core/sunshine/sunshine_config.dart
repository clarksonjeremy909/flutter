/// Reader/writer for Sunshine's `sunshine.conf` (`key = value` lines).
///
/// Writing preserves comments, blank lines and key order of the existing
/// file; changed keys are updated in place and new keys appended.
class SunshineConfigFile {
  SunshineConfigFile._(this._lines);

  factory SunshineConfigFile.parse(String text) {
    final lines = <_Line>[];
    for (final raw in const LineSplitterCompat().split(text)) {
      lines.add(_Line.parse(raw));
    }
    // Drop a trailing empty line produced by a final newline.
    if (lines.isNotEmpty && lines.last.raw.isEmpty && text.endsWith('\n')) {
      lines.removeLast();
    }
    return SunshineConfigFile._(lines);
  }

  factory SunshineConfigFile.empty() => SunshineConfigFile._([]);

  final List<_Line> _lines;

  Map<String, String> get values => {
        for (final l in _lines)
          if (l.key != null) l.key!: l.value!,
      };

  String? operator [](String key) => values[key];

  /// Set (or remove when [value] is null) a key.
  void set(String key, String? value) {
    final idx = _lines.lastIndexWhere((l) => l.key == key);
    if (value == null) {
      _lines.removeWhere((l) => l.key == key);
      return;
    }
    if (value.contains('\n')) {
      throw ArgumentError.value(value, key, 'must be a single line');
    }
    final line = _Line.kv(key, value);
    if (idx >= 0) {
      _lines[idx] = line;
    } else {
      _lines.add(line);
    }
  }

  void merge(Map<String, String?> updates) => updates.forEach(set);

  @override
  String toString() =>
      _lines.isEmpty ? '' : '${_lines.map((l) => l.raw).join('\n')}\n';
}

class _Line {
  _Line(this.raw, this.key, this.value);
  factory _Line.kv(String k, String v) => _Line('$k = $v', k, v);
  factory _Line.parse(String raw) {
    final t = raw.trim();
    if (t.isEmpty || t.startsWith('#') || t.startsWith(';')) {
      return _Line(raw, null, null);
    }
    final eq = t.indexOf('=');
    if (eq <= 0) return _Line(raw, null, null);
    return _Line(raw, t.substring(0, eq).trim(), t.substring(eq + 1).trim());
  }
  final String raw;
  final String? key;
  final String? value;
}

/// Splits on \n and \r\n without importing dart:convert's LineSplitter
/// semantics for a trailing newline.
class LineSplitterCompat {
  const LineSplitterCompat();
  List<String> split(String s) =>
      s.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
}

/// Settings AktifDesk manages in Sunshine. Anything else in the user's
/// config is left untouched.
class SunshineManagedSettings {
  const SunshineManagedSettings({
    this.hostName = 'AktifDesk',
    this.port = 47989,
    this.webUiOrigin = 'pc',
    this.upnp = false,
    this.encoder,
    this.extra = const {},
  });

  /// `sunshine_name` shown to Moonlight clients.
  final String hostName;

  /// Base port. HTTPS = port-5, Web UI = port+1, RTSP = port+21.
  final int port;

  /// `origin_web_ui_allowed`: `pc` = localhost only (safest), `lan`, `wan`.
  final String webUiOrigin;
  final bool upnp;

  /// Optional `encoder` (nvenc, quicksync, amdvce, software). null = auto.
  final String? encoder;
  final Map<String, String> extra;

  int get webUiPort => port + 1;
  int get httpsPort => port - 5;

  Map<String, String?> toConfigMap() => {
        'sunshine_name': hostName,
        'port': '$port',
        'origin_web_ui_allowed': webUiOrigin,
        'upnp': upnp ? 'enabled' : 'disabled',
        'encoder': encoder,
        ...extra,
      };

  Map<String, Object?> toJson() => {
        'hostName': hostName,
        'port': port,
        'webUiOrigin': webUiOrigin,
        'upnp': upnp,
        'encoder': encoder,
      };

  factory SunshineManagedSettings.fromJson(Map<String, Object?> j) =>
      SunshineManagedSettings(
        hostName: j['hostName'] as String? ?? 'AktifDesk',
        port: (j['port'] as num?)?.toInt() ?? 47989,
        webUiOrigin: j['webUiOrigin'] as String? ?? 'pc',
        upnp: j['upnp'] == true,
        encoder: j['encoder'] as String?,
      );
}
