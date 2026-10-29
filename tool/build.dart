// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

// Builds Wiretune for release and puts what ships into dist/, one folder per target:
//
//   dart tool/build.dart server linux android
//
// It finds the repository by its own location, so any working directory will do. docs/building.md says what each target
// needs installed first.
import 'dart:ffi' show Abi;
import 'dart:io';

const String _usage = '''
Builds Wiretune for release and puts what ships into dist/<target>/.

Usage: dart tool/build.dart <target>...

  server      the server for this system: bin/ and the lib/ it loads  → dist/server/
  linux       the Linux player, on Linux, with its install.sh          → dist/linux/
  linux-deb   linux, as a package for apt (Debian, Ubuntu)             → dist/linux-deb/*.deb
  linux-rpm   linux, as a package for dnf (Fedora)                     → dist/linux-rpm/*.rpm
  windows     the Windows player, on Windows                           → dist/windows/
  windows-installer  windows, and its installer (Inno Setup 6)         → dist/windows-installer/*.exe
  macos       the macOS player and its disk image, on macOS            → dist/macos/Wiretune.app, Wiretune.dmg
  android     one APK per processor type                               → dist/android/*.apk
  appbundle   the Android App Bundle for Google Play                   → dist/android/*.aab
  ios         the .ipa, on a Mac with a signing team                   → dist/ios/*.ipa
  tizen       the .tpk for Samsung TVs, with flutter-tizen on the PATH → dist/tizen/*.tpk

The macOS player is signed with the identity in WIRETUNE_MACOS_SIGN_IDENTITY and notarised with the notarytool
keychain profile in WIRETUNE_NOTARY_PROFILE, when they are set. docs/building.md says what each target needs installed
first.''';

/// The repository: this script lives in its tool/ folder.
final String _root = File.fromUri(Platform.script).parent.parent.path;

/// The processor the desktop players are built for: Flutter builds for the one it runs on.
final String _arch = switch (Abi.current()) {
  Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
  _ => 'x64',
};

final Map<String, Future<void> Function()> _targets = {
  'server': () async {
    await _run('server', 'dart', ['pub', 'get']);
    await _run('server', 'dart', ['build', 'cli', '--output', 'build']);
    _publishFolder('server/build/bundle', 'server');
  },
  'linux': _buildLinux,
  'linux-deb': () async {
    await _buildLinux();
    await _packageDeb();
  },
  'linux-rpm': () async {
    await _buildLinux();
    await _packageRpm();
  },
  'windows': _buildWindows,
  'windows-installer': () async {
    await _buildWindows();
    await _buildWindowsInstaller();
  },
  'macos': () async {
    await _run('app', 'flutter', ['build', 'macos', '--release']);
    _publishFolder('app/build/macos/Build/Products/Release/Wiretune.app', 'macos/Wiretune.app');
    await _packageMacos();
  },
  'android': () => _buildPackages(
    'flutter',
    ['build', 'apk', '--release', '--split-per-abi'],
    'app/build/app/outputs/flutter-apk',
    '.apk',
    'android',
  ),
  'appbundle': () => _buildPackages(
    'flutter',
    ['build', 'appbundle', '--release'],
    'app/build/app/outputs/bundle/release',
    '.aab',
    'android',
  ),
  'ios': () => _buildPackages('flutter', ['build', 'ipa', '--release'], 'app/build/ios/ipa', '.ipa', 'ios'),
  'tizen': () => _withPubspecAddition(
    _tizenSqlite,
    () => _buildPackages('flutter-tizen', ['build', 'tpk', '--release'], 'app/build/tizen/tpk', '.tpk', 'tizen'),
  ),
};

/// A Samsung TV can't load the SQLite the sqlite3 package downloads for Linux on ARM (built for hard-float and a newer
/// glibc), so the Tizen build uses the TV's own: 3.31 or later, and Wiretune needs nothing newer. The package can't tell
/// a TV from desktop Linux, which keeps the one it bundles, so the setting is in app/pubspec.yaml only during the build.
const String _tizenSqlite = '''

hooks:
  user_defines:
    sqlite3:
      source: system
      name: /usr/lib/libsqlite3.so.0
''';

