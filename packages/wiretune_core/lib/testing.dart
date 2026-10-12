// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

/// Test doubles shared by the tests of the core, the server and the app: an in-memory repository, an audio driver
/// that plays nothing, a signed-in session, a remote-control hub, sample tracks and a WAV writer. Not used by any
/// shipped code.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'wiretune_core.dart';

/// Points the data directory at a fresh temporary folder (so no test touches the real profile) and silences the
/// console log. Returns the folder.
Directory useTempDataDirectory() {
  final dir = Directory.systemTemp.createTempSync('wiretune_test_');
  AppPaths.platformDataRoot = dir.path;
  WiretuneLog.writeToConsole = false;
  return dir;
}

/// An in-memory repository: the library service's storage without SQLite.
class MockRepository extends LibraryRepository {
  final List<Track> tracks = [];
  final List<Playlist> playlists = [];
  final Map<String, String> settings = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<List<Track>> getAllTracks() async => [for (final t in tracks) copyTrack(t)];

  /// Seeds stored tracks.
  void saveTracks(Iterable<Track> list) => tracks.addAll(list);

  @override
  Future<void> replaceAllTracks(Iterable<Track> tracks) async {
    final copy = tracks.toList();
    this.tracks
      ..clear()
      ..addAll(copy);
  }

  @override
  Future<void> updateTrackFavorite(String trackId, DateTime? favoritedAt) async {
    for (final t in tracks.where((t) => t.id == trackId)) {
      t
        ..isFavorite = favoritedAt != null
        ..favoritedAt = favoritedAt;
    }
  }

  @override
  Future<void> incrementPlayCount(String trackId) async {
    for (final t in tracks.where((t) => t.id == trackId)) {
      t.playCount++;
    }
  }

  @override
  @override
  Future<List<Playlist>> getAllPlaylists() async => List.of(playlists);

  @override
  Future<void> savePlaylist(Playlist playlist) async {
    playlists
      ..removeWhere((p) => p.id == playlist.id)
      ..add(playlist);
  }

  @override
  Future<void> deletePlaylist(String playlistId) async => playlists.removeWhere((p) => p.id == playlistId);

  @override
  Future<void> deleteServerPlaylists() async => playlists.removeWhere((p) => p.isServer);

  @override
  Future<String?> getSetting(String key, [String? defaultValue]) async => settings[key] ?? defaultValue;

  @override
  Future<void> setSetting(String key, String value) async => settings[key] = value;

  @override
  Future<String> getOrAddSetting(String key, String Function() createValue) async =>
      settings.putIfAbsent(key, createValue);

  final Map<String, Map<String, Set<String>>> _hidden = {};

  @override
  Future<Map<String, Set<String>>> getHiddenItems([String userId = 'local']) async {
    final userMap = _hidden.putIfAbsent(userId, () => {'artist': <String>{}, 'album': <String>{}, 'track': <String>{}});
    return {
      'artist': Set<String>.from(userMap['artist'] ?? const {}),
      'album': Set<String>.from(userMap['album'] ?? const {}),
      'track': Set<String>.from(userMap['track'] ?? const {}),
    };
  }

  @override
  Future<void> setHiddenItem(String itemType, String itemId, bool hidden, [String userId = 'local']) async {
    final userMap = _hidden.putIfAbsent(userId, () => {'artist': <String>{}, 'album': <String>{}, 'track': <String>{}});
    final set = userMap.putIfAbsent(itemType, () => <String>{});
    if (hidden) {
      set.add(itemId);
    } else {
      set.remove(itemId);
    }
  }

  @override
  Future<void> replaceHiddenItems(
    String userId, {
    required Iterable<String> artists,
    required Iterable<String> albums,
    required Iterable<String> tracks,
  }) async {
    _hidden[userId] = {'artist': artists.toSet(), 'album': albums.toSet(), 'track': tracks.toSet()};
  }

  @override
  Future<void> clearHiddenItems([String userId = 'local']) async {
    _hidden.remove(userId);
  }

  final Map<String, (String, String)> downloads = {};

  @override
  Future<Map<String, (String version, String path)>> getDownloads() async => Map.of(downloads);

  @override
  Future<void> saveDownload(String trackId, String version, String path) async => downloads[trackId] = (version, path);

  @override
  Future<void> deleteDownload(String trackId) async => downloads.remove(trackId);
}

