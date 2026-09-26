# Wiretune — Rendszerterv

> Ez a dokumentum a `csizmi` ág jelenlegi állapotát írja le. Forrás: a projekt teljes
> kódbázisának átvizsgálása (2026-09-26). Ha a kód változik, ezt a dokumentumot is
> frissíteni kell — ellenkező esetben a leírás elavulttá válik.

## 1. Áttekintés

Wiretune egy önállóan hosztolt (self-hosted), veszteségmentes zenei streaming
rendszer. Egy otthoni gépen fut a **szerver**, amely indexeli és kiszolgálja a
zenei könyvtárat; ehhez kapcsolódnak a **kliensek** (asztali Linux/Windows és
Android). A kliens szerver nélkül, helyi mappával is használható.

Célja a Spotify/Tidal jellegű előfizetéses szolgáltatások kiváltása saját FLAC/
veszteségmentes gyűjteményre, hálózati streameléssel és — Linuxon — audiophile
(bit-perfect, kizárólagos hozzáférésű) lejátszási móddal.

## 2. Projektstruktúra és rétegek

```
Wiretune.Core     — platformfüggetlen modellek és üzleti logika (szerver ÉS kliens)
Wiretune.Data     — SQLite perzisztencia (Dapper + Microsoft.Data.Sqlite)
Wiretune.Audio    — lejátszó motor (IAudioEngine, driver absztrakció, DSP)
Wiretune.UI       — Avalonia MVVM felület (asztal és Android közös)
Wiretune.Desktop  — asztali belépési pont (Linux, Windows)
Wiretune.Android  — Android belépési pont
Wiretune.Server   — ASP.NET Core szerver (Minimal API)
Wiretune.Tests    — xUnit tesztek (unit + memóriában futó integrációs tesztek)
```

### 2.1 Rétegfüggőségek

```
Wiretune.Server ──┬─> Wiretune.Data ──> Wiretune.Core
                   └─> Wiretune.Core

Wiretune.Desktop ─> Wiretune.UI ──┬─> Wiretune.Audio ──> Wiretune.Core
Wiretune.Android ─┘               ├─> Wiretune.Data ────> Wiretune.Core
                                   └─> Wiretune.Core
```

A `Wiretune.Core` a közös nyelv szerver és kliens között: ugyanazok a modellek
(`Track`, `Album`, `Artist`, `Playlist`, `AudioFormat`, `UserInfo`) és ugyanaz a
`LibraryService` fut mindkét oldalon — a szerveren a teljes zenei könyvtárral, a
kliensen a szerverről letöltött (vagy helyi mappából beolvasott) számokkal.

## 3. Adatmodell (`Wiretune.Core/Models`)

| Típus | Lényeg |
|---|---|
| `Track` | Egy zeneszám. `INotifyPropertyChanged`-et implementál (`IsFavorite`, `PlayCount`, `LastPlayed` változása azonnal frissíti a kötött UI-t lista-újraépítés nélkül). `Id` a fájl teljes, kisbetűsített útvonalának SHA-256 hash-e (stabil scan-ek között). `FileModifiedUtc` az inkrementális szkenneléshez kell. |
| `Album` | Levezetett (nem tárolt) entitás: a `LibraryService` építi fel a számokból, `Album Artist` szerint csoportosítva. |
| `Artist` | Levezetett entitás. `Tracks` az előadó saját számait ÉS az albumain szereplő összes számot tartalmazza (pl. válogatásalbum-közreműködés). |
| `Playlist` | Tárolt entitás. `TrackIds` mindig új listaként cserélődik (copy-on-write), sosem mutálódik helyben — ez teszi biztonságossá a párhuzamos olvasást. `INotifyPropertyChanged`. |
| `AudioFormat` | `Codec`, `SampleRate`, `BitsPerSample`, `BitrateKbps`, `IsLossless`. `IsHiRes` és a címke-tulajdonságok (`DisplayBadge`, `QualityLabel`) csak lossless formátumra jelölnek Hi-Res-t; lossy fájlra codec+bitrate címke jelenik meg. |
| `AudioFileTypes` | Statikus lookup: kiterjesztés → codec név, lossless-e, MIME típus. Ez az egyetlen hely, ahol a támogatott formátumok fel vannak sorolva (FLAC, WAV, AIFF, WavPack, APE, DSF, M4A/ALAC, AAC, MP3, OGG, Opus). |
| `UserInfo`, `LoginRequest`, `RegisterRequest`, `AuthResponse` | Szerver-hitelesítési DTO-k, kliens és szerver között JSON-on át közlekednek. |
| `ServerLibraryStatus` | A `/api/library/status` válasza (szám/album/előadó darabszám, szkennelés állapota, utolsó hiba). |
| `AuthRules` | `MinPasswordLength = 8`, `MaxUsernameLength = 64` — egy helyen definiálva, szerver és kliens validáció is ezt használja. |