/// Runs [build] with [addition] at the end of app/pubspec.yaml, and puts the file back afterwards, also on Ctrl+C.
Future<void> _withPubspecAddition(String addition, Future<void> Function() build) async {
  final pubspec = File(_path('app/pubspec.yaml'));
  final original = pubspec.readAsStringSync();
  if (original.contains('\nhooks:')) {
    throw const _BuildFailure('app/pubspec.yaml already has a hooks: section; take it out first.');
  }
  void restore() => pubspec.writeAsStringSync(original);
  final interrupted = ProcessSignal.sigint.watch().listen((_) {
    restore();
    exit(130);
  });
  pubspec.writeAsStringSync('$original$addition');
  try {
    await build();
  } finally {
    restore();
    await interrupted.cancel();
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln(_usage);
    return;
  }
  final unknown = args.where((a) => !_targets.containsKey(a)).toList();
  if (args.isEmpty || unknown.isNotEmpty) {
    if (unknown.isNotEmpty) stderr.writeln('Unknown target: ${unknown.join(', ')}\n');
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  try {
    for (final target in args) {
      await _targets[target]!();
    }
  } on _BuildFailure catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  }
}

class _BuildFailure implements Exception {
  const _BuildFailure(this.message);

  final String message;
}

Future<void> _buildWindows() async {
  await _run('app', 'flutter', ['build', 'windows', '--release']);
  _publishFolder('app/build/windows/$_arch/runner/Release', 'windows');
}

/// What installs the Linux player from its folder (app/linux/packaging): the script, the menu entry and the icon.
const List<String> _linuxInstallFiles = ['install.sh', 'com.wiretune.player.desktop', 'com.wiretune.player.png'];

/// The Linux packages' description, as `apt show` and `dnf info` print it.
const String _linuxSummary = 'Lossless music player for self-hosted libraries and local files';
const List<String> _linuxDescription = [
  'Wiretune plays music from a Wiretune server on your network, from a folder on',
  'this computer, or both. It plays gapless, shows synced lyrics, keeps favorites',
  'and playlists with your account on the server, and can bypass the system mixer',
  'to play bit-perfect, straight to your DAC.',
];
const String _homepage = 'https://github.com/wirekurosastak/Wiretune';
const String _maintainer = 'wirekurosastak <75095332+wirekurosastak@users.noreply.github.com>';

Future<void> _buildLinux() async {
  await _run('app', 'flutter', ['build', 'linux', '--release']);
  _publishFolder('app/build/linux/$_arch/release/bundle', 'linux');
  for (final name in _linuxInstallFiles) {
    File(_path('app/linux/packaging/$name')).copySync(_path('dist/linux/$name'));
  }
}

/// What a Linux package installs, laid out under [root] as on the system: the player in /usr/lib/wiretune, the
/// wiretune command, the menu entry and its icon.
void _stageLinux(Directory root) {
  if (root.existsSync()) root.deleteSync(recursive: true);
  final app = Directory('${root.path}/usr/lib/wiretune');
  _copyTree(Directory(_path('dist/linux')), app);
  for (final name in _linuxInstallFiles) {
    File('${app.path}/$name').deleteSync();
  }
  final command = Link('${root.path}/usr/bin/wiretune');
  command.parent.createSync(recursive: true);
  command.createSync('../lib/wiretune/wiretune');
  final desktop = File('${root.path}/usr/share/applications/com.wiretune.player.desktop');
  desktop.parent.createSync(recursive: true);
  final entry = File(_path('app/linux/packaging/com.wiretune.player.desktop')).readAsStringSync();
  desktop.writeAsStringSync(entry.replaceAll('@EXEC@', 'wiretune'));
  final icon = File('${root.path}/usr/share/icons/hicolor/256x256/apps/com.wiretune.player.png');
  icon.parent.createSync(recursive: true);
  File(_path('app/linux/packaging/com.wiretune.player.png')).copySync(icon.path);
}

