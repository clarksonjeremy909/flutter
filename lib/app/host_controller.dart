import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/afk/afk_backend_factory.dart';
import '../core/afk/afk_scheduler.dart';
import '../core/afk/afk_status.dart';
import '../core/control/control_protocol.dart';
import '../core/control/control_server.dart';
import '../core/streaming/streaming_engine.dart';
import '../core/streaming/sunshine_host_engine.dart';
import '../core/streaming/webrtc_fallback_engine.dart';
import '../core/sunshine/sunshine_api.dart';
import '../core/sunshine/sunshine_config.dart';
import '../core/sunshine/sunshine_host.dart';

/// PC-side app state: AFK scheduler, Sunshine host management, control server.
class HostController extends ChangeNotifier implements HostSunshineHooks {
  static const _secure = FlutterSecureStorage();
  late final SharedPreferences _prefs;

  final afk = AfkScheduler(backend: createPlatformKeepAwakeBackend());
  late final SunshineHostManager sunshine;
  late final EngineSelector<HostStreamingEngine> engines;
  HostStreamingEngine? activeEngine;
  Map<String, String> skippedEngines = {};
  ControlServer? server;

  SunshineHostStatus? sunshineStatus;
  List<SunshinePendingPairing> pendingPairings = [];
  List<SunshineClientInfo> pairedClients = [];
  List<String> localAddresses = [];
  String token = '';
  int controlPort = ControlProtocol.defaultPort;
  String? serverError;
  String? lastMessage;
  bool busy = false;
  int phoneCount = 0;