Track copyTrack(Track t) => Track(
  id: t.id,
  title: t.title,
  artist: t.artist,
  album: t.album,
  albumArtist: t.albumArtist,
  trackNumber: t.trackNumber,
  trackCount: t.trackCount,
  discNumber: t.discNumber,
  year: t.year,
  genre: t.genre,
  duration: t.duration,
  fileSizeBytes: t.fileSizeBytes,
  fileModifiedUtc: t.fileModifiedUtc,
  filePath: t.filePath,
  streamUrl: t.streamUrl,
  hasCoverArt: t.hasCoverArt,
  coverArtPath: t.coverArtPath,
  format: t.format,
  dateAdded: t.dateAdded,
  isFavorite: t.isFavorite,
  favoritedAt: t.favoritedAt,
  playCount: t.playCount,
  lastPlayed: t.lastPlayed,
);

/// An audio driver that plays nothing, so engine and player tests never touch audio hardware.
class FakeAudioDriver with AudioDriverEvents implements AudioDriver {
  FakeAudioDriver({this.devices});

  final List<AudioOutputDevice>? devices;

  @override
  PlaybackState state = PlaybackState.stopped;

  @override
  Duration currentPosition = Duration.zero;

  double volume = 1.0;
  String? lastSource;
  int playCalls = 0;
  AudioOutputDevice? device;
  bool isExclusive = false;
  bool isBitperfect = false;

  @override
  Future<List<AudioOutputDevice>> detectDevices() async => devices ?? [TestSupport.capableDevice];

  @override
  Future<void> initialize(AudioOutputDevice device, {required bool exclusive, required bool bitperfect}) async {
    this.device = device;
    isExclusive = exclusive;
    isBitperfect = bitperfect;
  }

  @override
  Future<void> play(String audioSource, AudioFormat format, Duration startPosition) async {
    playCalls++;
    lastSource = audioSource;
    currentPosition = startPosition;
    _setState(PlaybackState.playing);
  }

  @override
  Future<void> pause() async {
    if (state == PlaybackState.playing) _setState(PlaybackState.paused);
  }

  @override
  Future<void> resume() async {
    if (state == PlaybackState.paused) _setState(PlaybackState.playing);
  }

  @override
  Future<void> seek(Duration position) async {
    currentPosition = position;
    positionChanged.emit(position);
  }

  @override
  Future<void> stop() async {
    currentPosition = Duration.zero;
    _setState(PlaybackState.stopped);
  }

  @override
  void setVolume(double volume) => this.volume = volume;

  void simulateTrackEnded() {
    _setState(PlaybackState.stopped);
    trackEnded.emit(null);
  }

  void simulateFailure(String message) {
    _setState(PlaybackState.error);
    playbackFailed.emit(message);
  }

  void simulateSpectrum(List<double> bands) => spectrumDataAvailable.emit(Float32List.fromList(bands));

  void _setState(PlaybackState newState) {
    if (state == newState) return;
    state = newState;
    stateChanged.emit(newState);
  }

  @override
  Future<void> dispose() async {}
}

abstract final class TestSupport {
  static const AudioOutputDevice capableDevice = AudioOutputDevice(
    id: 'hw:1,0',
    name: 'Test USB DAC',
    driverType: 'ALSA Direct',
    isDefault: true,
    isExclusiveSupported: true,
    isBitperfectSupported: true,
  );

  static const AudioOutputDevice sharedOnlyDevice = AudioOutputDevice(
    id: 'wasapi_default',
    name: 'Shared output',
    driverType: 'WASAPI Shared',
    isDefault: true,
  );

  static WiretuneAudioEngine createEngine([FakeAudioDriver? driver, List<AudioOutputDevice>? devices]) {
    final list = devices ?? [capableDevice];
    return WiretuneAudioEngine(driver ?? FakeAudioDriver(), deviceDetector: () async => list);
  }

  static Track makeTrack(
    String id,
    String title, {
    String artist = 'Artist',
    String album = 'Album',
    int sampleRate = 44100,
    int bits = 16,
    int trackNumber = 1,
    double minutes = 4.0,
    String? albumArtist,
  }) => Track(
    id: id,
    title: title,
    artist: artist,
    album: album,
    albumArtist: albumArtist,
    trackNumber: trackNumber,
    duration: Duration(microseconds: (minutes * 60 * 1000000).round()),
    filePath: '/music/$id.flac',
    format: AudioFormat(codec: 'FLAC', sampleRate: sampleRate, bitsPerSample: bits, isLossless: true),
  );

  static Track makeServerTrack(
    String id,
    String title, {
    String artist = 'Artist',
    String album = 'Album',
    double minutes = 4.0,
  }) {
    return makeTrack(id, title, artist: artist, album: album, minutes: minutes)
      ..filePath = ''
      ..streamUrl = 'http://server/api/stream/$id';
  }
}