/// The .deb for apt. libmpv, EGL and OpenGL ES are named by hand: the player loads them while it runs rather than
/// linking them.
Future<void> _packageDeb() async {
  final (name, build) = _version();
  final arch = _arch == 'arm64' ? 'arm64' : 'amd64';
  final root = Directory(_path('app/build/linux/deb'));
  _stageLinux(root);
  final copyright = File('${root.path}/usr/share/doc/wiretune/copyright');
  copyright.parent.createSync(recursive: true);
  copyright.writeAsStringSync(
    '${File(_path('NOTICE.md')).readAsStringSync()}\n${File(_path('LICENSE')).readAsStringSync()}',
  );
  final installedKiB = (_sizeOf(root) + 1023) ~/ 1024;
  final glib = await _glibFloor();
  final control = File('${root.path}/DEBIAN/control');
  control.parent.createSync();
  control.writeAsStringSync('''
Package: wiretune
Version: $name-$build
Architecture: $arch
Maintainer: $_maintainer
Installed-Size: $installedKiB
Depends: libc6 (>= ${await _glibcFloor()}), libglib2.0-0t64 (>= $glib) | libglib2.0-0 (>= $glib), libgtk-3-0t64 | libgtk-3-0, libmpv2, libegl1, libgles2, libstdc++6
Recommends: ffmpeg
Section: sound
Priority: optional
Homepage: $_homepage
Description: $_linuxSummary
${_linuxDescription.map((line) => ' $line').join('\n')}
''');
  final output = _emptyDist('linux-deb');
  await _run('app', 'dpkg-deb', [
    '--root-owner-group',
    '--build',
    root.path,
    '${output.path}/wiretune_$name-${build}_$arch.deb',
  ]);
  stdout.writeln('→ dist/linux-deb');
}

/// The .rpm for dnf. rpm works out the system libraries the player links by itself; libmpv, EGL and OpenGL ES, which it
/// loads while it runs, and the GLib it was compiled against are named by hand. The bundle's own libraries are kept out
/// of what the package provides and requires.
Future<void> _packageRpm() async {
  final (name, build) = _version();
  final arch = _arch == 'arm64' ? 'aarch64' : 'x86_64';
  final top = Directory(_path('app/build/linux/rpm'));
  if (top.existsSync()) top.deleteSync(recursive: true);
  final root = Directory('${top.path}/root');
  _stageLinux(root);
  final licenses = Directory('${root.path}/usr/share/licenses/wiretune')..createSync(recursive: true);
  for (final file in ['LICENSE', 'NOTICE.md']) {
    File(_path(file)).copySync('${licenses.path}/$file');
  }
  final glib = await _glibFloor();
  final spec = File('${top.path}/wiretune.spec');
  spec.writeAsStringSync('''
Name: wiretune
Version: $name
Release: $build
Summary: $_linuxSummary
License: AGPL-3.0-only
URL: $_homepage
Requires: libmpv.so.2()(64bit), libEGL.so.1()(64bit), libGLESv2.so.2()(64bit), glib2 >= $glib
Recommends: /usr/bin/ffmpeg

# A ready-made Flutter bundle: nothing to compile, and stripping it would break the Dart code in lib/libapp.so.
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
# The bundle's libraries (unversioned .so files) are its own, neither offered to the system nor asked of it.
%global __provides_exclude_from ^/usr/lib/wiretune/
%global __requires_exclude ^[^.]+[.]so[(]

%description
${_linuxDescription.join('\n')}

%install
cp -a ${root.path}/. %{buildroot}/

%files
/usr/bin/wiretune
/usr/lib/wiretune
/usr/share/applications/com.wiretune.player.desktop
/usr/share/icons/hicolor/256x256/apps/com.wiretune.player.png
%license /usr/share/licenses/wiretune/LICENSE
%license /usr/share/licenses/wiretune/NOTICE.md
''');
  await _run('app', 'rpmbuild', ['-bb', '--target', arch, '--define', '_topdir ${top.path}', spec.path]);
  final output = _emptyDist('linux-rpm');
  for (final package in Directory('${top.path}/RPMS').listSync(recursive: true).whereType<File>()) {
    if (!package.path.endsWith('.rpm')) continue;
    final file = package.uri.pathSegments.last;
    package.copySync('${output.path}/$file');
    stdout.writeln('→ dist/linux-rpm/$file');
  }
}