  final _sunChanges = StreamController<Map<String, Object?>>.broadcast();
  Timer? _poll;
  StreamSubscription<AfkStatus>? _afkSub;
  bool _shutdown = false;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    token = await _secure.read(key: 'control.token') ?? _newToken();
    await _secure.write(key: 'control.token', value: token);
    controlPort = _prefs.getInt('control.port') ?? ControlProtocol.defaultPort;
    final settingsJson = _prefs.getString('sunshine.settings');
    sunshine = SunshineHostManager(
      configuredExePath: _prefs.getString('sunshine.exePath'),
      username: _prefs.getString('sunshine.user') ?? 'aktifdesk',
      password: await _secure.read(key: 'sunshine.pass') ?? '',
      pinnedCertSha256: _prefs.getString('sunshine.certSha256'),
      onCertificatePinned: (fp) => _prefs.setString('sunshine.certSha256', fp),
      settings: settingsJson == null
          ? SunshineManagedSettings(hostName: Platform.localHostname)
          : SunshineManagedSettings.fromJson(
              (jsonDecode(settingsJson) as Map).cast<String, Object?>()),
    );
    engines = EngineSelector<HostStreamingEngine>([
      SunshineHostEngine(sunshine),
      WebRtcHostEngine(), // fallback only; no media backend bundled
    ]);
    _afkSub = afk.statusStream.listen((_) => notifyListeners());
    final method = KeepAwakeMethod.parse(_prefs.getString('afk.method'));
    await afk.setMethod(method);
    await _startServer();
    unawaited(_loadAddresses());
    unawaited(refreshSunshine());
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => refreshSunshine());
  }

  String _newToken() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(8, (_) => alphabet[r.nextInt(alphabet.length)]).join();
  }

  Future<void> regenerateToken() async {
    token = _newToken();
    await _secure.write(key: 'control.token', value: token);
    server?.token = token;
    notifyListeners();
  }

  Future<void> _startServer() async {
    final s = ControlServer(
      afk: afk,
      token: token,
      sunshine: this,
      hostName: Platform.localHostname,
      port: controlPort,
    );
    try {
      await s.start();
      s.clientCountStream.listen((n) {
        phoneCount = n;
        notifyListeners();
      });
      server = s;
      serverError = null;
    } catch (e) {
      serverError = 'Kontrol sunucusu başlatılamadı (port $controlPort): $e';
    }
  }

  Future<void> _loadAddresses() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      localAddresses = [
        for (final i in ifs)
          for (final a in i.addresses)
            if (!a.isLoopback) a.address
      ];
      notifyListeners();
    } catch (_) {}
  }

  // ---------------- AFK ----------------
  Future<void> setAfk(bool on) => on ? afk.enable() : afk.disable();

  Future<void> setAfkMethod(KeepAwakeMethod m) async {
    await _prefs.setString('afk.method', m.name);
    await afk.setMethod(m);
    notifyListeners();
  }

  // ---------------- Sunshine ----------------
  Future<void> refreshSunshine() async {
    if (_shutdown) return;
    try {
      sunshineStatus = await sunshine.status();
      if (sunshineStatus!.apiAuthOk) {
        pendingPairings = await sunshine.api.pendingPairings();
        pairedClients = await sunshine.api.getClients();
      } else {
        pendingPairings = [];
      }
    } catch (e) {
      lastMessage = '$e';
    }
    if (!_sunChanges.isClosed) _sunChanges.add(sunshineStatus?.toJson() ?? const {});
    notifyListeners();
  }

  Future<T?> _run<T>(Future<T> Function() f, {String? ok}) async {
    busy = true;
    notifyListeners();
    try {
      final r = await f();
      if (ok != null) lastMessage = ok;
      return r;
    } catch (e) {
      lastMessage = '$e';
      return null;
    } finally {
      busy = false;
      await refreshSunshine();
    }
  }

  Future<void> saveExePath(String path) async {
    sunshine.configuredExePath = path.trim().isEmpty ? null : path.trim();
    await _prefs.setString('sunshine.exePath', path.trim());
    await refreshSunshine();
  }

  Future<void> saveCredentials(String user, String pass, {bool applyToSunshine = false}) =>
      _run(() async {
        if (applyToSunshine) {
          await sunshine.setCredentials(user, pass);
        } else {
          sunshine.username = user;
          sunshine.password = pass;
          sunshine.resetApi();
        }
        await _prefs.setString('sunshine.user', user);
        await _secure.write(key: 'sunshine.pass', value: pass);
      }, ok: 'Kimlik bilgileri kaydedildi');

  Future<void> saveSettings(SunshineManagedSettings s) => _run(() async {
        sunshine.settings = s;
        sunshine.resetApi();
        await _prefs.setString('sunshine.settings', jsonEncode(s.toJson()));
        final via = await sunshine.applyConfig();
        lastMessage = via == 'api'
            ? 'Ayarlar Sunshine API ile uygulandı, Sunshine yeniden başlatılıyor'
            : 'Ayarlar sunshine.conf dosyasına yazıldı (Sunshine\'ı yeniden başlatın)';
      });

  Future<void> startHost() => _run(() async {
        final (engine, skipped) = await engines.select();
        skippedEngines = skipped;
        activeEngine = engine;
        if (engine == null) throw StateError('Kullanılabilir yayın motoru yok: $skipped');
        await engine.prepareHost();
        lastMessage = '${engine.displayName}: ${engine.status.message ?? engine.status.state.name}';
      });

  Future<void> stopHost() => _run(() => sunshine.stop(), ok: 'Sunshine durduruldu');

  Future<void> approvePin(String pin, {String? pairingId, String name = 'Telefon'}) => _run(() async {
        final ok = await sunshine.api.submitPin(pin, clientName: name, pairingId: pairingId);
        lastMessage = ok ? 'Eşleştirme onaylandı' : 'PIN reddedildi';
      });

  Future<void> unpairClient(String uuid) =>
      _run(() => sunshine.api.unpair(uuid), ok: 'Eşleştirme kaldırıldı');

  // ---------------- HostSunshineHooks (for the phone) ----------------
  @override
  Stream<Map<String, Object?>> get changes => _sunChanges.stream;

  @override
  Future<Map<String, Object?>> status() async =>
      (sunshineStatus ?? await sunshine.status()).toJson();

  @override
  Future<void> prepare() => startHost();

  @override
  Future<bool> submitPin(String pin, {required String clientName, String? clientAddress}) async {
    final ok = await sunshine.submitPairingPin(pin,
        clientName: clientName, clientAddress: clientAddress);
    unawaited(refreshSunshine());
    return ok;
  }

  /// Release everything (window close / app exit). AFK is disabled first so
  /// the execution state is cleared before the process goes away.
  Future<void> shutdown() async {
    if (_shutdown) return;
    _shutdown = true;
    _poll?.cancel();
    await afk.dispose();
    await server?.stop();
    await _afkSub?.cancel();
    await _sunChanges.close();
  }
}
