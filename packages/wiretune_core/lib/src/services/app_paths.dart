// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:path/path.dart' as p;

/// Where Wiretune keeps its files.
abstract final class AppPaths {
  static const String dataDirectoryEnvironmentVariable = 'WIRETUNE_DATA_DIR';

  /// The data directory of a head that has no per-user application data folder in the usual sense (Android, iOS, Tizen):
  /// set by the app at start-up, before anything is opened, to the app's private support folder.
  static String? platformDataRoot;

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

  /// The user's music folder (`~/Music`, `%USERPROFILE%\Music`).
  static String musicFolder() {
    final env = Platform.environment;
    final home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
    final xdg = env['XDG_MUSIC_DIR'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    return p.join(home ?? '.', 'Music');
  }

  /// [path] made absolute and normalised (`..` and `.` resolved, symbolic links left alone).
  static String fullPath(String path) => p.normalize(p.absolute(path));

  /// [path] the way the file system compares it: lower-cased on Windows and macOS, which ignore case.
  static String comparable(String path) => Platform.isWindows || Platform.isMacOS ? path.toLowerCase() : path;

  /// True when [path] resolves to [root] or a location inside it. Compares whole path segments, so `/music2` is not
  /// inside `/music`.
  static bool isPathUnderRoot(String? path, String? root) {
    if (path == null || root == null || path.trim().isEmpty || root.trim().isEmpty) return false;

    String fullFile, fullRoot;
    try {
      fullFile = comparable(fullPath(path));
      fullRoot = comparable(fullPath(root));
    } catch (_) {
      return false;
    }
    return fullFile == fullRoot || p.isWithin(fullRoot, fullFile);
  }
}
