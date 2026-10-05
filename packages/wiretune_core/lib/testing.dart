/// Test doubles shared by the tests of the core, the server and the app: an in-memory repository, an audio driver
/// that plays nothing, sample tracks and a WAV writer. Not used by any shipped code.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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
  Future<void> updateTrackFavorite(String trackId, bool isFavorite) async {
    for (final t in tracks.where((t) => t.id == trackId)) {
      t.isFavorite = isFavorite;
    }
  }

  @override
  Future<void> incrementPlayCount(String trackId) async {
    for (final t in tracks.where((t) => t.id == trackId)) {
      t.playCount++;
    }
  }

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
