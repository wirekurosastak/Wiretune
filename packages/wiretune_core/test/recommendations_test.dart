// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// The bell's recommendations as a player keeps them: downloaded on sign-in and whenever the server says so, only
/// what this library has, seen and dismissed at once.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  late LibraryService library;
  late ServerSession session;
  late FakeRemoteHub hub;
  late RemoteClient remote;
  late List<Map<String, Object?>> onServer;
  late List<String> requests;

  Map<String, Object?> recommendation(String id, String trackId, {bool seen = false}) => Recommendation(
    id,
    const AccountInfo('user-2', 'anna'),
    RecommendationKind.track,
    trackId,
    'listen',
    DateTime.utc(2026, 11, 3),
    seen: seen,
  ).toJson();

  http.Response answer(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

  setUp(() async {
    library = LibraryService(testRepository(), MetadataScanner(), coverCacheDirectory: '/nonexistent');
    library.initialize();
    onServer = [recommendation('r1', 's1'), recommendation('r2', 'gone', seen: true)];
    requests = [];
    session = await signedInSession(
      library,
      tracks: [TestSupport.makeServerTrack('s1', 'One'), TestSupport.makeServerTrack('s2', 'Two')],
      respond: (request) {
        final path = request.url.path;
        if (!path.startsWith('/api/me/recommendations') && path != '/api/accounts') return null;
        requests.add('${request.method} $path');
        return switch ((request.method, path)) {
          ('GET', '/api/me/recommendations') => answer(onServer),
          ('GET', '/api/accounts') => answer([
            const AccountInfo('user-1', 'owner').toJson(),
            const AccountInfo('user-2', 'anna').toJson(),
          ]),
          ('POST', '/api/me/recommendations') => answer({
            'ids': ['new-1'],
          }),
          _ => answer({'ok': true}),
        };
      },
    );
    hub = FakeRemoteHub();
    remote = RemoteClient(session, connector: hub.connect)
      ..configure(id: 'phone', name: '', kind: DeviceKind.phone, enabled: true);
    await until(() => remote.isConnected);
  });
  tearDown(() {
    remote.dispose();
    session.dispose();
  });

  test('come with the sign-in, only what this library has, and again when the server says so', () async {
    final inbox = Recommendations(session, library, remote);
    addTearDown(inbox.dispose);
    await until(() => inbox.items.isNotEmpty);
    expect(inbox.items.map((r) => r.id), ['r1'], reason: "a track this library doesn't have is left out");
    expect(inbox.unseenCount, 1);

    onServer = [recommendation('r3', 's2'), ...onServer];
    var changes = 0;
    inbox.changed.listen((_) => changes++);
    hub.deliver({'type': 'recommendationsChanged'});
    await until(() => inbox.items.length == 2);
    expect(inbox.unseenCount, 2);
    expect(changes, greaterThan(0));

    await session.logout();
    expect(inbox.items, isEmpty, reason: "another account's are not shown");
  });

  test("what this account hides never shows, whoever recommends it, and shows again once it isn't hidden", () async {
    final inbox = Recommendations(session, library, remote);
    addTearDown(inbox.dispose);
    await until(() => inbox.items.isNotEmpty);
    final track = library.resolveTracks(['s1']).single;
    var changes = 0;
    inbox.changed.listen((_) => changes++);

    for (final (kind, id) in [
      (HiddenKind.track, track.id),
      (HiddenKind.album, track.albumId),
      (HiddenKind.artist, artistIdOf(track.primaryArtist)),
    ]) {
      library.setHidden(kind, id, true);
      expect(inbox.items, isEmpty, reason: 'its $kind hidden');
      expect(inbox.unseenCount, 0, reason: 'nor counted under the bell');
      library.setHidden(kind, id, false);
      expect(inbox.items.map((r) => r.id), ['r1'], reason: 'its $kind shown again');
    }
    expect(changes, greaterThanOrEqualTo(6), reason: 'the bell redrawn at each change');
  });

  test('opening the bell sees them all; a dismissed one goes at once', () async {
    final inbox = Recommendations(session, library, remote);
    addTearDown(inbox.dispose);
    await until(() => inbox.items.isNotEmpty);

    final seen = inbox.markSeen();
    expect(inbox.unseenCount, 0, reason: 'at once, not after the server answered');
    await seen;
    expect(requests, contains('POST /api/me/recommendations/seen'));

    await inbox.dismiss(inbox.items.single);
    expect(inbox.items, isEmpty);
    expect(requests, contains('DELETE /api/me/recommendations/r1'));
  });

  test('sending lists the other accounts, and its Undo takes back what was sent', () async {
    final inbox = Recommendations(session, library, remote);
    addTearDown(inbox.dispose);
    expect((await inbox.otherAccounts()).map((a) => a.username), ['anna'], reason: 'not oneself');

    final undo = await inbox.send(RecommendationKind.track, 's1', ['user-2'], '  hi\n ');
    expect(requests, contains('POST /api/me/recommendations'));
    await undo();
    expect(requests.last, 'DELETE /api/me/recommendations/new-1');
  });
}
