// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:wiretune_core/wiretune_core.dart';

import 'user_data_service.dart';

/// The Blends: two accounts' listening mixed into one playlist, which both have once the one invited accepts. Either can
/// leave, which ends it for both; blocking ends it too. While one account blocks the other, an invitation between them
/// waits: its sender sees it as sent, the account that blocks never sees it, and nobody can accept it. The tracks are mixed when asked for, from what each account plays and loves now ([mix]).
class BlendService {
  BlendService(this._db, this._userData, this._library, this._blocks);

  final DatabaseManager _db;
  final UserDataService _userData;
  final LibraryService _library;
  final bool Function(String userId, String otherId) _blocks;

  /// The Blends [userId] is in or invited to, by the other account's name: an active one with its tracks.
  List<Blend> of(String userId) {
    final rows = _db.connection.select(
      'SELECT b.id, b.inviter_id, b.accepted_at, u.id AS other_id, u.username FROM blends b '
      'JOIN users u ON u.id = CASE WHEN b.inviter_id = ?1 THEN b.invitee_id ELSE b.inviter_id END '
      'WHERE b.inviter_id = ?1 OR b.invitee_id = ?1 ORDER BY u.username COLLATE NOCASE, b.id',
      [userId],
    );
    UserDataSnapshot? mine;
    return [
      for (final row in rows)
        if (row['other_id'] as String case final other when _shows(userId, other, sentByMe: row['inviter_id'] == userId))
          if (row['accepted_at'] != null)
            Blend(
              row['id'] as String,
              AccountInfo(other, row['username'] as String),
              BlendState.active,
              // The inviter's turn first, so that both have the same mix.
              row['inviter_id'] == userId
                  ? mix(mine ??= _userData.get(userId), _userData.get(other))
                  : mix(_userData.get(other), mine ??= _userData.get(userId)),
            )
          else
            Blend(
              row['id'] as String,
              AccountInfo(other, row['username'] as String),
              row['inviter_id'] == userId ? BlendState.inviting : BlendState.invited,
            ),
    ];
  }

  /// Whether [userId] sees its Blend with [otherId]: not while either blocks the other, but for its own invitation
  /// ([sentByMe]) while only [otherId] blocks it, so that it can't tell.
  bool _shows(String userId, String otherId, {required bool sentByMe}) =>
      !_blocks(userId, otherId) && (sentByMe || !_blocks(otherId, userId));

  /// [userId] invites [otherId] (an account of the server other than itself), or accepts its invitation when it sent
  /// one and neither blocks the other; inviting again changes nothing. Returns the Blend's ID; null when [userId] is
  /// at [BlendRules.maxBlends].
  String? invite(String userId, String otherId) => _db.transaction((db) {
    final existing = db.select(
      'SELECT id, inviter_id, accepted_at FROM blends '
      'WHERE (inviter_id = ?1 AND invitee_id = ?2) OR (inviter_id = ?2 AND invitee_id = ?1)',
      [userId, otherId],
    ).firstOrNull;
    if (existing != null) {
      final id = existing['id'] as String;
      if (existing['accepted_at'] == null &&
          existing['inviter_id'] == otherId &&
          !_blocks(userId, otherId) &&
          !_blocks(otherId, userId)) {
        db.execute('UPDATE blends SET accepted_at = ? WHERE id = ?', [toDbTime(DateTime.now().toUtc()), id]);
      }
      return id;
    }
    final count =
        db.select('SELECT COUNT(*) AS n FROM blends WHERE inviter_id = ?1 OR invitee_id = ?1', [userId]).first['n']
            as int;
    if (count >= BlendRules.maxBlends) return null;
    final id = newId();
    db.execute('INSERT INTO blends (id, inviter_id, invitee_id, invited_at) VALUES (?, ?, ?, ?)', [
      id,
      userId,
      otherId,
      toDbTime(DateTime.now().toUtc()),
    ]);
    return id;
  });

