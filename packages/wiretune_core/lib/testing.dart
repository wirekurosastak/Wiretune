// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

/// Test doubles shared by the tests of the core, the server and the app: a repository on a throw-away database, an
/// audio driver that plays nothing, a signed-in session, a remote-control hub, sample tracks and a WAV writer. Not used
/// by any shipped code.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'wiretune_core.dart';

/// Points the data directory at a fresh temporary folder (so no test touches the real profile) and silences the
/// console log. Returns the folder.
Directory useTempDataDirectory() {
  final dir = Directory.systemTemp.createTempSync('wiretune_test_');
  AppPaths.platformDataRoot = dir.path;
  WiretuneLog.writeToConsole = false;
  // The log stays open until the tests end: outside the folder, which a test may delete (Windows can't delete it open).
  WiretuneLog.initialize(path: p.join(Directory.systemTemp.path, 'wiretune_test.log'));
  return dir;
}

/// A repository on a database file of its own in the temporary folder, as the player keeps one.
LibraryRepository testRepository() {
  final folder = Directory.systemTemp.createTempSync('wiretune_db_');
  return LibraryRepository(DatabaseManager(p.join(folder.path, 'wiretune.db')))..initialize();
}

/// An audio driver that plays nothing, so engine and player tests never touch audio hardware.
class FakeAudioDriver with AudioDriverEvents implements AudioDriver {
  FakeAudioDriver({this.devices});

  final List<AudioOutputDevice>? devices;

  @override
  PlaybackState state = PlaybackState.stopped;

  @override
  Duration currentPosition = Duration.zero;

  double volume = 1.0;
  VolumeNormalization normalization = VolumeNormalization.off;
  String? lastSource;

  /// What [setNext] was given and a new [play] has not dropped.
  String? nextSource;
  int playCalls = 0;
  AudioOutputDevice? device;
  bool isExclusive = false;
  bool isBitPerfect = false;

  @override
  Future<List<AudioOutputDevice>> detectDevices() async => devices ?? [TestSupport.capableDevice];

  @override
  Future<void> initialize(AudioOutputDevice device, {required bool exclusive, required bool bitPerfect}) async {
    this.device = device;
    isExclusive = exclusive;
    isBitPerfect = bitPerfect;
  }

  @override
  Future<void> play(String audioSource, AudioFormat format, Duration startPosition) async {
    playCalls++;
    lastSource = audioSource;
    nextSource = null;
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

  @override
  void setNormalization(VolumeNormalization mode) => normalization = mode;

  @override
  Future<void> setNext(String? audioSource) async => nextSource = audioSource;

  /// The track ends and the next one given takes over without a gap, as mpv does; without one it just ends.
  void simulateGaplessEnd() {
    final next = nextSource;
    if (next == null) return simulateTrackEnded();
    lastSource = next;
    nextSource = null;
    currentPosition = Duration.zero;
    advanced.emit(null);
  }

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
    isBitPerfectSupported: true,
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
    int? discNumber,
    double minutes = 4.0,
    String? albumArtist,
  }) => Track(
    id: id,
    title: title,
    artist: artist,
    album: album,
    albumArtist: albumArtist,
    trackNumber: trackNumber,
    discNumber: discNumber,
    duration: Duration(microseconds: (minutes * 60 * 1000000).round()),
    filePath: '/music/$id.flac',
    format: AudioFormat(codec: 'FLAC', sampleRate: sampleRate, bitsPerSample: bits, isLossless: true),
  );

  static Track makeServerTrack(
    String id,
    String title, {
    String artist = 'Artist',
    String album = 'Album',
    String? albumArtist,
    int trackNumber = 1,
    int? discNumber,
    double minutes = 4.0,
  }) {
    return makeTrack(
        id,
        title,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
        trackNumber: trackNumber,
        discNumber: discNumber,
        minutes: minutes,
      )
      ..filePath = ''
      ..streamUrl = 'http://server/api/stream/$id';
  }
}

/// Writes a 16-bit stereo PCM WAV file with a 440 Hz tone; with [picture], that as its embedded cover, and with
/// [artist] that as its artist (an ID3 tag).
void writeWav(String path, int sampleRate, {double seconds = 1.0, List<int>? picture, String? artist}) {
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
  if (picture == null && artist == null) return File(path).writeAsBytesSync(data.buffer.asUint8List());

  // An `id3 ` chunk holding an ID3v2.3 tag: an APIC frame with the front cover, a TPE1 frame with the artist.
  List<int> frame(String id, List<int> body) => [
    ...latin1.encode(id),
    ..._bigEndian(body.length + 1),
    0,
    0,
    0,
    ...body,
  ];
  final tag = [
    if (picture != null) ...frame('APIC', [...latin1.encode('image/png'), 0, 3, 0, ...picture]),
    if (artist != null) ...frame('TPE1', latin1.encode(artist)),
  ];
  final id3 = [...latin1.encode('ID3'), 3, 0, 0, ..._syncSafe(tag.length), ...tag];
  final chunk = [...latin1.encode('id3 '), ..._littleEndian(id3.length), ...id3, if (id3.length.isOdd) 0];
  final bytes = [...data.buffer.asUint8List(), ...chunk];
  bytes.setRange(4, 8, _littleEndian(bytes.length - 8));
  File(path).writeAsBytesSync(bytes);
}

List<int> _bigEndian(int value) => [for (var shift = 24; shift >= 0; shift -= 8) (value >> shift) & 0xFF];

List<int> _littleEndian(int value) => [for (var shift = 0; shift < 32; shift += 8) (value >> shift) & 0xFF];

List<int> _syncSafe(int value) => [for (var shift = 21; shift >= 0; shift -= 7) (value >> shift) & 0x7F];

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
  final session = ServerSession(library, testRepository(), ServerClient(client));
  session.initialize();
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
