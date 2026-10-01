# Wiretune

Önállóan üzemeltethető, veszteségmentes zenei streaming: egy kis ASP.NET Core szerver, amely indexeli a
FLAC/WAV/… gyűjteményedet, és Avalonia kliensek (Linux, Windows, Android), amelyek lejátszzák — Linuxon
opcionális bit-perfect kimenettel. .NET 10 alapú. A felület magyarul, angolul és németül is elérhető, és futás közben
váltható.

*English version: [README.md](README.md)*

## Komponensek

```
Wiretune.Core      Modellek, SQLite könyvtár, metaadat-olvasó, lejátszó motor és driverek (szerver és kliens közös)
Wiretune.Server    ASP.NET Core minimal API: JWT-hitelesítés, könyvtár-szkennelés, HTTP range streaming, borítóképek
Wiretune.UI        Avalonia MVVM felület (asztal és Android)
Wiretune.Desktop   Asztali belépési pont (Linux, Windows)
Wiretune.Android   Android belépési pont (Android workload kell; a solution build nem építi)
Wiretune.Tests     xUnit tesztek (unit, memóriában futó szerver-integrációs és valódi ffmpeg/ffplay tesztek)
```

Részletek: [docs/rendszerTerv.md](docs/rendszerTerv.md) (rendszerterv) és [docs/funkSpec.md](docs/funkSpec.md)
(funkcionális specifikáció).

## Platformtámogatás

| | Linux asztal | Windows asztal | Android |
|---|:---:|:---:|:---:|
| Lejátszó motor | `ffplay` gyerekfolyamat, ALSA / PipeWire | NAudio WASAPI (shared / exclusive) | `MediaPlayer` |
| Bit-perfect / kizárólagos kimenet | igen | igen | nem |
| Spektrumanalizátor | igen | igen | nem |
| Helyi könyvtár (szerver nélkül) | igen | igen | nem |
| Szerver | igen | igen | – |

Androidon ugyanazok a nézetmodellek egy saját telefonos elrendezést hajtanak (alsó navigáció, mini lejátszó, teljes
képernyős lejátszó sorral és dalszöveggel, keresőoldal, lejátszási lista lapok) az asztali oldalsáv helyett.

A CI csak Linuxon fordít és tesztel. A Windows-kód ott lefordul, az Android-fejet (a telefonos felülettel együtt) a CI
nem építi, mert az Android workload kell hozzá; automatikus teszt egyiket sem fedi.

## Előfeltételek

- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) a fordításhoz; .NET 10 runtime a futtatáshoz.
- Linux asztali lejátszás és spektrum: `ffmpeg` és `ffplay` a `PATH`-ban (`sudo apt install ffmpeg`).
  A bit-perfect mód emellett `aplay`-t (ALSA) és `wpctl`-t (PipeWire) használ, ha vannak.
- A szervernek nincs külső függősége.
- Android: `dotnet workload install android`.

## Fordítás, futtatás, tesztelés

```bash
dotnet build Wiretune.slnx
dotnet test  Wiretune.slnx

dotnet run --project Wiretune.Server     # http://0.0.0.0:5200
dotnet run --project Wiretune.Desktop    # asztali kliens
dotnet build Wiretune.Android            # az Android workload telepítése után
```

Az ffmpeg/ffplay-t használó tesztek azonnal visszatérnek, ha az eszközök nincsenek telepítve. Az SDL `dummy`
audio-drivert használják, tehát semmi sem szólal meg.

Első indításkor a kliens megkérdezi, szerverhez csatlakozzon-e vagy helyi zenemappát használjon. Egy friss
szerveren az első létrehozott fiók (`POST /api/auth/setup`, a kliens beállító képernyője ezt hívja) lesz az
adminisztrátor; alapértelmezett jelszó nincs. További felhasználókat az adminisztrátor vehet fel.

## Nyelvek és megjelenés

Magyar, angol és német nyelv van beépítve. Első indításkor a kliens az operációs rendszer nyelvét használja, ha az
ezek egyike, egyébként angolt; a **Beállításokban** (asztalon a felső sáv nyelvgombján is) bármikor átváltható, és
azonnal érvényesül, újraindítás nélkül. A nyelv és a világos/sötét téma a kliens adatbázisában marad meg
(`Preference.Language`, `Preference.Theme`).

Az összes szöveg a `Wiretune.Core/Localization/Strings.cs` fájlban van. Új nyelvhez add hozzá a kódját a
`Localizer.Languages`-hez, és egy negyedik szöveget minden `T(...)` sorhoz; a tesztek elbuknak, ha egy kulcsnak
hiányzik a fordítása, a nyelvek között eltérnek a helyőrzői, nincs használva, vagy kódból/XAML-ből hivatkoznak rá, de
nem létezik.

## Szerver beállítások

A beállítások a `Wiretune.Server/appsettings.json` `Wiretune` szakaszában vannak, és az ASP.NET Core szokásos
módján felülbírálhatók (pl. `--Wiretune:Port=8080` vagy `Wiretune__Port=8080`).

| Kulcs | Alapérték | Jelentés |
|---|---|---|
| `Wiretune:LibraryPath` | `""` | Zenemappa (abszolút, vagy az alkalmazás könyvtárához képest relatív). Ha üres vagy nem létezik, a felhasználó Zene mappáját használja, és figyelmeztetést naplóz. Az adminisztrátor által az API-n át választott mappa az adatbázisban tárolódik, és újraindítás után is elsőbbséget élvez. |
| `Wiretune:DataDirectory` | `""` | Az adatbázis (`wiretune-server.db`), a borítógyorsítótár és a napló (`wiretune-server.log`) helye. Üresen: `<felhasználói appdata>/Wiretune/Server`. |
| `Wiretune:ScanIntervalMinutes` | `30` | A háttérben futó inkrementális újraszkennelés intervalluma; `0` kikapcsolja (az indításkori és a kézi szkennelés ettől még megy). |
| `Wiretune:Port` | `5200` | HTTP port. Figyelmen kívül marad, ha `ASPNETCORE_URLS` vagy `--urls` meg van adva. |

