// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'platform.dart';

/// How this copy of Wiretune was installed, which decides the release file that updates it and how that goes in.
enum InstallKind {
  /// The Linux folder, run from where it was unpacked or put in place by its install.sh: replaced in place.
  linuxFolder,

  /// The .deb in /usr/lib/wiretune: apt installs the new one, after the system asks for the password.
  deb,

  /// The .rpm in /usr/lib/wiretune: dnf installs the new one, after the system asks for the password.
  rpm,

  /// The Windows installer's copy: the new installer runs without questions once the player has closed.
  windowsSetup,

  /// The macOS app: the new disk image opens, and the user drags the app over the old one.
  macosApp,

  /// An APK: Android's installer takes the new one, after asking.
  androidApk,
}

/// Puts a release in place of this copy of Wiretune ([kind] says how), with the release file meant for it.
class UpdateInstaller {
  UpdateInstaller(this.kind, {String? executable, String? arch})
    : _executable = executable ?? Platform.resolvedExecutable,
      _arch = arch ?? _archOf(Abi.current());

  final InstallKind kind;
  final String _executable;

  /// The processor as the release's file names say it: x64 or arm64 on a computer, the ABI on Android.
  final String _arch;

  static const String _linuxPackageFolder = '/usr/lib/wiretune';

  /// How this copy was installed, or null when no release file updates it: iOS and Tizen (no release has them), the
  /// portable Windows folder, and a Linux or macOS copy in a shape this doesn't know.
  static Future<UpdateInstaller?> detect(AppPlatform platform) async {
    final executable = Platform.resolvedExecutable;
    final folder = File(executable).parent.path;
    final InstallKind? kind;
    if (platform.isLinuxDesktop) {
      kind = p.equals(folder, _linuxPackageFolder)
          ? (File('/var/lib/dpkg/info/wiretune.list').existsSync() ? InstallKind.deb : InstallKind.rpm)
          : (Directory(p.join(folder, 'lib')).existsSync() && Directory(p.join(folder, 'data')).existsSync()
                ? InstallKind.linuxFolder
                : null);
    } else if (platform.isWindows) {
      kind = File(p.join(folder, 'unins000.exe')).existsSync() ? InstallKind.windowsSetup : null;
    } else if (platform.isMacOS) {
      kind = executable.contains('.app/Contents/MacOS/') ? InstallKind.macosApp : null;
    } else if (platform.isAndroid) {
      kind = InstallKind.androidApk;
    } else {
      kind = null;
    }
    return kind == null ? null : UpdateInstaller(kind, executable: executable);
  }

  /// The name of the file in [release] that updates this copy, or null when it has none (a processor it isn't built
  /// for). The names are the ones .github/workflows/release.yml gives them.
  String? fileFor(Release release) {
    final version = RegExp.escape(release.version);
    final pattern = switch (kind) {
      InstallKind.linuxFolder => 'wiretune-$version-linux-$_arch\\.tar\\.gz',
      InstallKind.deb => 'wiretune_$version-[0-9]+_${_arch == 'arm64' ? 'arm64' : 'amd64'}\\.deb',
      InstallKind.rpm => 'wiretune-$version-[0-9]+\\.${_arch == 'arm64' ? 'aarch64' : 'x86_64'}\\.rpm',
      InstallKind.windowsSetup => 'Wiretune-$version-windows-$_arch-setup\\.exe',
      InstallKind.macosApp => 'Wiretune-$version-macos\\.dmg',
      InstallKind.androidApk => 'wiretune-$version-$_arch-release\\.apk',
    };
    return release.fileMatching(RegExp(pattern));
  }

  /// An empty folder for the download: the app's cache on Android, the system's temporary folder elsewhere.
  Future<String> downloadFolder() async {
    final base = kind == InstallKind.androidApk ? (await getTemporaryDirectory()).path : Directory.systemTemp.path;
    final folder = Directory(p.join(base, 'wiretune-update'));
    if (folder.existsSync()) folder.deleteSync(recursive: true);
    return (folder..createSync(recursive: true)).path;
  }

