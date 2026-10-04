# AktifDesk

Telefon/tablet ile PC oyun yayını ve uzaktan kontrol — **Sunshine/Moonlight** tabanlı,
güçlü bir **AFK (uyanık tutma) modu** ile.

Tek Flutter kod tabanı:

| Platform | Rol |
|---|---|
| **Windows** | Ana makine (host): Sunshine'ı yönetir, AFK modunu çalıştırır, telefona kontrol kanalı açar |
| **Android** | İstemci: PC'ye bağlanır, AFK'yı uzaktan açar/kapatır ve canlı izler, Moonlight protokolüyle eşleşir/oyun başlatır |

## AFK modu (öncelikli özellik)

PC tarafında `AfkScheduler` (`lib/core/afk/afk_scheduler.dart`):

* Açıkken `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)`
  tutulur ve her döngüde yeniden uygulanır (sistem uykusu + ekran kapanması engellenir).
* **Her 2 dakikada** `SendInput` ile zararsız bir giriş gönderilir — sıfır mesafeli
  göreli fare hareketi ve/veya **F15** tuşu (bas/bırak). Böylece Windows ve oyunların
  boşta/AFK sayaçları sıfırlanır. Yöntem arayüzden seçilir (varsayılan: ikisi birden).
* Hatalarda üstel geri çekilme ile yeniden dener (15 sn, 30 sn, … en fazla aralık kadar).
  `SendInput` başarısızsa (ör. kilit ekranı / yönetici olarak çalışan pencere — UIPI)
  durum **"degraded"** olur, uyku engeli tutulmaya devam eder.
* Uyku/uyanma ve saat atlamalarına dayanıklı: tek uzun zamanlayıcı yerine 5 sn'lik
  kalp atışıyla duvar saatini kontrol eder; uyanınca tek bir telafi ping'i atar (patlama yok).
* Kapatıldığında `SetThreadExecutionState(ES_CONTINUOUS)` ile temizce bırakır; kapatma,
  devam eden bir döngüyle yarışsa bile hiçbir şey tutulu kalmaz. Pencere kapanırken /
  uygulama çıkarken otomatik bırakılır.
* Durum göstergesi (renkli nabız), **son ping zamanı** (saat + "x sn önce"), sonraki ping,
  uyku engeli durumu, ping sayısı, ardışık hata ve son hata — **hem PC'de hem telefonda**.
  Telefon, durumu kontrol kanalı üzerinden canlı alır; bağlantı koparsa AFK PC'de
  çalışmaya devam eder ve telefon bunu gösterir. İsteğe bağlı: AFK açıkken telefon
  ekranını açık tut.

Windows tarafı ham `dart:ffi` ile (`lib/core/afk/windows_keep_awake_backend.dart`),
zamanlama mantığı platformdan bağımsız ve `fake_async` ile birim testli
(`test/afk/afk_scheduler_test.dart`, 22 test).

## Sunshine (Windows host)

`SunshineHostManager` (`lib/core/sunshine/sunshine_host.dart`):

* `sunshine.exe`'yi bulur: ayarlanabilir yol (klasör veya exe) → `Program Files` →
  `LOCALAPPDATA\Programs` → `PATH`.
* Çalışıyor mu: `tasklist`, Windows hizmeti `SunshineService` (`sc query`).
* Başlatma: hizmet varsa `sc start`, yoksa `sunshine.exe <config>` ayrık süreç; API yanıt
  verene kadar bekler. Durdurma: `sc stop` / `taskkill`.
* Web UI kimlik bilgileri: mevcutları kullan ya da `sunshine.exe --creds` ile yenisini ata.
* Yapılandırma: önce REST API (`GET`+birleştir+`POST /api/config`, sonra `/api/restart`);
  API yoksa `config\sunshine.conf` dosyası yerinde düzenlenir (yorumlar ve diğer anahtarlar
  korunur, atomik yazma + `.bak`). Yönetilen anahtarlar: `sunshine_name`, `port`,
  `origin_web_ui_allowed=pc`, `upnp`, `encoder`.
