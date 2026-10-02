namespace Wiretune.Core.Localization;

/// <summary>
/// Every translatable text: key -> (Hungarian, English, German). Keys are grouped by the screen or component
/// that shows them. Rules the tests enforce: every key has all three texts, a key's placeholders
/// ({0}, {1}, ...) are the same in every language, and every key used in code or XAML exists here.
/// A key with a "_One" variant is used instead when the first format argument is exactly 1.
/// </summary>
internal static class Strings
{
    internal static readonly IReadOnlyDictionary<string, (string Hu, string En, string De)> All = Build();

    private static Dictionary<string, (string Hu, string En, string De)> Build()
    {
        var d = new Dictionary<string, (string Hu, string En, string De)>(StringComparer.Ordinal);
        void T(string key, string hu, string en, string de) => d.Add(key, (hu, en, de));

        // ── Common ───────────────────────────────────────────────────────────────────────────────────
        T("Close", "Bezárás", "Close", "Schließen");
        T("Cancel", "Mégse", "Cancel", "Abbrechen");
        T("Save", "Mentés", "Save", "Speichern");
        T("Delete", "Törlés", "Delete", "Löschen");
        T("Add", "Hozzáadás", "Add", "Hinzufügen");
        T("Create", "Létrehozás", "Create", "Erstellen");
        T("Refresh", "Frissítés", "Refresh", "Aktualisieren");
        T("Connect", "Csatlakozás", "Connect", "Verbinden");
        T("ConnectShort", "Kapcsolódás", "Connect", "Verbinden");
        T("Reconnect", "Újracsatlakozás", "Reconnect", "Erneut verbinden");
        T("Play", "Lejátszás", "Play", "Wiedergabe");
        T("Shuffle", "Véletlenszerű", "Shuffle", "Zufällig");
        T("Or", "VAGY", "OR", "ODER");
        T("Language", "Nyelv", "Language", "Sprache");
        T("Theme", "Téma", "Theme", "Farbschema");
        T("Unknown", "ismeretlen", "unknown", "unbekannt");

        // ── Navigation and shell ─────────────────────────────────────────────────────────────────────
        T("NavArtists", "Előadók", "Artists", "Künstler");
        T("NavAlbums", "Albumok", "Albums", "Alben");
        T("NavTracks", "Számok", "Tracks", "Titel");
        T("NavSongs", "Számok", "Songs", "Titel");
        T("NavFavorites", "Kedvencek", "Favorites", "Favoriten");
        T("NavPlaylists", "Lejátszási listák", "Playlists", "Playlists");
        T("NavPlaylistsShort", "Listák", "Playlists", "Playlists");
        T("NavSettings", "Beállítások", "Settings", "Einstellungen");
        T("SectionLibrary", "KÖNYVTÁR", "LIBRARY", "BIBLIOTHEK");
        T("SectionCollection", "GYŰJTEMÉNY", "COLLECTION", "SAMMLUNG");
        T("SectionSettings", "BEÁLLÍTÁSOK", "SETTINGS", "EINSTELLUNGEN");
        T("SearchPlaceholder", "Keresés számok, előadók, albumok között...", "Search tracks, artists, albums…", "Titel, Künstler und Alben durchsuchen …");
        T("SearchPlaceholderShort", "Keresés...", "Search…", "Suchen …");
        T("Search", "Keresés", "Search", "Suche");
        T("TipClearSearch", "Keresés törlése", "Clear search", "Suche löschen");
        T("TipBitPerfect", "Bit-perfect mód (a Wiretune nem erősít és nem halkít, a hangerő 100%-on rögzítve)", "Bit-perfect mode (Wiretune applies no gain, volume locked at 100%)", "Bit-Perfect-Modus (Wiretune ändert die Lautstärke nicht, Lautstärke auf 100 % fixiert)");
        T("TipExclusive", "Kizárólagos (Exclusive) mód (közvetlen ALSA / WASAPI DAC hozzáférés)", "Exclusive mode (direct ALSA / WASAPI DAC access)", "Exklusivmodus (direkter ALSA-/WASAPI-DAC-Zugriff)");
        T("TipAccount", "Wiretune Szerver Fiók és Bejelentkezés", "Wiretune server account and sign-in", "Wiretune-Serverkonto und Anmeldung");
        T("TipAccountSettings", "Fiók és beállítások", "Account and settings", "Konto und Einstellungen");
        T("SettingsPerformanceStats", "Teljesítménystatisztika", "Performance statistics", "Leistungsstatistik");
        T("SettingsPerformanceStatsHint", "Képkocka-grafikonok és számlálók a képernyő alján, a teljesítményhangoláshoz.", "Frame graphs and counters at the bottom of the screen, for tuning performance.", "Bildraten-Diagramme und Zähler am unteren Bildschirmrand zur Leistungsabstimmung.");
        T("TipToggleTheme", "Téma váltása (Sötét / Világos)", "Switch theme (dark / light)", "Design wechseln (Dunkel / Hell)");
        T("TipMinimize", "Kis méret", "Minimize", "Minimieren");
        T("TipMaximize", "Teljes méret / Visszaállítás", "Maximize / Restore", "Maximieren / Wiederherstellen");
        T("TipDismissNotice", "Értesítés bezárása", "Dismiss notification", "Benachrichtigung schließen");
        T("TipLanguage", "Nyelv váltása", "Change language", "Sprache wechseln");
        T("Back", "Vissza", "Back", "Zurück");
        T("BackToMusic", "Vissza a zenékhez", "Back to music", "Zurück zur Musik");
        T("BackToSearch", "Vissza a kereséshez", "Back to search", "Zurück zur Suche");
        T("BackToTracks", "Vissza a számokhoz", "Back to tracks", "Zurück zu den Titeln");
        T("BackToFavorites", "Vissza a kedvencekhez", "Back to favorites", "Zurück zu den Favoriten");
        T("BackToAlbums", "Vissza az összes albumhoz", "Back to all albums", "Zurück zu allen Alben");
        T("BackToArtists", "Vissza az összes előadóhoz", "Back to all artists", "Zurück zu allen Künstlern");
        T("BackToPlaylists", "Vissza a lejátszási listákhoz", "Back to playlists", "Zurück zu den Playlists");
        T("BackTo", "Vissza: {0}", "Back to: {0}", "Zurück zu: {0}");

        // ── Counts and durations ─────────────────────────────────────────────────────────────────────
        T("TrackCount", "{0} szám", "{0} tracks", "{0} Titel");
        T("TrackCount_One", "{0} szám", "{0} track", "{0} Titel");
        T("ArtistCount", "{0} előadó", "{0} artists", "{0} Künstler");
        T("ArtistCount_One", "{0} előadó", "{0} artist", "{0} Künstler");
        T("AlbumCount", "{0} album", "{0} albums", "{0} Alben");
        T("AlbumCount_One", "{0} album", "{0} album", "{0} Album");
        T("TrackCountInDatabase", "{0} szám az adatbázisban", "{0} tracks in the database", "{0} Titel in der Datenbank");
        T("TrackCountInDatabase_One", "{0} szám az adatbázisban", "{0} track in the database", "{0} Titel in der Datenbank");
        T("DurationHoursMinutes", "{0} óra {1} perc", "{0} h {1} min", "{0} Std. {1} Min.");
        T("DurationMinutesSeconds", "{0} perc {1} mp", "{0} min {1} s", "{0} Min. {1} Sek.");
        T("CreatedAt", "Létrehozva: {0:yyyy.MM.dd HH:mm}", "Created: {0:yyyy-MM-dd HH:mm}", "Erstellt: {0:dd.MM.yyyy HH:mm}");
        T("QuotedText", "„{0}”", "“{0}”", "„{0}“");
        T("FooterLocalAndServer", "({0} helyi, {1} szerver)", "({0} local, {1} server)", "({0} lokal, {1} Server)");
        T("FooterServerOnly", "({0} szerver)", "({0} server)", "({0} Server)");
        T("FooterLocalOnly", "({0} helyi)", "({0} local)", "({0} lokal)");
        T("FooterLoading", "Könyvtár betöltése...", "Loading library…", "Bibliothek wird geladen …");
        T("FooterScanning", "Könyvtár beolvasása...", "Scanning library…", "Bibliothek wird eingelesen …");
        T("FooterNoTracks", "Nincs elérhető szám", "No tracks available", "Keine Titel verfügbar");

        // ── Library views ────────────────────────────────────────────────────────────────────────────
        T("EmptyLibraryTitle", "A zenei könyvtárad még üres", "Your music library is empty", "Deine Musikbibliothek ist noch leer");
        T("EmptyLibraryHint", "Csatlakozz a Wiretune szerveredhez, vagy olvass be egy helyi zenemappát a Beállításokban.", "Connect to your Wiretune server, or scan a local music folder in Settings.", "Verbinde dich mit deinem Wiretune-Server oder lies in den Einstellungen einen lokalen Musikordner ein.");
        T("EmptyConnectHint", "Csatlakozz a szerveredhez vagy olvass be egy helyi mappát a Beállításokban.", "Connect to your server or scan a local folder in Settings.", "Verbinde dich mit deinem Server oder lies in den Einstellungen einen lokalen Ordner ein.");
        T("ConnectToServer", "Csatlakozás szerverhez", "Connect to server", "Mit Server verbinden");
        T("LocalFolder", "Helyi mappa", "Local folder", "Lokaler Ordner");
        T("ColTitle", "CÍM", "TITLE", "TITEL");
        T("ColArtist", "ELŐADÓ", "ARTIST", "KÜNSTLER");
        T("ColAlbum", "ALBUM", "ALBUM", "ALBUM");
        T("ColQuality", "MINŐSÉG", "QUALITY", "QUALITÄT");
        T("ColLength", "HOSSZ", "LENGTH", "DAUER");
        T("LabelAlbums", "ALBUMOK", "ALBUMS", "ALBEN");
        T("LabelArtists", "ELŐADÓK", "ARTISTS", "KÜNSTLER");
        T("LabelTracks", "SZÁMOK", "TRACKS", "TITEL");
        T("LabelAllTracks", "ÖSSZES SZÁM", "ALL TRACKS", "ALLE TITEL");
        T("LabelPlaylist", "LEJÁTSZÁSI LISTA", "PLAYLIST", "PLAYLIST");
        T("SortBy", "Rendezés:", "Sort by:", "Sortieren nach:");
        T("SortYear", "Év", "Year", "Jahr");
        T("EmptyAlbumsTitle", "Még nincsenek albumok", "No albums yet", "Noch keine Alben");
        T("EmptyArtistsTitle", "Még nincsenek előadók", "No artists yet", "Noch keine Künstler");
        T("EmptyFavoritesTitle", "Még nincsenek kedvenceid", "No favorites yet", "Noch keine Favoriten");
        T("EmptyFavoritesHint", "A számok melletti szív ikonnal jelölhetsz meg kedvenceket.", "Use the heart icon next to a track to mark favorites.", "Mit dem Herz-Symbol neben einem Titel markierst du Favoriten.");
        T("TipAddToPlaylist", "Hozzáadás lejátszási listához", "Add to playlist", "Zur Playlist hinzufügen");
        T("TipPlay", "Lejátszás", "Play", "Wiedergabe");
        T("TipFavorite", "Kedvenc", "Favorite", "Favorit");
        T("TipRemoveFromFavorites", "Eltávolítás a kedvencek közül", "Remove from favorites", "Aus Favoriten entfernen");

        // ── Playlists ────────────────────────────────────────────────────────────────────────────────
        T("PlaylistNew", "Új lejátszási lista", "New playlist", "Neue Playlist");
        T("EmptyPlaylistsTitle", "Még nincs lejátszási listád", "You have no playlists yet", "Du hast noch keine Playlists");
        T("EmptyPlaylistsHint", "Hozz létre egy listát, majd a számok melletti „+” gombbal adj hozzá zenéket a gyűjteményedből.", "Create a playlist, then use the “+” button next to tracks to add music from your collection.", "Erstelle eine Playlist und füge über die „+“-Schaltfläche neben den Titeln Musik aus deiner Sammlung hinzu.");
        T("PlaylistEmptyTitle", "Ez a lejátszási lista még üres", "This playlist is empty", "Diese Playlist ist noch leer");
        T("PlaylistEmptyHint", "Böngészd a számaidat vagy albumaidat, és a „+” gombbal adj dalokat ehhez a listához.", "Browse your tracks or albums and use the “+” button to add songs to this playlist.", "Durchstöbere deine Titel oder Alben und füge über die „+“-Schaltfläche Songs zu dieser Playlist hinzu.");
        T("NoPlaylistsCreateOne", "Még nincs lejátszási listád – hozz létre egyet.", "You have no playlists yet – create one.", "Du hast noch keine Playlists – erstelle eine.");
        T("PlaylistNamePlaceholder", "Lista neve", "Playlist name", "Name der Playlist");
        T("PlaylistAlsoAddsTrack", "A(z) „{0}” szám is bekerül az új listába.", "The track “{0}” will also be added to the new playlist.", "Der Titel „{0}“ wird auch zur neuen Playlist hinzugefügt.");
        T("PlaylistDeleteAction", "Lista törlése", "Delete playlist", "Playlist löschen");
        T("PlaylistDeleteConfirm", "Biztosan törlöd a(z) „{0}” listát? A számok a könyvtárban maradnak.", "Really delete the playlist “{0}”? The tracks stay in your library.", "Möchtest du die Playlist „{0}“ wirklich löschen? Die Titel bleiben in deiner Bibliothek.");
        T("TipRename", "Kattints az átnevezéshez", "Click to rename", "Zum Umbenennen klicken");
        T("TipRemoveFromPlaylist", "Eltávolítás a listából", "Remove from playlist", "Aus Playlist entfernen");

        // ── Search ───────────────────────────────────────────────────────────────────────────────────
        T("SearchResultsFor", "Keresési találatok:", "Search results:", "Suchergebnisse:");
        T("SearchSubtitle", "Számok, albumok és előadók egy helyen", "Tracks, albums and artists in one place", "Titel, Alben und Künstler an einem Ort");
        T("NoResultsTitle", "Nincs találat a keresésre", "No results found", "Keine Treffer");
        T("NoResultsHint", "Próbálj meg más előadóra, számcímre vagy albumra keresni.", "Try searching for a different artist, track title or album.", "Versuche es mit einem anderen Künstler, Titel oder Album.");
        T("BestMatch", "LEGJOBB TALÁLAT", "BEST MATCH", "BESTER TREFFER");
        T("TypeMatch", "TALÁLAT", "MATCH", "TREFFER");
        T("TypeArtist", "ELŐADÓ", "ARTIST", "KÜNSTLER");
        T("TypeAlbum", "ALBUM", "ALBUM", "ALBUM");
        T("TypeTrack", "SZÁM", "TRACK", "TITEL");
        T("SubtitleArtist", "Előadó", "Artist", "Künstler");

        // ── Player ───────────────────────────────────────────────────────────────────────────────────
        T("NothingPlaying", "Nincs lejátszás", "Nothing playing", "Keine Wiedergabe");
        T("ChooseMusic", "Válassz zenét", "Choose some music", "Wähle Musik");
        T("Queue", "Lejátszási sor", "Queue", "Warteschlange");
        T("NowPlaying", "MOST SZÓL", "NOW PLAYING", "WIRD GESPIELT");
        T("ClearQueue", "Sor kiürítése", "Clear queue", "Warteschlange leeren");
        T("QueueEmptyTitle", "A lejátszási sor jelenleg üres", "The queue is empty", "Die Warteschlange ist leer");
        T("QueueEmptyHint", "Indíts el egy albumot vagy számot a lejátszáshoz a gyűjteményedből.", "Start an album or track from your collection to play it.", "Starte ein Album oder einen Titel aus deiner Sammlung.");
        T("TipDragToReorder", "Húzd a sorrend módosításához", "Drag to reorder", "Zum Umsortieren ziehen");
        T("TipMoveUp", "Mozgatás feljebb", "Move up", "Nach oben");
        T("TipMoveDown", "Mozgatás lejjebb", "Move down", "Nach unten");
        T("TipRemoveFromQueue", "Eltávolítás a sorból", "Remove from queue", "Aus Warteschlange entfernen");
        T("Lyrics", "DALSZÖVEG", "LYRICS", "LIEDTEXT");
        T("TabPlayer", "Lejátszó", "Player", "Player");
        T("TabLyrics", "Dalszöveg", "Lyrics", "Liedtext");
        T("NoLyrics", "Ehhez a számhoz nincs dalszöveg a metaadatokban.", "This track has no lyrics in its metadata.", "Für diesen Titel sind keine Liedtexte in den Metadaten vorhanden.");
        T("TipQueueToggle", "Lejátszási sor (kattints a megnyitáshoz / elrejtéshez)", "Queue (click to show / hide)", "Warteschlange (zum Ein-/Ausblenden klicken)");
        T("TipShuffle", "Véletlenszerű lejátszás", "Shuffle", "Zufallswiedergabe");
        T("TipPrevious", "Előző szám", "Previous track", "Vorheriger Titel");
        T("TipPlayPause", "Lejátszás / Szünet", "Play / Pause", "Wiedergabe / Pause");
        T("TipNext", "Következő szám", "Next track", "Nächster Titel");
        T("TipRepeat", "Ismétlés: Ki / Összes / Egy szám", "Repeat: off / all / one track", "Wiederholen: Aus / Alle / Ein Titel");
        T("TipSpectrum", "32 sávos valós idejű spektrumanalizátor", "32-band real-time spectrum analyzer", "32-Band-Echtzeit-Spektrumanalysator");
        T("TipDismissError", "Hibaüzenet elrejtése", "Dismiss error message", "Fehlermeldung ausblenden");
        T("TipCloseToPlayer", "Bezárás / vissza a lejátszóhoz", "Close / back to player", "Schließen / zurück zum Player");
        T("VolumeMute", "Némítás", "Mute", "Stummschalten");
        T("VolumeUnmute", "Némítás feloldása", "Unmute", "Stummschaltung aufheben");
        T("VolumeLocked", "Bit-perfect mód (Hangerő rögzítve)", "Bit-perfect mode (volume locked)", "Bit-Perfect-Modus (Lautstärke fixiert)");
        T("UnexpectedError", "Váratlan hiba: {0}", "Unexpected error: {0}", "Unerwarteter Fehler: {0}");

        BuildSettings(T);
        BuildServer(T);
        BuildAudio(T);
        return d;
    }

