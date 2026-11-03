// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter_test/flutter_test.dart';
import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune/src/view_models/player_view_model.dart';
import 'package:wiretune_core/wiretune_core.dart';

import 'support.dart';

/// Listening together from the player's side: a host tells what it plays and does what the members ask; a member
/// plays what the host plays, where the host is, pauses for itself, and asks the host for the rest.
void main() {
  setUpAll(useTempDataDirectory);
  setUp(() => Localizer.instance.setLanguage('en'));

  late FakeAudioDriver driver;
  late List<Track> tracks;
  late FakeRemoteHub hub;
  late MainViewModel vm;
  late PlayerViewModel player;
  late List<String> notices;

  setUp(() async {
    final saved = (
      PlayerViewModel.followCheckInterval,
      PlayerViewModel.hostBeatInterval,
      ListenTogether.clockAskInterval,
    );
    PlayerViewModel.followCheckInterval = const Duration(milliseconds: 50);
    PlayerViewModel.hostBeatInterval = const Duration(milliseconds: 50);
    ListenTogether.clockAskInterval = const Duration(milliseconds: 5);
    addTearDown(() {
      PlayerViewModel.followCheckInterval = saved.$1;
      PlayerViewModel.hostBeatInterval = saved.$2;
      ListenTogether.clockAskInterval = saved.$3;
    });
    driver = FakeAudioDriver();
    tracks = [for (var i = 1; i <= 4; i++) TestSupport.makeTrack('t$i', 'Song $i', trackNumber: i, minutes: 3)];
    final library = createLibrary(tracks);
    library.initialize();
    final session = await signedInSession(library);
    hub = FakeRemoteHub();
    final remote = RemoteClient(session, connector: hub.connect);
    vm = createMainViewModel(library, TestSupport.createEngine(driver), session, remote);
    notices = [];
    vm.notices.listen((notice) => notices.add(notice.message));
    player = vm.player;
    tracks = library.tracks;
    remote.configure(id: 'phone-id', name: 'Phone', kind: DeviceKind.phone, enabled: true);
    await until(() => remote.isConnected);
  });
  tearDown(() => vm.dispose());

  Map<String, Object?> who(String deviceId) => {
    'accountId': deviceId == 'phone-id' ? 'user-1' : 'user-2',
    'username': deviceId == 'phone-id' ? 'owner' : 'anna',
    'deviceId': deviceId,
    'deviceName': '',
  };
  void group({required String host, List<String> members = const []}) => hub.deliver({
    'type': 'listen',
    'group': {
      'id': 'g1',
      'host': who(host),
      'members': [for (final member in members) who(member)],
    },
  });
  Future<void> answerClock() async {
    await until(() => hub.ofType('time').isNotEmpty);
    for (final ask in hub.ofType('time').toList()) {
      hub.deliver({'type': 'time', 't': ask['t'], 'server': ask['t']});
    }
    await until(() => vm.together.hasClock);
  }

  void hostPlays(int index, Duration at, {bool playing = true}) => hub.deliver({
    'type': 'listenState',
    'state': ListeningState(
      queue: const ['t1', 't2', 't3'],
      queueIndex: index,
      playing: playing,
      position: at,
      at: vm.together.serverNow(),
    ).toJson(),
  });

  test('a host tells what it plays (and now and then while it plays), and does what members ask', () async {
    vm.together.start(['user-2']);
    group(host: 'phone-id');
    await pumpEventQueue();
    expect(player.isHostingGroup, isTrue);

    player.playQueue(tracks.take(3), tracks[0]);
    await pumpEventQueue();
    final state = ListeningState.fromJson(hub.ofType('listenState').last['state'])!;
    expect(state.queue, ['t1', 't2', 't3']);
    expect((state.queueIndex, state.playing), (0, true));
    final told = hub.ofType('listenState').length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hub.ofType('listenState').length, greaterThan(told), reason: 'its position, while it plays');

    group(host: 'phone-id', members: ['anna-phone']);
    await pumpEventQueue();
    expect(notices, contains('anna joined'));

    for (final command in [
      const RemoteCommand(RemoteAction.next),
      const RemoteCommand(RemoteAction.addToQueue, trackIds: ['t4']),
      const RemoteCommand(RemoteAction.pause),
      const RemoteCommand(RemoteAction.clearQueue),
    ]) {
      hub.deliver({'type': 'listenCommand', 'from': 'anna', 'command': command.toJson()});
    }
    await pumpEventQueue();
    expect(player.currentTrack, same(tracks[1]));
    expect(player.queueTracks, hasLength(4));
    expect(player.queueTracks.last, same(tracks[3]));
    expect(notices, contains('anna added Song 4'));
    expect(player.isPlaying, isTrue, reason: "pausing is each player's own, and the queue isn't a member's to clear");
  });

  test('a member plays what the host plays, where the host is, and asks the host for the rest', () async {
    player.playQueue([tracks[3]], tracks[3]);
    await pumpEventQueue();
    vm.together.join('g1');
    group(host: 'desk', members: ['phone-id']);
    await pumpEventQueue();
    expect(player.isFollowingHost, isTrue);
    expect(player.isPlaying, isFalse, reason: "its own music gives way to the host's");
    await answerClock();

    hostPlays(1, const Duration(seconds: 30));
    await pumpEventQueue();
    expect(player.currentTrack, same(tracks[1]));
    expect(player.isPlaying, isTrue);
    expect(driver.currentPosition.inMilliseconds, inInclusiveRange(30000, 30500));
    expect([for (final item in player.queueItems) item.track.title], ['Song 1', 'Song 2', 'Song 3']);

    // Seconds off: it seeks to where the host is.
    driver.positionChanged.emit(const Duration(seconds: 20));
    await until(() => driver.currentPosition > const Duration(seconds: 29));
    expect(driver.currentPosition.inMilliseconds, inInclusiveRange(30000, 31000));

    // The rest is the host's to do.
    player.nextTrack();
    player.seekTo(const Duration(seconds: 60));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    player.addToQueue([tracks[3]]);
    player.playQueueItem(player.queueItems[2]);
    player.clearQueue();
    expect(
      [for (final m in hub.ofType('listenCommand')) m['command']],
      [
        {'action': 'next'},
        {'action': 'seek', 'positionMs': 60000},
        {
          'action': 'addToQueue',
          'trackIds': ['t4'],
        },
        {'action': 'playIndex', 'index': 2},
      ],
    );
    expect(player.currentTrack, same(tracks[1]), reason: 'until the host moves on');

    // Paused here, while the host plays on: play catches up.
    await player.pause();
    hostPlays(1, const Duration(seconds: 40));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(player.isPlaying, isFalse);
    await player.play();
    await pumpEventQueue();
    expect(player.isPlaying, isTrue);
    expect(driver.currentPosition.inMilliseconds, inInclusiveRange(40000, 41000));

    // The host pauses: so does this one, and it plays on with the host.
    hostPlays(1, const Duration(seconds: 45), playing: false);
    await pumpEventQueue();
    expect(player.isPlaying, isFalse);
    hostPlays(2, Duration.zero);
    await pumpEventQueue();
    expect(player.isPlaying, isTrue);
    expect(player.currentTrack, same(tracks[2]));

    // Paused by something else (a call): following leaves it paused.
    await driver.pause();
    hostPlays(2, const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(player.isPlaying, isFalse);

    hub.deliver({'type': 'listen', 'group': null});
    await pumpEventQueue();
    expect(notices, contains('Listening together ended.'));
    expect(player.isFollowingHost, isFalse);
  });

  test('a member that plays music of its own leaves the group', () async {
    vm.together.join('g1');
    group(host: 'desk', members: ['phone-id']);
    await pumpEventQueue();

    player.playQueue(tracks, tracks[2]);
    await pumpEventQueue();
    expect(hub.ofType('listenLeave'), hasLength(1));
    expect(notices, contains('You left listening together.'));
    expect(player.currentTrack, same(tracks[2]));
  });

  test('an invite shows a notice that joins', () async {
    hub.deliver({
      'type': 'listenInvites',
      'invites': [
        {
          'group': 'g1',
          'host': {'id': 'user-2', 'username': 'anna'},
        },
      ],
    });
    await pumpEventQueue();
    expect(vm.friends.invites.single.host.username, 'anna');
    expect(vm.friends.unseenCount, 1, reason: 'the bell counts it');
    expect(notices, ['anna invites you to listen together']);
  });
}