/// The newest glibc that the player's binaries ask for, which is the oldest a package installs on.
Future<String> _glibcFloor() async {
  final bundle = Directory(_path('dist/linux'));
  final binaries = [
    File('${bundle.path}/wiretune'),
    ...Directory('${bundle.path}/lib').listSync().whereType<File>().where((f) => f.path.endsWith('.so')),
  ];
  var floor = [2, 17];
  for (final binary in binaries) {
    final ProcessResult result;
    try {
      result = await Process.run('objdump', ['-T', binary.path]);
    } on ProcessException catch (e) {
      throw _BuildFailure('Cannot start objdump (${e.message}). Is binutils installed?');
    }
    if (result.exitCode != 0) throw _BuildFailure('objdump -T ${binary.path} failed: ${result.stderr}');
    for (final match in RegExp(r'GLIBC_([0-9]+(?:\.[0-9]+)+)').allMatches(result.stdout as String)) {
      final version = match.group(1)!.split('.').map(int.parse).toList();
      if (_compareVersions(version, floor) > 0) floor = version;
    }
  }
  return floor.join('.');
}

/// The GLib the player is compiled against (major.minor): the runner's GObject macros call what that GLib's headers
/// name, and GLib's symbols carry no version a package could read off the binary.
Future<String> _glibFloor() async {
  final ProcessResult result;
  try {
    result = await Process.run('pkg-config', ['--modversion', 'glib-2.0']);
  } on ProcessException catch (e) {
    throw _BuildFailure('Cannot start pkg-config (${e.message}). Is it installed?');
  }
  final version = RegExp(r'^([0-9]+\.[0-9]+)').firstMatch((result.stdout as String).trim())?.group(1);
  if (result.exitCode != 0 || version == null) throw _BuildFailure('pkg-config finds no GLib: ${result.stderr}');
  return version;
}

int _compareVersions(List<int> a, List<int> b) {
  for (var i = 0; i < a.length || i < b.length; i++) {
    final difference = (i < a.length ? a[i] : 0) - (i < b.length ? b[i] : 0);
    if (difference != 0) return difference;
  }
  return 0;
}

/// The bytes of the files under [folder], links not followed.
int _sizeOf(Directory folder) => folder
    .listSync(recursive: true, followLinks: false)
    .whereType<File>()
    .fold(0, (total, file) => total + file.lengthSync());

/// dist/[target], emptied.
Directory _emptyDist(String target) {
  final folder = Directory(_path('dist/$target'));
  if (folder.existsSync()) folder.deleteSync(recursive: true);
  return folder..createSync(recursive: true);
}

/// The installer of dist/windows, made by Inno Setup's compiler from app/windows/packaging/wiretune.iss, which takes
/// the version, the processor and the folders from here.
Future<void> _buildWindowsInstaller() async {
  final (name, build) = _version();
  final output = Directory(_path('dist/windows-installer'));
  if (output.existsSync()) output.deleteSync(recursive: true);
  output.createSync(recursive: true);
  await _run('app', _innoSetupCompiler(), [
    '/DAppVersion=$name',
    '/DFileVersion=$name.$build',
    '/DArch=${_arch == 'arm64' ? 'arm64' : 'x64compatible'}',
    '/DArchName=$_arch',
    '/DSourceDir=${_path('dist/windows')}',
    '/DOutputDir=${output.path}',
    '/DIconFile=${_path('app/windows/runner/resources/app_icon.ico')}',
    '/DLicenseFile=${_path('LICENSE')}',
    _path('app/windows/packaging/wiretune.iss'),
  ]);
  stdout.writeln('→ dist/windows-installer');
}

/// ISCC from the PATH, or where Inno Setup 6 installs itself.
String _innoSetupCompiler() {
  for (final folder in [Platform.environment['ProgramFiles(x86)'], Platform.environment['ProgramFiles']]) {
    if (folder == null) continue;
    final candidate = '$folder\\Inno Setup 6\\ISCC.exe';
    if (File(candidate).existsSync()) return candidate;
  }
  return 'iscc';
}

