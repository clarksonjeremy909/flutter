import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'sunshine_api.dart';
import 'sunshine_config.dart';

/// Abstraction over Process so the manager can be tested off-Windows.
abstract class ProcessRunner {
  Future<ProcessResult> run(String exe, List<String> args);
  Future<int> startDetached(String exe, List<String> args, {String? workingDirectory});
  bool fileExists(String path);
  Future<String?> readFile(String path);
  Future<void> writeFile(String path, String contents);
  String? env(String name);
}

class IoProcessRunner implements ProcessRunner {
  const IoProcessRunner();
  @override
  Future<ProcessResult> run(String exe, List<String> args) =>
      Process.run(exe, args, runInShell: false);
  @override
  Future<int> startDetached(String exe, List<String> args,
      {String? workingDirectory}) async {
    final proc = await Process.start(exe, args,
        workingDirectory: workingDirectory, mode: ProcessStartMode.detached);
    return proc.pid;
  }

  @override
  bool fileExists(String path) => File(path).existsSync();
  @override
  Future<String?> readFile(String path) async {
    final f = File(path);
    return f.existsSync() ? f.readAsString() : null;
  }

  @override
  Future<void> writeFile(String path, String contents) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    // Write to temp then rename so Sunshine never sees a half-written file.
    final tmp = File('$path.aktifdesk.tmp');
    await tmp.writeAsString(contents, flush: true);
    if (f.existsSync()) {
      await f.copy('$path.aktifdesk.bak');
    }
    await tmp.rename(path);
  }

  @override
  String? env(String name) => Platform.environment[name];
}

enum SunshineRunState { notInstalled, stopped, starting, running, unknown }

class SunshineHostStatus {
  const SunshineHostStatus({
    required this.runState,
    this.exePath,
    this.configPath,
    this.serviceInstalled = false,
    this.apiReachable = false,
    this.apiAuthOk = false,
    this.version,
    this.message,
  });
  final SunshineRunState runState;
  final String? exePath;
  final String? configPath;
  final bool serviceInstalled;
  final bool apiReachable;
  final bool apiAuthOk;
  final String? version;
  final String? message;

  Map<String, Object?> toJson() => {
        'runState': runState.name,
        'exePath': exePath,
        'configPath': configPath,
        'serviceInstalled': serviceInstalled,
        'apiReachable': apiReachable,
        'apiAuthOk': apiAuthOk,
        'version': version,
        'message': message,
      };

  factory SunshineHostStatus.fromJson(Map<String, Object?> j) =>
      SunshineHostStatus(
        runState: SunshineRunState.values.firstWhere(
            (s) => s.name == j['runState'],
            orElse: () => SunshineRunState.unknown),
        exePath: j['exePath'] as String?,
        configPath: j['configPath'] as String?,
        serviceInstalled: j['serviceInstalled'] == true,
        apiReachable: j['apiReachable'] == true,
        apiAuthOk: j['apiAuthOk'] == true,
        version: j['version'] as String?,
        message: j['message'] as String?,
      );
}

/// Manages a local Sunshine (LizardByte) host on Windows:
/// detection, launching, credentials, config, pairing PINs.
class SunshineHostManager {
  SunshineHostManager({
    this.runner = const IoProcessRunner(),
    this.configuredExePath,
    this.username = 'aktifdesk',
    this.password = '',
    this.settings = const SunshineManagedSettings(),
    this.pinnedCertSha256,
    this.onCertificatePinned,
    this.apiFactory,
  });

  static const serviceName = 'SunshineService';
  static const exeName = 'sunshine.exe';

  final ProcessRunner runner;
  String? configuredExePath;
  String username;
  String password;
  SunshineManagedSettings settings;
  String? pinnedCertSha256;
  void Function(String)? onCertificatePinned;
  final SunshineApi Function(SunshineHostManager m)? apiFactory;
  SunshineApi? _api;

  SunshineApi get api => _api ??= (apiFactory?.call(this) ??
      SunshineApi(
        baseUri: Uri.parse('https://localhost:${settings.webUiPort}'),
        username: username,
        password: password,
        pinnedCertSha256: pinnedCertSha256,
        onCertificatePinned: (fp) {
          pinnedCertSha256 = fp;
          onCertificatePinned?.call(fp);
        },
      ));

  /// Call after changing credentials/port so the next call uses them.
  void resetApi() {
    _api?.close();
    _api = null;
  }

  /// Candidate locations, in priority order.
  List<String> candidateExePaths() {
    final out = <String>[];
    void add(String? s) {
      if (s != null && s.trim().isNotEmpty && !out.contains(s)) out.add(s);
    }

    final cfg = configuredExePath?.trim();
    if (cfg != null && cfg.isNotEmpty) {
      add(cfg.toLowerCase().endsWith('.exe') ? cfg : p.windows.join(cfg, exeName));
    }
    for (final envName in ['ProgramFiles', 'ProgramW6432', 'ProgramFiles(x86)']) {
      final base = runner.env(envName);
      if (base != null) add(p.windows.join(base, 'Sunshine', exeName));
    }
    add(r'C:\Program Files\Sunshine\sunshine.exe');
    final local = runner.env('LOCALAPPDATA');
    if (local != null) add(p.windows.join(local, 'Programs', 'Sunshine', exeName));
    final path = runner.env('PATH');
    if (path != null) {
      for (final dir in path.split(';')) {
        if (dir.trim().isNotEmpty) add(p.windows.join(dir.trim(), exeName));
      }
    }
    return out;
  }