## 4. Adatbázis (`Wiretune.Data`)

SQLite, WAL módban. **A szerver és minden kliens külön adatbázis-fájlt használ**
(lásd 6. pont) — ez szándékos elkülönítés, nem közös állapot.

### 4.1 Séma (`DatabaseManager.InitializeSchema`)

Verziózott séma (`PRAGMA user_version`), migrációval:

```sql
tracks (
  id TEXT PRIMARY KEY, title, artist, album, album_artist, track_number,
  track_count, disc_number, year, genre, duration_seconds, file_size_bytes,
  file_path TEXT UNIQUE, stream_url, has_cover_art, cover_art_path,
  codec, sample_rate, bits_per_sample, channels, bitrate_kbps, is_lossless,
  is_favorite, play_count, last_played, date_added,
  file_modified_utc  -- v2-ben hozzáadva (inkrementális szkenneléshez)
)
playlists (id PK, name, description, track_ids_json, created_at, modified_at)
settings  (key PK, value)          -- ServerUrl, AuthToken, LibrarySource, jwt_secret (csak szerveren)
users     (id PK, username UNIQUE COLLATE NOCASE, password_hash, display_name,
           is_admin, created_at, last_login)   -- csak a szerver adatbázisában releváns
```

`LibraryRepository.ReplaceAllTracksAsync` egyetlen tranzakcióban törli és
újraírja a `tracks` táblát — nincs részleges/inkonzisztens állapot egy scan
közepén megszakadva sem.

## 5. Szerver (`Wiretune.Server`)

Minimal API, JWT Bearer hitelesítéssel. Belépési pont: `Program.cs`.

### 5.1 Konfiguráció (`ServerOptions`, `appsettings.json` → `Wiretune:` szekció)

| Kulcs | Jelentés | Alapérték |
|---|---|---|
| `LibraryPath` | Zenei gyökérmappa | `WiretuneLibrary`; ha nem létezik, a felhasználó Zene mappája |
| `DataDirectory` | DB, borító-cache, napló helye | `<AppData>/Wiretune/Server` |
| `ScanIntervalMinutes` | Időzített inkrementális rescan | 30 (0 = kikapcsolva) |
| `Port` | HTTP port | 5200 |

A könyvtárgyökér és az adatkönyvtár feloldását az `AppPaths` (Core) végzi;
`WIRETUNE_DATA_DIR` környezeti változóval felülírható (teszteknél és a
kliens/szerver adatkönyvtárak szétválasztásánál használt mechanizmus).

### 5.2 Hitelesítés (`Auth/AuthService.cs`)

- Jelszavak: BCrypt, munkatényező 12.
- JWT: HMAC-SHA256, saját `jwt_secret` (véletlen, adatbázisban tárolt, első
  induláskor generált) — **nincs beégetett kulcs vagy alapértelmezett fiók**.
- Első admin létrehozása (`CreateAdminAsync`) atomikus SQL-lel
  (`INSERT ... WHERE NOT EXISTS (SELECT 1 FROM users)`), így párhuzamos
  first-run kérés esetén is pontosan egy admin jön létre, a többi 409-et kap.
- `LoginAsync` időzítés-kiegyenlítést végez ismeretlen felhasználónévnél
  (dummy BCrypt-ellenőrzés), hogy a válaszidő ne árulja el a felhasználó
  létezését.
- Szerepkör: `admin` / `user` (JWT `role` claim). `admin` policy védi a
  regisztrációt és a manuális szkennelés-indítást.

### 5.3 Végpontok

