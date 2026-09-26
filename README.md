# 🎵 Wiretune — Audiophile Lossless Streamer & Player

> **Önállóan hosztolt, veszteségmentes zenei streaming rendszer: szerver + asztali (Linux / Windows) és Android kliens (C# • Avalonia FluentUI).**
> Tervezve a Spotify és Tidal előfizetések kiváltására, a saját FLAC gyűjtemény professzionális lejátszására és hálózati streamelésére.

---

## ⚡ Főbb Funkciók

- **🌐 Otthoni Streaming Szerver**:
  - `Wiretune.Server`: ASP.NET Core szerver az otthoni gépre, JWT alapú felhasználókezeléssel.
  - A zenemappa indexelése induláskor, beállítható időközönként (inkrementálisan: a változatlan fájlokat nem olvassa újra) és kérésre.
  - **HTTP 206 Partial Content (Range Request)**: azonnali tekerés, a FLAC bitfolyam átkódolás nélkül jut el a kliensig.
  - Első indításkor a kliensből hozható létre az adminisztrátori fiók – **nincs alapértelmezett jelszó**.
- **🎧 Audiophile Bit-Perfect Mód (Linux)**:
  - Közvetlen ALSA hardveres kimenet (`hw:X,Y`) vagy PipeWire órajel-illesztés a forrás mintavételezési frekvenciájára.
  - **0 dB Unity Gain hangerőrögzítés**: kikapcsoláskor a korábbi hangerő visszaáll.
- **🔒 Kizárólagos Mód (Exclusive Mode)**:
  - **Linux**: közvetlen ALSA / PipeWire eszközhozzáférés.
  - **Windows**: jelenleg csak megosztott (WASAPI shared) kimenet érhető el; a felület ezt jelzi, és nem kínál nem létező módot.
- **🏷️ Metaadat és Borítókép Kezelés**:
  - `TagLibSharp` alapú kiolvasás: FLAC, ALAC (m4a), WAV, AIFF, WavPack, APE, DSF, MP3, AAC, Ogg Vorbis, Opus.
  - Beágyazott és mappaszintű (`cover.jpg`, `Folder.png` stb.) borítók; a kliens a képeket megjelenítési méretre dekódolva, korlátos gyorsítótárban tartja.
  - Válogatásalbumok helyes kezelése (Album Artist szerint csoportosítva).
- **📁 Könyvtár, Kedvencek, Lejátszási listák & Keresés**:
  - Előadók, Albumok, Számok nézet, azonnali keresés legjobb találattal.
  - Kedvencek és lejátszási listák (létrehozás, számok hozzáadása/eltávolítása, törlés megerősítéssel) – eszközönként tárolva.
- **💎 Neon & Glassmorphism Felület**:
  - Sötét és világos téma dinamikus háttérgradienssel, keskeny ablakban kompakt elrendezés.
  - Élő 32-sávos spektrumanalizátor és jelút (Signal Path) kijelzés.

---

## 🏗️ Architektúra & Projektstruktúra

```
Wiretune/
├── Wiretune.slnx                  # Solution fájl (.NET 10)
│
├── Wiretune.Core/                 # Platformfüggetlen modellek és üzleti logika (szerver és kliens közös)
│   ├── Models/                    # Track, Album, Artist, Playlist, AudioFormat, AudioFileTypes, UserInfo
│   ├── Audio/                     # IAudioEngine
│   ├── Services/                  # LibraryService, MetadataScanner, ServerSession + ServerStreamingClient (kliens), AppPaths, WiretuneLog
│   └── Repositories/              # ILibraryRepository
│
├── Wiretune.Audio/                # Lejátszó motor
│   ├── Devices/                   # AudioDeviceManager (ALSA, PipeWire, Windows eszközök)
│   ├── Drivers/                   # FfmpegAudioDriver (ffplay alapú lejátszás, ALSA/PipeWire útvonalválasztás)
│   ├── Dsp/                       # FFT spektrumanalizátor, PCM gyorsítótár
│   └── WiretuneAudioEngine.cs     # Módok, eszközök, stream-hitelesítés
│
├── Wiretune.Data/                 # SQLite perzisztencia (sémaverziózás és migráció)
│
├── Wiretune.UI/                   # Avalonia felület (asztal és mobil közös)
│
├── Wiretune.Desktop/              # Asztali futtató (Linux & Windows)
├── Wiretune.Android/              # Android futtató (MediaPlayer alapú lejátszás)
│
├── Wiretune.Server/               # Streaming szerver
│   ├── Auth/AuthService.cs        # Felhasználók, BCrypt, JWT
│   ├── LibraryScanService.cs      # Indítási, időzített és kézi indexelés
│   ├── ServerOptions.cs           # Konfiguráció
│   └── Program.cs                 # REST API és streaming végpontok
│
└── Wiretune.Tests/                # xUnit tesztek, köztük memóriában futó szerver–kliens integrációs tesztek
```

---

## 🚀 Indítás és Használat

### Követelmények
- .NET 10 SDK
- Asztali kliensen **FFmpeg** (`ffplay` és `ffmpeg` a `PATH`-ban). Nélküle a lejátszó hibaüzenetet jelez.

### 1. Szerver indítása (a zenét tároló gépen)
Állítsd be a `Wiretune.Server/appsettings.json` fájlban:

| Kulcs | Jelentés | Alapérték |
|---|---|---|
| `Wiretune:LibraryPath` | A zenemappa (relatív út a szerver mappájához képest) | `WiretuneLibrary`, ha nem létezik: a felhasználó Zene mappája |
| `Wiretune:DataDirectory` | Adatbázis, borító-gyorsítótár, napló helye | `<AppData>/Wiretune/Server` |
| `Wiretune:ScanIntervalMinutes` | Időzített inkrementális újraindexelés (0 = kikapcsolva) | `30` |
| `Wiretune:Port` | HTTP port | `5200` |

```bash
dotnet run --project Wiretune.Server
```
A szerver a `http://0.0.0.0:5200` címen érhető el a helyi hálózaton. Bármely kulcs parancssorból is megadható, pl. `-- --Wiretune:LibraryPath=/srv/music`.

### 2. Asztali kliens indítása (Linux / Windows)
```bash
dotnet run --project Wiretune.Desktop
```
Első indításkor add meg a szerver címét (pl. `192.168.1.10:5200`) és kattints a **Csatlakozás** gombra.
- Friss szervernél itt hozod létre az **adminisztrátori fiókot** (legalább 8 karakteres jelszó).
- Később ugyanitt jelentkezhetsz be; a „Maradjak bejelentkezve” opcióval a kliens induláskor automatikusan visszakapcsolódik.
- Szerver nélkül is használható: **Beállítások → Helyi zenemappa**.

A kliens adatai (gyorsítótár, kedvencek, lejátszási listák) a `<AppData>/Wiretune` mappában vannak; ez a `WIRETUNE_DATA_DIR` környezeti változóval felülírható.

### 3. Tesztek futtatása
```bash
dotnet test
```

### Android
A `Wiretune.Android` projekt nincs a solutionben, mert fordításához az Android workload szükséges (`dotnet workload install android`). A lejátszás az Android `MediaPlayer`-rel történik, exkluzív/bit-perfect mód nélkül.

---

## 🎛️ Audiophile Beállítások

1. Nyisd meg a **Beállítások → Hangkimenet** részt.
2. **Kizárólagos (Exclusive) mód**: a kiválasztott DAC közvetlen lefoglalása (Linux: ALSA `hw:X,Y` vagy PipeWire).
3. **Bit-Perfect mód**: bekapcsolja a kizárólagos módot is, 0 dB-re rögzíti a hangerőt, és a forrás mintavételezési frekvenciáján szól.
4. A **Jelút** panel mutatja a teljes útvonalat, pl.:
   `Forrás: Hi-Res Studio Master (96kHz/24b) → Szerver stream → Bit-perfect (1:1 PCM) → Közvetlen ALSA: USB Audio`.

Ha az adott rendszer egyik eszköze sem támogatja ezeket a módokat (pl. Windows), a kapcsolók inaktívak, és a felület jelzi az okát.

---

## 🧪 Fejlesztői UI-automatizálás

`WIRETUNE_UI_AUTOMATION=1` környezeti változóval az asztali kliens a `http://127.0.0.1:5201/api/ui/...` címen egy csak helyi, böngészőből nem elérhető tesztelő végpontot indít (állapot, navigáció, képernyőkép stb.). Alapértelmezetten ki van kapcsolva.
