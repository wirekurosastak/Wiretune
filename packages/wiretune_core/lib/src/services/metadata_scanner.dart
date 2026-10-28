// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../metadata/byte_source.dart';
import '../metadata/tag_reader.dart';
import '../models/audio_format.dart';
import '../models/library_models.dart';
import '../util/cancellation.dart';
import '../util/text.dart';
import 'app_paths.dart';
import 'wiretune_log.dart';

/// Recognises the image formats covers come in.
abstract final class ImageFormat {
  static bool isPng(List<int> data) =>
      data.length >= 8 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47;

  static String mimeType(List<int> data) => isPng(data) ? 'image/png' : 'image/jpeg';

  static String mimeTypeFromPath(String path) => p.extension(path).toLowerCase() == '.png' ? 'image/png' : 'image/jpeg';
}

/// What a scan already knows about a file, so that an unchanged file is not read again (unless its cover changed), and
/// one read again keeps the date it joined the library.
class _Known {
  const _Known(this.size, this.modifiedMicros, this.coverPath, this.added);

  final int size;
  final int? modifiedMicros;
  final String? coverPath;
  final DateTime added;
}

/// Turns audio files into [Track]s: tags, stream properties, cover art. Folder scans run in background isolates.
class MetadataScanner {
  static const List<String> folderCoverNames = [
    'cover.jpg',
    'cover.jpeg',
    'cover.png',
    'folder.jpg',
    'folder.jpeg',
    'folder.png',
    'front.jpg',
    'front.jpeg',
    'front.png',
    'albumart.jpg',
    'artwork.jpg',
  ];

  /// The names of an artist's own picture, in the order they are looked for (ignoring case): see [findArtistPictures].
  static const List<String> artistPictureNames = ['artist.jpg', 'artist.jpeg', 'artist.png'];

  static const int _maxLyricsLength = 100000;
  static const int _batchSize = 24;

  /// The track ID: the first 32 hex digits of the SHA-256 of the full path, compared as the file system compares it.
  static String computeTrackId(String filePath) =>
      sha256.convert(utf8.encode(AppPaths.comparable(AppPaths.fullPath(filePath)))).toString().substring(0, 32);

