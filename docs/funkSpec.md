# Wiretune — Funkcionális specifikáció

> Ez a dokumentum a `csizmi` ág jelenlegi (2026-09-26-i) állapotát írja le: mit
> csinál a rendszer *ténylegesen*, nem egy tervezett jövőbeli állapotot. A "Hatókörön
> kívül" szakasz sorolja fel, ami tudatosan nincs megvalósítva.

## 1. Termékleírás és célközönség

Wiretune egy önállóan hosztolt (self-hosted) veszteségmentes zenelejátszó és
streaming rendszer. Egy háztartáson belül egy gép (szerver) tárolja és
szolgáltatja a zenei gyűjteményt; erre csatlakoznak a lejátszó kliensek
(asztali Linux/Windows, Android). Célközönség: saját FLAC/veszteségmentes
gyűjteménnyel rendelkező, technikailag jártas felhasználók, akik nem akarnak
előfizetéses streaming szolgáltatásra hagyatkozni.

## 2. Szerepkörök

| Szerepkör | Jogosultság |
|---|---|
| **Adminisztrátor** | Az első regisztrált fiók automatikusan admin. Jogosult: új felhasználó regisztrálására, manuális könyvtár-újraindexelés indítására. |
| **Felhasználó** | Bejelentkezhet, böngészheti és lejátszhatja a könyvtárat, kezelheti a saját kedvenceit és lejátszási listáit (ezek a kliens eszközön tárolódnak, nem szerveren). Nem indíthat szkennelést, nem regisztrálhat új felhasználót. |
| **Bejelentkezés nélküli (offline/helyi) mód** | Szerver nélkül, helyi zenemappával is használható a kliens — ekkor nincs felhasználófogalom. |

## 3. Funkcionális követelmények

### 3.1 Első beállítás és hitelesítés

- **Első szerver-indítás**: nincs alapértelmezett fiók. A kliens felismeri
  (`/api/auth/setup-required`), és admin-létrehozó űrlapot jelenít meg
  (felhasználónév, jelszó ≥ 8 karakter, opcionális megjelenített név).
- Ha közben egy másik kliens már beállította a szervert, a felhasználó
  egyértelmű üzenetet kap ("A szervert időközben már beállították..."), nem
  hibaüzenetet vagy lefagyást.
- **Bejelentkezés**: felhasználónév + jelszó. "Maradjak bejelentkezve ezen az
  eszközön" jelölőnégyzet: ha be van jelölve, a token eltárolódik és
  induláskor automatikus a visszakapcsolódás; ha nincs, a token csak a
  munkamenet végéig érvényes (bezáráskor elvész).
- Hibás jelszó/felhasználónév esetén egységes hibaüzenet (nem árulja el,
  hogy a felhasználónév létezik-e).
- **Kijelentkezés**: törli a helyi tokent, visszatér a bejelentkezés
  képernyőre.
