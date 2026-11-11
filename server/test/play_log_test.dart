// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Each play is logged with its time, so an account's listening summary can cover a year; another account's don't count.
void main() {
  setUpAll(useTempDataDirectory);

  test("an account's plays in a time, each track's count, and since when they are kept", () async {
    final server = await ServerFixture.start();
    addTearDown(server.close);
    final (admin, _) = await setupAdmin(server);
    final (guest, _) = await registerGuest(server, admin);
    final before = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    for (final id in ['track-a', 'track-a', 'track-b']) {
      expect((await admin.post('/api/me/plays/$id')).statusCode, 200);
    }
    expect((await guest.post('/api/me/plays/track-a')).statusCode, 200);
    final after = DateTime.now().toUtc().add(const Duration(minutes: 1));

    Future<Map<String, dynamic>> plays(Api client, DateTime from, DateTime to) async =>
        json(await client.get('/api/me/plays?from=${formatIsoUtc(from)}&to=${formatIsoUtc(to)}'))
            as Map<String, dynamic>;

    final mine = await plays(admin, before, after);
    expect(mine['plays'], {'track-a': 2, 'track-b': 1});
    expect(parseIsoUtc(mine['since'])!.isAfter(before), isTrue);
    expect((await plays(guest, before, after))['plays'], {'track-a': 1}, reason: 'its own only');
    expect((await plays(admin, before.subtract(const Duration(days: 1)), before))['plays'], isEmpty);

    final bad = await admin.get('/api/me/plays?from=${formatIsoUtc(after)}&to=${formatIsoUtc(before)}');
    expect((bad.statusCode, json(bad)['code']), (400, ErrorCodes.invalidPeriod));
  });

  test('a play told of later is logged at the time it was made, and never moves the last play back', () async {
    final server = await ServerFixture.start();
    addTearDown(server.close);
    final (admin, _) = await setupAdmin(server);
    final now = DateTime.now().toUtc();
    final yesterday = now.subtract(const Duration(days: 1));

    final today = json(await admin.post('/api/me/plays/track-a'));
    final late = json(await admin.post('/api/me/plays/track-a', {'at': formatIsoUtc(yesterday)}));
    expect(late['playCount'], 2);
    expect(late['lastPlayedAt'], today['lastPlayedAt'], reason: 'the newer play stays the last one');

    Future<Object?> plays(DateTime from, DateTime to) async =>
        json(await admin.get('/api/me/plays?from=${formatIsoUtc(from)}&to=${formatIsoUtc(to)}'))['plays'];
    const hour = Duration(hours: 1);
    expect(await plays(yesterday.subtract(hour), yesterday.add(hour)), {'track-a': 1});
    expect(await plays(now.subtract(hour), now.add(hour)), {'track-a': 1});

    // A time still to come is taken for now.
    await admin.post('/api/me/plays/track-b', {'at': formatIsoUtc(now.add(const Duration(days: 30)))});
    expect(await plays(now.subtract(hour), now.add(hour)), {'track-a': 1, 'track-b': 1});
  });
}
