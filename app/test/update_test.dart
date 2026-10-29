// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:wiretune/src/platform.dart';
import 'package:wiretune/src/update_installer.dart';
import 'package:wiretune/src/view_models/app_section.dart';
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune/src/widgets/update_banner.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Updating from a release: which file each kind of copy takes, putting a Linux folder in place, and the banner.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() {
    Localizer.instance.setLanguage('en');
    AppPlatform.forTesting();
    // The desktop window's buttons ask the window manager plugin, which tests don't have.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
  });

  // The files of a release as .github/workflows/release.yml names them.
  final release = Release('1.1.2026', {
    'wiretune-1.1.2026-linux-x64.tar.gz': _url,
    'wiretune_1.1.2026-1_amd64.deb': _url,
    'wiretune-1.1.2026-1.x86_64.rpm': _url,
    'Wiretune-1.1.2026-windows-x64-setup.exe': _url,
    'wiretune-1.1.2026-windows-x64-portable.zip': _url,
    'Wiretune-1.1.2026-macos.dmg': _url,
    'wiretune-1.1.2026-arm64-v8a-release.apk': _url,
    'wiretune-1.1.2026-armeabi-v7a-release.apk': _url,
    'wiretune-1.1.2026-x86_64-release.apk': _url,
    'wiretune-1.1.2026-release.aab': _url,
    'wiretune-server-1.1.2026-linux-x64.tar.gz': _url,
    'SHA256SUMS.txt': _url,
  });

  test('each kind of copy takes its own file of the release, and none for a processor it lacks', () {
    String? file(InstallKind kind, String arch) =>
        UpdateInstaller(kind, executable: '/x/wiretune', arch: arch).fileFor(release);
    expect(file(InstallKind.linuxFolder, 'x64'), 'wiretune-1.1.2026-linux-x64.tar.gz');
    expect(file(InstallKind.deb, 'x64'), 'wiretune_1.1.2026-1_amd64.deb');
    expect(file(InstallKind.rpm, 'x64'), 'wiretune-1.1.2026-1.x86_64.rpm');
    expect(file(InstallKind.windowsSetup, 'x64'), 'Wiretune-1.1.2026-windows-x64-setup.exe');
    expect(file(InstallKind.macosApp, 'arm64'), 'Wiretune-1.1.2026-macos.dmg');
    expect(file(InstallKind.androidApk, 'arm64-v8a'), 'wiretune-1.1.2026-arm64-v8a-release.apk');
    expect(file(InstallKind.androidApk, 'armeabi-v7a'), 'wiretune-1.1.2026-armeabi-v7a-release.apk');
    // The release builds the computers' players for x64 only.
    expect(file(InstallKind.linuxFolder, 'arm64'), isNull);
    expect(file(InstallKind.deb, 'arm64'), isNull);
    expect(file(InstallKind.windowsSetup, 'arm64'), isNull);
  });

  group('a Linux folder', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('wiretune_update_app_'));
    tearDown(() => dir.deleteSync(recursive: true));

    // The release's tarball: a folder with the player, lib/, data/ and install.sh, as tool/build.dart linux leaves it.
    File tarball(String version) {
      final bundle = Directory(p.join(dir.path, 'build', 'wiretune-$version-linux-x64'))..createSync(recursive: true);
      File(p.join(bundle.path, 'wiretune')).writeAsStringSync('player $version');
      File(p.join(bundle.path, 'lib', 'libapp.so'))
        ..createSync(recursive: true)
        ..writeAsStringSync('code $version');
      File(p.join(bundle.path, 'data', 'icudtl.dat'))
        ..createSync(recursive: true)
        ..writeAsStringSync('data $version');
      final packaging = p.join(Directory.current.path, 'linux', 'packaging');
      for (final name in ['install.sh', 'com.wiretune.player.desktop', 'com.wiretune.player.png']) {
        File(p.join(packaging, name)).copySync(p.join(bundle.path, name));
      }
      final archive = File(p.join(dir.path, 'download', 'wiretune-$version-linux-x64.tar.gz'))
        ..parent.createSync(recursive: true);
      final result = Process.runSync('tar', ['-czf', archive.path, '-C', bundle.parent.path, p.basename(bundle.path)]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return archive;
    }

    // The old version where [app] is, with a file of its own that an update leaves alone.
    void oldCopy(String app) {
      File(p.join(app, 'wiretune'))
        ..createSync(recursive: true)
        ..writeAsStringSync('player 1.0');
      File(p.join(app, 'lib', 'gone.so'))
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      Directory(p.join(app, 'data')).createSync();
      File(p.join(app, 'notes.txt')).writeAsStringSync('mine');
    }

    test('unpacked anywhere: its player, lib/ and data/ are replaced, and the new one starts', () async {
      final app = p.join(dir.path, 'Wiretune');
      oldCopy(app);
      String? relaunched;
      await UpdateInstaller(
        InstallKind.linuxFolder,
        executable: p.join(app, 'wiretune'),
      ).install(tarball('1.1'), ({relaunch}) async => relaunched = relaunch);

      expect(File(p.join(app, 'wiretune')).readAsStringSync(), 'player 1.1');
      expect(File(p.join(app, 'lib', 'libapp.so')).readAsStringSync(), 'code 1.1');
      expect(File(p.join(app, 'lib', 'gone.so')).existsSync(), isFalse, reason: 'the old lib/ is gone whole');
      expect(File(p.join(app, 'notes.txt')).readAsStringSync(), 'mine');
      expect(relaunched, p.join(app, 'wiretune'));
    });

    test('put in place by install.sh: the new install.sh installs it again, menu entry and icon too', () async {
      final prefix = p.join(dir.path, 'prefix');
      final app = p.join(prefix, 'lib', 'wiretune');
      oldCopy(app);
      final menuEntry = File(p.join(prefix, 'share', 'applications', 'com.wiretune.player.desktop'))
        ..createSync(recursive: true)
        ..writeAsStringSync('old entry');
      String? relaunched;
      await UpdateInstaller(
        InstallKind.linuxFolder,
        executable: p.join(app, 'wiretune'),
      ).install(tarball('1.1'), ({relaunch}) async => relaunched = relaunch);

      expect(File(p.join(app, 'wiretune')).readAsStringSync(), 'player 1.1');
      expect(File(p.join(app, 'notes.txt')).existsSync(), isFalse, reason: 'install.sh replaces the folder');
      expect(menuEntry.readAsStringSync(), contains('Exec=$app/wiretune'));
      expect(
        File(p.join(prefix, 'share', 'icons', 'hicolor', '256x256', 'apps', 'com.wiretune.player.png')).existsSync(),
        isTrue,
      );
      expect(relaunched, p.join(app, 'wiretune'));
    });

    test('an archive without a Wiretune folder changes nothing and throws', () async {
      final app = p.join(dir.path, 'Wiretune');
      oldCopy(app);
      final empty = Directory(p.join(dir.path, 'empty'))..createSync();
      File(p.join(empty.path, 'readme')).writeAsStringSync('nothing here');
      final archive = File(p.join(dir.path, 'download', 'bad.tar.gz'))..parent.createSync(recursive: true);
      Process.runSync('tar', ['-czf', archive.path, '-C', empty.path, 'readme']);
      var quit = false;
      await expectLater(
        UpdateInstaller(
          InstallKind.linuxFolder,
          executable: p.join(app, 'wiretune'),
        ).install(archive, ({relaunch}) async => quit = true),
        throwsA(isA<UpdateException>()),
      );
      expect((File(p.join(app, 'wiretune')).readAsStringSync(), quit), ('player 1.0', false));
    });
  });

  group('the banner', () {
    late List<String> requests;

    MainViewModel create({String tag = 'v99.0.0'}) {
      requests = [];
      final check = UpdateCheck(
        client: MockClient((request) async {
          requests.add(request.url.path);
          return http.Response(
            jsonEncode({
              'tag_name': tag,
              'assets': [
                {'name': 'wiretune-${tag.substring(1)}-linux-x64.tar.gz', 'browser_download_url': _url.toString()},
              ],
            }),
            200,
          );
        }),
        latestUrl: Uri.parse('https://api.test/latest'),
      );
      return MainViewModel(
        TestSupport.createEngine(),
        createLibrary(),
        ServerSession(createLibrary(), testRepository()),
        updateCheck: check,
        updateInstaller: UpdateInstaller(InstallKind.linuxFolder, executable: '/x/wiretune', arch: 'x64'),
      );
    }

    testWidgets('offers a newer release; Later puts it away until the next check', (tester) async {
      final vm = create();
      await showApp(tester, vm, const Size(1400, 900));
      expect(find.byType(UpdateBanner), findsOneWidget);
      expect(find.text('Wiretune 99.0.0 is available'), findsNothing, reason: 'nothing before a check');

      await tester.runAsync(vm.updates.checkNow);
      await tester.pump();
      expect(find.text('Wiretune 99.0.0 is available'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Update'), findsOneWidget);

      await tester.tap(find.byTooltip('Later'));
      await tester.pump();
      expect(find.text('Wiretune 99.0.0 is available'), findsNothing);

      await tester.runAsync(vm.updates.checkNow);
      await tester.pump();
      expect(find.text('Wiretune 99.0.0 is available'), findsOneWidget, reason: 'the next check offers it again');

      // Its switch is in Settings → About.
      vm.navigateTo(AppSection.settings);
      await settle(tester);
      await tester.scrollUntilVisible(find.text('Look for updates'), 300, scrollable: find.byType(Scrollable).last);
      expect(find.text('At start and once a day, on GitHub.'), findsOneWidget);
    });

    testWidgets("the phone's banner has the same offer", (tester) async {
      AppPlatform.forTesting(system: 'android');
      final vm = create();
      await showApp(tester, vm, const Size(400, 860));
      await tester.runAsync(vm.updates.checkNow);
      await tester.pump();
      expect(find.text('Wiretune 99.0.0 is available'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Update'), findsOneWidget);
    });

    testWidgets('the same version, the switch off or offline mode offer nothing', (tester) async {
      final same = create(tag: 'v${UpdateCheck.currentVersion}');
      await showApp(tester, same, const Size(1400, 900));
      await tester.runAsync(same.updates.checkNow);
      await tester.pump();
      expect((requests.length, same.updates.isBannerVisible), (1, false));

      final off = create()..checkForUpdates = false;
      await tester.runAsync(off.updates.checkNow);
      expect(requests, isEmpty);
      expect(off.updates.isBannerVisible, isFalse);
      off.checkForUpdates = true; // looks at once
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(off.updates.isBannerVisible, isTrue);
      off.checkForUpdates = false;
      expect(off.updates.isBannerVisible, isFalse, reason: 'turning it off takes the offer away');

      final offline = create();
      await tester.runAsync(() => offline.session.setOfflineMode(true));
      await tester.runAsync(offline.updates.checkNow);
      expect(requests, isEmpty);
      expect(offline.updates.isBannerVisible, isFalse);
    });

    testWidgets('a copy no release updates shows no switch and asks nothing', (tester) async {
      final vm = createMainViewModel(createLibrary());
      expect(vm.updates.isSupported, isFalse);
      await tester.runAsync(vm.updates.checkNow);
      expect(vm.updates.isBannerVisible, isFalse);
    });
  });
}

final Uri _url = Uri.parse('https://dl.test/file');