    private static void BuildSettings(Action<string, string, string, string> T)
    {
        // ── Settings screen ──────────────────────────────────────────────────────────────────────────
        T("SettingsSubtitle", "Szerverkapcsolat, zenei könyvtár és hangkimenet.", "Server connection, music library and audio output.", "Serververbindung, Musikbibliothek und Audioausgabe.");
        T("SettingsServerSection", "SZERVER ÉS KÖNYVTÁR", "SERVER & LIBRARY", "SERVER & BIBLIOTHEK");
        T("SettingsAudioSection", "HANGKIMENET ÉS AUDIOFIL BEÁLLÍTÁSOK", "AUDIO OUTPUT & AUDIOPHILE SETTINGS", "AUDIOAUSGABE & AUDIOPHILE EINSTELLUNGEN");
        T("SettingsAppearanceSection", "MEGJELENÉS", "APPEARANCE", "DARSTELLUNG");
        T("SettingsLanguageHint", "A felület nyelve. A választás megmarad a következő indításig is.", "The language of the interface. Your choice is remembered.", "Die Sprache der Oberfläche. Deine Auswahl bleibt erhalten.");
        T("SettingsThemeHint", "Sötét vagy világos megjelenés.", "Dark or light appearance.", "Dunkles oder helles Erscheinungsbild.");
        T("Connection", "Kapcsolat", "Connection", "Verbindung");
        T("LabelServer", "SZERVER", "SERVER", "SERVER");
        T("ServerUrlPlaceholder", "http://szerver-ip:5200", "http://server-ip:5200", "http://server-ip:5200");
        T("ServerFolderLabel", "SZERVER ZENEMAPPA (ADMIN)", "SERVER MUSIC FOLDER (ADMIN)", "MUSIKORDNER AUF DEM SERVER (ADMIN)");
        T("ServerFolderPlaceholder", "/eleresi/ut/a/szerveren/zenek", "/path/on/the/server/music", "/pfad/auf/dem/server/musik");
        T("SaveFolder", "Mappa mentése", "Save folder", "Ordner speichern");
        T("LocalFolderLabel", "HELYI ZENEMAPPA", "LOCAL MUSIC FOLDER", "LOKALER MUSIKORDNER");
        T("LocalFolderPlaceholder", "/eleresi/ut/zenek", "/path/to/music", "/pfad/zur/musik");
        T("Scan", "Beolvasás", "Scan", "Einlesen");
        T("Reindex", "Újraindexelés", "Reindex", "Neu indizieren");
        T("TipReindex", "A szerver újraolvassa a zenemappát (adminisztrátori jog szükséges).", "The server rescans the music folder (administrator rights required).", "Der Server liest den Musikordner neu ein (Administratorrechte erforderlich).");
        T("TipCheckConnection", "Kapcsolat ellenőrzése", "Check connection", "Verbindung prüfen");

        // Account
        T("SignIn", "Bejelentkezés", "Sign in", "Anmelden");
        T("SignOut", "Kijelentkezés", "Sign out", "Abmelden");
        T("TipSignOut", "Kijelentkezés a szerverfiókból", "Sign out of the server account", "Vom Serverkonto abmelden");
        T("NotSignedIn", "Nincs bejelentkezve", "Not signed in", "Nicht angemeldet");
        T("NotSignedInHint", "Jelentkezz be a szerverre a veszteségmentes streameléshez, vagy használj helyi mappát.", "Sign in to the server for lossless streaming, or use a local folder.", "Melde dich am Server an, um verlustfrei zu streamen, oder nutze einen lokalen Ordner.");
        T("RoleAdmin", "Adminisztrátor", "Administrator", "Administrator");
        T("RoleUser", "Felhasználó", "User", "Benutzer");
        T("ServerAddressLabel", "SZERVER CÍME", "SERVER ADDRESS", "SERVERADRESSE");
        T("ServerUnreachableHint", "A szerver nem érhető el. Ellenőrizd a címet és hogy a Wiretune.Server fut-e. Helyi zenék szerver nélkül is lejátszhatók.", "The server is unreachable. Check the address and that Wiretune.Server is running. Local music can be played without a server.", "Der Server ist nicht erreichbar. Prüfe die Adresse und ob Wiretune.Server läuft. Lokale Musik kann auch ohne Server abgespielt werden.");
        T("FirstRun", "Első indítás", "First run", "Erster Start");
        T("FirstRunHint", "Hozd létre a szerver adminisztrátori fiókját. Később ezzel adhatsz hozzá további felhasználókat.", "Create the server's administrator account. You can use it later to add more users.", "Erstelle das Administratorkonto des Servers. Damit kannst du später weitere Benutzer hinzufügen.");
        T("AdminUsernamePlaceholder", "Admin felhasználónév", "Admin username", "Admin-Benutzername");
        T("CreateAdminAndSignIn", "Admin fiók létrehozása és belépés", "Create admin account and sign in", "Admin-Konto erstellen und anmelden");
        T("UsernamePlaceholder", "Felhasználónév", "Username", "Benutzername");
        T("PasswordPlaceholder", "Jelszó", "Password", "Passwort");
        T("PasswordMinPlaceholder", "Jelszó (min. 8)", "Password (min. 8)", "Passwort (mind. 8)");
        T("PasswordConfirmPlaceholder", "Jelszó megerősítése", "Confirm password", "Passwort bestätigen");
        T("PasswordHint", "Jelszó (legalább {0} karakter)", "Password (at least {0} characters)", "Passwort (mindestens {0} Zeichen)");
        T("StaySignedIn", "Bejelentkezve maradok", "Keep me signed in", "Angemeldet bleiben");
        T("ContinueWithoutServer", "Folytatás szerver nélkül (helyi zenék)", "Continue without a server (local music)", "Ohne Server fortfahren (lokale Musik)");

        // Users
        T("Users", "Felhasználók", "Users", "Benutzer");
        T("UsersSubtitle", "Felhasználók regisztrálása és eltávolítása a szerverről", "Register and remove users on the server", "Benutzer auf dem Server registrieren und entfernen");
        T("NewUser", "Új felhasználó", "New user", "Neuer Benutzer");
        T("RegisteredUsers", "REGISZTRÁLT FELHASZNÁLÓK", "REGISTERED USERS", "REGISTRIERTE BENUTZER");
        T("TipRefreshList", "Lista frissítése", "Refresh list", "Liste aktualisieren");
        T("TipDeleteUser", "Felhasználó törlése", "Delete user", "Benutzer löschen");

        // Connection state, library source and status line (view model texts)
        T("StatusReady", "Készenlétben", "Ready", "Bereit");
        T("StatusStarting", "Indítás...", "Starting…", "Wird gestartet …");
        T("StartupError", "Indítási hiba: {0}", "Startup error: {0}", "Startfehler: {0}");
        T("BadgeConnected", "Csatlakoztatva", "Connected", "Verbunden");
        T("BadgeOnline", "Online", "Online", "Online");
        T("BadgeOffline", "Offline", "Offline", "Offline");
        T("BadgeConnecting", "Kapcsolódás...", "Connecting…", "Verbinde …");
        T("BadgeLoginRequired", "Bejelentkezés szükséges", "Sign-in required", "Anmeldung erforderlich");
        T("BadgeSetupRequired", "Beállítás szükséges", "Setup required", "Einrichtung erforderlich");
        T("BadgeNoConnection", "Nincs kapcsolat", "No connection", "Keine Verbindung");
        T("SourceHybrid", "Egyesített ({0} + helyi mappa)", "Combined ({0} + local folder)", "Kombiniert ({0} + lokaler Ordner)");
        T("SourceServer", "Szerver ({0})", "Server ({0})", "Server ({0})");
        T("SourceLocal", "Helyi mappa ({0})", "Local folder ({0})", "Lokaler Ordner ({0})");
        T("SourceNone", "Nincs aktív forrás", "No active source", "Keine aktive Quelle");
        T("SourceNoneSelected", "Nincs kiválasztott könyvtár", "No library selected", "Keine Bibliothek ausgewählt");
        T("ServerBannerOffline", "A Wiretune szerver ({0}) nem érhető el. A helyi zeneszámok továbbra is elérhetők offline módban.", "The Wiretune server ({0}) is unreachable. Local tracks are still available offline.", "Der Wiretune-Server ({0}) ist nicht erreichbar. Lokale Titel sind weiterhin offline verfügbar.");
        T("ServerBannerUnreachable", "A Wiretune szerver ({0}) nem érhető el.", "The Wiretune server ({0}) is unreachable.", "Der Wiretune-Server ({0}) ist nicht erreichbar.");
        T("ModeBitPerfect", "Bit-Perfect", "Bit-Perfect", "Bit-Perfect");
        T("ModeExclusive", "Exclusive", "Exclusive", "Exclusive");
        T("ModeShared", "Megosztott", "Shared", "Gemeinsam");
        T("DefaultOutput", "Alapértelmezett kimenet", "Default output", "Standardausgabe");

        // Validation and operation results (server settings view model)
        T("AuthEnterCredentials", "Add meg a felhasználónevet és a jelszót!", "Enter a username and password!", "Gib Benutzername und Passwort ein!");
        T("AuthEnterAdminCredentials", "Add meg az admin felhasználónevet és jelszót!", "Enter the admin username and password!", "Gib Admin-Benutzername und Passwort ein!");
        T("AuthSetupFirst", "A szerver még nincs beállítva: előbb hozd létre az adminisztrátori fiókot.", "The server is not set up yet: create the administrator account first.", "Der Server ist noch nicht eingerichtet: Erstelle zuerst das Administratorkonto.");
        T("PasswordTooShort", "A jelszónak legalább {0} karakter hosszúnak kell lennie!", "The password must be at least {0} characters long!", "Das Passwort muss mindestens {0} Zeichen lang sein!");
        T("PasswordsDontMatch", "A megadott jelszavak nem egyeznek!", "The passwords do not match!", "Die eingegebenen Passwörter stimmen nicht überein!");
        T("ScanSignInFirst", "Előbb jelentkezz be a szerverre.", "Sign in to the server first.", "Melde dich zuerst am Server an.");
        T("ReindexStarted", "Szerveroldali újraindexelés elindítva...", "Server-side reindexing started…", "Serverseitige Neuindizierung gestartet …");
        T("ReindexProgress", "A szerver indexel... ({0} szám eddig)", "The server is indexing… ({0} tracks so far)", "Der Server indiziert … (bisher {0} Titel)");
        T("ReindexProgress_One", "A szerver indexel... ({0} szám eddig)", "The server is indexing… ({0} track so far)", "Der Server indiziert … (bisher {0} Titel)");
        T("ReindexFinished", "Indexelés kész, könyvtár frissítése...", "Indexing finished, refreshing library…", "Indizierung abgeschlossen, Bibliothek wird aktualisiert …");
        T("ServerReported", "A szerver jelezte: {0}", "The server reported: {0}", "Der Server meldet: {0}");
        T("LibraryRefreshFailed", "A könyvtár frissítése nem sikerült.", "Refreshing the library failed.", "Die Bibliothek konnte nicht aktualisiert werden.");
        T("ServerSynced", "Szerver szinkronizálva: {0} szám elérhető.", "Server synchronised: {0} tracks available.", "Server synchronisiert: {0} Titel verfügbar.");
        T("ServerSynced_One", "Szerver szinkronizálva: {0} szám elérhető.", "Server synchronised: {0} track available.", "Server synchronisiert: {0} Titel verfügbar.");
        T("ReindexNeedsAdmin", "Az újraindexeléshez adminisztrátori jogosultság kell.", "Reindexing requires administrator rights.", "Für die Neuindizierung sind Administratorrechte erforderlich.");
        T("ReindexError", "Hiba az újraindexelés közben: {0}", "Error while reindexing: {0}", "Fehler bei der Neuindizierung: {0}");
        T("FolderMissing", "A megadott mappa nem létezik!", "The specified folder does not exist!", "Der angegebene Ordner existiert nicht!");
        T("ScanAlreadyRunning", "Már folyamatban van egy szkennelés.", "A scan is already in progress.", "Es läuft bereits ein Scan.");
        T("ScanStarted", "Zenefájlok keresése és metaadatok beolvasása...", "Searching for music files and reading metadata…", "Musikdateien werden gesucht und Metadaten eingelesen …");
        T("ScanDoneMixed", "Könyvtár beolvasva: {0} helyi szám, {1} szerver szám ({2} összesen).", "Library scanned: {0} local tracks, {1} server tracks ({2} in total).", "Bibliothek eingelesen: {0} lokale Titel, {1} Servertitel ({2} insgesamt).");
        T("ScanDoneLocal", "Helyi könyvtár beolvasva: {0} szám.", "Local library scanned: {0} tracks.", "Lokale Bibliothek eingelesen: {0} Titel.");
        T("ScanDoneLocal_One", "Helyi könyvtár beolvasva: {0} szám.", "Local library scanned: {0} track.", "Lokale Bibliothek eingelesen: {0} Titel.");
        T("ScanError", "Hiba a szkennelés közben: {0}", "Error while scanning: {0}", "Fehler beim Einlesen: {0}");
        T("ServerSettingsLoadError", "Szerver beállítások betöltési hiba: {0}", "Could not load the server settings: {0}", "Die Servereinstellungen konnten nicht geladen werden: {0}");
        T("EnterServerFolder", "Add meg a szerver zenemappájának elérését!", "Enter the path of the server's music folder!", "Gib den Pfad des Musikordners auf dem Server ein!");
        T("ServerFolderUpdated", "Szerver zenemappa frissítve, indexelés elindítva!", "Server music folder updated, indexing started!", "Musikordner auf dem Server aktualisiert, Indizierung gestartet!");
        T("FolderSaveError", "Hiba a mappa mentésekor: {0}", "Error while saving the folder: {0}", "Fehler beim Speichern des Ordners: {0}");
        T("UsersLoadError", "Felhasználók betöltési hiba: {0}", "Could not load the users: {0}", "Die Benutzer konnten nicht geladen werden: {0}");
        T("UserAddError", "Hiba a felhasználó hozzáadásakor: {0}", "Error while adding the user: {0}", "Fehler beim Hinzufügen des Benutzers: {0}");
        T("UserDeleteError", "Hiba a törlésnél: {0}", "Error while deleting: {0}", "Fehler beim Löschen: {0}");
    }

