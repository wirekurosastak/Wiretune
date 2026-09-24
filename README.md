# 🎵 Wiretone — Audiophile Lossless Streamer & Player

> **Natív, bit-perfect és exkluzív módú veszteségmentes zenelejátszó és otthoni streaming rendszer (C# • Avalonia FluentUI).**
> Tervezve a Spotify és Tidal előfizetések kiváltására, a **spotiFLAC** által letöltött FLAC albumok és zeneszámok professzionális lejátszására és hálózati streamelésére.

---

## ⚡ Főbb Funkciók

- **🎧 Audiophile Bit-Perfect Mód**:
  - Teljes mértékben megkerüli az operációs rendszer szoftveres keverőjét (OS Mixer bypass).
  - Automatikus hardveres mintavételezési frekvencia illesztés a DAC-hoz (44.1 kHz, 48 kHz, 88.2 kHz, 96 kHz, 176.4 kHz, 192 kHz).
  - **0 dB Unity Gain hangerőrögzítés**: Kizárja a digitális csonkolást, dither-t és felbontásvesztést a 24-bites FLAC hangfájloknál.
- **🔒 Kizárólagos Mód (Exclusive Mode)**:
  - **Linux**: Közvetlen hardveres ALSA kimenet (`hw:X,Y`, pl. SMSL USB AUDIO DAC) és PipeWire Pro Audio stream közvetlen illesztéssel.
  - **Windows**: WASAPI Exclusive Mode (`AUDCLNT_SHAREMODE_EXCLUSIVE`), hardveres DMA pufferméret-vezérléssel.
- **🏷️ Teljes Metaadat és Borítókép Kezelés**:
  - `TagLibSharp` alapú közvetlen metaadat-kiolvasás FLAC, MP3, WAV, ALAC, AAC formátumokból.
  - Cím, Előadó, Album, Év, Műfaj, Lemez- és számsorszám, Bitmélység (16/24/32-bit), Mintavételezési frekvencia (kHz), Bitráta.
  - Beágyazott lemezborítók automatikus kibontása és memóriahatékony gyorsítótárazása.
- **📁 Könyvtár Rendszerezés & Keresés**:
  - Számok (Tracks), Albumok (Albums), Előadók (Artists), Műfajok (Genres).
  - Kedvencek (Favorites) egykattintásos mentése.
  - Egyedi lejátszási listák (Playlists) létrehozása, szerkesztése.
  - Valós idejű, azonnali keresőmező.
- **🌐 Otthoni Streaming Szerver Architektúra**:
  - `Wiretone.Server`: Pehelykönnyű ASP.NET Core szerver az otthoni szervergépre.
  - A szerveren lévő `WiretoneLibrary` főkönyvtár automatikus figyelése és indexelése.
  - **HTTP 206 Partial Content (Range Request)** támogatás: Azonnali tekerés és streamelés veszteségmentes FLAC bitfolyammal, újrakódolás nélkül!
- **💎 Prémium Neon & Glassmorphism Felület**:
  - Az `EnergyStorageModel` modern, cyber-neon és üveghatású stílusvilágára épül.
  - Sötét és világos téma dinamikus háttérgradienssel.
  - Élő 16-sávos spektrumanalizátor (audio visualizer).
  - Folyamatos vizuális jelút (Signal Path Diagnostics) kijelzés.

---

## 🏗️ Architektúra & Projektstruktúra

```
Wiretone/
├── Wiretone.slnx                  # Solution fájl (Modern .NET 10 formátum)
│
├── Wiretone.Core/                 # Platformfüggetlen üzleti logika és modellek
│   ├── Models/                    # Track, Album, Artist, Playlist, AudioFormat, AudioOutputDevice
│   ├── Audio/                     # IAudioEngine, PlaybackState
│   ├── Services/                  # MetadataScanner (TagLibSharp), LibraryService, ServerStreamingClient
│   └── Repositories/              # ILibraryRepository adatbázis interfész
│
├── Wiretone.Audio/                # Audiophile lejátszó motor
│   ├── Devices/                   # AudioDeviceManager (ALSA, PipeWire, WASAPI hardvereszköz-detektálás)
│   ├── Drivers/                   # LinuxAudioDriver (bitperfect unity gain, PipeWire/ALSA közvetlen vezérlés)
│   └── WiretoneAudioEngine.cs     # IAudioEngine megvalósítás, DAC illesztés és jelút-diagnosztika
│
├── Wiretone.Data/                 # Helyi gyorsítótár és perzisztencia
│   ├── DatabaseManager.cs         # SQLite adatbázis kapcsolat kezelő (WAL mód)
│   └── LibraryRepository.cs       # Dapper alapú gyors kötegelt mentés és lekérdezés
│
├── Wiretone.UI/                   # Avalonia FluentUI felhasználói felület (Megosztott Desktop & Mobil)
│   ├── Assets/                    # Ikonok és alkalmazás erőforrások
│   ├── Converters/                # Audio és állapot konverterek
│   ├── Services/                  # ThemeService (dinamikus gradiensek és neon akcentusok)
│   ├── ViewModels/                # MainViewModel, PlayerViewModel, Tracks, Albums, Artists, AudiophileSettings
│   └── Views/                     # MainView.axaml (teljes felület), MainWindow.axaml
│
├── Wiretone.Desktop/              # Asztali futtató (Linux & Windows)
│   └── Program.cs
│
├── Wiretone.Server/               # Otthoni streaming szerver (WiretoneLibrary kiszolgáló)
│   ├── appsettings.json           # WiretoneLibrary elérési út konfiguráció
│   └── Program.cs                 # REST API & veszteségmentes audio streaming végpontok
│
├── Wiretone.Android/              # Android futtató (Avalonia MainActivity)
│   └── MainActivity.cs
│
└── Wiretone.Tests/                # Automatizált egységtesztek (xUnit)
    ├── AudioEngineTests.cs        # Bit-perfect hangerőzár és Hi-Res formátum tesztek
    └── LibraryServiceTests.cs     # Indexelési, keresési és lejátszási lista tesztek
```

---

## 🚀 Indítás és Használat

### 1. Asztali Kliens Indítása (Linux / Windows)
```bash
cd /home/wirekurosastak/Dokumentumok/GitHub/Wiretone
dotnet run --project Wiretone.Desktop
```

### 2. Otthoni Streaming Szerver Indítása (a Szervergépen)
Állítsd be a `Wiretone.Server/appsettings.json` fájlban a zenéid főkönyvtárát (`WiretoneLibrary`), majd:
```bash
dotnet run --project Wiretone.Server
```
A szerver alapértelmezetten a `http://0.0.0.0:5200` címen válik elérhetővé a helyi hálózaton.

### 3. Tesztek Futtatása
```bash
dotnet test
```

---

## 🎛️ Audiophile Beállítások

1. Nyisd meg az alkalmazásban a bal oldali menüből az **Audiophile Mód** fület.
2. Kapcsold be a **Bit-Perfect Mód** kapcsolót:
   - A lejátszó azonnal rögzíti a digitális szoftveres hangerőt 100%-ra (0 dB Unity Gain).
   - A rendszer szoftveres újramintavételezése kikapcsol.
3. Kapcsold be a **Kizárólagos Mód (Exclusive Mode)** kapcsolót a DAC közvetlen lefoglalásához (pl. **SMSL USB AUDIO**).
4. A lejátszási sávban bármikor megtekinthető a valós idejű **Jelút (Signal Path)**:
   `Forrás FLAC (24-bit / 96.0 kHz) -> Wiretone Dekóder -> Bit-perfect (1:1 PCM) -> SMSL USB AUDIO Pro`.