* API: `https://localhost:47990` (port+1), Basic auth, self-signed sertifika **yalnızca
  loopback** için ve ilk kullanımda SHA-256 ile sabitlenir (TOFU). PIN eşleştirme
  `POST /api/pin` — yeni Sunshine'daki `pairing_id` (bekleyen istekler `GET /api/pin`)
  ve eski `{pin,name}` biçimi desteklenir; CSRF belirteci varsa gönderilir.

## Moonlight protokolü (Android istemci)

`GameStreamClient` (`lib/core/gamestream/gamestream_client.dart`) — saf Dart:

* `serverinfo`, tam **PIN eşleştirme el sıkışması** (getservercert → clientchallenge →
  serverchallengeresp → clientpairingsecret → HTTPS pairchallenge; AES-128-ECB,
  SHA-256, RSA-2048 imza/doğrulama, MITM kontrolü), `applist`, `launch`, `resume`, `cancel`.
* İstemci kimliği: RSA-2048 + kendinden imzalı X.509 (kendi DER kodlayıcımız), güvenli
  depoda saklanır; HTTPS'te sunucu sertifikası eşleştirmede sabitlenir.
* **Otomatik eşleştirme:** telefon PIN üretir ve kontrol kanalıyla PC'ye iletir; PC
  uygulaması Sunshine'a `/api/pin` ile gönderir — kullanıcı hiçbir şey yazmaz.
* Medya düzlemi (RTSP/ENet/RTP + donanım çözme) için yüklü **Moonlight** uygulamasına
  `ShortcutTrampoline` intent'iyle (PC UUID + AppId) devredilir. Moonlight'ın kendi
  eşleştirmesi için gösterdiği PIN, uygulamadan PC'ye iletilebilir.

## Yayın motoru soyutlaması

`lib/core/streaming/streaming_engine.dart`: `HostStreamingEngine` / `ClientStreamingEngine`
ve öncelik sırasıyla seçen `EngineSelector`.

* Birincil: `SunshineHostEngine` (PC), `MoonlightClientEngine` (Android).
* Yedek: `WebRtcHostEngine` / `WebRtcClientEngine` — yalnızca birincil kullanılamazsa;
  medya arka ucu (`WebRtcMediaBackend`) bu derlemede paketlenmedi, takılabilir.

## Kontrol kanalı

PC, LAN'da `ws://<pc>:47100/aktifdesk` WebSocket sunucusu açar; telefon PC'de görünen
8 karakterli **bağlantı kodunu** `X-AktifDesk-Token` başlığıyla gönderir (sabit zamanlı
karşılaştırma). Komutlar: `afk.set`, `afk.ping`, `status.get`, `sunshine.pin`,
`sunshine.prepare`; PC `afk.status` / `sunshine.status` değişikliklerini anında iter.
İstemci otomatik yeniden bağlanır (üstel geri çekilme), 10 sn WebSocket ping.

## Derleme ve test

```bash
flutter test                 # 44 test: AFK zamanlayıcı, eşleştirme, Sunshine, kontrol kanalı, arayüz
flutter build windows        # Windows'ta
flutter build apk            # Android
```

Notlar:
* Oyun yönetici olarak çalışıyorsa Windows UIPI `SendInput`'u engelleyebilir; o zaman
  AktifDesk'i de yönetici olarak çalıştırın (uyku engeli yine de çalışır, durum "degraded" görünür).
* Sunshine ayarlarını dosyaya yazmak `Program Files` altında yönetici izni gerektirebilir;
  API yolu (Sunshine çalışırken) izin gerektirmez.
* Windows Güvenlik Duvarı'nda 47100 (AktifDesk) ve Sunshine portlarına özel ağ izni verin.
