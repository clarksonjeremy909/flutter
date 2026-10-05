import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/afk/afk_backend_factory.dart';
import '../core/afk/afk_scheduler.dart';
import '../core/afk/afk_status.dart';
import '../core/control/control_protocol.dart';
import '../core/control/discovery.dart';
import '../core/control/pc_control_agent.dart';
import '../core/control/pc_link.dart';
import '../core/streaming/streaming_engine.dart';
import '../core/streaming/sunshine_host_engine.dart';
import '../core/streaming/webrtc_fallback_engine.dart';
import '../core/sunshine/sunshine_api.dart';
import '../core/sunshine/sunshine_config.dart';
import '../core/sunshine/sunshine_host.dart';

/// PC-side app state: AFK scheduler, Sunshine host management, and the
/// links to paired phones (the PC finds the phone by its pairing code and
/// connects to it — no IP addresses in the UI).
class HostController extends ChangeNotifier implements HostSunshineHooks {
  final _secrets = PlatformSecretStore();
  late final SharedPreferences _prefs;

  final afk = AfkScheduler(backend: createPlatformKeepAwakeBackend());
  late final SunshineHostManager sunshine;
  late final EngineSelector<HostStreamingEngine> engines;
  HostStreamingEngine? activeEngine;
  Map<String, String> skippedEngines = {};
  late final PcControlAgent agent;
  late final PcIdentity identity;
  final PcDiscovery discovery = PcDiscovery();
  final links = <String, PhoneLink>{};
  List<PairedPhone> pairedPhones = [];

  PairStage pairStage = PairStage.idle;
  String? pairMessage;
  bool showDashboard = false;

  SunshineHostStatus? sunshineStatus;
  List<SunshinePendingPairing> pendingPairings = [];
  List<SunshineClientInfo> pairedClients = [];
  String? lastMessage;
  bool busy = false;
  int phoneCount = 0;

  final _sunChanges = StreamController<Map<String, Object?>>.broadcast();
  Timer? _poll;
  StreamSubscription<AfkStatus>? _afkSub;
  bool _shutdown = false;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    var pcId = _prefs.getString('pc.id');
    if (pcId == null) {
      pcId = randomToken(16);
      await _prefs.setString('pc.id', pcId);
    }
    identity = PcIdentity(id: pcId, name: Platform.localHostname);
    final stored = await _secrets.read('phones');
    if (stored != null) {
      try {
        pairedPhones = [
          for (final j in jsonDecode(stored) as List)
            PairedPhone.fromJson((j as Map).cast<String, Object?>())
        ];
      } catch (_) {}
    }
    showDashboard = pairedPhones.isNotEmpty;
    final settingsJson = _prefs.getString('sunshine.settings');
    sunshine = SunshineHostManager(
      configuredExePath: _prefs.getString('sunshine.exePath'),
      username: _prefs.getString('sunshine.user') ?? 'aktifdesk',
      password: await _secrets.read('sunshine.pass') ?? '',
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
    agent = PcControlAgent(afk: afk, sunshine: this, hostName: Platform.localHostname)..start();
    agent.clientCountStream.listen((n) {
      phoneCount = n;
      notifyListeners();
    });
    for (final p in pairedPhones) {
      _startLink(p);
    }
    unawaited(refreshSunshine());
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => refreshSunshine());
  }

  // ---------------- Phone pairing / links ----------------
  void _startLink(PairedPhone p, {WebSocket? adopt, String? address}) {
    final l = PhoneLink(phone: p, pc: identity, agent: agent, discovery: discovery);
    links[p.id] = l;
    l.changes.listen((_) => notifyListeners());
    l.start(adopt: adopt, adoptAddress: address);
  }

  Future<void> _savePhones() =>
      _secrets.write('phones', jsonEncode([for (final p in pairedPhones) p.toJson()]));

  /// "Eşleştir": find the phone showing [code] on the LAN and connect.
  Future<bool> pairWithPhone(String code) async {
    if (pairStage == PairStage.searching || pairStage == PairStage.connecting) return false;
    pairMessage = null;
    try {
      final r = await pairWithCode(
        code: code,
        pc: identity,
        discovery: discovery,
        onStage: (s, d) {
          pairStage = s;
          pairMessage = switch (s) {
            PairStage.searching => 'Telefon aranıyor…',
            PairStage.connecting => 'Telefon bulundu: $d — bağlanılıyor…',
            _ => null,
          };
          notifyListeners();
        },
      );
      final old = links.remove(r.phone.id);
      await old?.stop();
      pairedPhones = [...pairedPhones.where((p) => p.id != r.phone.id), r.phone];
      await _savePhones();
      _startLink(r.phone, adopt: r.socket, address: r.address);
      pairStage = PairStage.success;
      pairMessage = 'Eşleşti: ${r.phone.name}';
      showDashboard = true;
      notifyListeners();
      return true;
    } catch (e) {
      pairStage = PairStage.failed;
      pairMessage = '$e';
      notifyListeners();
      return false;
    }
  }

  Future<void> unpairPhone(String id) async {
    await links.remove(id)?.stop();
    pairedPhones = pairedPhones.where((p) => p.id != id).toList();
    await _savePhones();
    notifyListeners();
  }

  void openDashboard() {
    showDashboard = true;
    notifyListeners();
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
        await _secrets.write('sunshine.pass', pass);
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
    for (final l in links.values) {
      await l.stop();
    }
    await agent.stop();
    await _afkSub?.cancel();
    await _sunChanges.close();
  }
}
