# 🎵 Wiretune — Lossless Audio Streaming & Player Platform

> Önállóan üzemeltethető (self-hosted), bit-perfect veszteségmentes audio streaming szerver és keresztplatformos kliens (.NET 10, Avalonia UI).

---

## 🏛️ Rendszerarchitektúra és komponensek

A Wiretune moduláris, elosztott architektúrára épül, szigorúan szétválasztva a hanglejátszó alrendszert, az adatperzisztenciát, a streaming kiszolgálást és a felhasználói réteget.

```
Wiretune/
├── Wiretune.slnx                  # Solution leíró (.NET 10)
│
├── Wiretune.Core/                 # Domain modellek, interfészek, absztrakciók és közös üzleti logika
├── Wiretune.Data/                 # SQLite perzisztencia (WAL mód, sémaverziózás és migrációk)
├── Wiretune.Audio/                # Hanglejátszó motor (FFmpeg driver, ALSA/PipeWire routing, DSP spektrumanalizátor)
├── Wiretune.Server/               # ASP.NET Core streaming és REST API szerver (JWT auth, inkrementális scanner)
│
├── Wiretune.UI/                   # Megosztott Avalonia FluentUI MVVM prezentációs réteg
├── Wiretune.Desktop/              # Asztali futtatókörnyezet (Linux & Windows)
├── Wiretune.Android/              # Mobil futtatókörnyezet (Android MediaPlayer integráció)
│
└── Wiretune.Tests/                # Automatizált xUnit egység- és integrációs tesztcsomag
```

---

## ⚡ Technológiai specifikáció és képességek

### 1. Streaming és Szerver (`Wiretune.Server`)
- **Protokoll**: RESTful API és **HTTP 206 Partial Content (Range Request)** az azonnali, transzkódolás nélküli FLAC/audió bitfolyam továbbításhoz és alacsony késleltetésű pozicionáláshoz (seek).
- **Hitelesítés és Biztonság**: JWT bearer token hitelesítés (query-string token fallback a külső médialejátszóknak), BCrypt jelszóhashelés. Nincs alapértelmezett hitelesítő adat; első indításkor a felületről inicializálható az adminisztrátori fiók.
- **Könyvtárkezelés**: Aszinkron, inkrementális könyvtárindexelés (méret és módosítási időbélyeg alapján kihagyja a változatlan fájlokat).
- **Metaadatok**: `TagLibSharp` alapú metaadat-kinyerés (FLAC, ALAC, WAV, AIFF, WavPack, APE, DSF, MP3, AAC, OGG, Opus) és többméretű borítókép-gyorsítótárazás.

### 2. Audio Pipeline & Kliens (`Wiretune.Audio`, `Wiretune.Desktop`)
- **Lejátszó motor**: `IAudioDriver` absztrakció, asztali környezetben processz-alapú FFmpeg (`ffplay`) meghajtóval.
- **Linux Bit-Perfect kimenet**: Közvetlen hardveres ALSA kimenet (`hw:X,Y`) vagy dinamikus PipeWire mintavételezési órajel-illesztés a forrásfájl frekvenciájához.
- **0 dB Unity Gain**: Bit-perfect módban automatikus hangerőrögzítés a bit-tisztaság garantálására, kikapcsoláskor az eredeti hangerő visszaállításával.
- **Telemetria és DSP**: 32-sávos FFT spektrumanalizátor és valós idejű jelút (Signal Path) monitorozás.

---

## 📊 Platform-támogatási mátrix

| Képesség | Linux (Desktop) | Windows (Desktop) | Android |
|---|:---:|:---:|:---:|
| **Lejátszó motor** | FFmpeg / ALSA / PipeWire | Natív WASAPI (Shared & Exclusive) | Natív `MediaPlayer` |
| **Kizárólagos (Exclusive) mód** | ✅ (Közvetlen ALSA / PipeWire) | ✅ (WASAPI Exclusive DAC) | ❌ |
| **Bit-Perfect mód (0 dB / rate match)** | ✅ | ✅ | ❌ |
| **Spektrum vizualizáció** | ✅ | ✅ | ❌ |
| **Offline helyi könyvtár** | ✅ | ✅ | ❌ |

---

## 🛠️ Előfeltételek

- **SDK**: [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- **Linux asztali lejátszás**: **FFmpeg** (`ffmpeg` és `ffplay` a rendszer `PATH`-jában).
- **Windows asztali lejátszás**: Beépített Windows Media Foundation + WASAPI (külső FFmpeg függőség nélkül).
- *(Opcionális) Android build*: `dotnet workload install android`.

---

## 🚀 Üzembe helyezés és futtatás

### Szerver indítása
```bash
dotnet run --project Wiretune.Server
```
Alapértelmezett elérés: `http://0.0.0.0:5200`.

### Asztali kliens indítása
```bash
dotnet run --project Wiretune.Desktop
```
- **Hálózati mód**: Csatlakozás a szerverhez (első indításkor adminisztrátor létrehozása).
- **Helyi mód**: A kliens önállóan, szerver nélkül is használható helyi zenemappa kijelölésével.

### Tesztek futtatása
```bash
dotnet test
```

---

## ⚙️ Konfigurációs referencia

### Szerver beállítások (`Wiretune.Server/appsettings.json`)

Parancssorból vagy környezeti változókból is felülbírálható (pl. `--Wiretune:Port=5200`).

| Kulcs | Típus | Alapérték | Leírás |
|---|---|---|---|
| `Wiretune:LibraryPath` | `string` | `WiretuneLibrary` | A zenemappa útvonala (relatív vagy abszolút). Ha nem létezik, a felhasználói *Zene* mappát használja. |
| `Wiretune:DataDirectory` | `string` | `""` | Adatbázis (`wiretune-server.db`), borító-gyorsítótár és logok helye. Üresen: `<AppData>/Wiretune/Server`. |
| `Wiretune:ScanIntervalMinutes` | `int` | `30` | Inkrementális háttér-indexelés intervalluma percben (`0` esetén inaktív). |
| `Wiretune:Port` | `int` | `5200` | HTTP listening port. |

### Környezeti változók

| Változó | Hatókör | Leírás |
|---|---|---|
| `WIRETUNE_DATA_DIR` | Kliens / Szerver | Felülbírálja az alkalmazás adatkönyvtárának gyökerét (`<AppData>/Wiretune`). |
| `WIRETUNE_UI_AUTOMATION` | Asztali kliens | `1` esetén elindítja a helyi tesztautomatizációs HTTP API-t (`127.0.0.1:5201`). |
