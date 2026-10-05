import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/afk/afk_status.dart';
import '../core/control/control_protocol.dart';
import '../core/control/phone_control_server.dart';
import '../core/gamestream/gamestream_client.dart';
import '../core/platform/android_bridge.dart';
import '../core/streaming/moonlight_client_engine.dart';
import '../core/streaming/streaming_engine.dart';
import '../core/streaming/webrtc_fallback_engine.dart';

/// Which phone screen is shown.
enum PhoneStage {
  /// "AktifDesk / Hoş geldin" → "Devam et".
  welcome,

  /// Big pairing code, waiting for the PC.
  code,

  /// "Şu an izinleri aldık — Telefondan PC'yi yönetebilirsin".
  success,

  /// AFK + streaming controls.
  dashboard,
}

/// Phone-side app state. The phone hosts the control channel and shows a
/// pairing code; the PC finds it on the LAN and connects. No IP entry.
class ClientController extends ChangeNotifier {
  ClientController({this.startServer = true});

  /// Tests can skip binding real sockets.
  final bool startServer;

  final _secrets = PlatformSecretStore();
  late final SharedPreferences _prefs;

  /// Last known PC address (taken from the PC's connection, never typed).
  String host = '';
  String deviceId = '';
  String deviceName = 'AktifDesk Telefon';
  bool keepScreenOnWithAfk = true;
  PhoneStage stage = PhoneStage.welcome;

  late PhoneControlServer control;
  StreamSubscription<void>? _sub;
  StreamSubscription<PairingEvent>? _pairSub;

  final moonlight = MoonlightClientEngine();
  late final EngineSelector<ClientStreamingEngine> engines =
      EngineSelector([moonlight, WebRtcClientEngine()]);
  ClientStreamingEngine? engine;
  Map<String, String> skippedEngines = {};

