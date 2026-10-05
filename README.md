# AktifDesk

[![Build](https://github.com/clarksonjeremy909/flutter/actions/workflows/build.yml/badge.svg)](https://github.com/clarksonjeremy909/flutter/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/clarksonjeremy909/flutter)](https://github.com/clarksonjeremy909/flutter/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Turn your Android phone or tablet into a low-latency game-streaming remote and controller for your Windows PC — powered by [Sunshine](https://github.com/LizardByte/Sunshine) / [Moonlight](https://moonlight-stream.org/).**

AktifDesk is a single Flutter codebase with two roles:

| Platform | Role |
|---|---|
| **Windows** (`AktifDesk.exe`) | **Host.** Finds, starts and configures Sunshine, runs the AFK keep-awake engine, and connects to your phone after you type the phone's pairing code. |
| **Android** (`AktifDesk.apk`) | **Client.** Shows a 6-digit pairing code and waits for the PC on the LAN, pairs with Sunshine using the Moonlight/GameStream protocol, launches games, and monitors/controls AFK mode live. |

> **Status: v1.1.0 — early public release.** The core (Sunshine management, GameStream pairing, control channel, AFK engine) is implemented and unit-tested. Some features below are on the roadmap and are clearly marked. Please read [Limitations](#limitations--todos) before relying on it.

---

## Features

### Available in v1.1.0

- **Code-only pairing — no IP addresses anywhere.**
  - The phone shows a **6-digit pairing code** (*Eşleştirme kodun*). You type it on the PC (*Eşleştirme kodunu gir* → *Eşleştir*); the PC finds the phone on the LAN by itself (UDP discovery, no mDNS dependency) and connects.
  - After the first pairing the PC remembers the phone (long-term random key) and reconnects automatically whenever both apps are open, even if the phone's IP changed.
  - Moonlight/GameStream pairing is automatic: the phone generates the **4-digit PIN** and forwards it to the PC, which submits it to Sunshine for you.
- **Sunshine host management (Windows).** Locates `sunshine.exe` (custom path → Program Files → LocalAppData → `PATH`), detects the `SunshineService` service, starts/stops it, sets Web UI credentials, and applies settings through Sunshine's REST API (or edits `sunshine.conf` safely with a `.bak` backup when the API isn't up).
- **Native Moonlight/GameStream client (pure Dart).** `serverinfo`, full PIN pairing handshake (AES-128, SHA-256, RSA-2048 signatures, MITM check), app list, launch / resume / quit. The server certificate is pinned after pairing.
- **Full-screen, hardware-decoded streaming via Moonlight.** Once paired and launched, the video session is handed to the installed Moonlight app, which provides full-screen low-latency playback, **physical keyboard + mouse passthrough** (press `W` on a Bluetooth/USB keyboard and your character moves), gamepad support and its own on-screen controls.
- **Robust AFK mode (Windows host).**
  - Holds `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)` so the PC and display don't sleep.
  - **Every 2 minutes** sends a harmless `SendInput` (zero-distance relative mouse move and/or an `F15` key tap) to reset Windows/game idle timers.
  - Exponential back-off on errors, a "degraded" state if `SendInput` is blocked (e.g. UIPI), sleep/clock-jump resilience, and a clean release on exit.
  - Live status (last ping, next ping, error count) on **both** the PC and the phone; optionally keeps the phone screen on while AFK is active.
- **Live LAN control channel** with automatic reconnect and status push.

### Roadmap (planned, not yet in v1.1.0)

These are the target experience for AktifDesk's own in-app player. Until it ships, the equivalent functions are provided by the Moonlight app that AktifDesk hands the stream to.

- **Floating side button → slide-out side menu** during a session (AFK toggle, keyboard, settings, disconnect).
- **FPS selector from 44 to 130 FPS** in the AktifDesk UI (the protocol already sends a configurable `WxHxFPS` mode; default 1080p60).
- **Custom, editable virtual controls** — drag-and-resize layouts for WASD, a full on-screen keyboard, and mouse buttons/trackpad.
- **WebRTC fallback engine** — the engine abstraction and selector exist, but the media backend is a stub and is not bundled.

---

## How it works

```
        Windows PC                                         Android phone / tablet
┌──────────────────────────────┐  UDP discovery :47101    ┌──────────────────────────────┐
│ AktifDesk.exe (host)         │ ── query (HMAC of code) ►│ AktifDesk (client)           │
│  • PcDiscovery / PhoneLink   │ ◄── reply / beacon ───── │  • PhoneAdvertiser           │
│  • PcControlAgent            │  WebSocket → phone:47100 │  • PhoneControlServer        │
│                              │ ────────────────────────►│    (code / key auth)         │
│  • AfkScheduler (FFI)        │                          │  • GameStreamClient (Dart)   │
│  • SunshineHostManager ──┐   │                          │      │ pair / applist /      │
│                          ▼   │   GameStream HTTP(S)     │      │ launch                │
│  Sunshine (REST :47990) ◄────┼──────────────────────────┼──────┘                       │
│     │                        │                          │                              │
│     └── RTSP/RTP video+audio, ENet input ───────────────┼─► Moonlight app (decode,     │
│                              │                          │   full-screen, kbd/mouse)    │
└──────────────────────────────┘                          └──────────────────────────────┘
```

1. **Windows host manages Sunshine.** AktifDesk finds and starts Sunshine, keeps its Web UI credentials, pins Sunshine's self-signed certificate on first use (loopback only), and pushes managed settings (`sunshine_name`, `port`, `upnp`, `encoder`, `origin_web_ui_allowed=pc`).
2. **Pairing & discovery (no IP entry).**
   - The phone hosts the control WebSocket on **TCP 47100** (ephemeral port if busy), listens on **UDP 47101**, and broadcasts a small beacon every 2 s. It shows a one-time **6-digit code**.
   - When you type the code on the PC, the PC sends discovery queries to the LAN broadcast addresses (plus a unicast sweep of the local /24 as a fallback for routers that drop broadcasts), each carrying `HMAC-SHA256(code, nonce)`. Only the phone showing that code answers, with its port and an HMAC proof. The code itself never travels in discovery packets.
   - The PC then connects to `ws://<phone>:<port>/aktifdesk` with the code in `X-AktifDesk-Token` and a fresh random key in `X-AktifDesk-Pair-Key`. The phone verifies the code (constant-time), stores the key, and rotates the code (codes are one-time; 5 wrong attempts also rotate it).
   - Later the PC finds the phone by its device id and reconnects with the stored key — no code needed.
   - Commands (phone → PC): `afk.set`, `afk.ping`, `status.get`, `sunshine.pin`, `sunshine.prepare`; the PC pushes `hello`, `afk.status` / `sunshine.status` updates.
3. **Android speaks Moonlight/GameStream.** The phone has its own RSA-2048 client identity and self-signed X.509 cert (stored in Android secure storage), performs the GameStream PIN pairing with Sunshine, and lists/launches apps.
4. **Video.** The media plane (RTSP/ENet/RTP + hardware decode) is delegated to the installed **Moonlight** Android app via an intent (`ShortcutTrampoline` with the PC UUID and App ID).
5. **Fallback.** A `WebRtcHostEngine` / `WebRtcClientEngine` pair is selected only if the primary engines are unavailable; in v1.1.0 the media backend is still a stub.

Code map:

| Path | What |
|---|---|
| `lib/core/afk/` | AFK scheduler + Windows `dart:ffi` backend |
| `lib/core/sunshine/` | Sunshine discovery, REST API, config file editing |
| `lib/core/gamestream/` | Pure-Dart GameStream client, pairing crypto, DER/X.509 |
| `lib/core/control/` | UDP discovery, pairing codes, control protocol (phone-hosted WebSocket, PC agent/links) |
| `lib/core/streaming/` | Streaming engine abstraction (Sunshine/Moonlight primary, WebRTC fallback) |
| `lib/app/` | Host / client controllers, secret storage |
| `lib/ui/` | Flutter UI |

---

## Download

Grab the latest build from **[GitHub Releases](https://github.com/clarksonjeremy909/flutter/releases/latest)**:

- `AktifDesk-windows-x64.zip` — Windows host (unzip anywhere and run `AktifDesk.exe`)
- `AktifDesk-android.apk` — Android client (universal APK: arm64-v8a, armeabi-v7a, x86_64)
- `AktifDesk-android-arm64-v8a.apk` / `-armeabi-v7a.apk` / `-x86_64.apk` — smaller per-ABI APKs (most phones: `arm64-v8a`)

Every push to `main` also produces downloadable artifacts in [GitHub Actions](https://github.com/clarksonjeremy909/flutter/actions).

> The APK is currently signed with a debug key. Android will ask you to allow installation from unknown sources.

---

## Setup

1. **Install Sunshine on your PC** — <https://github.com/LizardByte/Sunshine/releases> (installer or portable).
2. **Install Moonlight on your phone** ([Google Play](https://play.google.com/store/apps/details?id=com.limelight)) — used for video decoding.
3. **Pair the phone and the PC** (both on the same Wi-Fi/LAN — no addresses to type):
   1. **Android:** open AktifDesk → *AktifDesk / Hoş geldin* → tap **Devam et** (Continue). The phone shows a big 6-digit code under *Eşleştirme kodun* (“your pairing code”) with *Bunu PC'deki cihazına gir* (“enter this on your PC”) and waits.
   2. **Windows:** run `AktifDesk.exe`. On the *Aktif Desk* screen, type the code into **Eşleştirme kodunu gir** (“enter the pairing code”) and click **Eşleştir** (Pair). The PC finds the phone on the network and connects.
   3. **Android** confirms with *Şu an izinleri aldık — Telefondan PC'yi yönetebilirsin* (“We have the permissions — you can manage the PC from your phone”). Tap **Devam et** to open the AFK and streaming controls.
   
   From then on the PC reconnects to the phone automatically whenever both apps are open. To add another PC, use *Yeni PC eşleştir* in the phone's menu; to add another phone, use *Yeni telefon eşleştir* on the PC.
4. On the phone tap **Prepare Sunshine on PC** (*PC'de Sunshine'ı hazırla*), then **Pair (automatic PIN)** (*Eşleştir (otomatik PIN)*). Pick a game or *Desktop* (*Masaüstü*) to start streaming.
5. **Firewall** (private network): the PC only makes *outgoing* connections to the phone, so the AktifDesk control channel needs no inbound rule on the PC. If Windows asks, allow AktifDesk on **private networks** so it can also hear the phone's discovery beacons (UDP 47101).
   - Sunshine (default base port 47989): **TCP 47984, 47989, 47990, 48010** and **UDP 47998–48000, 48002, 48010**

> **Pairing troubleshooting:** the phone and PC must be on the same LAN segment. Guest Wi-Fi / “AP isolation” / client isolation blocks device-to-device traffic and discovery. Keep AktifDesk open in the foreground on the phone while pairing.

> If your game runs as Administrator, Windows UIPI can block `SendInput`. Run AktifDesk as Administrator too (the sleep block keeps working either way; AFK status will show *degraded*).

---

## Build from source

Requirements: Flutter (stable, Dart ≥ 3.13), Android SDK + JDK 17 for Android, Visual Studio 2022 with **Desktop development with C++** (including the **C++ ATL** component) for Windows.

```bash
git clone https://github.com/clarksonjeremy909/flutter.git aktifdesk
cd aktifdesk
flutter pub get

flutter analyze
flutter test                     # 55 tests: AFK scheduler, GameStream pairing, Sunshine, discovery + control channel, UI

flutter build apk --release      # Android  -> build/app/outputs/flutter-apk/app-release.apk
flutter build apk --release --split-per-abi   # per-ABI APKs (app-arm64-v8a-release.apk, …)
flutter config --enable-windows-desktop
flutter build windows --release  # Windows  -> build/windows/x64/runner/Release/AktifDesk.exe
```

You can run the host UI on a non-Windows desktop for development with `--dart-define=AKTIFDESK_HOST=true` (Windows-only calls are no-ops there).

CI (`.github/workflows/build.yml`) builds both targets on every push to `main`; pushing a `v*` tag publishes a GitHub Release with both binaries attached.

---

## Limitations & TODOs

Being honest about where v1.1.0 stands:

- **Windows-only code paths have not been tested on real hardware yet.** The `SetThreadExecutionState` / `SendInput` FFI calls, Sunshine service control (`sc`, `tasklist`, `taskkill`) and the Windows build are compiled in CI and covered by unit tests with fakes, but have not been exercised end-to-end on a physical Windows PC.
- **Anti-cheat may block virtual input.** Some games/anti-cheat systems ignore or flag `SendInput` events and virtual devices. Use at your own risk and respect each game's terms of service.
- **AFK is not guaranteed.** Games with their own server-side or input-pattern AFK detection may still kick you; the AFK engine only resets the OS/game idle timers that react to local input.
- **Video decode is handed to the installed Moonlight app.** AktifDesk does not yet render the stream itself, so the in-app player features (side menu, FPS selector, editable virtual controls) are on the roadmap.
- **WebRTC fallback is a stub** — no media backend is bundled.
- **Secrets on Windows** (phone pairing keys, Sunshine Web UI password) are stored in the user profile via SharedPreferences, not encrypted. Moving them to DPAPI is a TODO. On Android they use the Keystore-backed secure storage.
- **The control channel is plain `ws://` on the LAN.** The first connection is authenticated by the 6-digit one-time code, later ones by a 256-bit random key, but traffic is not encrypted and a 6-digit code is brute-forceable by an attacker who can sniff the LAN during pairing. Pair on a trusted network and don't expose ports 47100/47101 to the internet. TLS / a PAKE-based pairing is a TODO.
- **Discovery uses UDP broadcast + a /24 sweep**, not mDNS; networks that isolate clients (guest Wi-Fi, AP isolation) prevent pairing.
- **The phone must have AktifDesk open** for the PC to connect; there is no Android background service yet.
- **Release APK is debug-signed**; a proper release keystore is a TODO.
- The UI is currently in Turkish; English localisation is a TODO.

Contributions and bug reports are welcome via [Issues](https://github.com/clarksonjeremy909/flutter/issues).

---

## License

[MIT](LICENSE) © 2026 Miraç Aytaç

AktifDesk is an independent project and is not affiliated with the Sunshine or Moonlight projects. Sunshine is licensed under GPL-3.0 and Moonlight under GPL-3.0; they are installed separately and are not bundled with AktifDesk.
