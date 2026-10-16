// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../localization/localizer.dart';
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
    this.title = 'Unknown Title',
    this.artist = 'Unknown Artist',
    List<String>? artists,
    String album = 'Unknown Album',
    String? albumArtist,
    int? trackNumber,
    this.trackCount,
    int? discNumber,
    this.year,
    this.bpm,
    this.genre,
    this.duration = Duration.zero,
    this.fileSizeBytes = 0,
    this.fileModifiedUtc,
    this.filePath = '',
    this.streamUrl,
    this.hasCoverArt = false,
    this.coverArtPath,
    this.format = const AudioFormat(),
    DateTime? dateAdded,
  }) : id = id ?? newId(),
       artists = artists != null && artists.length > 1 ? List.unmodifiable(artists) : const [],
       tagged = (album: album, albumArtist: albumArtist, trackNumber: trackNumber, discNumber: discNumber),
       dateAdded = dateAdded ?? DateTime.now().toUtc();

  final String id;
  String title;

  /// The artist as shown: when the track has several ([artists]), their names joined by ", ".
  String artist;

  /// Every artist of the track, main artist first, when the tags name more than one (featured artists); empty when
  /// there is one.
  final List<String> artists;

  /// Where the file's tags put the track. This is what is stored.
  final AlbumPlace tagged;

  /// Where the library files the track instead, worked out afresh from [tagged] at every build of the library (see
  /// `LibrarySnapshot.build`): the album of a folder put together by hand, or an album artist taken from the folder's
  /// other songs. Null: as tagged.
  AlbumPlace? filed;

  String get album => (filed ?? tagged).album;
  String? get albumArtist => (filed ?? tagged).albumArtist;
  int? get trackNumber => (filed ?? tagged).trackNumber;
  int? get discNumber => (filed ?? tagged).discNumber;

  int? trackCount;
  int? year;
  int? bpm;
  String? genre;
  Duration duration;
  int fileSizeBytes;
  DateTime? fileModifiedUtc;
  String filePath;
  String? streamUrl;
  bool hasCoverArt;
  String? coverArtPath;
  AudioFormat format;
  DateTime dateAdded;

  /// Each artist of the track on its own, main artist first: [artists], or [artist] alone.
  List<String> get artistNames => artists.isEmpty ? [artist] : artists;

  /// The main artist: the first of [artists], or [artist].
  String get primaryArtist => artists.isEmpty ? artist : artists.first;

  /// The artist an album is filed under: the album artist when tagged, otherwise the track's main artist.
  String get effectiveAlbumArtist =>
      (albumArtist == null || albumArtist!.trim().isEmpty) ? primaryArtist : albumArtist!;

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
    'trackNumber': trackNumber,
    'trackCount': trackCount,
    'discNumber': discNumber,
    'year': year,
    'bpm': bpm,
    'genre': genre,
    'durationMs': duration.inMilliseconds,
    'fileSizeBytes': fileSizeBytes,
    'fileModifiedUtc': fileModifiedUtc == null ? null : formatIsoUtc(fileModifiedUtc!),
    'hasCoverArt': hasCoverArt,
    'format': format.toJson(),
    'dateAdded': formatIsoUtc(dateAdded),
  };

  /// Reads a track of the server's listing. Throws [FormatException] when [json] is not a track.
  static Track fromJson(Object? json) {
    if (json is! Map) throw const FormatException('A track must be a JSON object.');
    final id = json['id'];
    if (id is! String || id.isEmpty) throw const FormatException('A track has no ID.');
    int? integer(String key) => (json[key] as num?)?.toInt();
    return Track(
      id: id,
      title: json['title'] as String? ?? 'Unknown Title',
      artist: json['artist'] as String? ?? 'Unknown Artist',
      artists: [
        for (final name in json['artists'] as List? ?? const [])
          if (name is String && name.trim().isNotEmpty) name,
      ],
      album: json['album'] as String? ?? 'Unknown Album',
      albumArtist: json['albumArtist'] as String?,
      trackNumber: integer('trackNumber'),
      trackCount: integer('trackCount'),
      discNumber: integer('discNumber'),
      year: integer('year'),
      bpm: integer('bpm'),
      genre: json['genre'] as String?,
      duration: Duration(milliseconds: integer('durationMs') ?? 0),
      fileSizeBytes: integer('fileSizeBytes') ?? 0,
      fileModifiedUtc: parseIsoUtc(json['fileModifiedUtc']),
      hasCoverArt: json['hasCoverArt'] as bool? ?? false,
      format: AudioFormat.fromJson(json['format']),
      dateAdded: parseIsoUtc(json['dateAdded']),
    );
  }

  @override
  String toString() => 'Track($artist - $title)';
}

