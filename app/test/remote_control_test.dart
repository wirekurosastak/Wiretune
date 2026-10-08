// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:audio_service/audio_service.dart' show AudioServiceRepeatMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/audio/media_session.dart';
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune/src/view_models/player_view_model.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Remote control from the player's side: it shows and commands another device of the account, tells the others what
/// it plays itself, does what they ask of it, and hands music over either way.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  late FakeAudioDriver driver;
  late List<Track> tracks;
  late FakeRemoteHub hub;
  late MainViewModel vm;
  late PlayerViewModel player;

  setUp(() async {
    driver = FakeAudioDriver();
    tracks = [for (var i = 1; i <= 4; i++) TestSupport.makeTrack('t$i', 'Song $i', trackNumber: i)];
    final library = createLibrary(tracks);
    await library.initialize();
    final session = await signedInSession(library);
    hub = FakeRemoteHub();
    final remote = RemoteClient(session, connector: hub.connect);
    vm = createMainViewModel(library, TestSupport.createEngine(driver), session, remote);
    player = vm.player;
    tracks = library.tracks; // the library's own instances
    remote.configure(id: 'phone-id', name: 'Phone', kind: DeviceKind.phone, enabled: true);
    expect(await waitUntil(() => remote.isConnected), isTrue);
    hub.devices([('desk', 'Desk', DeviceKind.desktop)]);
    await pumpEventQueue();
  });
  tearDown(() => vm.dispose());

  RemotePlayback deskPlaying(int index, Duration at, {bool playing = true}) => RemotePlayback(
    track: tracks[index],
    playing: playing,
    position: at,
    volume: 70,
    shuffle: true,
    repeat: RepeatMode.all,
    queue: [for (final t in tracks.take(3)) t.id],
    queueIndex: index,
  );

  test("another device's playback is shown, and the controls command it instead of playing here", () async {
    hub.state('desk', deskPlaying(1, const Duration(seconds: 30)));
    await pumpEventQueue();
    expect(player.otherDevices.single.name, 'Desk');

    player.selectDevice('desk');
    expect((player.isRemote, player.remoteDeviceName), (true, 'Desk'));
    expect(player.currentTrack, same(tracks[1]), reason: "this library's copy, with its cover and its lyrics");
    expect(tracks[1].isPlaying, isTrue, reason: 'the lists highlight what plays there');
    expect((player.isPlaying, player.volume, player.isShuffle, player.repeatMode), (true, 70.0, true, RepeatMode.all));
    expect(player.position.value.inMilliseconds, inInclusiveRange(30000, 31000));
    expect([for (final item in player.queueItems) item.track.title], ['Song 1', 'Song 2', 'Song 3']);
    expect((player.currentQueueIndex, player.canEditQueue), (1, true));

    player.nextTrack();
    await player.togglePlayPause();
    player.toggleRepeat();
    player.setShuffle(false);
    player
      ..setVolume(20)
      ..setVolume(25);
    expect(player.volume, 25, reason: 'the slider follows the finger');
    player.seekTo(const Duration(seconds: 90));
    expect(player.position.value, const Duration(seconds: 90));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    player.moveQueueTrack(0, 2);
    player.removeQueueTrack(player.queueItems[0].track);
    player.clearQueue();

    expect(hub.commandsTo('desk'), [
      {'action': 'next'},
      {'action': 'toggle'},
      {'action': 'repeat', 'repeat': 'one'},
      {'action': 'shuffle', 'on': false},
      {'action': 'volume', 'volume': 25.0},
      {'action': 'seek', 'positionMs': 90000},
      {'action': 'moveTrack', 'index': 0, 'toIndex': 2},
      {'action': 'removeTrack', 'index': 0},
      {'action': 'clearQueue'},
    ]);
    expect(driver.playCalls, 0);

    // The device moves on: its next state is what is shown.
    hub.state('desk', deskPlaying(2, Duration.zero, playing: false));
    await pumpEventQueue();
    expect(player.currentTrack, same(tracks[2]));
    expect((player.isPlaying, tracks[1].isPlaying, tracks[2].isPlaying), (false, false, true));

    // Back to this device, with nothing playing there: nothing moves, and this device's state is shown again.
    player.selectDevice(null);
    expect((player.isRemote, player.repeatMode), (false, RepeatMode.off));
    expect(player.currentTrack, isNull);
    expect(hub.commandsTo('desk'), hasLength(9));
  });

  test('this device tells the others what it plays, at changes only, and does what they ask', () async {
    player.playQueue(tracks, tracks[0]);
    await Future<void>.delayed(const Duration(milliseconds: 200)); // states go out at most every 150 ms
    Map<Object?, Object?> lastState() => hub.ofType('state').last['state'] as Map;
    expect(((lastState()['track'] as Map)['id'], lastState()['playing'], lastState()['queueIndex']), ('t1', true, 0));
    expect(lastState()['queue'], ['t1', 't2', 't3', 't4']);

    // Playing on at the pace of the clock is nothing to tell; a jump is.
    final told = hub.ofType('state').length;
    final clock = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      driver.currentPosition = clock.elapsed;
      driver.positionChanged.emit(clock.elapsed);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200)); // past the publishing interval
    expect(hub.ofType('state'), hasLength(told));
    await driver.seek(const Duration(minutes: 2));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hub.ofType('state'), hasLength(told + 1));
    expect(lastState()['positionMs'], 120000);

    // Commands from the desk run here.
    hub.command('desk', const RemoteCommand(RemoteAction.pause));
    await pumpEventQueue();
    expect(driver.state, PlaybackState.paused);
    hub.command('desk', const RemoteCommand(RemoteAction.volume, volume: 40));
    await pumpEventQueue();
    expect((player.volume, driver.volume), (40.0, 0.4));
    hub.command(
      'desk',
      const RemoteCommand(
        RemoteAction.playTracks,
        trackIds: ['unknown', 't3', 't4'],
        index: 2,
        position: Duration(seconds: 15),
      ),
    );
    await pumpEventQueue();
    expect([for (final t in player.queueTracks) t.id], ['t3', 't4']);
    expect((driver.lastSource, driver.currentPosition), (tracks[3].filePath, const Duration(seconds: 15)));

    // A device the server never announced is nobody.
    hub.command('stranger', const RemoteCommand(RemoteAction.stop));
    await pumpEventQueue();
    expect(driver.state, PlaybackState.playing);
  });

  test('choosing another device while music plays moves the music there; coming back takes it over again', () async {
    player.playQueue(tracks, tracks[1]);
    await driver.seek(const Duration(seconds: 30));
    await pumpEventQueue();

    player.selectDevice('desk');
    expect(hub.commandsTo('desk').single, {
      'action': 'playTracks',
      'positionMs': 30000,
      'trackIds': ['t1', 't2', 't3', 't4'],
      'index': 1,
    });
    await pumpEventQueue();
    expect(driver.state, PlaybackState.paused);
    expect(player.isRemote, isTrue);

    // The desk took it and has moved on to the third track by now.
    hub.state('desk', deskPlaying(2, const Duration(seconds: 60)));
    await pumpEventQueue();
    player.selectDevice(null);
    expect(hub.commandsTo('desk').last, {'action': 'pause'});
    await pumpEventQueue();
    expect(player.currentTrack, same(tracks[2]));
    expect((player.isRemote, driver.lastSource), (false, tracks[2].filePath));
    expect(driver.currentPosition.inMilliseconds, inInclusiveRange(60000, 61000));
    expect([for (final t in player.queueTracks) t.id], ['t1', 't2', 't3']);
  });

  test('a device that stays out of reach gives control back here, with a word about it', () async {
    final grace = PlayerViewModel.remoteGrace;
    PlayerViewModel.remoteGrace = const Duration(milliseconds: 300);
    addTearDown(() => PlayerViewModel.remoteGrace = grace);
    hub.state('desk', deskPlaying(0, Duration.zero));
    await pumpEventQueue();
    player.selectDevice('desk');

    await hub.drop();
    await pumpEventQueue();
    expect(player.isRemote, isTrue, reason: 'a dropped connection gets a moment to come back');
    expect(player.currentTrack, same(tracks[0]), reason: 'meanwhile the last known state stays');

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(player.isRemote, isFalse);
    expect(player.errorMessage, 'Desk can no longer be reached: back to this device.');
  });

  test("the system's repeat control sets the other device's mode with one command", () async {
    hub.state('desk', deskPlaying(0, Duration.zero));
    await pumpEventQueue();
    player.selectDevice('desk');
    final session = WiretuneMediaSession(vm);
    addTearDown(session.playbackState.close);
    // Stepping through the modes until the player shows the wanted one would never end: the device answers later.
    await session.setRepeatMode(AudioServiceRepeatMode.one);
    expect(hub.commandsTo('desk'), [
      {'action': 'repeat', 'repeat': 'one'},
    ]);
  });

  test('signing out stops controlling the other device, and so does turning remote control off', () async {
    hub.state('desk', deskPlaying(0, Duration.zero));
    await pumpEventQueue();
    player.selectDevice('desk');
    vm.isRemoteEnabled = false;
    expect((player.isRemote, vm.remote.isConnected), (false, false));
    expect(hub.commandsTo('desk'), isEmpty, reason: 'the music there is left as it is');

    vm.isRemoteEnabled = true;
    expect(await waitUntil(() => vm.remote.isConnected), isTrue);
    hub.devices([('desk', 'Desk', DeviceKind.desktop)]);
    await pumpEventQueue();
    player.selectDevice('desk');
    await vm.logout();
    expect((player.isRemote, vm.remote.isConnected), (false, false));
  });
}