- **Szerver nélküli folytatás**: bármikor választható ("Folytatás szerver
  nélkül") — ekkor a helyi (korábban beolvasott vagy soha be nem olvasott)
  könyvtár használható.

### 3.2 Szerverkapcsolat kezelése

- Szervercím megadása (host:port vagy teljes URL), "Kapcsolódás" gomb
  teszteli az elérhetőséget és jelzi az állapotot (beállítás szükséges /
  bejelentkezés szükséges / kapcsolódva / nem elérhető).
- Ha a kliens korábban szerver-könyvtárat használt, és a szerver induláskor
  nem elérhető, egy elutasítható **figyelmeztető sáv** jelenik meg a
  felületen ("A szerver (...) nem érhető el"), "Újracsatlakozás" és
  "Beállítások" gombokkal — eközben a korábban letöltött (gyorsítótárazott)
  könyvtár továbbra is böngészhető és lejátszható.
- **Manuális újraindexelés** (csak adminnak): a szerver a háttérben
  újraolvassa a könyvtárat; a kliens állapotszöveggel jelzi a folyamatot és
  automatikusan frissíti a listát, amint kész.

### 3.3 Zenei könyvtár böngészése

- **Számok** nézet: teljes lista, lejátszás, "Mind lejátszása",
  "Véletlenszerű" (shuffle-lel indított teljes lejátszás).
- **Albumok** nézet: rácsos elrendezés borítóképekkel, minőségjelzéssel
  (pl. "HI-RES LOSSLESS • 24bit/96kHz"); kattintásra album-részlet
  (számlista, teljes album lejátszása vagy keverve).
- **Előadók** nézet: rácsos elrendezés; kattintásra előadó-részlet (az
  előadó összes albuma és összes száma, beleértve azokat is, amelyeken csak
  közreműködőként szerepel egy válogatáslemezen).
- **Keresés**: azonnali, a gépelés közben frissülő találati lista számokra,
  albumokra, előadókra egyszerre; kiemelt "legjobb találat" kártya (pontos
  egyezés > kezdő egyezés > első találat prioritási sorrendben).
- **Üres állapotok**: ha nincs betöltött szám, minden nézet magyarázó
  szöveget és cselekvésre hívó gombot mutat (szerverre csatlakozás vagy
  helyi mappa megadása) ahelyett, hogy üresen maradna.

### 3.4 Lejátszás

- Play/Pause, Előző/Következő szám, tekerés (csúszka, debounce-olt seek),
  hangerő (csúszka + némítás gomb), keverés be/ki, ismétlés (Ki → Összes →
  Egy szám ciklikusan).
- **Keverés futó lejátszás közben is átkapcsolható**: bekapcsoláskor a
  jelenlegi számtól számítva véletlenszerűsíti a hátralévő sort;
  kikapcsoláskor visszaáll az eredeti sorrendre a jelenlegi szám után.
- **Lejátszási hiba jelzése**: ha a lejátszás nem indul (pl. hiányzó
  lejátszó komponens, hálózati hiba a streamnél), a lejátszósávban és az
  állapotsorban is felhasználóbarát hibaüzenet jelenik meg, elutasítható
  ("X") gombbal — a felület nem marad csendben, mintha semmi nem történt
  volna.
- **Élő spektrumanalizátor** (32 sáv) a lejátszósávban, ha van aktív
  lejátszás.
- **Minőségjelző** (pl. "HI-RES", "LOSSLESS", codec neve) a jelenlegi
  számhoz, tooltipben a teljes technikai leírással.
- **Dalszöveg**: a lejátszási sor nézetében (telefonon a teljes képernyős
  lejátszó "Dalszöveg" fülén) a jelenlegi szám fájljába ágyazott
  dalszöveg-címke jelenik meg, ha van; ha nincs, erről tájékoztató üzenet. Csak
  a nézet megnyitásakor tölti be. Szerveres számnál a szerver `/api/lyrics`
  végpontjáról jön.

### 3.5 Audiophile beállítások

- **Kizárólagos (Exclusive) mód**: a kiválasztott kimeneti eszköz kizárólagos
  hardveres lefoglalása (csak olyan eszközön kapcsolható be, amely ezt
  támogatja — ha egyik sem támogatja, a kapcsoló inaktív és a felület
  megmagyarázza, miért).
- **Bit-Perfect mód**: 1:1 bitpontos átvitel keverés/újramintavételezés
  nélkül, a hangerő 0 dB-en (100%) rögzítve; bekapcsolása automatikusan
  bekapcsolja a kizárólagos módot is; kikapcsolásakor a korábbi (bit-perfect
  előtti) hangerő visszaáll.
- **Kimeneti eszköz kiválasztása**: legördülő lista a rendszer által
  észlelt eszközökről, "Frissítés" gombbal újra-észleléshez.
- **Jelút (Signal Path) kijelző**: szöveges leírás a teljes útvonalról
  (forrás formátum → átviteli mód → feldolgozás → hozzáférési mód → célgép),
  valós időben frissülve módváltáskor.

### 3.6 Kedvencek

- Bármely számnál egy kattintással kedvencnek jelölhető/eltávolítható (szív
  ikon), listákban és a lejátszósávban egyaránt.
- Külön "Kedvencek" nézet, amely csak a megjelölt számokat listázza,
  "Kedvencek lejátszása" gombbal.

### 3.7 Lejátszási listák

- **Létrehozás**: névvel, dialógusablakban.
- **Szám hozzáadása listához**: bármely számnál "+" gombbal, dialógusablak
  megjeleníti a meglévő listákat (darabszámmal) VAGY azonnal új lista
  létrehozását ajánlja fel, ha még nincs egy sem.
- **Lista tartalmának kezelése**: szám eltávolítása egy adott listából
  (a szám maga nem törlődik a könyvtárból).
- **Lista törlése**: megerősítő dialógussal ("Biztosan törlöd... A számok a
  könyvtárban maradnak.").
- **Lejátszás**: teljes lista vagy egy adott szám a listából indítva.
- Üres lista esetén magyarázó szöveg jelenik meg a számlista helyén.

### 3.8 Beállítások felület

Egyetlen egyesített "Beállítások" nézet, két szekcióval:
1. **Szerver és könyvtár**: fiókállapot, szerver URL és kapcsolódás,
   statisztikák (szám/album/előadó darabszám), helyi mappa beolvasása
   (szerver nélküli használathoz).
2. **Hangkimenet**: exclusive/bit-perfect kapcsolók, eszközválasztó, jelút
   kijelző.
3. **Megjelenés**: nyelv (magyar / angol / német) és világos/sötét téma. A
   váltás azonnal érvényesül, újraindítás nélkül, és megmarad a következő
   indításig. Első indításkor az operációs rendszer nyelve érvényes, ha az
   támogatott, egyébként angol.

### 3.9 Telefonos felület (Android)

Androidon a felület telefonra szabott: alsó navigációs sáv (Előadók, Albumok,
Számok, Lejátszási listák, Beállítások; a Kedvencek a Lejátszási listák lapról
érhető el), lebegő mini lejátszó, teljes képernyős lejátszó Lejátszó / Sor /
Dalszöveg füllel, külön keresőoldal, és alulról felcsúszó lapok a lejátszási
listák létrehozásához, törléséhez és a számok listához adásához. A rendszer
vissza-gesztusa a legbelső nyitott réteget zárja be, és csak akkor lépteti ki az
alkalmazást, ha már nincs mit bezárni. A funkciók azonosak az asztalival.

## 4. Nem-funkcionális követelmények

| Terület | Elvárás |
|---|---|
| **Biztonság** | Jelszavak BCrypt-tel tárolva (legfeljebb 72 bájt); JWT aláírt, saját titkos kulccsal szerverenként, és a fiók törlésével azonnal érvénytelen; a bejelentkezés sebességkorlátozott; a query-string token csak a stream/borító végpontokon érvényes; fájlelérés a könyvtárgyökérre korlátozva (path traversal védelem); a fejlesztői UI-automatizálási felület alapból kikapcsolt és csak localhost-ról, böngészőn kívülről érhető el. |
| **Megbízhatóság** | Egy le nem csatolt hálózati megosztás átmeneti "üresség"-e nem törli a szerveroldali indexet; egyszerre csak egy szkennelés futhat; a szerver és a kliens(ek) külön adatbázist használnak, így egy gépen futtatva sem írják felül egymás adatait. |
| **Teljesítmény** | Inkrementális szkennelés (csak a változott fájlok olvasódnak újra); párhuzamos metaadat-olvasás; borítóképek megjelenítési méretre dekódolva, korlátos (300 elem) gyorsítótárban; csak a látható albumkártyák töltenek be borítót. |
| **Platform-korlátok jelzése** | A felület nem kínál fel olyan hangkimeneti módot, amit az adott platform/eszköz ténylegesen nem támogat (pl. Androidon nincs kizárólagos mód). |
| **Naplózás** | Fájlalapú napló (`WiretuneLog`), külön fájl szerver és kliens folyamatonként; a hitelesítési tokenek maszkolva kerülnek a naplóba. |
| **Tesztelhetőség** | A lejátszási logika hardver-/külső folyamat-függetlenül tesztelhető (absztrahált audio driver); a szerver API valódi HTTP-kérésekkel, memóriában futtatva tesztelhető. |

## 5. Jellemző felhasználói folyamatok

### 5.1 Első használatbavétel (szerverrel)

1. Felhasználó telepíti és elindítja a szervert egy zenei mappára mutatva.
2. Felhasználó megnyitja a kliens alkalmazást; megjelenik a bejelentkezés
   képernyő.
3. Megadja a szerver címét, "Csatlakozás" → a rendszer jelzi: beállítás
   szükséges.
4. Létrehozza az admin fiókot (felhasználónév + jelszó ≥ 8 karakter) →
   automatikusan bejelentkezik.
5. A szerver a háttérben már indexeli a könyvtárat (induláskor automatikusan
   elindul); a kliens letölti a (folyamatosan bővülő) számlistát.
6. A felhasználó böngészhet és lejátszhat.

### 5.2 Visszatérő használat, mentett bejelentkezéssel

1. Felhasználó elindítja a klienst.
2. A helyi gyorsítótárazott könyvtár azonnal megjelenik (nincs várakozás a
   hálózatra).
3. A háttérben a kliens automatikusan megpróbál visszakapcsolódni a mentett
   szerverre és tokennel bejelentkezni.
4. Sikeres visszakapcsolódás esetén a könyvtár frissül a szerver aktuális
   állapotára; sikertelen esetén (szerver offline) figyelmeztető sáv
   jelenik meg, de a gyorsítótárazott könyvtár tovább használható.

### 5.3 Szám hozzáadása lejátszási listához, menet közben

1. Felhasználó a "+" (lejátszási listához adás) ikonra kattint egy számnál.
2. Ha van már lista: kiválasztja a célt egy listából; a szám bekerül.
3. Ha nincs lista: a dialógus felajánlja új lista létrehozását, a szám
   automatikusan bekerül az újonnan létrehozott listába.

### 5.4 Audiophile lejátszás bekapcsolása

1. Felhasználó a Beállítások → Hangkimenet alatt bekapcsolja a Bit-Perfect
   kapcsolót.
2. A rendszer automatikusan kizárólagos módra vált (ha még nem volt az), és
   olyan eszközt választ, amely mindkettőt támogatja.
3. A hangerő 100%-ra rögzül, a csúszka inaktívvá válik (lakat ikonnal
   jelezve).
4. A Jelút kijelző frissül, mutatva a teljes útvonalat.

## 6. Hatókörön kívül (tudatosan nem megvalósított)

- **Többfelhasználós szinkronizáció**: kedvencek és lejátszási listák
  eszközönként/kliensenként tárolódnak, nincs szerveroldali megosztásuk a
  felhasználók vagy eszközök között.
- **Transzkódolás**: a szerver mindig az eredeti fájlformátumot streameli;
  nincs átkódolás alacsonyabb bitrátára/formátumra gyengébb hálózathoz.
- **Exclusive/bit-perfect kimenet Androidon**: ezen a platformon csak
  megosztott (rendszerkeverős) lejátszás érhető el. (Windowson a WASAPI
  Exclusive elérhető, de hardver nélkül nem volt ellenőrizve.)
- **Háttérben lejátszás / médiavezérlők Androidon**: az Android-integráció
  jelen állapotban alap lejátszást biztosít, nincs értesítési sáv-vezérlés
  vagy zárolt képernyős widget.
- **Offline lejátszás szerver nélkül, szerver-könyvtárból**: a szerverről
  streamelt számok nem kerülnek helyi másolatba; internetkapcsolat (LAN)
  nélkül csak a helyi mappából beolvasott könyvtár játszható le.