/// dist/macos/Wiretune.dmg from the app: signed with a Developer ID and the hardened runtime, and notarised, when the
/// environment names the identity and the notary profile; with the build's own ad-hoc signature otherwise.
Future<void> _packageMacos() async {
  final app = _path('dist/macos/Wiretune.app');
  final dmg = _path('dist/macos/Wiretune.dmg');
  final identity = Platform.environment['WIRETUNE_MACOS_SIGN_IDENTITY'] ?? '';
  final notaryProfile = Platform.environment['WIRETUNE_NOTARY_PROFILE'] ?? '';
  if (identity.isNotEmpty) {
    await _run('app', 'codesign', [
      '--force',
      '--deep',
      '--options',
      'runtime',
      '--timestamp',
      '--entitlements',
      _path('app/macos/Runner/Release.entitlements'),
      '--sign',
      identity,
      app,
    ]);
  }
  if (File(dmg).existsSync()) File(dmg).deleteSync();
  await _run('app', 'hdiutil', ['create', '-volname', 'Wiretune', '-srcfolder', app, '-ov', '-format', 'UDZO', dmg]);
  if (identity.isNotEmpty) await _run('app', 'codesign', ['--force', '--timestamp', '--sign', identity, dmg]);
  if (notaryProfile.isNotEmpty) {
    if (identity.isEmpty) throw const _BuildFailure('Notarising needs WIRETUNE_MACOS_SIGN_IDENTITY as well.');
    await _run('app', 'xcrun', ['notarytool', 'submit', dmg, '--keychain-profile', notaryProfile, '--wait']);
    await _run('app', 'xcrun', ['stapler', 'staple', dmg]);
  }
  stdout.writeln('→ dist/macos/Wiretune.dmg');
}

/// The version name and the build number from app/pubspec.yaml (`version: 1.0.2026+1`).
(String, String) _version() {
  final pubspec = File(_path('app/pubspec.yaml')).readAsStringSync();
  final match = RegExp(r'^version:\s*([0-9.]+)\+([0-9]+)\s*$', multiLine: true).firstMatch(pubspec);
  if (match == null) throw const _BuildFailure('app/pubspec.yaml has no version of the form 1.2.3+4.');
  return (match.group(1)!, match.group(2)!);
}

/// [relative] (with forward slashes) inside the repository, in the form of the system.
String _path(String relative) => [_root, ...relative.split('/')].join(Platform.pathSeparator);

/// Runs a build command in [package] (`app` or `server`), with its output on the console.
Future<void> _run(String package, String executable, List<String> arguments) async {
  final command = '$executable ${arguments.join(' ')}';
  stdout.writeln('\$ $command  (in $package/)');
  final Process process;
  try {
    // On Windows flutter and dart are batch files, which only a shell starts; the arguments are fixed words.
    process = await Process.start(
      executable,
      arguments,
      workingDirectory: _path(package),
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows,
    );
  } on ProcessException catch (e) {
    throw _BuildFailure('Cannot start $executable (${e.message}). Is it on the PATH?');
  }
  final code = await process.exitCode;
  if (code != 0) throw _BuildFailure('$command failed with exit code $code.');
}

/// Makes dist/[target] an exact copy of the folder [built].
void _publishFolder(String built, String target) {
  final source = Directory(_path(built));
  if (!source.existsSync()) throw _BuildFailure('The build left nothing in $built.');
  final destination = Directory(_path('dist/$target'));
  if (destination.existsSync()) destination.deleteSync(recursive: true);
  _copyTree(source, destination);
  stdout.writeln('→ dist/$target');
}

/// Copies a folder, with symbolic links as links (a macOS app's frameworks are made of them).
void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(followLinks: false)) {
    final copy = '${to.path}${Platform.pathSeparator}${entity.path.substring(from.path.length + 1)}';
    switch (entity) {
      case Link():
        Link(copy).createSync(entity.targetSync());
      case Directory():
        _copyTree(entity, Directory(copy));
      case File():
        entity.copySync(copy);
    }
  }
}

/// Builds packages (APKs, an .ipa, a .tpk) into [output] and replaces the [extension] files in dist/[target] with them.
Future<void> _buildPackages(String tool, List<String> arguments, String output, String extension, String target) async {
  // Emptied first, so that only this build's packages are collected.
  final built = Directory(_path(output));
  if (built.existsSync()) built.deleteSync(recursive: true);
  await _run('app', tool, arguments);

  List<File> packagesIn(Directory folder) => folder.existsSync()
      ? folder.listSync().whereType<File>().where((f) => f.path.endsWith(extension)).toList()
      : const [];
  final packages = packagesIn(built);
  if (packages.isEmpty) throw _BuildFailure('The build left no $extension file in $output.');

  final destination = Directory(_path('dist/$target'))..createSync(recursive: true);
  for (final old in packagesIn(destination)) {
    old.deleteSync();
  }
  for (final package in packages) {
    final name = package.uri.pathSegments.last;
    package.copySync('${destination.path}${Platform.pathSeparator}$name');
    stdout.writeln('→ dist/$target/$name');
  }
}