class Album {
  Album({
    String? id,
    this.title = 'Unknown Album',
    this.artist = 'Unknown Artist',
    this.year,
    this.coverArtPath,
    this.trackCount = 0,
    this.totalDuration = Duration.zero,
    this.tier = QualityTier.silver,
    this.tagSpec = '',
    List<Track>? tracks,
  }) : id = id ?? newId(),
       tracks = tracks ?? [];

  final String id;
  final String title;
  final String artist;
  final int? year;
  final String? coverArtPath;
  final int trackCount;
  final Duration totalDuration;

  /// The lowest [QualityTier] among the album's tracks (see [QualitySummary]).
  final QualityTier tier;

  /// What the quality tag says after the tier word, e.g. "FLAC 24bit/96kHz", or "MIXED".
  final String tagSpec;

  /// A compact representation of quality suitable for small thumbnails.
  String get compactTagSpec => AudioFormat.compactSpec(tier, tagSpec);

  final List<Track> tracks;

  String get formattedTotalDuration => Localizer.formatTotalDuration(totalDuration);
}

class Artist {
  Artist({
    String? id,
    this.name = 'Unknown Artist',
    this.albumCount = 0,
    this.trackCount = 0,
    this.picturePath,
    List<Album>? albums,
    List<Track>? tracks,
  }) : id = id ?? newId(),
       albums = albums ?? [],
       tracks = tracks ?? [];

  final String id;
  final String name;
  final int albumCount;
  final int trackCount;

  /// An album cover at first; replaced by the artist's photo once the online lookup found one.
  String? picturePath;
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

  /// The lowest tier among the playlist's tracks; only meaningful while [formatSpec] is not empty.
  QualityTier formatTier = QualityTier.silver;

  /// What the quality tag says, e.g. "FLAC 24bit/96kHz" or "MIXED"; empty for an empty playlist, which has no tag.
  String formatSpec = '';

  /// A compact representation of quality suitable for small thumbnails.
  String get compactFormatSpec => AudioFormat.compactSpec(formatTier, formatSpec);

  /// Sets [formatTier] and [formatSpec] from the playlist's tracks.
  void applyQuality(List<Track> tracks) {
    final summary = QualitySummary.of(tracks.map((t) => t.format));
    formatSpec = summary?.spec ?? '';
    if (summary != null) formatTier = summary.tier;
  }
}

enum PlaybackState { stopped, playing, paused, error }

enum RepeatMode { off, all, one }

class ScanProgressReport {
  const ScanProgressReport({
    this.scannedFiles = 0,
    this.totalEstimatedFiles = 0,
    this.currentFile = '',
    this.currentArtist = '',
  });

  final int scannedFiles;
  final int totalEstimatedFiles;
  final String currentFile;
  final String currentArtist;

  double get progressPercentage =>
      totalEstimatedFiles > 0 ? (scannedFiles / totalEstimatedFiles * 100.0).clamp(0.0, 100.0) : 0;
}

/// An output the player can send audio to.
class AudioOutputDevice {
  const AudioOutputDevice({
    this.id = 'default',
    String? name,
    this.nameKey,
    this.driverType = 'Default',
    this.hardwareCard = '',
    this.isExclusiveSupported = false,
    this.isBitperfectSupported = false,
    this.isDefault = false,
    this.supportedSampleRates = const [44100, 48000, 88200, 96000, 176400, 192000],
  }) : _name = name;

  final String id;
  final String? _name;

  /// Key of the translated name to use when no explicit name was given.
  final String? nameKey;

  /// ALSA, PipeWire, WASAPI, CoreAudio, Android, Tizen ...
  final String driverType;
  final String hardwareCard;
  final bool isExclusiveSupported;
  final bool isBitperfectSupported;
  final bool isDefault;
  final List<int> supportedSampleRates;

  /// Name shown to the user. Devices without an explicit name get a translated "default output" text that is looked
  /// up when read, so it follows the interface language.
  String get name => _name ?? Localizer.get(nameKey ?? 'AudioSystemDefaultOutput');

  String get displayTitle => hardwareCard.trim().isEmpty ? name : '$name ($hardwareCard)';
}