| Módszer | Útvonal | Auth | Leírás |
|---|---|---|---|
| GET | `/api/auth/setup-required` | — | Van-e már felhasználó |
| POST | `/api/auth/setup` | — | Első admin létrehozása |
| POST | `/api/auth/login` | — | Bejelentkezés, JWT visszaadása |
| POST | `/api/auth/register` | admin | Új (nem-admin) felhasználó |
| GET | `/api/auth/me` | bármely | Bejelentkezett felhasználó adatai |
| GET | `/api/library/status` | bármely | Szám/album/előadó szám, szkennelés állapota |
| POST | `/api/library/scan` | admin | Manuális (inkrementális) rescan kérése |
| GET | `/api/tracks?q=` | bármely | Számlista, opcionális kereséssel |
| GET | `/api/albums` | bármely | Levezetett albumlista |
| GET | `/api/artists` | bármely | Levezetett előadólista |
| GET | `/api/stream/{trackId}` | bármely | Fájl streamelése, `enableRangeProcessing: true` (HTTP 206) |
| GET | `/api/cover/{trackId}` | bármely | Borítókép (beágyazott vagy mappaszintű) |
| GET | `/api/cover/album/{albumId}` | bármely | Album borítója (első számáról) |

A JWT tokent fejlécben (`Authorization: Bearer`) vagy — ha a kliens ezt nem
tudja küldeni (pl. натив médialejátszó) — `?token=` query paraméterben is el
lehet fogadtatni (`OnMessageReceived`).

### 5.4 Könyvtárindexelés (`LibraryScanService : BackgroundService`)

- Induláskor lefut egy scan.
- Ha `ScanIntervalMinutes > 0`, azon időközönként ismétlődik.
- `/api/library/scan` hívás egy `SemaphoreSlim(0,1)`-en keresztül azonnali
  scant kér (nem torlódik, ha már fut egy).
- **Védelem le nem csatolt hálózati megosztás ellen**: ha a könyvtár korábban
  nem volt üres, de a gyökérmappa hirtelen üresnek látszik, a szolgáltatás
  *nem* üríti ki az indexet — csak naplózza a hibát. Ez azért fontos, mert egy
  ideiglenesen leválasztott SMB/NFS mountpoint üres mappaként jelentkezik, és
  enélkül a védelem nélkül egy pillanatnyi hálózati hiba törölné a teljes
  könyvtárat.
- A tényleges beolvasást a `Wiretune.Core.Services.LibraryService.ScanFolderAsync`
  végzi, ami a `MetadataScanner`-t hívja.

### 5.5 Útvonal-ellenőrzés (`AppPaths.IsPathUnderRoot`)

A stream és cover végpontok minden fájlelérést ellenőriznek: a kért fájl
útvonala a könyvtárgyökér *alatt* kell legyen. Az ellenőrzés útvonal-szegmens
alapú (nem puszta `StartsWith`), így egy `library2` nevű testvérmappa nem
számít `library` alattinak — enélkül egy előtag-egyezés kijátszhatná a
korlátozást.

## 6. Kliens–szerver kapcsolat (`Wiretune.Core.Services.ServerSession`)

A kliensoldali szerverkapcsolat **külön osztály**, nem a `LibraryService`
része — ez a réteg csak a helyi könyvtárlogikáért felel, hálózati
ismeretei nincsenek.

### 6.1 Állapotgép (`ServerConnectionState`)

```
NotConfigured → Connecting → { Offline | SetupRequired | LoginRequired | Connected }
```

- **SetupRequired**: a szerveren még nincs felhasználó.
- **LoginRequired**: a szerver elérhető, de nincs (érvényes) token.
- **Connected**: sikeres bejelentkezés, könyvtár letöltve.
- **Offline**: hálózati hiba vagy a szerver nem válaszol.

Lejárt/érvénytelen token esetén a session automatikusan `LoginRequired`
állapotba vált (nem próbálkozik végtelenül 401-es kéréssel).

### 6.2 Könyvtárforrás (`LibrarySource`)

`None | Server | Local` — eltárolva a helyi beállításokban. Induláskor, ha a
forrás `Server`, a kliens automatikusan megpróbál visszakapcsolódni a mentett
szerverre (mentett token esetén bejelentkezés nélkül).

### 6.3 Adatfolyam letöltéskor