  /// Scans [rootPath] recursively. Files whose path, size and modification time match [knownTracks] are not read
  /// again, unless a folder image was added, replaced or removed next to them: the known track is returned instead; one
  /// that changed keeps its date added. Hidden files and folders (names starting with a dot) are skipped, and so is the
  /// folder [skip] (the player's own downloads).
  Future<List<Track>> scanDirectory(
    String rootPath, {
    String? coverCacheDirectory,
    void Function(ScanProgressReport report)? onProgress,
    CancellationToken? cancellationToken,
    Map<String, Track>? knownTracks,
    String? skip,
  }) async {
    final ct = cancellationToken ?? CancellationToken.none;
    if (!Directory(rootPath).existsSync()) return [];

    final log = WiretuneLog.isolateSettings;
    final files = await _enumerateInIsolate(rootPath, skip);
    ct.throwIfCancelled();

    final total = files.length;
    final results = <Track>[];
    var processed = 0;
    var unreadable = 0;

    final batches = <List<String>>[
      for (var i = 0; i < files.length; i += _batchSize) files.sublist(i, math.min(i + _batchSize, files.length)),
    ];
    final parallel = math.max(2, math.min(Platform.numberOfProcessors, 8));
    var next = 0;

    Future<void> worker() async {
      while (next < batches.length) {
        ct.throwIfCancelled();
        final batch = batches[next++];
        final known = <String, _Known>{
          for (final file in batch)
            if (knownTracks?[file] case final track?)
              file: _Known(
                track.fileSizeBytes,
                track.fileModifiedAt?.microsecondsSinceEpoch,
                track.coverArtPath,
                track.addedAt,
              ),
        };

        final outcome = await _scanBatchInIsolate(batch, known, coverCacheDirectory, log);
        for (var i = 0; i < batch.length; i++) {
          final result = outcome[i];
          final Track? track = result == true ? knownTracks![batch[i]] : result as Track?;
          if (track != null) {
            results.add(track);
          } else {
            unreadable++;
          }
        }
        processed += batch.length;
        if (onProgress != null) {
          final last = outcome.last;
          onProgress(
            ScanProgressReport(
              scannedFiles: processed,
              totalEstimatedFiles: total,
              currentFile: p.basename(batch.last),
              currentArtist: last is Track ? last.artist : '',
            ),
          );
        }
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
    ct.throwIfCancelled();

    if (unreadable > 0) {
      WiretuneLog.warn(
        'MetadataScanner',
        '$unreadable of $total audio files could not be read and were skipped (details in the debug log).',
      );
    }
    return results;
  }

  /// The lyrics stored in the file's tag, or null when there are none or the file cannot be read.
  static Future<String?> readLyrics(String filePath) => _readLyricsInIsolate(filePath, WiretuneLog.isolateSettings);

  /// The embedded cover of [filePath], else a folder image next to it, else null.
  static Future<Uint8List?> extractCoverArt(String filePath) => _extractCoverInIsolate(filePath);

  /// The first file named like a cover ([folderCoverNames], ignoring case) in [directory].
  static String? findFolderCover(String? directory) => _firstNamed(directory, folderCoverNames);

  /// The artists' own pictures in [musicFolder], by artist ID: an [artistPictureNames] file in a folder named after the
  /// artist (ignoring case), directly in the music folder or holding their songs or their albums' folders. They take
  /// the place of the pictures found online. The artists looked for are those of [tracks], whose folders are searched.
  static Map<String, String> findArtistPictures(String musicFolder, Iterable<Track> tracks) {
    if (musicFolder.isEmpty) return const {};
    final wanted = <String>{};
    final folders = <String>{};
    try {
      for (final entity in Directory(musicFolder).listSync(followLinks: false)) {
        if (entity is Directory) folders.add(entity.path);
      }
    } catch (_) {
      // Unreadable or gone: only the tracks' folders, then.
    }
    for (final track in tracks) {
      for (final name in [...track.artistNames, ...track.albumArtistNames]) {
        wanted.add(name.trim().toLowerCase());
      }
      if (track.filePath.isEmpty) continue;
      final folder = p.dirname(track.filePath);
      folders
        ..add(folder)
        ..add(p.dirname(folder));
    }
    final pictures = <String, String>{};
    for (final folder in folders) {
      final name = p.basename(folder).trim().toLowerCase();
      if (!wanted.contains(name) || !p.isWithin(musicFolder, folder)) continue;
      final id = stableId(name);
      if (pictures.containsKey(id)) continue;
      if (_firstNamed(folder, artistPictureNames) case final picture?) pictures[id] = picture;
    }
    return pictures;
  }

  /// The first file in [directory] with one of [names] (lower case), ignoring case.
  static String? _firstNamed(String? directory, List<String> names) {
    if (directory == null || directory.isEmpty) return null;
    try {
      final byName = <String, String>{};
      for (final entity in Directory(directory).listSync(followLinks: false)) {
        if (entity is File) byName.putIfAbsent(p.basename(entity.path).toLowerCase(), () => entity.path);
      }
      for (final name in names) {
        final match = byName[name];
        if (match != null) return match;
      }
    } catch (_) {
      // Unreadable directory: no such file.
    }
    return null;
  }
}

// ── Isolate side ────────────────────────────────────────────────────────────────────────────────────────
// Every Isolate.run starts from a top-level function: a closure made inside a method captures that method's whole
// context, and with it objects (completers, callbacks) that cannot be sent to another isolate.

typedef _LogSettings = (String?, LogLevel, bool);

Future<List<String>> _enumerateInIsolate(String root, String? skip) =>
    Isolate.run(() => _enumerateAudioFiles(root, skip));

Future<List<Object?>> _scanBatchInIsolate(
  List<String> batch,
  Map<String, _Known> known,
  String? coverCacheDirectory,
  _LogSettings log,
) => Isolate.run(() {
  WiretuneLog.adoptIsolateSettings(log);
  return _scanBatch(batch, known, coverCacheDirectory);
});

Future<String?> _readLyricsInIsolate(String filePath, _LogSettings log) => Isolate.run(() {
  WiretuneLog.adoptIsolateSettings(log);
  if (!File(filePath).existsSync()) return null;
  try {
    final lyrics = TagReader.readLyrics(filePath)?.trim();
    if (lyrics == null || lyrics.isEmpty) return null;
    return lyrics.length > MetadataScanner._maxLyricsLength
        ? lyrics.substring(0, MetadataScanner._maxLyricsLength)
        : lyrics;
  } catch (e) {
    WiretuneLog.debug('MetadataScanner', "Cannot read lyrics of '$filePath': $e");
    return null;
  }
});

Future<Uint8List?> _extractCoverInIsolate(String filePath) => Isolate.run(() {
  if (!File(filePath).existsSync()) return null;
  try {
    final data = TagReader.readPicture(filePath);
    if (data != null && data.isNotEmpty) return data;
  } catch (_) {
    // Unreadable tags: fall back to a folder image below.
  }
  final folderCover = MetadataScanner.findFolderCover(p.dirname(filePath));
  try {
    return folderCover == null ? null : File(folderCover).readAsBytesSync();
  } catch (_) {
    // Unreadable, or gone since it was found: no cover.
    return null;
  }
});

List<String> _enumerateAudioFiles(String root, String? skip) {
  final files = <String>[];
  final skipped = skip == null ? null : AppPaths.comparable(AppPaths.fullPath(skip));
  final pending = <Directory>[Directory(AppPaths.fullPath(root))];
  while (pending.isNotEmpty) {
    final directory = pending.removeLast();
    List<FileSystemEntity> entries;
    try {
      entries = directory.listSync(followLinks: false);
    } catch (_) {
      continue; // inaccessible
    }
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (name.startsWith('.')) continue; // hidden
      if (entry is Directory) {
        if (AppPaths.comparable(entry.path) != skipped) pending.add(entry);
      } else if (entry is File && AudioFileTypes.isSupported(name)) {
        files.add(entry.path);
      } else if (entry is Link) {
        try {
          final target = File(entry.path).resolveSymbolicLinksSync();
          if (!AppPaths.isPathUnderRoot(target, root)) continue;
          final type = FileSystemEntity.typeSync(entry.path);
          if (type == FileSystemEntityType.file && AudioFileTypes.isSupported(name)) files.add(entry.path);
        } on FileSystemException catch (e) {
          // A link to nowhere, or one that may not be followed: the rest of the folder still counts.
          WiretuneLog.debug('MetadataScanner', "Skipping the link '${entry.path}': ${e.message}");
        }
      }
    }
  }
  files.sort();
  return files;
}

/// For each file of [batch]: `true` when the known track can be reused, a [Track] when the file was read, or null.
List<Object?> _scanBatch(List<String> batch, Map<String, _Known> known, String? coverCacheDirectory) {
  final folderCovers = <String, String?>{};
  return [
    for (final file in batch)
      _tryReuse(file, known[file], folderCovers)
          ? true
          : _readTrack(file, coverCacheDirectory, folderCovers, known[file]?.added),
  ];
}

/// Whether the known track of [file] still stands: the file is unchanged, and so is its cover. A picture cached from
/// the file must still be there; a folder image may have been added, replaced or taken away next to the file since (an
/// address, the cover a server lent the track, counts as none of its own).
bool _tryReuse(String file, _Known? known, Map<String, String?> folderCovers) {
  if (known == null || known.modifiedMicros == null) return false;
  try {
    final stat = File(file).statSync();
    if (stat.size != known.size || stat.modified.toUtc().microsecondsSinceEpoch != known.modifiedMicros) return false;
  } catch (_) {
    return false;
  }
  final cover = known.coverPath ?? '';
  final ownCover = cover.isNotEmpty && !cover.contains('://');
  final directory = p.dirname(file);
  if (ownCover && p.dirname(cover) != directory) return File(cover).existsSync();
  final folderCover = folderCovers.putIfAbsent(directory, () => MetadataScanner.findFolderCover(directory));
  return (folderCover ?? '') == (ownCover ? cover : '');
}

Track? _readTrack(
  String filePath,
  String? coverCacheDirectory,
  Map<String, String?> folderCoverCache,
  DateTime? added,
) {
  try {
    if (!AudioFileTypes.isSupported(filePath)) return null;
    final file = File(filePath);
    if (!file.existsSync()) return null;

    final fullPath = AppPaths.fullPath(filePath);
    final stat = file.statSync();
    final source = ByteSource.open(fullPath);
    try {
      final tags = TagReader.readFrom(source, fullPath);
      if (tags == null) {
        WiretuneLog.debug('MetadataScanner', "Skipping unreadable file '$filePath': not a recognised audio file.");
        return null;
      }

      final title = cleanText(tags.title) ?? p.basenameWithoutExtension(fullPath);
      final albumArtist = cleanText(tags.albumArtist);
      final artist = cleanText(tags.artist) ?? albumArtist ?? Track.unknownArtist;
      final album = cleanText(tags.album) ?? Track.unknownAlbum;

      final (codec, isLossless) = AudioFileTypes.describe(fullPath, tags.codecDescription);
      var bitsPerSample = tags.bitsPerSample;
      if (bitsPerSample == 0 && isLossless) bitsPerSample = 16;
      if (!isLossless) bitsPerSample = 0;

      final format = AudioFormat(
        codec: codec,
        sampleRate: tags.sampleRate > 0 ? tags.sampleRate : 44100,
        bitsPerSample: bitsPerSample,
        channels: tags.channels > 0 ? tags.channels : 2,
        bitrateKbps: tags.bitrateKbps,
        isLossless: isLossless,
      );

      final directory = p.dirname(fullPath);
      final coverArtPath =
          _cacheEmbeddedCover(
            tags,
            source,
            coverCacheDirectory,
            albumArtist ?? tags.artists.firstOrNull ?? artist,
            album,
          ) ??
          folderCoverCache.putIfAbsent(directory, () => MetadataScanner.findFolderCover(directory));

      int? positive(int? value) => value != null && value > 0 ? value : null;
      return Track(
        id: MetadataScanner.computeTrackId(fullPath),
        title: title,
        artist: artist,
        artists: [for (final name in tags.artists) ?cleanText(name)],
        album: album,
        albumArtist: albumArtist,
        albumArtists: [for (final name in tags.albumArtists) ?cleanText(name)],
        trackNumber: positive(tags.track),
        trackCount: positive(tags.trackCount),
        discNumber: positive(tags.disc),
        releaseYear: positive(tags.year),
        bpm: positive(tags.bpm),
        genre: cleanText(tags.genre),
        duration: tags.duration,
        fileSizeBytes: stat.size,
        fileModifiedAt: stat.modified.toUtc(),
        filePath: fullPath,
        hasCoverArt: tags.hasPicture || coverArtPath != null,
        coverArtPath: coverArtPath,
        format: format,
        addedAt: added ?? DateTime.now().toUtc(),
      );
    } finally {
      source.close();
    }
  } catch (e) {
    WiretuneLog.debug('MetadataScanner', "Skipping unreadable file '$filePath': $e");
    return null;
  }
}

/// Writes the embedded picture to the cover cache (once per album and picture) and returns its path. The picture's size
/// is part of the name, so a new picture in the files gets a file of its own instead of the old one's.
String? _cacheEmbeddedCover(
  AudioTags tags,
  ByteSource source,
  String? cacheDirectory,
  String albumArtist,
  String album,
) {
  if (!tags.hasPicture || cacheDirectory == null || cacheDirectory.trim().isEmpty) return null;
  try {
    Directory(cacheDirectory).createSync(recursive: true);
    final size = tags.pictureData?.length ?? tags.pictureLocation?.length ?? 0;
    final stem = 'cover_${stableId('${albumArtist.toLowerCase()}\u001f${album.toLowerCase()}')}_$size';

    for (final extension in const ['.jpg', '.png']) {
      final existing = p.join(cacheDirectory, '$stem$extension');
      if (File(existing).existsSync()) return existing;
    }

    final data = tags.readPicture(source);
    if (data == null || data.isEmpty) return null;
    final path = p.join(cacheDirectory, '$stem${ImageFormat.isPng(data) ? '.png' : '.jpg'}');
    // Tracks of one album may be read in parallel: write to a unique temporary file and move it into place.
    final temp = '$path.${newId()}.tmp';
    File(temp).writeAsBytesSync(data, flush: true);
    if (File(path).existsSync()) {
      File(temp).deleteSync();
    } else {
      File(temp).renameSync(path);
    }
    return path;
  } catch (e) {
    WiretuneLog.debug('MetadataScanner', "Could not cache embedded cover for '$album': $e");
    return null;
  }
}

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