/// Writes a 16-bit stereo PCM WAV file with a 440 Hz tone.
void writeWav(String path, int sampleRate, {double seconds = 1.0}) {
  File(path).parent.createSync(recursive: true);
  final frames = (sampleRate * seconds).toInt();
  const channels = 2, bits = 16;
  final dataSize = frames * channels * bits ~/ 8;
  final data = ByteData(44 + dataSize);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      data.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + dataSize, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * channels * bits ~/ 8, Endian.little);
  data.setUint16(32, channels * bits ~/ 8, Endian.little);
  data.setUint16(34, bits, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < frames; i++) {
    final sample = (8000 * math.sin(2 * math.pi * 440 * i / sampleRate)).round();
    data.setInt16(44 + i * 4, sample, Endian.little);
    data.setInt16(46 + i * 4, sample, Endian.little);
  }
  File(path).writeAsBytesSync(data.buffer.asUint8List());
}

/// True when [tool] can be started (tests that need it are skipped without it).
bool hasTool(String tool) {
  try {
    return Process.runSync(tool, ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// A session signed in to a server that answers just enough for that: no tracks of its own unless [tracks] are given,
/// an account with nothing in it. Its token is "sign-in-token"; [serverUrl] is the address the session believes in, and
/// [respond] may answer any request in place of that stand-in.
Future<ServerSession> signedInSession(
  LibraryService library, {
  List<Track> tracks = const [],
  String serverUrl = 'http://server:5200',
  http.Response? Function(http.Request request)? respond,
}) async {
  final user = UserInfo('user-1', 'owner', true, DateTime.utc(2026), null);
  final client = MockClient((request) async {
    // A test's own answer for a request comes first; null leaves it to the stand-in below.
    final own = respond?.call(request);
    if (own != null) return own;
    final body = switch (request.url.path) {
      '/api/auth/setup-required' => {'setupRequired': false},
      '/api/auth/login' => AuthResponse('sign-in-token', user, DateTime.utc(2099)).toJson(),
      '/api/auth/me' => user.toJson(),
      '/api/tracks' => [for (final t in tracks) t.toJson()],
      '/api/me/data' => const UserDataSnapshot([], [], []).toJson(),
      _ => <String, Object?>{},
    };
    return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
  });
  final session = ServerSession(library, MockRepository(), ServerStreamingClient(client));
  await session.initialize();
  await session.connect(serverUrl);
  final error = await session.login('owner', 'password', false);
  if (error != null) throw StateError('signing in failed: $error');
  return session;
}

/// The server's remote-control hub as one player sees it: what the player sent, and messages for it. Pass [connect] as
/// the [RemoteClient]'s connector.
class FakeRemoteHub {
  final List<Map<String, Object?>> sent = [];
  StreamController<Object?>? _incoming;
  int connections = 0;

  Future<RemoteChannel> connect(Uri uri, String token) async {
    connections++;
    final incoming = _incoming = StreamController<Object?>();
    return RemoteChannel(
      messages: incoming.stream,
      send: (text) => sent.add((jsonDecode(text) as Map).cast<String, Object?>()),
      close: () => incoming.close(),
      closeCode: () => null,
    );
  }

  /// Hands the player a message, as the server would.
  void deliver(Map<String, Object?> message) => _incoming!.add(jsonEncode(message));

  /// Hands the player a frame as it is, which a real server would never send.
  void deliverRaw(Object? frame) => _incoming!.add(frame);

  /// The other devices of the account that are online: (id, name, kind).
  void devices(List<(String, String, DeviceKind)> devices) => deliver({
    'type': 'devices',
    'devices': [
      for (final (id, name, kind) in devices) {'id': id, 'name': name, 'kind': kind.name},
    ],
  });

  void state(String device, RemotePlayback playback) =>
      deliver({'type': 'state', 'device': device, 'state': playback.toJson()});

  void command(String from, RemoteCommand command) =>
      deliver({'type': 'command', 'from': from, 'command': command.toJson()});

  /// Ends the connection the way a network failure does.
  Future<void> drop() => _incoming!.close();

  Iterable<Map<String, Object?>> ofType(String type) => sent.where((m) => m['type'] == type);

  /// The command objects sent to [device], in order.
  List<Object?> commandsTo(String device) => [
    for (final m in ofType('command'))
      if (m['to'] == device) m['command'],
  ];
}
