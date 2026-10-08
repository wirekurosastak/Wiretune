// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:test/test.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

void main() {
  group('cleanTitle removes notes that do not change the recording', () {
    for (final (title, expected) in [
      ('Hotel California (2013 Remaster)', 'hotelcalifornia'),
      ('Hey Jude [Remastered 2015]', 'heyjude'),
      ('Song (Radio Edit) [Remastered]', 'song'),
      ('Monologue (Mono Mix)', 'monologue'),
      ('Song (Single Version)', 'song'),
    ]) {
      test(title, () => expect(TrackDeduplication.cleanTitle(title), expected));
    }
  });

  group('cleanTitle keeps what makes a recording different', () {
    for (final (title, expected) in [
      ('Song (Live Version)', 'songliveversion'),
      ('Song (Acoustic Version)', 'songacousticversion'),
      ('Song (Credits)', 'songcredits'), // "credits" contains "edit" but is not an edit
      ('Song (Stereophonic)', 'songstereophonic'), // neither is a stereo mix
      ('Monologue', 'monologue'),
      ('(Remaster)', 'remaster'), // never reduce a title to nothing
    ]) {
      test(title, () => expect(TrackDeduplication.cleanTitle(title), expected));
    }
  });

  test('live and studio versions of the same length are not duplicates', () {
    final studio = TestSupport.makeTrack('a', 'Song', artist: 'Band', album: 'Album');
    final live = TestSupport.makeTrack('b', 'Song (Live Version)', artist: 'Band', album: 'Album');
    expect(TrackDeduplication.isDuplicate(studio, live), isFalse);
  });

  test('a remaster of the same song is a duplicate', () {
    final original = TestSupport.makeTrack('a', 'Song', artist: 'Band', album: 'Album');
    final remaster = TestSupport.makeTrack(
      'b',
      'Song (2011 Remaster)',
      artist: 'Band',
      album: 'Album (Deluxe Edition)',
    );
    expect(TrackDeduplication.isDuplicate(original, remaster), isTrue);
  });

  group('albumsMatch does not let a short name hide inside a long one', () {
    for (final (a, b, expected) in [
      ('Discovery', 'Discovery Live 2001', true),
      ('Discovery', 'Discovery (Deluxe Edition)', true),
      ('1', 'Abbey Road 1969', false),
      ('Live', 'Live at Wembley', true),
      ('Us', 'Abbey Road Studios', false),
      ('', 'Anything', true),
      ('Unknown Album', 'Anything', true),
    ]) {
      test('$a / $b', () => expect(TrackDeduplication.albumsMatch(a, b), expected));
    }
  });

  test('lengths decide between duplicates of different albums', () {
    final local = TestSupport.makeTrack('l', 'Song', artist: 'Band', album: 'Studio Album', minutes: 4);
    final close = TestSupport.makeServerTrack('s', 'Song', artist: 'Band', album: 'Greatest Hits', minutes: 4.05);
    final far = TestSupport.makeServerTrack('f', 'Song', artist: 'Band', album: 'Greatest Hits', minutes: 4.1);
    expect(TrackDeduplication.isDuplicate(local, close), isTrue); // 3 s apart
    expect(TrackDeduplication.isDuplicate(local, far), isFalse); // 6 s apart
  });

  test('merging folds the server copy into the local one and keeps its data', () {
    final local = TestSupport.makeTrack('local', 'Song', artist: 'Band');
    final server = TestSupport.makeServerTrack('server', 'Song', artist: 'Band')
      ..isFavorite = true
      ..playCount = 7
      ..lastPlayed = DateTime.utc(2024, 5, 1);
    final other = TestSupport.makeServerTrack('other', 'Other', artist: 'Band');
    final aliases = <String, String>{};

    final merged = TrackDeduplication.mergeTracks([local], [server, other], aliases);

    expect(merged.map((t) => t.id), ['local', 'other']);
    expect(aliases, {'server': 'local'});
    expect(local.isFavorite, isTrue);
    expect(local.playCount, 7);
    expect(local.lastPlayed, DateTime.utc(2024, 5, 1));
  });
}