    private static void BuildServer(Action<string, string, string, string> T)
    {
        // ── Server session (Core) ────────────────────────────────────────────────────────────────────
        T("SessionInvalidUrl", "Érvénytelen szervercím: „{0}”. Példa: http://192.168.1.10:5200", "Invalid server address: “{0}”. Example: http://192.168.1.10:5200", "Ungültige Serveradresse: „{0}“. Beispiel: http://192.168.1.10:5200");
        T("SessionConnecting", "Kapcsolódás: {0}...", "Connecting to {0}…", "Verbinde mit {0} …");
        T("SessionSetupRequired", "A szerver még nincs beállítva. Hozz létre egy adminisztrátori fiókot!", "The server is not set up yet. Create an administrator account!", "Der Server ist noch nicht eingerichtet. Erstelle ein Administratorkonto!");
        T("SessionLoginRequired", "A szerver ({0}) elérhető. Jelentkezz be a folytatáshoz.", "The server ({0}) is reachable. Sign in to continue.", "Der Server ({0}) ist erreichbar. Melde dich an, um fortzufahren.");
        T("SessionExpired", "A munkamenet lejárt. Jelentkezz be újra.", "Your session has expired. Please sign in again.", "Deine Sitzung ist abgelaufen. Bitte melde dich erneut an.");
        T("SessionUnreachable", "A szerver ({0}) nem érhető el. {1}", "The server ({0}) is unreachable. {1}", "Der Server ({0}) ist nicht erreichbar. {1}");
        T("SessionCancelled", "A kapcsolódás megszakadt.", "The connection attempt was cancelled.", "Der Verbindungsaufbau wurde abgebrochen.");
        T("SessionUnexpected", "Váratlan hiba a szerverrel való kapcsolat közben: {0}", "Unexpected error while talking to the server: {0}", "Unerwarteter Fehler bei der Kommunikation mit dem Server: {0}");
        T("SessionBadCredentials", "Hibás felhasználónév vagy jelszó.", "Incorrect username or password.", "Falscher Benutzername oder falsches Passwort.");
        T("SessionRejected", "A szerver elutasította a kérést.", "The server rejected the request.", "Der Server hat die Anfrage abgelehnt.");
        T("SessionRejectedWith", "A szerver elutasította a kérést: {0}", "The server rejected the request: {0}", "Der Server hat die Anfrage abgelehnt: {0}");
        T("SessionAlreadySetUp", "A szervert időközben már beállították. Jelentkezz be a meglévő fiókkal.", "The server has been set up in the meantime. Sign in with the existing account.", "Der Server wurde inzwischen eingerichtet. Melde dich mit dem vorhandenen Konto an.");
        T("SessionSignedOut", "Kijelentkezve a szerverről.", "Signed out of the server.", "Vom Server abgemeldet.");
        T("SessionConnectedHybrid", "Csatlakozva: {1} ({2}) • {0} szám (Helyi + Szerver)", "Connected: {1} ({2}) • {0} tracks (local + server)", "Verbunden: {1} ({2}) • {0} Titel (lokal + Server)");
        T("SessionConnectedHybrid_One", "Csatlakozva: {1} ({2}) • {0} szám (Helyi + Szerver)", "Connected: {1} ({2}) • {0} track (local + server)", "Verbunden: {1} ({2}) • {0} Titel (lokal + Server)");
        T("SessionConnected", "Csatlakozva: {1} ({2}) • {0} szám", "Connected: {1} ({2}) • {0} tracks", "Verbunden: {1} ({2}) • {0} Titel");
        T("SessionConnected_One", "Csatlakozva: {1} ({2}) • {0} szám", "Connected: {1} ({2}) • {0} track", "Verbunden: {1} ({2}) • {0} Titel");
        T("SessionLocalInUse", "Helyi könyvtár használatban.", "Using the local library.", "Lokale Bibliothek wird verwendet.");
        T("SessionDownloading", "Könyvtár letöltése a szerverről...", "Downloading the library from the server…", "Bibliothek wird vom Server geladen …");

        // ── Server client (Core) ─────────────────────────────────────────────────────────────────────
        T("ClientNotWiretune", "A szerver válasza nem értelmezhető (nem Wiretune szerver?).", "The server's response could not be understood (is this a Wiretune server?).", "Die Antwort des Servers wurde nicht verstanden (ist das ein Wiretune-Server?).");
        T("ClientTimeout", "A szerver nem válaszolt {0} másodpercen belül.", "The server did not respond within {0} seconds.", "Der Server hat nicht innerhalb von {0} Sekunden geantwortet.");
        T("ClientBodyTimeout", "A szerver nem küldte el a választ {0} másodpercen belül.", "The server did not finish sending its response within {0} seconds.", "Der Server hat die Antwort nicht innerhalb von {0} Sekunden vollständig gesendet.");
        T("ClientEmptyResponse", "A szerver üres választ küldött.", "The server sent an empty response.", "Der Server hat eine leere Antwort gesendet.");
        T("ClientConnectionCutOff", "A kapcsolat megszakadt a válasz olvasása közben. {0}", "The connection was lost while reading the response. {0}", "Die Verbindung wurde beim Lesen der Antwort unterbrochen. {0}");
        T("ClientUnknownError", "Ismeretlen hiba", "Unknown error", "Unbekannter Fehler");
    }

