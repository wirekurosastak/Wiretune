// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:path/path.dart' as p;

/// Where Wiretune keeps its files.
abstract final class AppPaths {
  static const String dataDirectoryEnvironmentVariable = 'WIRETUNE_DATA_DIR';

  /// The data directory of a head that has no per-user application data folder in the usual sense (Android, iOS, Tizen):
  /// set by the app at start-up, before anything is opened, to the app's private support folder.
  static String? platformDataRoot;

  /// The music folder of a head whose system says where it is (Android): set by the app at start-up.
  static String? platformMusicFolder;

  /// Resolves (and creates) the Wiretune data directory. Precedence: [overridePath], `WIRETUNE_DATA_DIR`,
  /// [platformDataRoot], then the per-user application data folder. The server passes a [subdirectory] so it never
  /// shares a database with a player on the same machine.
  static String getDataDirectory({String? overridePath, String? subdirectory}) {
    String root;
    if (overridePath != null && overridePath.trim().isNotEmpty) {
      root = overridePath;
      subdirectory = null;
    } else if ((Platform.environment[dataDirectoryEnvironmentVariable] ?? '').isNotEmpty) {
      root = Platform.environment[dataDirectoryEnvironmentVariable]!;
    } else if (platformDataRoot != null) {
      root = platformDataRoot!;
    } else {
      root = p.join(applicationDataFolder(), 'Wiretune');
    }

    final dir = fullPath(subdirectory == null || subdirectory.isEmpty ? root : p.join(root, subdirectory));
    final directory = Directory(dir);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
      // The directory holds the player's access token or the server's token-signing key, so a directory created here is
      // private to the current user. An existing one is left as the admin set it up.
      if (Platform.isLinux || Platform.isMacOS) {
        try {
          Process.runSync('chmod', ['700', dir]);
        } catch (_) {}
      }
    }
    return dir;
  }

  /// The per-user application data folder: `%APPDATA%` on Windows, `~/Library/Application Support` on macOS,
  /// `$XDG_CONFIG_HOME` or `~/.config` elsewhere.
  static String applicationDataFolder() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      return env['APPDATA'] ?? p.join(env['USERPROFILE'] ?? '.', 'AppData', 'Roaming');
    }
    final home = env['HOME'] ?? Directory.systemTemp.path;
    if (Platform.isMacOS) return p.join(home, 'Library', 'Application Support');
    final xdg = env['XDG_CONFIG_HOME'];
    return xdg != null && xdg.isNotEmpty ? xdg : p.join(home, '.config');
  }

  /// The user's music folder: [platformMusicFolder] when the app set one, `%USERPROFILE%\Music` on Windows, `~/Music`
  /// on macOS, `/storage/emulated/0/Music` on Android, and on Linux the XDG music directory (`XDG_MUSIC_DIR`, which `xdg-user-dirs` keeps in
  /// `~/.config/user-dirs.dirs` and names in the system's language, e.g. `~/Zenék`), else `~/Music`.
  static String defaultMusicFolder() {
    final fromPlatform = platformMusicFolder;
    if (fromPlatform != null) return fromPlatform;
    if (Platform.isAndroid) return '/storage/emulated/0/Music';
    final env = Platform.environment;
    final home = (Platform.isWindows ? env['USERPROFILE'] : env['HOME']) ?? '.';
    if (Platform.isLinux) {
      final fromEnv = env['XDG_MUSIC_DIR'];
      if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
      try {
        final config = File(p.join(applicationDataFolder(), 'user-dirs.dirs'));
        final configured = config.existsSync() ? xdgUserDir(config.readAsStringSync(), 'MUSIC', home) : null;
        if (configured != null) return configured;
      } on FileSystemException {
        // Unreadable: the default below.
      }
    }
    return p.join(home, 'Music');
  }

  /// The directory `XDG_<name>_DIR` in the contents of a `user-dirs.dirs` file, or null when it is not set there. The
  /// value is `"$HOME/…"` or an absolute path; one that is just `$HOME` means the directory is switched off.
  static String? xdgUserDir(String contents, String name, String home) {
    final match = RegExp('^\\s*XDG_${name}_DIR\\s*=\\s*"([^"]*)"', multiLine: true).firstMatch(contents);
    final value = match?.group(1);
    if (value == null) return null;
    if (value == r'$HOME' || value == r'$HOME/') return null;
    if (value.startsWith(r'$HOME/')) return p.join(home, value.substring(6));
    return p.isAbsolute(value) ? value : null;
  }

  /// [path] made absolute and normalised (`..` and `.` resolved, symbolic links left alone).
  static String fullPath(String path) => p.normalize(p.absolute(path));

  /// [path] the way the file system compares it: lower-cased on Windows and macOS, which ignore case.
  static String comparable(String path) => Platform.isWindows || Platform.isMacOS ? path.toLowerCase() : path;

  /// True when [path] resolves to [root] or a location inside it. Compares whole path segments, so `/music2` is not
  /// inside `/music`. Also checks that if [path] exists on disk, its resolved symbolic links stay inside [root].
  static bool isPathUnderRoot(String? path, String? root) {
    if (path == null || root == null || path.trim().isEmpty || root.trim().isEmpty) return false;

    String fullFile, fullRoot;
    try {
      fullFile = comparable(fullPath(path));
      fullRoot = comparable(fullPath(root));
    } catch (_) {
      return false;
    }
    if (fullFile != fullRoot && !p.isWithin(fullRoot, fullFile)) {
      return false;
    }

    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        final canonicalFile = comparable(
          fullPath(
            type == FileSystemEntityType.directory
                ? Directory(path).resolveSymbolicLinksSync()
                : File(path).resolveSymbolicLinksSync(),
          ),
        );
        final canonicalRoot = comparable(
          fullPath(Directory(root).existsSync() ? Directory(root).resolveSymbolicLinksSync() : root),
        );
        if (canonicalFile != canonicalRoot && !p.isWithin(canonicalRoot, canonicalFile)) {
          return false;
        }
      }
    } catch (_) {
      return false;
    }

    return true;
  }
}