  /// [userId] leaves the Blend [id] (or turns down or takes back its invitation): it ends for both. Returns the other
  /// account, or null when [userId] isn't in it.
  String? leave(String userId, String id) => _db.transaction((db) {
    final row = db.select(
      'SELECT inviter_id, invitee_id FROM blends WHERE id = ?1 AND (inviter_id = ?2 OR invitee_id = ?2)',
      [id, userId],
    ).firstOrNull;
    if (row == null) return null;
    db.execute('DELETE FROM blends WHERE id = ?', [id]);
    return row['inviter_id'] == userId ? row['invitee_id'] as String : row['inviter_id'] as String;
  });

  /// The accounts [userId] has a Blend with or an invitation from or to.
  List<String> partners(String userId) => [
    for (final row in _db.connection.select(
      'SELECT CASE WHEN inviter_id = ?1 THEN invitee_id ELSE inviter_id END AS other FROM blends '
      'WHERE inviter_id = ?1 OR invitee_id = ?1',
      [userId],
    ))
      row['other'] as String,
  ];

  /// Ends the Blend of [userId] and [otherId], if they have one (one blocked the other). Whether there was one.
  bool end(String userId, String otherId) {
    _db.connection.execute(
      'DELETE FROM blends WHERE (inviter_id = ?1 AND invitee_id = ?2) OR (inviter_id = ?2 AND invitee_id = ?1)',
      [userId, otherId],
    );
    return _db.connection.updatedRows > 0;
  }

  /// The tracks of a Blend of the accounts with the data [a] and [b]: from each one's [BlendRules.picksPerAccount] most
  /// played and loved tracks (a favourite counting [BlendRules.favoriteWeight] plays), the ones both have first in
  /// each round, then one of [a]'s and one of [b]'s, up to [BlendRules.maxTracks]. Only tracks of the library, none
  /// that either account hides.
  List<String> mix(UserDataSnapshot a, UserDataSnapshot b) {
    final hiddenA = _Hidden(a);
    final hiddenB = _Hidden(b);
    Map<String, int> scores(UserDataSnapshot data) {
      final scores = <String, int>{for (final stats in data.plays) stats.trackId: stats.playCount};
      for (final id in data.favorites) {
        scores[id] = (scores[id] ?? 0) + BlendRules.favoriteWeight;
      }
      scores.removeWhere((id, score) {
        final track = _library.getTrack(id);
        return score <= 0 || track == null || hiddenA.hides(track) || hiddenB.hides(track);
      });
      return scores;
    }

    List<String> best(Map<String, int> scores) {
      final ids = scores.keys.toList()
        ..sort((x, y) {
          final byScore = scores[y]!.compareTo(scores[x]!);
          return byScore != 0 ? byScore : x.compareTo(y);
        });
      return ids.take(BlendRules.picksPerAccount).toList();
    }

    final scoresA = scores(a);
    final scoresB = scores(b);
    final pickedA = best(scoresA);
    final pickedB = best(scoresB);
    final both = [...pickedA.where(pickedB.contains)]
      ..sort((x, y) {
        int least(String id) => scoresA[id]! < scoresB[id]! ? scoresA[id]! : scoresB[id]!;
        final byScore = least(y).compareTo(least(x));
        return byScore != 0 ? byScore : x.compareTo(y);
      });
    final turns = [both.iterator, pickedA.iterator, pickedB.iterator];
    final mixed = <String>{};
    var moved = true;
    while (mixed.length < BlendRules.maxTracks && moved) {
      moved = false;
      for (final turn in turns) {
        while (turn.moveNext()) {
          moved = true;
          if (mixed.add(turn.current)) break;
        }
        if (mixed.length == BlendRules.maxTracks) break;
      }
    }
    return mixed.toList();
  }
}

/// What one account hides, as a track would be checked against it: the track, its album, its artist or an album
/// artist.
class _Hidden {
  _Hidden(UserDataSnapshot data)
    : _tracks = data.hiddenTracks.toSet(),
      _albums = data.hiddenAlbums.toSet(),
      _artists = data.hiddenArtists.toSet();

  final Set<String> _tracks;
  final Set<String> _albums;
  final Set<String> _artists;

  bool hides(Track track) =>
      _tracks.contains(track.id) ||
      _albums.contains(track.albumId) ||
      _artists.contains(artistIdOf(track.primaryArtist)) ||
      track.albumArtistNames.any((name) => _artists.contains(artistIdOf(name)));
}
