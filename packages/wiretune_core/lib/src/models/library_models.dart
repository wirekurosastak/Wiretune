// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../localization/localizer.dart';
import '../util/text.dart';
import '../util/time.dart';
import 'audio_format.dart';

/// A short ID that is the same on every machine for the same key: the first 16 hex digits of the key's SHA-256.
String stableId(String key) => sha256.convert(utf8.encode(key)).toString().substring(0, 16);

final Random _random = Random.secure();

/// A new random ID: 32 lower-case hex digits.
String newId() {
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Where a track sits on an album: the album, the album's artist, its number on the album and the disc's.
typedef AlbumPlace = ({String album, String? albumArtist, int? trackNumber, int? discNumber});

/// How often a track was played, and when last.
typedef PlayStats = ({int count, DateTime? lastPlayedAt});

/// One audio file: what its tags and stream properties say. Whether it is a favourite and how often it was played the
/// library keeps by track ID (`LibraryService.isFavorite`, `LibraryService.playCount`).
class Track {
  Track({
    String? id,
    this.title = unknownTitle,
    this.artist = unknownArtist,
    List<String>? artists,
    String album = unknownAlbum,
    String? albumArtist,
    List<String>? albumArtists,
    int? trackNumber,
    this.trackCount,
    int? discNumber,
    this.releaseYear,
    this.bpm,
    this.genre,
    this.duration = Duration.zero,
    this.fileSizeBytes = 0,
    this.fileModifiedAt,
    this.filePath = '',
    this.streamUrl,
    this.hasCoverArt = false,
    this.coverArtPath,
    this.format = const AudioFormat(),
    DateTime? addedAt,
  }) : id = id ?? newId(),
       artists = artists != null && artists.length > 1 ? List.unmodifiable(artists) : const [],
       albumArtists = albumArtists != null && albumArtists.length > 1 ? List.unmodifiable(albumArtists) : const [],
       tagged = (album: album, albumArtist: albumArtist, trackNumber: trackNumber, discNumber: discNumber),
       addedAt = addedAt ?? DateTime.now().toUtc();

  /// What a track without a title, artist or album tag goes by (the scanner names an untitled file after itself). They
  /// are data, stored in the library and grouping the untagged files together, so they don't follow the interface
  /// language.
  static const String unknownTitle = 'Unknown title';
  static const String unknownArtist = 'Unknown artist';
  static const String unknownAlbum = 'Unknown album';

  static bool isUnknownArtist(String? name) => equalsIgnoreCase(name, unknownArtist);

  final String id;
  String title;

  /// The artist as shown: when the track has several ([artists]), their names joined by ", ".
  String artist;

  /// Every artist of the track, main artist first, when the tags name more than one (featured artists); empty when
  /// there is one.
  final List<String> artists;

  /// Where the file's tags put the track. This is what is stored.
  final AlbumPlace tagged;

  /// Every album artist the tags name, the one in [tagged] first, when they name more than one (an album of two acts);
  /// empty when they name one.
  final List<String> albumArtists;

  /// Where the library files the track instead, worked out afresh from [tagged] at every build of the library (see
  /// `LibrarySnapshot.build`): the album of a folder put together by hand, or an album artist taken from the folder's
  /// other songs. Null: as tagged.
  AlbumPlace? filed;

  String get album => (filed ?? tagged).album;
  String? get albumArtist => (filed ?? tagged).albumArtist;
  int? get trackNumber => (filed ?? tagged).trackNumber;
  int? get discNumber => (filed ?? tagged).discNumber;

  int? trackCount;
  int? releaseYear;
  int? bpm;
  String? genre;
  Duration duration;
  int fileSizeBytes;
  DateTime? fileModifiedAt;
  String filePath;
  String? streamUrl;
  bool hasCoverArt;
  String? coverArtPath;
  AudioFormat format;
  DateTime addedAt;

  /// Each artist of the track on its own, main artist first: [artists], or [artist] alone.
  List<String> get artistNames => artists.isEmpty ? [artist] : artists;

  /// The main artist: the first of [artists], or [artist].
  String get primaryArtist => artists.isEmpty ? artist : artists.first;

  /// The artist an album is filed under: the album artist when tagged, otherwise the track's main artist.
  String get effectiveAlbumArtist =>
      (albumArtist == null || albumArtist!.trim().isEmpty) ? primaryArtist : albumArtist!;

  /// Every artist of the album the track is filed under, [effectiveAlbumArtist] first: the album artists its tags
  /// name, unless the library filed the track under another album.
  List<String> get albumArtistNames => filed == null && albumArtists.isNotEmpty ? albumArtists : [effectiveAlbumArtist];

  /// Identifies the album the track is filed under (title and album artist, ignoring case). It is the same on every
  /// device and on the server, so it is also the key of `/api/cover/album/{id}`.
  String get albumId => stableId('${album.toLowerCase()}\u001f${effectiveAlbumArtist.toLowerCase()}');

  String get formattedDuration => formatClock(duration);

  String get displayTrackNumber => trackNumber == null ? '--' : trackNumber.toString().padLeft(2, '0');

  bool get isLocal => streamUrl == null || streamUrl!.isEmpty;

  /// The track as `GET /api/tracks` lists it. The file path, the stream URL and the per-account data stay out: the
  /// first never leaves the server, the client builds the second, and `/api/me/data` carries the rest.
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    if (artists.isNotEmpty) 'artists': artists,
    'album': album,
    'albumArtist': albumArtist,
    // As filed, like the album and the album artist.
    if (albumArtistNames case final names when names.length > 1) 'albumArtists': names,
    'trackNumber': trackNumber,
    'trackCount': trackCount,
    'discNumber': discNumber,
    'releaseYear': releaseYear,
    'bpm': bpm,
    'genre': genre,
    'durationMs': duration.inMilliseconds,
    'fileSizeBytes': fileSizeBytes,
    'fileModifiedAt': fileModifiedAt == null ? null : formatIsoUtc(fileModifiedAt!),
    'hasCoverArt': hasCoverArt,
    'format': format.toJson(),
    'addedAt': formatIsoUtc(addedAt),
  };

  /// Reads a track of the server's listing. Throws [FormatException] when [json] is not a track.
  static Track fromJson(Object? json) {
    if (json is! Map) throw const FormatException('A track must be a JSON object.');
    final id = json['id'];
    if (id is! String || id.isEmpty) throw const FormatException('A track has no ID.');
    int? integer(String key) => (json[key] as num?)?.toInt();
    List<String> names(String key) => [
      for (final name in json[key] as List? ?? const [])
        if (name is String && name.trim().isNotEmpty) name,
    ];
    return Track(
      id: id,
      title: json['title'] as String? ?? unknownTitle,
      artist: json['artist'] as String? ?? unknownArtist,
      artists: names('artists'),
      album: json['album'] as String? ?? unknownAlbum,
      albumArtist: json['albumArtist'] as String?,
      albumArtists: names('albumArtists'),
      trackNumber: integer('trackNumber'),
      trackCount: integer('trackCount'),
      discNumber: integer('discNumber'),
      releaseYear: integer('releaseYear'),
      bpm: integer('bpm'),
      genre: json['genre'] as String?,
      duration: Duration(milliseconds: integer('durationMs') ?? 0),
      fileSizeBytes: integer('fileSizeBytes') ?? 0,
      fileModifiedAt: parseIsoUtc(json['fileModifiedAt']),
      hasCoverArt: json['hasCoverArt'] as bool? ?? false,
      format: AudioFormat.fromJson(json['format']),
      addedAt: parseIsoUtc(json['addedAt']),
    );
  }

  @override
  String toString() => 'Track($artist - $title)';
}