  String? detectExe() {
    for (final c in candidateExePaths()) {
      if (runner.fileExists(c)) return c;
    }
    return null;
  }

  /// `config/sunshine.conf` next to the executable (Sunshine's default on
  /// Windows).
  String configPathFor(String exePath) =>
      p.windows.join(p.windows.dirname(exePath), 'config', 'sunshine.conf');

  Future<bool> isProcessRunning() async {
    try {
      final r = await runner.run('tasklist',
          ['/FI', 'IMAGENAME eq $exeName', '/FO', 'CSV', '/NH']);
      return r.stdout.toString().toLowerCase().contains('"$exeName"');
    } catch (_) {
      return false;
    }
  }

  /// null = not installed; true = running; false = installed but stopped.
  Future<bool?> serviceRunning() async {
    try {
      final r = await runner.run('sc', ['query', serviceName]);
      final out = r.stdout.toString();
      if (r.exitCode != 0 && out.contains('1060')) return null; // not installed
      if (!out.contains('SERVICE_NAME')) return null;
      return out.contains('RUNNING');
    } catch (_) {
      return null;
    }
  }

  Future<SunshineHostStatus> status() async {
    final exe = detectExe();
    final svc = await serviceRunning();
    final running = await isProcessRunning();
    if (exe == null && !running && svc == null) {
      return const SunshineHostStatus(
          runState: SunshineRunState.notInstalled,
          message:
              'sunshine.exe bulunamadı. Sunshine\'ı kurun veya yolunu ayarlardan girin.');
    }
    var reachable = false;
    var authOk = false;
    String? version;
    String? message;
    try {
      final cfg = await api.getConfig();
      reachable = true;
      authOk = true;
      version = cfg['version']?.toString();
    } on SunshineApiException catch (e) {
      reachable = e.statusCode != null;
      message = e.unauthorized
          ? 'Sunshine Web UI kimlik bilgileri hatalı. "Kimlik bilgilerini ayarla" ile sıfırlayın.'
          : e.message;
    }
    return SunshineHostStatus(
      runState: running || svc == true || reachable
          ? SunshineRunState.running
          : SunshineRunState.stopped,
      exePath: exe,
      configPath: exe == null ? null : configPathFor(exe),
      serviceInstalled: svc != null,
      apiReachable: reachable,
      apiAuthOk: authOk,
      version: version,
      message: message,
    );
  }

  /// Start Sunshine: prefers the Windows service when installed, otherwise
  /// launches sunshine.exe detached with its config file. Waits until the API
  /// answers (or [timeout]).
  Future<SunshineHostStatus> start({Duration timeout = const Duration(seconds: 20)}) async {
    if (await isProcessRunning()) return status();
    final svc = await serviceRunning();
    if (svc == false) {
      final r = await runner.run('sc', ['start', serviceName]);
      if (r.exitCode != 0 && !r.stdout.toString().contains('1056')) {
        // Needs admin; fall through to launching the exe directly.
      }
    }
    if (!await isProcessRunning()) {
      final exe = detectExe();
      if (exe == null) {
        throw StateError('sunshine.exe bulunamadı');
      }
      final conf = configPathFor(exe);
      await runner.startDetached(
          exe, [if (runner.fileExists(conf)) conf],
          workingDirectory: p.windows.dirname(exe));
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final s = await status();
      if (s.apiReachable) return s;
      await Future<void>.delayed(const Duration(milliseconds: 750));
    }
    return status();
  }

  Future<void> stop() async {
    final svc = await serviceRunning();
    if (svc == true) {
      final r = await runner.run('sc', ['stop', serviceName]);
      if (r.exitCode == 0) return;
    }
    await runner.run('taskkill', ['/IM', exeName, '/T']);
  }

  /// Set the Web UI username/password using `sunshine.exe --creds`.
  /// Requires write access to Sunshine's state file (usually admin).
  Future<void> setCredentials(String user, String pass) async {
    final exe = detectExe();
    if (exe == null) throw StateError('sunshine.exe bulunamadı');
    final r = await runner.run(exe, ['--creds', user, pass]);
    if (r.exitCode != 0) {
      throw StateError(
          'Kimlik bilgileri ayarlanamadı (yönetici olarak çalıştırmayı deneyin): '
          '${r.stderr}${r.stdout}');
    }
    username = user;
    password = pass;
    resetApi();
  }

  /// Apply [settings] to Sunshine. Uses the REST API when available (Sunshine
  /// writes its own file, no admin needed), otherwise edits sunshine.conf in
  /// place (preserving unrelated keys and comments). Returns which way.
  Future<String> applyConfig({bool restart = true}) async {
    final updates = settings.toConfigMap();
    try {
      await api.updateConfig(updates);
      if (restart) await api.restart();
      return 'api';
    } on SunshineApiException {
      final exe = detectExe();
      if (exe == null) rethrow;
      final path = configPathFor(exe);
      final existing = await runner.readFile(path);
      final file = existing == null
          ? SunshineConfigFile.empty()
          : SunshineConfigFile.parse(existing);
      file.merge(updates);
      await runner.writeFile(path, file.toString());
      return 'file';
    }
  }

  Future<bool> submitPairingPin(String pin, {required String clientName, String? clientAddress}) =>
      api.submitPin(pin, clientName: clientName, clientAddress: clientAddress);
}