  /// Installs [file], the release file [fileFor] named. [quit] saves the session and ends the player, then starts
  /// `relaunch` when it is given: what replaces the player in place starts it again; an installer that needs it gone
  /// first quits it; the macOS disk image and Android's installer leave it running.
  Future<void> install(File file, Future<void> Function({String? relaunch}) quit) async {
    switch (kind) {
      case InstallKind.linuxFolder:
        await _replaceLinuxFolder(file);
        await quit(relaunch: _executable);
      case InstallKind.deb:
        await _run('pkexec', ['/usr/bin/apt-get', 'install', '-y', file.path]);
        await quit(relaunch: _executable);
      case InstallKind.rpm:
        await _run('pkexec', ['/usr/bin/dnf', 'install', '-y', file.path]);
        await quit(relaunch: _executable);
      case InstallKind.windowsSetup:
        // The installer closes nothing and asks nothing; it starts the new player when it is done (wiretune.iss).
        await Process.start(file.path, const [
          '/SILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
        ], mode: ProcessStartMode.detached);
        await quit();
      case InstallKind.macosApp:
        await _run('open', [file.path]);
      case InstallKind.androidApk:
        await AppPlatform.current.installAndroidUpdate(file.path);
    }
  }

  /// Unpacks the release's folder and puts it where this one is. A copy that install.sh put in `<prefix>/lib/wiretune`
  /// is installed again by the new install.sh, which also brings the new menu entry and icon; any other folder has
  /// its program, `lib/` and `data/` replaced.
  Future<void> _replaceLinuxFolder(File archive) async {
    final work = Directory(p.join(archive.parent.path, 'unpacked'))..createSync();
    await _run('tar', ['-xzf', archive.path, '-C', work.path]);
    final unpacked = work.listSync().whereType<Directory>().where((d) => File(p.join(d.path, 'wiretune')).existsSync());
    if (unpacked.isEmpty) throw UpdateException('${p.basename(archive.path)} holds no Wiretune folder.');
    final bundle = unpacked.first.path;

    final app = File(_executable).parent.path;
    final prefix = p.dirname(p.dirname(app));
    final menuEntry = File(p.join(prefix, 'share', 'applications', 'com.wiretune.player.desktop'));
    if (p.basename(app) == 'wiretune' && p.basename(p.dirname(app)) == 'lib' && menuEntry.existsSync()) {
      await _run('sh', [p.join(bundle, 'install.sh')], environment: {'PREFIX': prefix});
    } else {
      for (final name in ['wiretune', 'lib', 'data']) {
        final old = p.join(app, name);
        if (FileSystemEntity.isDirectorySync(old)) {
          Directory(old).deleteSync(recursive: true);
        } else if (File(old).existsSync()) {
          File(old).deleteSync();
        }
      }
      await _run('cp', ['-a', p.join(bundle, 'wiretune'), p.join(bundle, 'lib'), p.join(bundle, 'data'), app]);
    }
    work.deleteSync(recursive: true);
  }

  /// Runs a step of the update; one that fails, or that the user stops at the password prompt, throws.
  static Future<void> _run(String executable, List<String> arguments, {Map<String, String>? environment}) async {
    final ProcessResult result;
    try {
      result = await Process.run(executable, arguments, environment: environment).timeout(const Duration(minutes: 10));
    } on ProcessException catch (e) {
      throw UpdateException('Cannot start $executable: ${e.message}');
    }
    if (result.exitCode == 0) return;
    // pkexec: 126 when the password prompt was dismissed, 127 when the user may not do it.
    final why = executable == 'pkexec' && (result.exitCode == 126 || result.exitCode == 127)
        ? 'the password prompt was dismissed or refused'
        : '${result.stderr}'.trim();
    throw UpdateException('$executable ${arguments.first} failed (exit code ${result.exitCode}): $why');
  }

  static String _archOf(Abi abi) => switch (abi) {
    Abi.androidArm64 => 'arm64-v8a',
    Abi.androidArm => 'armeabi-v7a',
    Abi.androidX64 => 'x86_64',
    Abi.linuxArm64 || Abi.windowsArm64 || Abi.macosArm64 => 'arm64',
    _ => 'x64',
  };
}