  bool paired = false;
  ServerInfo? serverInfo;
  List<GameStreamApp> apps = [];
  String? moonlightPackage;
  String? message;
  String? pairingPin;
  bool busy = false;
  bool afkBusy = false;
  PairedPc? lastPairedPc;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    host = _prefs.getString('pc.host') ?? '';
    deviceId = _prefs.getString('device.id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = randomToken(12);
      await _prefs.setString('device.id', deviceId);
    }
    deviceName = _prefs.getString('device.name') ?? deviceName;
    keepScreenOnWithAfk = _prefs.getBool('afk.keepScreenOn') ?? true;
    final pcs = <PairedPc>[];
    try {
      final raw = await _secrets.read('pc.pairings');
      if (raw != null) {
        for (final j in jsonDecode(raw) as List) {
          pcs.add(PairedPc.fromJson((j as Map).cast<String, Object?>()));
        }
      }
    } catch (_) {}
    stage = pcs.isEmpty ? PhoneStage.welcome : PhoneStage.dashboard;
    moonlightPackage = await AndroidBridge.moonlightPackage().catchError((_) => null);
    control = PhoneControlServer(deviceId: deviceId, deviceName: deviceName, pairedPcs: pcs);
    _attach(control);
    if (startServer) {
      await AndroidBridge.acquireMulticastLock().catchError((_) => false);
      try {
        await control.start();
      } catch (e) {
        message = 'Bağlantı servisi başlatılamadı: $e';
      }
    }
    if (host.isNotEmpty) unawaited(refreshStream());
    notifyListeners();
  }

  void _attach(PhoneControlServer c) {
    AfkPhase? lastPhase;
    ControlConnection? lastConn;
    String? lastErr;
    _sub = c.changes.listen((_) {
      final ph = c.afkStatus?.phase;
      if (ph != lastPhase) {
        lastPhase = ph;
        _applyScreenOn();
      }
      if (c.connection != lastConn) {
        lastConn = c.connection;
        if (lastConn == ControlConnection.connected && c.peerAddress != null) {
          host = c.peerAddress!;
          unawaited(_prefs.setString('pc.host', host));
          unawaited(refreshStream());
        }
      }
      if (c.lastError != null && c.lastError != lastErr) message = c.lastError;
      lastErr = c.lastError;
      notifyListeners();
    });
    _pairSub = c.pairings.listen((e) async {
      lastPairedPc = e.pc;
      stage = PhoneStage.success;
      await _savePairings();
      notifyListeners();
    });
  }

  Future<void> _savePairings() => _secrets.write(
      'pc.pairings', jsonEncode([for (final p in control.pairedPcs) p.toJson()]));

  ControlConnection get connection => control.connection;
  AfkStatus? get afkStatus => control.afkStatus;
  Map<String, Object?>? get sunshineStatus => control.sunshineStatus;
  String get pairingCode => control.code;
  List<PairedPc> get pairedPcs => control.pairedPcs;

  // ---------------- Onboarding / pairing ----------------
  void continueFromWelcome() {
    stage = PhoneStage.code;
    notifyListeners();
  }

  /// Show a (fresh) pairing code for adding a PC.
  void showPairingCode() {
    control.regenerateCode();
    stage = PhoneStage.code;
    notifyListeners();
  }

  void openDashboard() {
    stage = PhoneStage.dashboard;
    notifyListeners();
  }

  void newCode() {
    control.regenerateCode();
    notifyListeners();
  }

  Future<void> forgetPc(String id) async {
    control.forgetPc(id);
    await _savePairings();
    if (control.pairedPcs.isEmpty) stage = PhoneStage.code;
    notifyListeners();
  }

  Future<void> setDeviceName(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    deviceName = n;
    control.rename(n);
    await _prefs.setString('device.name', n);
    notifyListeners();
  }

  void _applyScreenOn() {
    final on = keepScreenOnWithAfk && (afkStatus?.enabled ?? false);
    unawaited(AndroidBridge.setKeepScreenOn(on).catchError((_) {}));
  }

  Future<void> setKeepScreenOn(bool v) async {
    keepScreenOnWithAfk = v;
    await _prefs.setBool('afk.keepScreenOn', v);
    _applyScreenOn();
    notifyListeners();
  }

  // ---------------- AFK (remote) ----------------
  Future<void> _afk(Future<void> Function(PhoneControlServer c) f) async {
    final c = control;
    afkBusy = true;
    notifyListeners();
    try {
      await f(c);
    } catch (e) {
      message = '$e';
    } finally {
      afkBusy = false;
      notifyListeners();
    }
  }

  Future<void> setAfk(bool on) => _afk((c) => c.setAfk(on));
  Future<void> pingAfk() => _afk((c) => c.pingAfkNow());
  Future<void> setAfkMethod(KeepAwakeMethod m) =>
      _afk((c) => c.setAfk(afkStatus?.enabled ?? false, method: m));

  // ---------------- Streaming (Moonlight protocol) ----------------
  Future<void> refreshStream() async {
    if (host.isEmpty) return;
    try {
      serverInfo = await moonlight.serverInfo(host);
      paired = await moonlight.isPaired(host);
      apps = paired ? await moonlight.apps(host) : [];
    } catch (e) {
      serverInfo = null;
      message = 'GameStream (Sunshine) erişilemiyor: $e';
    }
    final (e, skipped) = await engines.select();
    engine = e;
    skippedEngines = skipped;
    notifyListeners();
  }

  /// GameStream pairing. The PIN is forwarded over the control channel so
  /// the PC app approves it in Sunshine automatically — no typing needed.
  Future<void> pair() async {
    busy = true;
    pairingPin = null;
    notifyListeners();
    try {
      await moonlight.pair(host, onPin: (pin) async {
        pairingPin = pin;
        notifyListeners();
        // Give Sunshine a moment to register the pending request.
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (control.connection == ControlConnection.connected) {
          await control.submitSunshinePin(pin, name: deviceName);
        }
      });
      message = 'Sunshine ile eşleşildi';
    } catch (e) {
      message = 'Eşleştirme başarısız: $e';
    } finally {
      busy = false;
      pairingPin = null;
      await refreshStream();
    }
  }

  /// Forward the PIN shown by the Moonlight app (for its own pairing).
  Future<bool> forwardMoonlightPin(String pin) async {
    final ok = await control.submitSunshinePin(pin, name: 'Moonlight ($deviceName)');
    message = ok ? 'Moonlight eşleştirmesi onaylandı' : 'PIN gönderilemedi/reddedildi';
    notifyListeners();
    return ok;
  }

  Future<void> launch(GameStreamApp? app) async {
    final e = engine;
    if (e == null) {
      message = 'Yayın motoru yok: $skippedEngines';
      notifyListeners();
      return;
    }
    try {
      await e.startStream(StreamTarget(host: host, appId: app?.id, appName: app?.title));
    } catch (err) {
      message = '$err';
    }
    notifyListeners();
  }

  Future<void> quitApp() async {
    await engine?.stopStream();
    await refreshStream();
  }

  Future<void> prepareHost() async {
    try {
      await control.prepareSunshine();
      message = 'PC\'de Sunshine hazırlandı';
    } catch (e) {
      message = '$e';
    }
    await refreshStream();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pairSub?.cancel();
    control.close();
    moonlight.dispose();
    super.dispose();
  }
}
