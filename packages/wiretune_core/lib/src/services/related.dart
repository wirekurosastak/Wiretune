// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;

import '../models/library_models.dart';
import '../models/protocol.dart';

/// What an account likes and has played lately, for [RelatedMusic.autoplay]: its loves, its play counts and when it
/// last played a track, what it hides, and the artists skipped since the music went on by itself.
class Taste {
  const Taste({
    this.isFavorite = _never,
    this.playCount = _none,
    this.lastPlayedAt = _unknown,
    this.isHidden = _never,
    this.skippedArtists = const {},
  });

  final bool Function(Track track) isFavorite;
  final int Function(Track track) playCount;
  final DateTime? Function(Track track) lastPlayedAt;
  final bool Function(Track track) isHidden;

  /// Artists (by [RelatedMusic.key]) the listener skipped a track of before it counted as played.
  final Set<String> skippedArtists;

  static bool _never(Track _) => false;
  static int _none(Track _) => 0;
  static DateTime? _unknown(Track _) => null;
}

/// Which music of a library is alike: the rows at the bottom of artist and album pages (Related artists, Similar
/// albums) and what Autoplay goes on with.
///
/// Two artists are alike by several signs, each where the library has it, and each the stronger the surer it is:
/// - Deezer's listeners relate them, directly or through the artists both are related to ([RelatedMusicFacts],
///   from the server);
/// - this account plays them in the same sitting ([ListeningPairs], from the server's play log);
/// - tracks credit them together (a guest on the other's tracks);
/// - their styles match: MusicBrainz's genres for the artist and its albums, and the genre of the tags or of Deezer.
///   A style few artists of the library have counts for much more than one most have ("pop"), so a broad genre alone
///   doesn't make everything alike.
///
/// The signs add up as chances do (two weak ones make a fair one, a strong one is enough), and the era tells apart
/// what they found alike. Albums are alike when their artists are, and by their own styles, era and tempo.
class RelatedMusic {
  RelatedMusic(
    List<Artist> artists,
    List<Album> albums, {
    this.facts = RelatedMusicFacts.none,
    this.pairs = ListeningPairs.none,
  }) : _artists = artists,
       _albums = albums {
    for (final artist in artists) {
      _artistByKey[key(artist.name)] = artist;
    }
  }

  /// The most a row shows.
  static const int max = 12;

  /// Below this, two artists or albums aren't shown as alike.
  static const double threshold = 0.12;

  /// How many tracks Autoplay adds at a time.
  static const int autoplayCount = 20;

  final RelatedMusicFacts facts;
  final ListeningPairs pairs;
  final List<Artist> _artists;
  final List<Album> _albums;
  final Map<String, Artist> _artistByKey = {};

  /// The key an artist is known by: its name in lower case.
  static String key(String name) => name.trim().toLowerCase();

  // ── Rows ──────────────────────────────────────────────────────────────────────────────────────────────────────────

  final Map<String, List<Artist>> _artistRows = {};
  final Map<String, List<Album>> _albumRows = {};
  final Map<String, List<Album>> _moreByRows = {};

  /// The artists most like [artist], the closest first: Related artists.
  List<Artist> artistsLike(Artist artist) => _artistRows[artist.id] ??= () {
    if (_namesNobody(artist.name)) return const <Artist>[];
    final self = key(artist.name);
    final scored =
        [
          for (final other in _artists)
            if (key(other.name) != self && !_namesNobody(other.name)) (other, artistSimilarity(self, key(other.name))),
        ].where((entry) => entry.$2 >= threshold).toList()..sort((a, b) {
          final byScore = b.$2.compareTo(a.$2);
          return byScore != 0 ? byScore : b.$1.trackCount.compareTo(a.$1.trackCount);
        });
    return [for (final (other, _) in scored.take(max)) other];
  }();

  /// The other albums of [album]'s artists, the newest first: More by.
  List<Album> moreBy(Album album) => _moreByRows[album.id] ??= () {
    final names = {for (final name in album.artistNames) key(name)};
    return [
      for (final other in _albums)
        if (other.id != album.id && other.artistNames.any((name) => names.contains(key(name)))) other,
    ]..sort((a, b) => (b.releaseYear ?? 0).compareTo(a.releaseYear ?? 0));
  }();

