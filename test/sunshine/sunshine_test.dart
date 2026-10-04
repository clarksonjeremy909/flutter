import 'dart:io';

import 'package:aktifdesk/core/sunshine/sunshine_config.dart';
import 'package:aktifdesk/core/sunshine/sunshine_host.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRunner implements ProcessRunner {
  final files = <String, String>{};
  final envs = <String, String>{};
  final ran = <String>[];
  String tasklist = '';
  String sc = '[SC] EnumQueryServicesStatus:OpenService FAILED 1060:';
  int scExit = 1060;

  @override
  Future<ProcessResult> run(String exe, List<String> args) async {
    ran.add('$exe ${args.join(' ')}');
    if (exe == 'tasklist') return ProcessResult(1, 0, tasklist, '');
    if (exe == 'sc') return ProcessResult(1, scExit, sc, '');
    return ProcessResult(1, 0, '', '');
  }

  @override
  Future<int> startDetached(String exe, List<String> args, {String? workingDirectory}) async {
    ran.add('start $exe ${args.join(' ')} @ $workingDirectory');
    return 42;
  }

  @override
  bool fileExists(String path) => files.containsKey(path);
  @override
  Future<String?> readFile(String path) async => files[path];
  @override
  Future<void> writeFile(String path, String contents) async => files[path] = contents;
  @override
  String? env(String name) => envs[name];
}

void main() {
  group('SunshineConfigFile', () {
    test('parse, update in place, append, preserve comments', () {
      final f = SunshineConfigFile.parse(
          '# my config\nsunshine_name = Old\n\nencoder=nvenc\r\nfps = [10,30]\n');
      expect(f['sunshine_name'], 'Old');
      expect(f['encoder'], 'nvenc');
      f.merge({'sunshine_name': 'AktifDesk', 'upnp': 'disabled', 'encoder': null});
      expect(f.toString(),
          '# my config\nsunshine_name = AktifDesk\n\nfps = [10,30]\nupnp = disabled\n');
    });

    test('rejects multi-line values', () {
      expect(() => SunshineConfigFile.empty().set('a', 'x\ny'), throwsArgumentError);
    });

    test('managed settings map', () {
      const s = SunshineManagedSettings(hostName: 'Oyun PC', port: 48000);
      expect(s.webUiPort, 48001);
      expect(s.toConfigMap()['sunshine_name'], 'Oyun PC');
      expect(s.toConfigMap()['origin_web_ui_allowed'], 'pc');
      expect(SunshineManagedSettings.fromJson(s.toJson()).port, 48000);
    });
  });

  group('SunshineHostManager detection', () {
    test('configured path (dir or exe) wins over defaults', () {
      final r = FakeRunner()
        ..envs['ProgramFiles'] = r'C:\Program Files'
        ..files[r'D:\Tools\Sunshine\sunshine.exe'] = ''
        ..files[r'C:\Program Files\Sunshine\sunshine.exe'] = '';
      final m = SunshineHostManager(runner: r, configuredExePath: r'D:\Tools\Sunshine');
      expect(m.detectExe(), r'D:\Tools\Sunshine\sunshine.exe');
      m.configuredExePath = r'D:\Tools\Sunshine\sunshine.exe';
      expect(m.detectExe(), r'D:\Tools\Sunshine\sunshine.exe');
      m.configuredExePath = null;
      expect(m.detectExe(), r'C:\Program Files\Sunshine\sunshine.exe');
    });

    test('falls back to PATH; null when missing', () {
      final r = FakeRunner()..envs['PATH'] = r'C:\x;C:\bin';
      final m = SunshineHostManager(runner: r);
      expect(m.detectExe(), isNull);
      r.files[r'C:\bin\sunshine.exe'] = '';
      expect(m.detectExe(), r'C:\bin\sunshine.exe');
      expect(m.configPathFor(r'C:\bin\sunshine.exe'), r'C:\bin\config\sunshine.conf');
    });

    test('process + service detection parsing', () async {
      final r = FakeRunner()
        ..tasklist = '"sunshine.exe","1234","Console","1","50,000 K"';
      final m = SunshineHostManager(runner: r);
      expect(await m.isProcessRunning(), isTrue);
      expect(await m.serviceRunning(), isNull);
      r
        ..scExit = 0
        ..sc = 'SERVICE_NAME: SunshineService\n STATE : 4  RUNNING';
      expect(await m.serviceRunning(), isTrue);
      r.sc = 'SERVICE_NAME: SunshineService\n STATE : 1  STOPPED';
      expect(await m.serviceRunning(), isFalse);
    });

    test('applyConfig falls back to editing sunshine.conf when API is down', () async {
      const exe = r'C:\Program Files\Sunshine\sunshine.exe';
      const conf = r'C:\Program Files\Sunshine\config\sunshine.conf';
      final r = FakeRunner()
        ..envs['ProgramFiles'] = r'C:\Program Files'
        ..files[exe] = ''
        ..files[conf] = '# keep\nmin_log_level = 2\n';
      // Port 1 on loopback: connection refused immediately.
      final m = SunshineHostManager(
          runner: r,
          settings: const SunshineManagedSettings(hostName: 'Salon PC', port: 0));
      final via = await m.applyConfig();
      expect(via, 'file');
      final text = r.files[conf]!;
      expect(text, startsWith('# keep\nmin_log_level = 2\n'));
      expect(text, contains('sunshine_name = Salon PC'));
      expect(text, contains('origin_web_ui_allowed = pc'));
    });

    test('start launches exe detached with its config when not running', () async {
      const exe = r'C:\S\sunshine.exe';
      final r = FakeRunner()
        ..files[exe] = ''
        ..files[r'C:\S\config\sunshine.conf'] = '';
      final m = SunshineHostManager(
          runner: r,
          configuredExePath: exe,
          settings: const SunshineManagedSettings(port: 0));
      await m.start(timeout: Duration.zero);
      expect(r.ran.where((c) => c.startsWith('start ')).single,
          r'start C:\S\sunshine.exe C:\S\config\sunshine.conf @ C:\S');
    });
  });
}