    private static void BuildAudio(Action<string, string, string, string> T)
    {
        // ── Audio engine and drivers (Core) ──────────────────────────────────────────────────────────
        T("AudioNoOutput", "Nincs elérhető audio kimenet", "No audio output available", "Keine Audioausgabe verfügbar");
        T("AudioModesFull", "exclusive / bit-perfect támogatott", "exclusive / bit-perfect supported", "Exclusive / Bit-Perfect unterstützt");
        T("AudioModesShared", "csak megosztott mód", "shared mode only", "nur gemeinsamer Modus");
        T("AudioDefaultOutput", "Alapértelmezett audio kimenet", "Default audio output", "Standard-Audioausgabe");
        T("AudioSystemDefaultOutput", "Rendszer alapértelmezett kimenet", "System default output", "Systemstandardausgabe");
        T("AudioWindowsDefaultOutput", "Windows alapértelmezett kimenet", "Windows default output", "Windows-Standardausgabe");
        T("ExclusiveLabel", "Kizárólagos", "Exclusive", "Exklusiv");
        T("ExclusiveDescription", "Közvetlen ALSA / PipeWire hozzáférés", "Direct ALSA / PipeWire access", "Direkter ALSA-/PipeWire-Zugriff");
        T("ExclusiveUnavailable", "Ezen a rendszeren nem érhető el: a lejátszás megosztott keverőn történik.", "Not available on this system: playback goes through the shared mixer.", "Auf diesem System nicht verfügbar: Die Wiedergabe läuft über den gemeinsamen Mixer.");
        T("BitPerfectDescription", "1:1 bitpontos átvitel (0 dB)", "1:1 bit-accurate transfer (0 dB)", "1:1 bitgenaue Übertragung (0 dB)");
        T("OutputDevice", "Kimeneti eszköz", "Output device", "Ausgabegerät");
        T("SignalPath", "Jelút", "Signal path", "Signalweg");
        T("SignalNone", "Nincs aktív lejátszás", "No active playback", "Keine aktive Wiedergabe");
        T("SignalSource", "Forrás: {0}", "Source: {0}", "Quelle: {0}");
        T("SignalTransport", "Átvitel: {0}", "Transport: {0}", "Übertragung: {0}");
        T("SignalProcessing", "Feldolgozás: {0}", "Processing: {0}", "Verarbeitung: {0}");
        T("SignalAccess", "Hozzáférés: {0}", "Access: {0}", "Zugriff: {0}");
        T("SignalTarget", "Cél eszköz: {0}", "Target device: {0}", "Zielgerät: {0}");
        T("SignalProcessingBitPerfect", "Bit-perfect kérve (PCM, erősítés nélkül, kizárólagos eszközhozzáférés)", "Bit-perfect requested (PCM, no gain, exclusive device access)", "Bit-Perfect angefordert (PCM, ohne Verstärkung, exklusiver Gerätezugriff)");
        T("SignalProcessingMixer", "Rendszerkeverő (megosztott kimenet)", "System mixer (shared output)", "Systemmixer (gemeinsame Ausgabe)");
        T("SignalAccessExclusive", "Kizárólagos mód (közvetlen hardver)", "Exclusive mode (direct hardware)", "Exklusivmodus (direkte Hardware)");
        T("SignalAccessShared", "Megosztott mód", "Shared mode", "Gemeinsamer Modus");
        T("SignalTransportServer", "Szerver stream (veszteségmentes, átkódolás nélkül)", "Server stream (lossless, no transcoding)", "Server-Stream (verlustfrei, ohne Transcodierung)");
        T("SignalTransportLocal", "Helyi fájl", "Local file", "Lokale Datei");
        T("EngineDeviceInitFailed", "A(z) „{0}” kimenet inicializálása sikertelen: {1}", "Initializing the output “{0}” failed: {1}", "Die Ausgabe „{0}“ konnte nicht initialisiert werden: {1}");
        T("EngineNoSource", "A(z) „{0}” szám nem játszható le: nincs elérhető forrás.", "The track “{0}” cannot be played: no source is available.", "Der Titel „{0}“ kann nicht abgespielt werden: keine Quelle verfügbar.");
        T("EngineNoExclusive", "Egyik kimeneti eszköz sem támogatja a kizárólagos módot ezen a rendszeren.", "None of the output devices supports exclusive mode on this system.", "Kein Ausgabegerät unterstützt auf diesem System den Exklusivmodus.");
        T("EngineNoBitPerfect", "Egyik kimeneti eszköz sem támogatja a bit-perfect lejátszást ezen a rendszeren.", "None of the output devices supports bit-perfect playback on this system.", "Kein Ausgabegerät unterstützt auf diesem System die Bit-Perfect-Wiedergabe.");
        T("DriverAlsaMissingTools", "A közvetlen ALSA lejátszó nem indítható (ffmpeg vagy aplay hiányzik): {0}", "Direct ALSA playback cannot start (ffmpeg or aplay is missing): {0}", "Die direkte ALSA-Wiedergabe kann nicht gestartet werden (ffmpeg oder aplay fehlt): {0}");
        T("DriverAlsaStartFailed", "A közvetlen ALSA lejátszás nem indítható: {0}", "Direct ALSA playback cannot start: {0}", "Die direkte ALSA-Wiedergabe kann nicht gestartet werden: {0}");
        T("DriverFfplayMissing", "Az ffplay nem található. Telepítsd az FFmpeg-et, és gondoskodj róla, hogy a PATH-ban elérhető legyen.", "ffplay was not found. Install FFmpeg and make sure it is on your PATH.", "ffplay wurde nicht gefunden. Installiere FFmpeg und stelle sicher, dass es im PATH liegt.");
        T("DriverPlayerStartFailed", "A lejátszó nem indítható: {0}", "The player cannot be started: {0}", "Der Player kann nicht gestartet werden: {0}");
        T("DriverStoppedUnexpectedly", "A lejátszás váratlanul leállt (kilépési kód: {0}).", "Playback stopped unexpectedly (exit code: {0}).", "Die Wiedergabe wurde unerwartet beendet (Exit-Code: {0}).");
        T("DriverPlaybackFailed", "A lejátszás sikertelen: {0}", "Playback failed: {0}", "Wiedergabe fehlgeschlagen: {0}");
        T("DriverCannotStart", "A lejátszás nem indítható: {0}", "Playback cannot start: {0}", "Die Wiedergabe kann nicht gestartet werden: {0}");
        T("DriverWasapiError", "WASAPI hiba: {0}", "WASAPI error: {0}", "WASAPI-Fehler: {0}");
        T("DriverAndroidError", "A lejátszás megszakadt (MediaPlayer hiba: {0}, {1}).", "Playback failed (MediaPlayer error: {0}, extra: {1}).", "Die Wiedergabe ist fehlgeschlagen (MediaPlayer-Fehler: {0}, zusätzlich: {1}).");
        T("NotificationChannelName", "Lejátszás", "Playback", "Wiedergabe");
        T("NotificationChannelDescription", "A Wiretune lejátszási értesítése", "Wiretune playback notification", "Wiretune-Wiedergabebenachrichtigung");
        T("NotificationPlaying", "Lejátszás folyamatban…", "Playing…", "Wiedergabe läuft …");
    }
}
