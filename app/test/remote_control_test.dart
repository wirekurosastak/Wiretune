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
    library.initialize();
    final session = await signedInSession(library);
    hub = FakeRemoteHub();
    final remote = RemoteClient(session, connector: hub.connect);
    vm = createMainViewModel(library, TestSupport.createEngine(driver), session, remote);
    player = vm.player;
    tracks = library.tracks; // the library's own instances
    remote.configure(id: 'phone-id', name: 'Phone', kind: DeviceKind.phone, enabled: true);
    await until(() => remote.isConnected);
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
    expect(player.isCurrent(tracks[1]), isTrue, reason: 'the lists highlight what plays there');
    expect((player.isPlaying, player.volume, player.isShuffle, player.repeatMode), (true, 70.0, true, RepeatMode.all));
    expect(player.position.value.inMilliseconds, inInclusiveRange(30000, 31000));
    expect([for (final item in player.queueItems) item.track.title], ['Song 1', 'Song 2', 'Song 3']);
    expect(player.currentQueueIndex, 1);

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
    player.removeQueueItem(player.queueItems[0]);
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
    expect((player.isPlaying, player.isCurrent(tracks[1]), player.isCurrent(tracks[2])), (false, false, true));

    // Back to this device, with nothing playing there: nothing moves, and this device's state is shown again.
    player.selectDevice(null);
    expect((player.isRemote, player.repeatMode), (false, RepeatMode.off));
    expect(player.currentTrack, isNull);
    expect(hub.commandsTo('desk'), hasLength(9));
  });

  test("another device's queue is edited by its own places, also around tracks this library doesn't know", () async {
    // The desk plays a file of its own between the shared ones: the phone lists Song 1, 2 and 3 only.
    hub.state(
      'desk',
      RemotePlayback(
        track: tracks[1],
        playing: true,
        position: Duration.zero,
        volume: 70,
        shuffle: false,
        repeat: RepeatMode.off,
        queue: [tracks[0].id, 'desk-only', tracks[1].id, tracks[2].id],
        queueIndex: 2,
      ),
    );
    await pumpEventQueue();
    player.selectDevice('desk');
    expect([for (final item in player.queueItems) item.track.title], ['Song 1', 'Song 2', 'Song 3']);

    player.removeQueueItem(player.queueItems[2]); // Song 3: the desk's fourth
    player.moveQueueTrackUp(player.queueItems[1]); // Song 2 above Song 1
    player.moveQueueTrack(0, 1); // and back below it, by dragging

    expect([for (final item in player.queueItems) item.track.title], ['Song 1', 'Song 2']);
    expect(hub.commandsTo('desk'), [
      {'action': 'removeTrack', 'index': 3},
      {'action': 'moveTrack', 'index': 2, 'toIndex': 0},
      {'action': 'moveTrack', 'index': 0, 'toIndex': 1},
    ]);
  });

  test('play next and add to queue go to the device being controlled, and are done when asked of this one', () async {
    hub.state('desk', deskPlaying(0, Duration.zero));
    await pumpEventQueue();
    player.selectDevice('desk');
    player.playNext([tracks[3]]);
    player.addToQueue([tracks[2], tracks[3]]);
    expect(hub.commandsTo('desk'), [
      {
        'action': 'playNext',
        'trackIds': ['t4'],
      },
      {
        'action': 'addToQueue',
        'trackIds': ['t3', 't4'],
      },
    ]);
    expect(driver.playCalls, 0);

    player.selectDevice(null);
    player.playQueue(tracks.take(2), tracks[0]);
    hub.command('desk', const RemoteCommand(RemoteAction.playNext, trackIds: ['t4', 'not-here']));
    hub.command('desk', const RemoteCommand(RemoteAction.addToQueue, trackIds: ['t3']));
    await pumpEventQueue();
    expect([for (final t in player.queueTracks) t.id], ['t1', 't4', 't2', 't3']);
  });

  test('this device tells the others what it plays, at changes only, and does what they ask', () async {
    player.playQueue(tracks, tracks[0]);
    Map<Object?, Object?> lastState() => hub.ofType('state').last['state'] as Map;
    await until(() => hub.ofType('state').isNotEmpty && lastState()['playing'] == true);
    await Future<void>.delayed(const Duration(milliseconds: 200)); // states go out at most every 150 ms
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
    await until(() => hub.ofType('state').length > told);
    expect(hub.ofType('state'), hasLength(told + 1));
    expect(lastState()['positionMs'], 120000);

    // Commands from the desk run here.
    hub.command('desk', const RemoteCommand(RemoteAction.pause));
    await pumpEventQueue();
    expect(driver.state, PlaybackState.paused);
    player.toggleMute();
    hub.command('desk', const RemoteCommand(RemoteAction.volume, volume: 40));
    await pumpEventQueue();
    expect((player.volume, player.isMuted, driver.volume), (40.0, false, 0.4), reason: 'a volume set unmutes');
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

  test("a repeat mode another device asks for holds for the next track's gapless start too", () async {
    player.playQueue(tracks, tracks[0]);
    await pumpEventQueue();
    expect(driver.nextSource, tracks[1].filePath);
    hub.command('desk', const RemoteCommand(RemoteAction.repeat, repeat: RepeatMode.one));
    await pumpEventQueue();
    expect(driver.nextSource, tracks[0].filePath, reason: 'repeat one: the same track again');
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

    await until(() => !player.isRemote);
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
    await until(() => vm.remote.isConnected);
    hub.devices([('desk', 'Desk', DeviceKind.desktop)]);
    await pumpEventQueue();
    player.selectDevice('desk');
    await vm.logout();
    expect((player.isRemote, vm.remote.isConnected), (false, false));
  });

  test("a player lets the others play only music its account doesn't hide until another choice is saved", () async {
    final library = createLibrary();
    var fresh = createMainViewModel(library);
    await fresh.start();
    expect(fresh.deviceSharing, DeviceSharing.unhidden);
    fresh.deviceSharing = DeviceSharing.off;
    fresh.dispose();
    fresh = createMainViewModel(library);
    await fresh.start();
    expect(fresh.deviceSharing, DeviceSharing.off, reason: 'kept');
    fresh.dispose();
  });

  test('a phone lets nobody else play on it until another choice is saved', () async {
    final library = createLibrary();
    MainViewModel phone() => MainViewModel(
      TestSupport.createEngine(),
      library,
      ServerSession(library, testRepository()),
      capabilities: const DeviceCapabilities(kind: DeviceKind.phone),
    );
    var fresh = phone();
    await fresh.start();
    expect(fresh.deviceSharing, DeviceSharing.off);
    fresh.deviceSharing = DeviceSharing.unhidden;
    fresh.dispose();
    fresh = phone();
    await fresh.start();
    expect(fresh.deviceSharing, DeviceSharing.unhidden, reason: 'kept');
    fresh.dispose();
  });

  group('another account casting', () {
    const anna = AccountInfo('anna-id', 'anna');
    const annaPlays = RemoteCommand(RemoteAction.playTracks, trackIds: ['t1', 't2', 't3'], index: 0);

    test('plays here only while this player lets it, without what this account hides, and counts for anna', () async {
      final notices = <String>[];
      vm.notices.listen((notice) => notices.add(notice.message));
      vm.library.setHidden(HiddenKind.track, 't2', true);

      hub.command('anna-desk', annaPlays, account: anna);
      await pumpEventQueue();
      expect(driver.playCalls, 0, reason: 'off');

      vm.deviceSharing = DeviceSharing.unhidden;
      expect(vm.library.getPreference('remote_sharing'), 'unhidden');
      expect((hub.ofType('hello').last['device'] as Map)['sharing'], 'unhidden', reason: 'the server is told');
      hub.command('anna-desk', annaPlays, account: anna);
      await until(() => driver.playCalls > 0);
      expect([for (final t in player.queueTracks) t.id], ['t1', 't3'], reason: 'not what this account hides');
      expect((player.playingFor?.username, notices.last), ('anna', 'anna is playing here'));
      driver.simulatePlaying(const Duration(seconds: 30));
      expect(vm.library.playCount('t1'), 0, reason: "anna's player counts it");
      Map<Object?, Object?> lastState() => hub.ofType('state').last['state'] as Map;
      await until(() => lastState()['playingFor'] == 'anna-id');

      // Any music: the hidden track plays too.
      vm.deviceSharing = DeviceSharing.any;
      hub.command('anna-desk', annaPlays, account: anna);
      await pumpEventQueue();
      expect([for (final t in player.queueTracks) t.id], ['t1', 't2', 't3']);

      // This account's own music again: its plays count here, and nobody else's music is said to play.
      player.playQueue(tracks, tracks[3]);
      await pumpEventQueue();
      driver.simulatePlaying(const Duration(seconds: 30));
      expect((player.playingFor, vm.library.playCount('t4')), (null, 1));
      await until(() => !lastState().containsKey('playingFor'));
    });

    test("music cast to another account's player counts here, once per track that played for 30 seconds", () async {
      hub.devices([('desk', 'Desk', DeviceKind.desktop), ('anna-tv', 'TV', DeviceKind.tv)], others: {'anna-tv': anna});
      await pumpEventQueue();
      expect([for (final d in player.otherDevices) (d.id, d.account?.username)], [('desk', null), ('anna-tv', 'anna')]);
      player.selectDevice('anna-tv');

      RemotePlayback tv(int index, {String? playingFor = 'user-1', bool playing = true, int at = 31}) => RemotePlayback(
        track: tracks[index],
        playing: playing,
        position: Duration(seconds: at),
        queue: [for (final t in tracks) t.id],
        queueIndex: index,
        playingFor: playingFor,
      );
      hub.state('anna-tv', tv(0, at: 0)); // only begun: not yet
      await pumpEventQueue();
      expect(vm.library.playCount(tracks[0].id), 0);
      hub.state('anna-tv', tv(0));
      hub.state('anna-tv', tv(0)); // the same track, told again
      hub.state('anna-tv', tv(1, playing: false, at: 0)); // paused before it started: not yet
      hub.state('anna-tv', tv(1));
      hub.state('anna-tv', tv(2, playingFor: null)); // anna's own music
      hub.state('anna-tv', tv(3, playingFor: 'someone-else'));
      await pumpEventQueue();
      expect([for (final t in tracks) vm.library.playCount(t.id)], [1, 1, 0, 0]);
    });
  });

  test('a streamer on the network is played on like another device: the music moves there, its state shows', () async {
    final streamer = _FakeLocalDevice(RemoteDevice('upnp:uuid:1', 'Living room', DeviceKind.streamer));
    vm.remote.addLocal(streamer);
    await pumpEventQueue();
    expect([for (final d in player.otherDevices) d.id], ['desk', 'upnp:uuid:1']);

    player.playQueue(tracks, tracks[1]);
    await until(() => driver.state == PlaybackState.playing);
    player.selectDevice('upnp:uuid:1');
    await pumpEventQueue();
    expect(streamer.commands.single.action, RemoteAction.playTracks);
    expect(streamer.commands.single.trackIds, ['t1', 't2', 't3', 't4']);
    expect(streamer.commands.single.index, 1);
    expect(driver.state, PlaybackState.paused, reason: 'it plays there now');
    expect(hub.commandsTo('upnp:uuid:1'), isEmpty, reason: 'not through the server');

    streamer.device
      ..playback = RemotePlayback(track: tracks[2], playing: true, queue: [for (final t in tracks) t.id], queueIndex: 2)
      ..playbackReceivedAt = DateTime.now();
    vm.remote.localChanged();
    await pumpEventQueue();
    expect((player.remoteDeviceName, player.isPlaying), ('Living room', true));
    expect(player.currentTrack, same(tracks[2]));
    player.nextTrack();
    expect(streamer.commands.last.action, RemoteAction.next);

    // It goes from the network: control comes back here after the grace.
    final grace = PlayerViewModel.remoteGrace;
    PlayerViewModel.remoteGrace = const Duration(milliseconds: 50);
    addTearDown(() => PlayerViewModel.remoteGrace = grace);
    vm.remote.removeLocal('upnp:uuid:1');
    await until(() => !player.isRemote);
  });
}

class _FakeLocalDevice implements LocalDevice {
  _FakeLocalDevice(this.device);

  @override
  final RemoteDevice device;
  final List<RemoteCommand> commands = [];

  @override
  void execute(RemoteCommand command) => commands.add(command);

  @override
  void dispose() {}
}
