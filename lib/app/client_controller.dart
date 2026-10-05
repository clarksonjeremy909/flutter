import 'dart:async';

import 'package:flutter/foundation.dart';
import 'secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/afk/afk_status.dart';
import '../core/control/control_client.dart';
import '../core/control/control_protocol.dart';
import '../core/gamestream/gamestream_client.dart';
import '../core/platform/android_bridge.dart';
import '../core/streaming/moonlight_client_engine.dart';
import '../core/streaming/streaming_engine.dart';
import '../core/streaming/webrtc_fallback_engine.dart';

/// Phone-side app state.
class ClientController extends ChangeNotifier {
  final _secrets = PlatformSecretStore();
  late final SharedPreferences _prefs;

  String host = '';
  int port = ControlProtocol.defaultPort;
  String token = '';
  String deviceName = 'AktifDesk Telefon';
  bool keepScreenOnWithAfk = true;

  ControlClient? control;
  StreamSubscription<void>? _sub;

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

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    host = _prefs.getString('pc.host') ?? '';
    port = _prefs.getInt('pc.port') ?? ControlProtocol.defaultPort;
    deviceName = _prefs.getString('device.name') ?? deviceName;
    keepScreenOnWithAfk = _prefs.getBool('afk.keepScreenOn') ?? true;
    token = await _secrets.read('pc.token') ?? '';
    moonlightPackage = await AndroidBridge.moonlightPackage().catchError((_) => null);
    if (host.isNotEmpty && token.isNotEmpty) {
      await connect();
    }
    notifyListeners();
  }

  ControlConnection get connection => control?.connection ?? ControlConnection.disconnected;
  AfkStatus? get afkStatus => control?.afkStatus;
  Map<String, Object?>? get sunshineStatus => control?.sunshineStatus;

  Future<void> saveConnection(String h, int p, String t, String name) async {
    host = h.trim();
    port = p;
    token = t.trim().toUpperCase();
    deviceName = name.trim().isEmpty ? deviceName : name.trim();
    await _prefs.setString('pc.host', host);
    await _prefs.setInt('pc.port', port);
    await _prefs.setString('device.name', deviceName);
    await _secrets.write('pc.token', token);
    await connect();
  }

  Future<void> connect() async {
    await _sub?.cancel();
    await control?.close();
    final c = ControlClient(host: host, port: port, token: token);
    control = c;
    AfkPhase? lastPhase;
    _sub = c.changes.listen((_) {
      final ph = c.afkStatus?.phase;
      if (ph != lastPhase) {
        lastPhase = ph;
        _applyScreenOn();
      }
      notifyListeners();
    });
    await c.connect();
    unawaited(refreshStream());
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
  Future<void> _afk(Future<void> Function(ControlClient c) f) async {
    final c = control;
    if (c == null) return;
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
        if (control?.connection == ControlConnection.connected) {
          await control!.submitSunshinePin(pin, name: deviceName);
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
    final ok = await control?.submitSunshinePin(pin, name: 'Moonlight ($deviceName)') ?? false;
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
      await control?.prepareSunshine();
      message = 'PC\'de Sunshine hazırlandı';
    } catch (e) {
      message = '$e';
    }
    await refreshStream();
  }

  @override
  void dispose() {
    _sub?.cancel();
    control?.close();
    moonlight.dispose();
    super.dispose();
  }
}
