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
}