Környezeti változók:

| Változó | Hatókör | Jelentés |
|---|---|---|
| `WIRETUNE_DATA_DIR` | szerver, kliens | A Wiretune adatainak gyökere (a szerver ennek `Server` almappáját használja). |
| `WIRETUNE_NO_ARTIST_PICTURES` | kliens | `1` esetén kikapcsolja az előadóképek lekérését (lásd Adatvédelem). |
| `WIRETUNE_UI_AUTOMATION` | asztali kliens | `1` esetén helyi tesztautomatizációs HTTP API indul a `127.0.0.1:5201` címen. Csak fejlesztéshez. |

### A szerver futtatása szolgáltatásként

```bash
dotnet publish Wiretune.Server -c Release -o /opt/wiretune
```

Példa systemd unit (`/etc/systemd/system/wiretune.service`):

```ini
[Unit]
Description=Wiretune server
After=network-online.target

[Service]
User=wiretune
WorkingDirectory=/opt/wiretune
ExecStart=/usr/bin/dotnet /opt/wiretune/Wiretune.Server.dll
Environment=Wiretune__LibraryPath=/srv/music
Environment=WIRETUNE_DATA_DIR=/var/lib/wiretune
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Telepített runtime nélküli, önálló csomaghoz add hozzá: `-r linux-x64 --self-contained -p:PublishSingleFile=true`
(a célgép runtime-azonosítójával).

### Biztonsági megjegyzések

- A szerver sima HTTP-n beszél. Ne tedd ki közvetlenül az internetre: TLS-t lezáró reverse proxy (Caddy, nginx, …)
  mögé vagy VPN-re (WireGuard/Tailscale) tedd. Proxy mögött állítsd be az `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true`
  értéket, különben minden kliens a proxy címén osztozik, és az alábbi belépési korlát mindenkire együtt vonatkozik.
- A bejelentkezés és a beállítás kliensenként (címenként) percenként 10 kísérletre korlátozott. A jelszavak
  bcrypt-tel hash-eltek, és legfeljebb 72 bájtosak (bcrypt-korlát).
- A tokenek legfeljebb 90 napig érvényes JWT-k; egy felhasználó törlése azonnal érvényteleníti a tokenjeit. Az
  aláírókulcs az első indításkor generálódik és a szerver adatbázisában van, ezért védd az adatkönyvtárat.
- A fejlécet küldeni nem tudó lejátszók (`ffplay`, Android `MediaPlayer`) a tokent `?token=` paraméterben adják át.
  A szerver ezt csak a `/api/stream` és `/api/cover` végpontokon fogadja el, a kezelő végpontokon soha. E két végpont
  URL-je tehát hitelesítő adatot tartalmaz: a reverse proxy hozzáférési naplóit tartsd zártan.
- Az `/api/tracks` minden hitelesített felhasználónak visszaadja a fájlok szerveroldali útvonalát.

Sérülékenységet a [SECURITY.md](SECURITY.md) szerint jelents.

### Adatvédelem

A kliens az előadóképeket a Deezer nyilvános API-ján keresi, így a könyvtárad előadóneveit elküldi az
`api.deezer.com` címre. A `WIRETUNE_NO_ARTIST_PICTURES=1` ezt kikapcsolja. Más nem hagyja el a hálózatodat.

## Ismert korlátok

- Az Android- és a Windows- (WASAPI) kódot automatikus teszt nem fedi, valódi hangkártyát pedig a CI nem tud
  tesztelni. Az Android-fejet (a telefonos felülettel együtt) a CI egyáltalán nem építi, mert az Android workload kell
  hozzá.
- A Linuxos bit-perfect út az ALSA `plughw` eszközén és 32 bites mintákon megy; hogy az eredmény valóban
  bit-transzparens-e, a hangkártyától és a drivertől függ.
- A `?token=` megoldás és az Android sima HTTP-engedélye miatt a streamelést csak megbízható hálózaton vagy TLS mögött
  érdemes használni.
- Az asztali kliens a hozzáférési tokenjét titkosítatlanul tárolja a helyi SQLite adatbázisban. Ez egyelőre szándékos:
  a token a felhasználó törlésével visszavonható, Linuxon, Windowson és Androidon egyaránt működő titoktároló pedig
  még nincs az alkalmazásban. Unixon az adatkönyvtár csak a felhasználó számára olvasható, több védelem nincs. A
  „Bejelentkezve maradok” jelölőnégyzet kikapcsolásával a token nem kerül az adatbázisba.
- A Windows-driver a felületi szálon kívül nyitja meg a forrást, az Android lejátszó szolgáltatás pedig túléli a
  számok közötti rövid szüneteket, tartja a hangfókuszt és részleges wake lockot. Ezeket a fejlesztői környezetben csak
  átnézni lehetett, futtatni nem.
- A dalszöveg csak a fájl saját címkéjéből jön (szinkronizálatlan szöveg); nincs keresőszolgáltatás és nincs
  szinkronizált megjelenítés.
- Az előadó nélküli számok az `Unknown artist` előadó alá kerülnek; ez a név az adatbázisban van tárolva, és nincs
  lefordítva. Ehhez nem keres a program előadóképet.

## Közreműködés és licenc

Lásd [CONTRIBUTING.md](CONTRIBUTING.md). A repóban még nincs licencfájl; amíg a tulajdonos nem tesz be egyet,
minden jog fenntartva.