```
ServerSession.RefreshLibraryCoreAsync
  → ServerStreamingClient.FetchTracksAsync (GET /api/tracks)
  → minden Track-hez StreamUrl/CoverArtPath beállítása (token NÉLKÜL,
    a base URL-ből képezve — ld. 8.4)
  → LibraryService.ReplaceTracksAsync
      → kedvencek/lejátszásszám megőrzése az egyező FilePath/Id alapján
      → LibraryRepository.ReplaceAllTracksAsync (tranzakció)
      → LibrarySnapshot újraépítése (albumok, előadók, műfajok)
      → LibraryChanged esemény
```

### 6.4 Hibakezelés (`ServerStreamingClient`)

Típusos kivételek: `ServerUnauthorizedException` (401), `ServerRequestException`
(hálózati hiba vagy egyéb HTTP hiba, `StatusCode`-dal). A `ServerSession` ezek
alapján dönt állapotváltásról (pl. 409 setup közben → már beállított szerver
üzenet; hálózati hiba → Offline).

## 7. Zenei könyvtár szolgáltatás (`Wiretune.Core.Services.LibraryService`)

Ugyanaz az osztály fut szerveren és kliensen. Belső állapota egy **immutábilis
pillanatkép** (`LibrarySnapshot`): minden módosítás (`ReplaceTracksAsync`,
scan) egy teljesen új pillanatképet épít és cserél be egyetlen referencia-
írással — az olvasók (`Tracks`, `Albums`, `Artists`, `Search`) sosem látnak
részleges állapotot, és nincs szükség lock-ra olvasáskor.

### 7.1 Album/előadó levezetés

- Albumok kulcsa: `Album` cím + `EffectiveAlbumArtist` (az `AlbumArtist` mező,
  vagy ha üres, a track `Artist`-je), kis-nagybetű független SHA-256 hash.
  Ez teszi lehetővé, hogy egy válogatásalbum (`Album Artist = "Various
  Artists"`) egyetlen albumként jelenjen meg, miközben a benne szereplő
  előadók külön-külön is látják a saját számukat az `Artists.Tracks`
  listájukban.
- Előadó → album és előadó → szám hozzárendelés `ToLookup`-pal (O(n)), nem
  beágyazott ciklussal.

### 7.2 Szkennelés (`ScanFolderAsync`)

- `SemaphoreSlim(1,1)` zárolással: egyszerre csak egy szkennelés futhat
  (párhuzamos hívás azonnal `false`-t ad vissza, nem várakozik és nem indul
  el mégegyszer).
- **Inkrementális**: a `MetadataScanner.ScanDirectoryAsync` megkapja az
  ismert (`FilePath → Track`) map-et; egy fájlt csak akkor olvas újra, ha a
  mérete vagy a módosítási ideje eltér a korábban ismerttől.
- Sikeres scan után `ReplaceTracksAsync`-en át frissíti az állapotot, a
  kedvenceket/lejátszásszámot megőrizve.

### 7.3 `MetadataScanner`

- `TagLibSharp` alapú tag-olvasás, párhuzamosítva (`Parallel.ForEachAsync`,
  2–8 szál a processzor magjai szerint).
- Beágyazott borító gyorsítótárazása (album-artist + album alapján hash-elt
  fájlnév, PNG/JPEG felismerés a fájl fejlécéből); ha nincs beágyazott kép,
  mappaszintű borítót keres (`cover.jpg`, `folder.png` stb., kis-nagybetű
  független).
- `Track.Id` a fájl teljes, normalizált útvonalának hash-e — **stabil scan-ek
  között**, így a kedvencek/lejátszásszám nem vész el újraindexeléskor.

## 8. Lejátszási architektúra (`Wiretune.Audio`)

### 8.1 Absztrakció

```
Wiretune.Core.Audio.IAudioEngine        — platformfüggetlen szerződés (UI ezt látja)
  └─ Wiretune.Audio.WiretuneAudioEngine — mód-logika (exclusive/bitperfect), eszközkezelés
       └─ Wiretune.Audio.Drivers.IAudioDriver — tényleges lejátszás
            ├─ FfmpegAudioDriver   (Desktop: Linux + Windows, ffplay child process)
            └─ AndroidAudioDriver  (Android: natív MediaPlayer)
```