/// The quality tag of [tracks] (an album's, a playlist's): their lowest tier and their format, or `MIXED`; null for none.
QualitySummary? qualityOf(Iterable<Track> tracks) => QualitySummary.of(tracks.map((t) => t.format));

class Album {
  Album({
    String? id,
    this.title = Track.unknownAlbum,
    this.artist = Track.unknownArtist,
    List<String>? artists,
    this.releaseYear,
    this.coverArtPath,
    this.totalDuration = Duration.zero,
    required this.quality,
    List<Track>? tracks,
  }) : id = id ?? newId(),
       artists = artists != null && artists.length > 1 ? List.unmodifiable(artists) : const [],
       tracks = tracks ?? [];

  final String id;
  final String title;

  /// The album artist as shown: when the album has several ([artists]), their names joined by ", ".
  final String artist;

  /// Every artist of the album, the one it is filed under first, when it has more than one (an album of two acts);
  /// empty when it has one.
  final List<String> artists;

  /// Each artist of the album on its own: [artists], or [artist] alone.
  List<String> get artistNames => artists.isEmpty ? [artist] : artists;
  final int? releaseYear;
  final String? coverArtPath;
  final Duration totalDuration;

  /// The album's quality tag: the lowest tier of its tracks, and their format or `MIXED`.
  final QualitySummary quality;

  final List<Track> tracks;
  int get trackCount => tracks.length;

  String get formattedTotalDuration => Localizer.formatTotalDuration(totalDuration);
}

class Artist {
  Artist({
    String? id,
    this.name = Track.unknownArtist,
    this.picturePath,
    this.hasOwnPicture = false,
    List<Album>? albums,
    List<Track>? tracks,
  }) : id = id ?? newId(),
       albums = albums ?? [],
       tracks = tracks ?? [];

  final String id;
  final String name;
  int get albumCount => albums.length;
  int get trackCount => tracks.length;

  /// The artist's own picture ([hasOwnPicture]), else an album cover at first, replaced by the artist's photo once the
  /// online lookup found one.
  String? picturePath;

  /// Whether [picturePath] is a picture put beside the music for the artist (`artist.jpg`), which the online lookup
  /// leaves alone.
  final bool hasOwnPicture;
  final List<Album> albums;

  /// Tracks performed by the artist plus every track on albums filed under the artist.
  final List<Track> tracks;
}

class Playlist {
  Playlist({
    String? id,
    String? name,
    this.description,
    DateTime? createdAt,
    DateTime? modifiedAt,
    this.isServer = false,
    this.isAutomatic = false,
    List<String>? trackIds,
  }) : id = id ?? newId(),
       name = name ?? Localizer.get('PlaylistNew'),
       createdAt = createdAt ?? DateTime.now().toUtc(),
       modifiedAt = modifiedAt ?? DateTime.now().toUtc(),
       trackIds = trackIds ?? const [];

  final String id;
  String name;
  String? description;
  DateTime createdAt;
  DateTime modifiedAt;

  /// True for a playlist that belongs to the signed-in server account: the server holds the original and this player's
  /// copy is a cache that is dropped on sign-out. False for a playlist that only exists on this device.
  bool isServer;

  /// One the player puts together itself from the play counts (most played, recently played): read-only, never stored.
  final bool isAutomatic;

  /// Replaced (never mutated in place) by the library service, so readers can iterate it safely.
  List<String> trackIds;

  int get trackCount => trackIds.length;
}

enum RepeatMode { off, all, one }
