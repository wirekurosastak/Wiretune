// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:wiretune/src/app.dart';
import 'package:wiretune/src/platform.dart';
import 'package:wiretune/src/view_models/app_section.dart';
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune/src/widgets/dialogs.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// What the player tells the user, and where: a short notice over either layout, a banner while the server's music
/// can't play, a question before what can't be undone, a server's refusal in the user's language beside the field it
/// is about, and a page of its own when the player can't start.
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

  const wide = Size(1400, 900);
  const phone = Size(400, 860);

  Future<void> show(WidgetTester tester, MainViewModel vm, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(WiretuneApp(vm: vm));
    await settle(tester);
  }

  final serverTrack = TestSupport.makeServerTrack('s1', 'Giant Steps', artist: 'John Coltrane', album: 'Giant Steps');

  // Made in the real event loop: the library's locks wait for it, and a widget test's own clock only moves on a pump.
  Future<LibraryService> library(WidgetTester tester, [List<Track> tracks = const []]) async =>
      (await tester.runAsync(() async {
        final created = createLibrary(tracks);
        created.initialize();
        return created;
      }))!;

  http.Response json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  testWidgets('a notice shows over either layout, and goes by itself or when tapped', (tester) async {
    for (final size in [wide, phone]) {
      final vm = createMainViewModel(await library(tester));
      await show(tester, vm, size);

      vm.showNotice('Saved.');
      await settle(tester);
      expect(find.text('Saved.'), findsOneWidget, reason: '$size');
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(find.text('Saved.'), findsNothing);

      vm.showNotice('It went wrong.', isError: true);
      await settle(tester);
      expect(find.text('It went wrong.'), findsOneWidget);
      await tester.tap(find.text('It went wrong.'));
      await settle(tester);
      expect(find.text('It went wrong.'), findsNothing);
      vm.dispose();
    }
  });

  testWidgets("a change the server's data can't take while it is out of reach says why", (tester) async {
    final lib = await library(tester, [serverTrack]);
    final vm = createMainViewModel(lib);
    await show(tester, vm, wide);

    lib.toggleFavorite('s1');
    await settle(tester);
    expect(find.text(Localizer.get('OfflineReadOnly')), findsOneWidget);
    expect(lib.isFavorite('s1'), isFalse);
    vm.dispose();
  });

  testWidgets('a device signed out by a password change elsewhere says so, and offers to sign in', (tester) async {
    final lib = await library(tester);
    var revoked = false;
    final session = (await tester.runAsync(
      () => signedInSession(
        lib,
        tracks: [serverTrack],
        respond: (request) => revoked && request.url.path == '/api/tracks'
            ? json(401, {'error': 'The password was changed since this sign-in.', 'code': ErrorCodes.passwordChanged})
            : null,
      ),
    ))!;
    final vm = createMainViewModel(lib, null, session);
    await show(tester, vm, wide);

    revoked = true;
    await tester.runAsync(session.refreshLibrary);
    await settle(tester);
    expect(find.text(Localizer.get('ErrorPasswordChanged')), findsOneWidget);
    await tester.tap(find.text(Localizer.get('SignIn')).last);
    await settle(tester);
    expect(vm.isLoginViewActive, isTrue);
    vm.dispose();
  });

  testWidgets('signing out asks first when it deletes downloads; cancelled, nothing happens', (tester) async {
    final lib = await library(tester);
    final session = (await tester.runAsync(() => signedInSession(lib, tracks: [serverTrack])))!;
    final vm = createMainViewModel(lib, null, session)..navigateTo(AppSection.settings);
    // One copy on disk, as an earlier download left it.
    final copy = File(p.join(vm.downloadService.directory, 'John Coltrane', 'Giant Steps', '01 - Giant Steps.flac'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(2048, 1));
    addTearDown(() => copy.existsSync() ? copy.deleteSync() : null);
    lib.repository.saveDownload('s1', 'v1', p.relative(copy.path, from: vm.downloadService.directory));
    await tester.runAsync(vm.downloadService.initialize);
    await show(tester, vm, wide);

    Future<void> pressSignOut() async {
      final button = find.text(Localizer.get('SignOut')).first;
      await tester.ensureVisible(button);
      await settle(tester);
      await tester.tap(button);
      await settle(tester);
    }

    await pressSignOut();
    expect(find.text(Localizer.get('SignOutConfirm')), findsOneWidget);
    expect(find.textContaining('1 downloaded track'), findsOneWidget);
    await tester.tap(find.text(Localizer.get('Cancel')));
    await settle(tester);
    expect(session.isLoggedIn, isTrue);
    expect(copy.existsSync(), isTrue);

    await pressSignOut();
    await tester.tap(find.descendant(of: find.byType(AppDialog), matching: find.text(Localizer.get('SignOut'))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await settle(tester);
    expect(session.isLoggedIn, isFalse);
    vm.dispose();
  });

  testWidgets('switching servers while signed in asks first', (tester) async {
    final lib = await library(tester);
    final session = (await tester.runAsync(() => signedInSession(lib)))!;
    final vm = createMainViewModel(lib, null, session)..navigateTo(AppSection.settings);
    await show(tester, vm, wide);

    final address = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'http://server:5200');
    await tester.enterText(address, 'http://elsewhere:5200');
    final connect = find.widgetWithText(FilledButton, Localizer.get('ConnectShort'));
    await tester.ensureVisible(connect);
    await settle(tester);
    await tester.tap(connect);
    await settle(tester);
    expect(find.text(Localizer.get('SwitchServerConfirm')), findsOneWidget);
    expect(find.textContaining('http://server:5200'), findsWidgets);
    await tester.tap(find.text(Localizer.get('Cancel')));
    await settle(tester);
    expect((session.isLoggedIn, session.serverUrl), (true, 'http://server:5200'));
    vm.dispose();
  });

  testWidgets("the server's music folder: its problem and a refused folder show beside the field", (tester) async {
    final lib = await library(tester);
    final session = (await tester.runAsync(
      () => signedInSession(
        lib,
        respond: (request) => switch ((request.method, request.url.path)) {
          ('GET', '/api/config') => json(200, {'musicFolder': '/mnt/nas/music'}),
          ('GET', '/api/library/status') => json(200, {
            'trackCount': 0,
            'albumCount': 0,
            'artistCount': 0,
            'isScanning': false,
            'lastScanError': 'Library folder does not exist: /mnt/nas/music',
            'lastScanProblem': ErrorCodes.folderMissing,
          }),
          ('POST', '/api/config/music-folder') => json(400, {
            'error': 'A whole disk cannot be the music folder.',
            'code': ErrorCodes.folderWholeDisk,
          }),
          _ => null,
        },
      ),
    ))!;
    final vm = createMainViewModel(lib, null, session)..navigateTo(AppSection.settings);
    await show(tester, vm, wide);
    await tester.runAsync(vm.serverSettings.loadServerFolder);
    await settle(tester);
    expect(find.text(Localizer.format('ServerFolderUnavailable', ['/mnt/nas/music'])), findsOneWidget);

    final folder = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '/mnt/nas/music');
    final save = find.widgetWithText(FilledButton, Localizer.get('SaveFolder'));
    // One column, the buttons beside the field: as tall as the field, its hint under them rather than inside it.
    tester.view.physicalSize = const Size(1100, 1600);
    await settle(tester);
    expect(find.descendant(of: folder, matching: find.text(Localizer.get('ServerFolderHelper'))), findsNothing);
    expect(find.text(Localizer.get('ServerFolderHelper')), findsOneWidget);
    expect(tester.getSize(save).height, tester.getSize(folder).height);
    expect(tester.getCenter(save).dy, moreOrLessEquals(tester.getCenter(folder).dy, epsilon: 1));
    tester.view.physicalSize = wide;
    await settle(tester);
    await tester.enterText(folder, '/');
    await tester.ensureVisible(save);
    await settle(tester);
    await tester.tap(save);
    await settle(tester);
    expect(find.text(Localizer.get('ServerFolderConfirm')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AppDialog), matching: find.text(Localizer.get('SaveFolder'))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle(tester);
    expect(find.text(Localizer.get('ErrorFolderWholeDisk')), findsOneWidget);
    vm.dispose();
  });

  testWidgets("remote control says why it isn't running", (tester) async {
    final lib = await library(tester);
    final session = (await tester.runAsync(() => signedInSession(lib)))!;
    final remote = RemoteClient(
      session,
      connector: (uri, token) async => throw const RemoteRefusedException('HTTP 401', 401),
    );
    final vm = createMainViewModel(lib, null, session, remote)..navigateTo(AppSection.settings);
    await show(tester, vm, wide);
    vm.remote.configure(id: 'desk', name: '', kind: DeviceKind.desktop, enabled: true);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle(tester);
    expect(find.text(Localizer.get('RemoteStatusEnded')), findsOneWidget);
    vm.dispose();
  });

  testWidgets('adding to a playlist says so, and says when the music is in it already', (tester) async {
    final lib = await library(tester, [TestSupport.makeTrack('1', 'So What')]);
    lib.createPlaylist('Mix');
    final vm = createMainViewModel(lib);
    await show(tester, vm, wide);
    for (final key in ['AddedToPlaylist', 'AlreadyInPlaylist']) {
      final page = tester.element(find.text(Localizer.get('NavArtists')).first);
      final adding = showAddTrackToPlaylistDialog(page, lib.tracks.single);
      await settle(tester);
      await tester.tap(find.text('Mix'));
      await settle(tester);
      await adding;
      expect(find.text(Localizer.format(key, ['Mix'])), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
    }
    expect(lib.getPlaylistTracks(lib.playlists.single), hasLength(1));
    vm.dispose();
  });

  test("Reindex is the server's scan: this device's folder can be scanned meanwhile", () async {
    final lib = createLibrary(const [])..initialize();
    var serverScanning = true;
    final session = await signedInSession(
      lib,
      respond: (request) => switch ((request.method, request.url.path)) {
        ('POST', '/api/library/scan') => json(200, <String, Object?>{}),
        ('GET', '/api/library/status') => json(200, {
          'trackCount': 0,
          'albumCount': 0,
          'artistCount': 0,
          'isScanning': serverScanning,
        }),
        _ => null,
      },
    );
    final vm = createMainViewModel(lib, null, session);
    addTearDown(vm.dispose);
    final server = vm.serverSettings;

    final reindexing = server.reindexServer();
    expect((server.isReindexing, server.canReindexServer), (true, false));
    expect(server.isScanning, isFalse, reason: "the local folder's Scan stays as it was");
    serverScanning = false;
    await reindexing;
    expect((server.isReindexing, server.canReindexServer), (false, true));
  });

  test('signing in to the server already connected, typed without http://, does not connect again first', () async {
    final lib = createLibrary(const [])..initialize();
    var asked = 0;
    final session = await signedInSession(
      lib,
      respond: (request) {
        if (request.url.path == '/api/auth/setup-required') asked++;
        return null;
      },
    );
    await session.logout();
    final vm = createMainViewModel(lib, null, session);
    addTearDown(vm.dispose);
    final server = vm.serverSettings
      ..serverUrl = 'server:5200'
      ..username = 'owner'
      ..password = 'password';
    final before = asked;
    await server.login();
    expect(session.isLoggedIn, isTrue);
    expect(asked, before);
    await pumpEventQueue(); // what signing in set off (the server's folder, for an administrator) ends first
  });

  testWidgets('hiding says so, and its Undo brings it back', (tester) async {
    final lib = await library(tester, [TestSupport.makeTrack('1', 'So What', album: 'Kind of Blue')]);
    final vm = createMainViewModel(lib);
    await show(tester, vm, wide);
    final album = lib.albums.single;
    final said = find.text(Localizer.format('HiddenNotice', ['Kind of Blue']));

    vm.hide(HiddenKind.album, album.id, album.title);
    await settle(tester);
    expect(said, findsOneWidget);
    expect(lib.albums, isEmpty);
    await tester.tap(find.text(Localizer.get('Undo')));
    await settle(tester);
    expect(lib.albums.map((a) => a.title), ['Kind of Blue']);
    expect(said, findsNothing);
    vm.dispose();
  });

  testWidgets('a player that cannot start says why, and shows nothing else', (tester) async {
    final broken = LibraryService(_NewerDatabase(), MetadataScanner(), coverCacheDirectory: '/nonexistent');
    final vm = createMainViewModel(broken);
    await tester.runAsync(vm.start);
    await show(tester, vm, phone);
    expect(find.text(Localizer.get('StartupFailedTitle')), findsOneWidget);
    expect(find.textContaining('/data/wiretune.db'), findsOneWidget);
    vm.dispose();
  });
}

/// Settles the transitions, without waiting for what keeps animating.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// The database of a newer Wiretune.
class _NewerDatabase extends LibraryRepository {
  @override
  void initialize() => throw const IncompatibleDatabaseException('made by another version', '/data/wiretune.db');
}