Az `App.AudioDriverFactory` static delegate-en át a platform belépési pont
(pl. `Wiretune.Android.MainActivity`) cserélheti a driver-t indulás előtt.

### 8.2 `FfmpegAudioDriver`

- A lejátszó folyamat argumentumai `ProcessStartInfo.ArgumentList`-en mennek
  át (nem összefűzött parancssor), így a fájlnévben lévő speciális karakterek
  nem tudnak extra argumentumot becsempészni.
- Linuxon: kizárólagos módban közvetlen ALSA hardvereszköz (`hw:X,Y`) vagy
  PipeWire node-routing és órajel-kényszerítés (`pw-metadata clock.force-rate`)
  a forrás mintavételezési frekvenciájára; szüneteltetéskor `SIGSTOP`/`SIGCONT`
  (P/Invoke `kill`), nem folyamat-újraindítás.
- Windowson: nincs `SIGSTOP` — szüneteltetéskor a folyamat leáll, majd
  folytatáskor a mentett pozícióról újraindul.
- Hiba esetén (`ffplay` hiányzik, nem-nulla kilépőkód) `PlaybackFailed`
  eseményt küld felhasználóbarát üzenettel, és `PlaybackState.Error`-ba vált —
  ez korábban csendben, jelzés nélkül történt.
- Hangerő: ha van vezérelhető kimenet (PipeWire/ALSA mixer), azonnal alkalmazza;
  ha nincs, a `-volume` csak indításkor állítható, ezért 400 ms debounce-szal
  újraindítja a folyamatot a jelenlegi pozícióról (csúszka húzása közben nem
  minden tick indít új folyamatot).

### 8.3 `AndroidAudioDriver`

Natív `Android.Media.MediaPlayer` köré épített adapter; ugyanazt az
`IAudioDriver` szerződést valósítja meg. Exclusive/bit-perfect mód nem
elérhető ezen az úton (a platform nem ad ilyen hozzáférést).

### 8.4 Stream-hitelesítés

A `Track.StreamUrl`/`CoverArtPath` **sosem tartalmaz tokent** (sem
adatbázisban, sem a hálózaton átküldött JSON-ban). A JWT-t a
`WiretuneAudioEngine.SetStreamAuthorization(token)` állítja be, és lejátszás
indításakor (`ResolveSource`) fűződik a stream URL-hez query paraméterként.
Ez azért fontos, mert a token éles ideje rövidebb, mint amíg egy track-objektum
él a kliens gyorsítótárában — ha a tokent tárolnánk, egy lejárt/kicserélt
tokennel ellátott URL használhatatlanná válna újralejátszáskor.

### 8.5 Mód-logika (`WiretuneAudioEngine`)

- `SetBitperfectModeAsync(true)`: automatikusan bekapcsolja az exclusive
  módot is (ha a kiválasztott eszköz támogatja), és a hangerőt 100%-ra
  (0 dB unity gain) rögzíti, elmentve a korábbi értéket.
- `SetBitperfectModeAsync(false)`: visszaállítja a mentett hangerőt.
- `SetExclusiveModeAsync(false)` bit-perfect aktív állapotban: kikapcsolja a
  bit-perfectet is (megosztott keverőben ez fizikailag nem értelmezhető).
- Ha egy eszköz nem támogatja a kért módot (`IsExclusiveSupported` /
  `IsBitperfectSupported` false — pl. Windows `AudioDeviceManager`
  jelenleg csak megosztott WASAPI-t ad vissza), a mód bekapcsolása
  `PlaybackFailed` üzenettel elutasításra kerül, a mód nem vált be
  hamisan „bekapcsolva” állapotba.

## 9. Kliens felület (`Wiretune.UI`, Avalonia MVVM)

### 9.1 ViewModel-fa

```
MainViewModel
 ├─ PlayerViewModel        (lejátszási sor, keverés, hangerő, spektrum)
 ├─ TracksViewModel        (Számok fül)
 ├─ AlbumsViewModel        (Albumok fül + album-részlet)
 ├─ ArtistsViewModel       (Előadók fül + előadó-részlet)
 ├─ FavoritesViewModel     (Kedvencek fül)
 ├─ PlaylistsViewModel     (Lejátszási listák fül + 3 dialógus)
 ├─ SearchResultsViewModel (egyesített kereső nézet, "legjobb találat")
 ├─ AudiophileSettingsViewModel (kimeneti eszköz, exclusive/bitperfect)
 ├─ ServerSettingsViewModel     (kapcsolat, bejelentkezés, szkennelés)
 └─ Session (ServerSession, Core-ból)
```