  /// The albums by other artists most like [album], the closest first: Similar albums.
  List<Album> albumsLike(Album album) => _albumRows[album.id] ??= () {
    final own = {for (final name in album.artistNames) key(name)};
    final scored = [
      for (final other in _albums)
        if (other.id != album.id && !other.artistNames.any((name) => own.contains(key(name))))
          (other, albumSimilarity(album, other)),
    ].where((entry) => entry.$2 >= threshold).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (other, _) in scored.take(max)) other];
  }();

  // ── Similarity ────────────────────────────────────────────────────────────────────────────────────────────────────

  final Map<(String, String), double> _artistScores = {};

  /// How alike the artists [a] and [b] are (by [key]), from 0 to 1.
  double artistSimilarity(String a, String b) {
    if (a == b) return 1;
    final pair = a.compareTo(b) < 0 ? (a, b) : (b, a);
    return _artistScores[pair] ??= () {
      final deezer = math.max(facts.similarArtists[a]?[b] ?? 0, facts.similarArtists[b]?[a] ?? 0);
      final played = math.max(pairs.artists[a]?[b] ?? 0, pairs.artists[b]?[a] ?? 0);
      final credited = math.min(1.0, (_profile(a).credited[b] ?? 0) / 2);
      final styles = _styleSimilarity(_profile(a).styles, _profile(b).styles);
      final evidence = _together([0.9 * deezer, 0.8 * played, 0.6 * credited, 0.7 * styles]);
      if (evidence == 0) return 0.0;
      return evidence * (0.85 + 0.15 * _closeness(_profile(a).year, _profile(b).year, within: 8));
    }();
  }

  /// How alike the albums [a] and [b] are, from 0 to 1.
  double albumSimilarity(Album a, Album b) {
    var artists = 0.0;
    for (final x in a.artistNames) {
      for (final y in b.artistNames) {
        artists = math.max(artists, artistSimilarity(key(x), key(y)));
      }
    }
    final styles = _styleSimilarity(_albumProfile(a).styles, _albumProfile(b).styles);
    // A guest of both, or the artist of one a guest on the other.
    final aGuests = _albumProfile(a).credited.keys.toSet();
    final bGuests = _albumProfile(b).credited.keys.toSet();
    bool among(Set<String> guests, Album album) => album.artistNames.any((name) => guests.contains(key(name)));
    final guests = aGuests.any(bGuests.contains) || among(aGuests, b) || among(bGuests, a) ? 1.0 : 0.0;
    final evidence = _together([0.85 * artists, 0.75 * styles, 0.5 * guests]);
    if (evidence == 0) return 0;
    final era = _closeness(_albumProfile(a).year, _albumProfile(b).year, within: 5);
    final tempo = _tempoCloseness(_albumProfile(a).bpm, _albumProfile(b).bpm);
    return evidence * (0.8 + 0.15 * era + 0.05 * tempo);
  }

  /// How alike two tracks are: their artists (the same one counts, but no more than a close other), the styles of their
  /// albums, and as a tiebreak their era and tempo.
  double trackSimilarity(Track a, Track b) {
    final aKeys = _trackArtists(a);
    final bKeys = _trackArtists(b);
    var artists = 0.0;
    var same = false;
    for (final x in aKeys) {
      for (final y in bKeys) {
        if (x == y) {
          same = true;
        } else {
          artists = math.max(artists, artistSimilarity(x, y));
        }
      }
    }
    final aAlbum = _albumOf(a);
    final bAlbum = _albumOf(b);
    final styles = aAlbum == null || bAlbum == null
        ? 0.0
        : _styleSimilarity(_albumProfile(aAlbum).styles, _albumProfile(bAlbum).styles);
    final evidence = _together([0.85 * artists, 0.6 * styles, if (same) 0.55]);
    if (evidence == 0) return 0;
    final era = _closeness(a.releaseYear, b.releaseYear, within: 6);
    final tempo = _tempoCloseness(a.bpm, b.bpm);
    return evidence * (0.75 + 0.1 * era + 0.15 * tempo);
  }

  // ── Autoplay ──────────────────────────────────────────────────────────────────────────────────────────────────────

  /// Up to [count] tracks to go on with after [queue], like its last tracks (the last the most): from the artists like
  /// theirs and the albums like theirs, and a few of their own. They lean towards what the listener loves and plays,
  /// keep away from what played in the last days and from artists just skipped, and now and then one never played
  /// comes in. They follow on from each other: each next one is also like the one before it, and no artist plays twice
  /// in a row. Never anything in [queue] or hidden. [random] picks among the closest, so it isn't the same each time.
  List<Track> autoplay(
    List<Track> queue, {
    Taste taste = const Taste(),
    math.Random? random,
    int count = autoplayCount,
  }) {
    final skipped = taste.skippedArtists;
    // The last tracks, not those skipped: skipping says what not to go on with.
    final seeds = [
      for (final track in queue.reversed)
        if (!_trackArtists(track).any(skipped.contains)) track,
    ].take(5).toList();
    if (seeds.isEmpty && queue.isNotEmpty) seeds.add(queue.last);
    if (seeds.isEmpty) return const [];
    const seedWeights = [1.0, 0.75, 0.55, 0.4, 0.3];
    final queued = {for (final track in queue) track.id};

    // Where to look: the seeds' artists, the artists most like them, and the albums most like theirs.
    final sources = <Album>{};
    for (final seed in seeds) {
      for (final name in _trackArtists(seed)) {
        final artist = _artistByKey[name];
        if (artist == null) continue;
        sources.addAll(artist.albums);
        for (final other in artistsLike(artist).take(8)) {
          sources.addAll(other.albums);
        }
      }
      if (_albumOf(seed) case final album?) sources.addAll(albumsLike(album).take(8));
    }
    final now = DateTime.now().toUtc();
    final candidates = <(Track, double)>[];
    for (final album in sources) {
      for (final track in album.tracks) {
        if (queued.contains(track.id) || taste.isHidden(track)) continue;
        var relation = 0.0;
        for (final (i, seed) in seeds.indexed) {
          relation = math.max(relation, seedWeights[i] * trackSimilarity(seed, track));
        }
        if (relation <= 0) continue;
        final plays = taste.playCount(track);
        final liking = 1 + (taste.isFavorite(track) ? 0.5 : 0) + 0.15 * math.min(1, math.log(1 + plays) / math.log(20));
        final played = taste.lastPlayedAt(track);
        final rest = played == null ? 1.0 : _restAfter(now.difference(played));
        final penalty = _trackArtists(track).any(skipped.contains) ? 0.1 : 1.0;
        candidates.add((track, relation * liking * rest * penalty));
      }
    }
    // The closest, a few of each artist at most: an artist of many albums mustn't crowd out the others.
    candidates.sort((a, b) => b.$2.compareTo(a.$2));
    final inPool = <String, int>{};
    final pool = [
      for (final candidate in candidates)
        if ((inPool[_mainArtist(candidate.$1)] = (inPool[_mainArtist(candidate.$1)] ?? 0) + 1) <= 5) candidate,
    ].take(math.max(60, count * 4)).toList();

    final rng = random ?? math.Random();
    final varied = {for (final (track, _) in pool) _mainArtist(track)}.length > 1;
    final picked = <Track>[];
    final perAlbum = <String, int>{};
    final perArtist = <String, int>{};
    var unplayed = 0;
    while (picked.length < count && pool.isNotEmpty) {
      final previous = picked.lastOrNull ?? seeds.first;
      final previousArtist = _mainArtist(previous);
      // After the first two, a third or so never played.
      final wantsNew = picked.length >= 2 && unplayed * 3 < picked.length;
      // Another artist than the one before (by whose album it is: a guest may be on both), and no album or artist
      // too often, unless only those are left.
      final others = [
        for (final (track, _) in pool)
          if (_mainArtist(track) != previousArtist) track,
      ];
      bool fits(Track track) {
        final artist = _mainArtist(track);
        if (artist == previousArtist) return false;
        final roomy = (perAlbum[track.albumId] ?? 0) < 2 && (perArtist[artist] ?? 0) < 3;
        return roomy || !others.any((other) => _mainArtist(other) != artist);
      }

      List<(int, double)> weigh({required bool strict}) => [
        for (final (i, (track, score)) in pool.indexed)
          if (!strict || fits(track))
            (
              i,
              score *
                  (0.6 + 0.4 * trackSimilarity(previous, track)) *
                  (wantsNew && taste.playCount(track) == 0 ? 1.6 : 1),
            ),
      ];
      var weighed = weigh(strict: true);
      // Only the artist that just played is left: the batch ends here, unless that is all the music there is.
      if (weighed.isEmpty && others.isEmpty && !varied) weighed = weigh(strict: false);
      if (weighed.isEmpty) break;
      // By chance among the closest: those at least half as close as the best, so a crowd of weak ones can't outdraw it.
      weighed.sort((a, b) => b.$2.compareTo(a.$2));
      final best = weighed.first.$2;
      final chosen = _draw(weighed.take(12).where((entry) => entry.$2 >= 0.55 * best).toList(), rng);
      final (track, _) = pool.removeAt(chosen);
      picked.add(track);
      perAlbum[track.albumId] = (perAlbum[track.albumId] ?? 0) + 1;
      perArtist[_mainArtist(track)] = (perArtist[_mainArtist(track)] ?? 0) + 1;
      if (taste.playCount(track) == 0) unplayed++;
    }
    return picked;
  }

  /// How much a track played [ago] is held back: much the same day, less over the next two weeks.
  static double _restAfter(Duration ago) => switch (ago.inHours) {
    < 24 => 0.15,
    < 72 => 0.4,
    < 336 => 0.75,
    _ => 1.0,
  };

  /// One of [weighed] (pool index, weight), by chance, the heavier the likelier (squared: the closest win more often).
  static int _draw(List<(int, double)> weighed, math.Random rng) {
    final total = weighed.fold(0.0, (sum, entry) => sum + entry.$2 * entry.$2);
    if (total <= 0) return weighed.first.$1;
    var at = rng.nextDouble() * total;
    for (final (index, weight) in weighed) {
      at -= weight * weight;
      if (at <= 0) return index;
    }
    return weighed.last.$1;
  }

  // ── Profiles ──────────────────────────────────────────────────────────────────────────────────────────────────────

  final Map<String, _Profile> _profiles = {};
  final Map<String, _Profile> _albumProfiles = {};
  Map<String, Album>? _albumByTrack;
  Map<String, double>? _rarity;

  Album? _albumOf(Track track) => (_albumByTrack ??= {
    for (final album in _albums)
      for (final t in album.tracks) t.id: album,
  })[track.id];

  /// The keys of [track]'s artists: its own and its album's; not "Various Artists" or an unknown one, which say nothing
  /// of how it sounds.
  static Set<String> _trackArtists(Track track) => {
    for (final name in [...track.artistNames, ...track.albumArtistNames])
      if (!_namesNobody(name)) key(name),
  };

  /// The artist whose album [track] is on, for not playing one artist twice in a row; a compilation's track goes by its
  /// own artist.
  static String _mainArtist(Track track) {
    final albumArtist = track.albumArtistNames.first;
    return key(_namesNobody(albumArtist) ? track.primaryArtist : albumArtist);
  }

  /// Whether [name] stands for no one artist: a compilation's "Various Artists", or a file that names none.
  static bool _namesNobody(String name) => Track.isUnknownArtist(name) || key(name) == 'various artists';

  _Profile _profile(String artist) => _profiles[artist] ??= () {
    final found = _artistByKey[artist];
    final tracks = found?.tracks ?? const <Track>[];
    final styles = <String, double>{};
    _add(styles, facts.artistStyles[artist], 1);
    for (final album in found?.albums ?? const <Album>[]) {
      _add(styles, facts.albumStyles[album.id], 0.6 / math.max(1, found!.albums.length));
    }
    _add(styles, _tagStyles(tracks), 0.5);
    final credited = <String, double>{};
    for (final track in tracks) {
      final names = _trackArtists(track);
      if (!names.contains(artist)) continue;
      for (final name in names) {
        if (name != artist) credited[name] = (credited[name] ?? 0) + 1;
      }
    }
    return _Profile(styles, credited, _median([for (final t in tracks) ?t.releaseYear]), null);
  }();

  _Profile _albumProfile(Album album) => _albumProfiles[album.id] ??= () {
    final styles = <String, double>{};
    _add(styles, facts.albumStyles[album.id], 1);
    _add(styles, _tagStyles(album.tracks), 0.5);
    // An album nobody described takes after its artists.
    if (styles.isEmpty) {
      for (final name in album.artistNames) {
        _add(styles, _profile(key(name)).styles, 0.5);
      }
    }
    final credited = <String, double>{
      for (final track in album.tracks)
        for (final name in _trackArtists(track))
          if (!album.artistNames.any((n) => key(n) == name)) name: 1,
    };
    return _Profile(
      styles,
      credited,
      album.releaseYear ?? _median([for (final t in album.tracks) ?t.releaseYear]),
      _median([for (final t in album.tracks) ?t.bpm]),
    );
  }();

  /// The genres the tags (or Deezer's lookups, which the server puts in their place) give [tracks], each with the share
  /// of tracks that have it; "Rap/Hip Hop" is two styles.
  static Map<String, double> _tagStyles(Iterable<Track> tracks) {
    final counts = <String, double>{};
    var total = 0;
    for (final track in tracks) {
      total++;
      for (final style in styleNames(track.genre ?? '')) {
        counts[style] = (counts[style] ?? 0) + 1;
      }
    }
    return {for (final MapEntry(:key, :value) in counts.entries) key: value / math.max(1, total)};
  }

  /// The styles a genre's text names, as their keys: in lower case, "hip-hop" as "hip hop", and split where it lists
  /// several ("Rap/Hip Hop", "Soul & Funk", "Rock; Indie"; but "R&B" is one).
  static List<String> styleNames(String text) => [
    for (final part in text.toLowerCase().split(RegExp(r'\s*[/;,|]\s*|\s+&\s+')))
      if (part.replaceAll('-', ' ').replaceAll(RegExp(r'\s+'), ' ').trim() case final style when style.isNotEmpty)
        style,
  ];

  /// Adds [styles] (any weights, made relative to their strongest) to [into], [share] of them.
  static void _add(Map<String, double> into, Map<String, double>? styles, double share) {
    if (styles == null || styles.isEmpty) return;
    final strongest = styles.values.fold(0.0, math.max);
    if (strongest <= 0) return;
    for (final MapEntry(key: name, value: weight) in styles.entries) {
      for (final style in styleNames(name)) {
        into[style] = (into[style] ?? 0) + share * weight / strongest;
      }
    }
  }

  /// How alike two sets of styles are, from 0 to 1: the angle between them, each shared style counting by how rare it
  /// is among the library's artists (a style all of them have counts for little).
  double _styleSimilarity(Map<String, double> a, Map<String, double> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final rarity = _rarity ??= _rarities();
    var shared = 0.0;
    for (final MapEntry(key: style, value: weight) in a.entries) {
      final other = b[style];
      if (other != null) shared += weight * other * (rarity[style] ?? 1);
    }
    if (shared == 0) return 0;
    double length(Map<String, double> v) => math.sqrt(v.values.fold(0.0, (sum, w) => sum + w * w));
    return math.min(1.0, shared / (length(a) * length(b)));
  }

  /// For each style, how rare it is among the artists, from near 0 (all have it) to 1 (one has it).
  Map<String, double> _rarities() {
    final artists = [for (final artist in _artists) key(artist.name)];
    final having = <String, int>{};
    for (final artist in artists) {
      for (final style in _profile(artist).styles.keys) {
        having[style] = (having[style] ?? 0) + 1;
      }
    }
    final n = artists.length;
    double idf(int count) => math.log((1 + n) / (1 + count)) + 1;
    final rarest = idf(1);
    return {for (final MapEntry(:key, :value) in having.entries) key: idf(value) / rarest};
  }

  /// Signs of likeness put together as chances: each from 0 to 1, together at least the strongest, never above 1.
  static double _together(List<double> signs) {
    var none = 1.0;
    for (final sign in signs) {
      none *= 1 - sign.clamp(0.0, 1.0);
    }
    return 1 - none;
  }

  static int? _median(List<int> values) {
    if (values.isEmpty) return null;
    values.sort();
    return values[values.length ~/ 2];
  }

  /// 1 for the same year, less the further apart, 0 beyond [within] years (or when one isn't known: 0.5).
  static double _closeness(int? a, int? b, {required int within}) {
    if (a == null || b == null) return 0.5;
    final apart = (a - b).abs();
    return apart > within ? 0 : 1 - apart / (within + 1);
  }

  /// 1 for the same tempo, 0 at 15 % apart (or when one isn't known: 0.5).
  static double _tempoCloseness(int? a, int? b) {
    if (a == null || b == null || a <= 0 || b <= 0) return 0.5;
    // A tempo tagged at half or double speed is the same beat.
    final ratio = math.max(a, b) / math.min(a, b);
    final apart = math.min((ratio - 1).abs(), (ratio / 2 - 1).abs());
    return math.max(0, 1 - apart / 0.15);
  }
}

/// What an artist or an album is like: its styles, whom it credits, its year and tempo.
class _Profile {
  const _Profile(this.styles, this.credited, this.year, this.bpm);

  final Map<String, double> styles;
  final Map<String, double> credited;
  final int? year;
  final int? bpm;
}
