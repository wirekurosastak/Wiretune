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
  linux       the Linux player, on Linux                               → dist/linux/
  windows     the Windows player, on Windows                           → dist/windows/
  macos       the macOS player, on macOS                               → dist/macos/Wiretune.app
  android     one APK per processor type                               → dist/android/*.apk
  appbundle   the Android App Bundle for Google Play                   → dist/android/*.aab
  ios         the .ipa, on a Mac with a signing team                   → dist/ios/*.ipa
  tizen       the .tpk for Samsung TVs, with flutter-tizen on the PATH → dist/tizen/*.tpk

docs/building.md says what each target needs installed first.''';

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
  'linux': () async {
    await _run('app', 'flutter', ['build', 'linux', '--release']);
    _publishFolder('app/build/linux/$_arch/release/bundle', 'linux');
  },
  'windows': () async {
    await _run('app', 'flutter', ['build', 'windows', '--release']);
    _publishFolder('app/build/windows/$_arch/runner/Release', 'windows');
  },
  'macos': () async {
    await _run('app', 'flutter', ['build', 'macos', '--release']);
    _publishFolder('app/build/macos/Build/Products/Release/Wiretune.app', 'macos/Wiretune.app');
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
  'tizen': () => _buildPackages('flutter-tizen', ['build', 'tpk', '--release'], 'app/build/tizen/tpk', '.tpk', 'tizen'),
};

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