- `MainViewModel.CreateDefault` építi fel a teljes production objektumgráfot
  (SQLite repository, `LibraryService`, `ServerSession`, `WiretuneAudioEngine`).
- `MainViewModel.StartAsync`: előbb a helyi cache-t tölti be (`IsStarting`
  false lesz, a UI azonnal használható), utána — ha a könyvtárforrás
  `Server` — a háttérben megpróbál visszakapcsolódni.

### 9.2 Borítókép-kezelés (`CoverArtService`)

Egyetlen statikus, korlátos LRU gyorsítótár (`MaxCachedBitmaps = 300`),
megjelenítési szélességre dekódolva (`Bitmap.DecodeToWidth`), egyidejű
kérések összevonásával (`ConcurrentDictionary<string, Task<Bitmap?>>`
in-flight lista). Az albumrács (`ViewportLoad` attached property) csak a
ténylegesen látható kártyák borítóját tölti be.

### 9.3 UI-automatizálás (`UiAutomationServer`)

Csak `WIRETUNE_UI_AUTOMATION=1` esetén indul el, kizárólag `127.0.0.1`-en
figyel, és minden kérést elutasít, amelynek van `Origin` fejléce (böngészőből
nem hívható). Fejlesztői/tesztelési célra szolgáló, állapot-lekérdező és
művelet-indító HTTP végpontokat ad (`/api/ui/state`, `/api/ui/play-track`,
`/api/ui/screenshot` stb.).

## 10. Konfiguráció és környezeti változók

| Változó | Hatás |
|---|---|
| `WIRETUNE_DATA_DIR` | Felülírja az `AppPaths.GetDataDirectory` alap (AppData) útvonalát |
| `WIRETUNE_UI_AUTOMATION=1` | Elindítja a helyi UI-automatizálási HTTP szervert |

Szerver oldali `appsettings.json` kulcsok: ld. 5.1.

## 11. Tesztelési stratégia (`Wiretune.Tests`)

- **Unit tesztek**: `LibraryService`, `MetadataScanner`, `AudioFormat`,
  konverterek, `FxSoundSpectrumEngine` — `MockRepository`-val, valódi fájlrendszer-
  műveletek csak ideiglenes mappákban.
- **`FakeAudioDriver`** (`TestSupport.cs`): a lejátszási teszteknek nincs
  szüksége valódi hangeszközre vagy `ffplay`-re.
- **`ServerIntegrationTests`**: `WebApplicationFactory<Program>`-mal
  memóriában futtatja a *valódi* szerver-alkalmazást (nem mock), generált
  WAV-fájlokból épített könyvtárral. Lefedi: first-run setup versenyhelyzetet,
  JWT-alapú jogosultságkezelést, Range-kéréseket, útvonal-ellenőrzést, teljes
  kliens (`ServerSession`) életciklust bejelentkezéstől kijelentkezésig.
- **`RefactorRegressionTests`**: válogatásalbum-csoportosítás, inkrementális/
  párhuzamos szkennelés, kedvencek megőrzése, eszközképesség-ellenőrzés,
  DB-migráció, URL-normalizálás.

## 12. Ismert korlátok (jelenlegi állapot szerint)

- Kedvencek és lejátszási listák **eszközönként** tárolódnak — nincs
  szerveroldali szinkronizáció a kliensek között.
- Nincs átkódolás (transzkódolás); a szerver mindig az eredeti fájlt streameli.
- Windowson és Androidon nincs exclusive/bit-perfect kimenet — csak Linuxon
  (ALSA/PipeWire).
- Nincs felhasználókezelő felület a kliensben (csak API-végpont a regisztrációra).
- Az Android build nem volt lefordítva ellenőrzésképp ezen a gépen (hiányzó
  workload); a `AndroidAudioDriver` és a manifest-módosítások kód szerint
  helyesek, de futásidőben nincsenek tesztelve.
