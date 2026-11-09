// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wiretune_core/testing.dart';
import 'package:wiretune_core/wiretune_core.dart';

/// A UPnP renderer on loopback: its description, its control (it records each action and plays along), and an SSDP
/// responder.
class FakeRenderer {
  FakeRenderer._(this._http, this._ssdp);

  final HttpServer _http;
  final RawDatagramSocket _ssdp;
  final List<(String, Map<String, String>)> actions = [];
  String state = 'STOPPED';
  Duration position = Duration.zero;
  int volume = 30;

  int get ssdpPort => _ssdp.port;
  Uri get location => Uri.parse('http://127.0.0.1:${_http.port}/description.xml');

  static Future<FakeRenderer> start({String controlHost = ''}) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ssdp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final renderer = FakeRenderer._(http, ssdp);
    ssdp.listen((event) {
      final datagram = event == RawSocketEvent.read ? ssdp.receive() : null;
      if (datagram == null || !utf8.decode(datagram.data).startsWith('M-SEARCH')) return;
      for (final answer in [
        'HTTP/1.1 200 OK\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\nLOCATION: http://127.0.0.1:1/other.xml\r\n\r\n',
        'HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nST: ${UpnpClient.rendererType}\r\n'
            'Location: ${renderer.location}\r\n\r\n',
      ]) {
        ssdp.send(utf8.encode(answer), datagram.address, datagram.port);
      }
    });
    http.listen((request) async {
      final body = await utf8.decodeStream(request);
      if (request.uri.path == '/description.xml') {
        request.response
          ..headers.contentType = ContentType('text', 'xml')
          ..write(renderer.description(controlHost));
      } else {
        final action = (request.headers.value('soapaction') ?? '').split('#').last.replaceAll('"', '');
        final arguments = {
          for (final m in RegExp(r'<(\w+)>([^<]*)</\1>').allMatches(body)) m[1]!: UpnpClient.xmlUnescape(m[2]!),
        };
        renderer.actions.add((action, arguments));
        request.response.write(renderer._answer(action, arguments));
      }
      await request.response.close();
    });
    return renderer;
  }

  String description(String controlHost) =>
      '<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
      '<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>'
      '<friendlyName>Living room &amp; kitchen\u0007</friendlyName><UDN>uuid:fake-1</UDN><serviceList>'
      '<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>'
      '<controlURL>$controlHost/rendering</controlURL></service>'
      '<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
      '<controlURL>$controlHost/transport</controlURL></service>'
      '</serviceList></device></root>';

  String _answer(String action, Map<String, String> arguments) {
    switch (action) {
      case 'Play':
        state = 'PLAYING';
      case 'Pause':
        state = 'PAUSED_PLAYBACK';
      case 'Stop':
        state = 'STOPPED';
      case 'SetAVTransportURI':
        state = 'TRANSITIONING';
        position = Duration.zero;
      case 'Seek':
        position = UpnpClient.parseTime(arguments['Target'])!;
      case 'SetVolume':
        volume = int.parse(arguments['DesiredVolume']!);
    }
    final out = switch (action) {
      'GetTransportInfo' => '<CurrentTransportState>$state</CurrentTransportState>',
      'GetPositionInfo' =>
        '<RelTime>${UpnpClient.formatTime(position)}</RelTime><TrackDuration>0:03:00</TrackDuration>',
      'GetVolume' => '<CurrentVolume>$volume</CurrentVolume>',
      _ => '',
    };
    return '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
        '<u:${action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">$out</u:${action}Response>'
        '</s:Body></s:Envelope>';
  }

  List<String> get names => [
    for (final (name, _) in actions)
      if (!name.startsWith('Get')) name,
  ];

  Future<void> close() async {
    _ssdp.close();
    await _http.close(force: true);
  }
}

void main() {
  late FakeRenderer fake;
  final upnp = UpnpClient();
  setUp(() async => fake = await FakeRenderer.start());
  tearDown(() => fake.close());

  test('a search finds the renderers that answer, and a description names its transport and volume', () async {
    final found = await upnp.search(
      to: InternetAddress.loopbackIPv4,
      port: fake.ssdpPort,
      wait: const Duration(milliseconds: 200),
    );
    expect(found, {fake.location}, reason: 'not the media server');
    final renderer = (await upnp.describe(fake.location))!;
    expect((renderer.id, renderer.name), ('upnp:uuid:fake-1', 'Living room & kitchen'));
    expect(renderer.avTransport.controlUrl.path, '/transport');
    expect(renderer.renderingControl!.type, 'urn:schemas-upnp-org:service:RenderingControl:1');
  });

  test("a description's control URL on another host is refused", () {
    final xml = fake.description('http://192.168.1.66:8080');
    expect(UpnpClient.parseDescription(xml, fake.location), isNull, reason: 'its transport is elsewhere');
  });

  test('times, escapes and the track description', () {
    expect(UpnpClient.parseTime('1:02:03.5'), const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500));
    expect(UpnpClient.parseTime('NOT_IMPLEMENTED'), isNull);
    expect(UpnpClient.formatTime(const Duration(minutes: 61, seconds: 5)), '1:01:05');
    expect(UpnpClient.xmlUnescape('a &lt;b&gt; &#233; &#x41; &amp;amp;'), 'a <b> é A &amp;');
    final didl = UpnpClient.didl(
      url: 'http://s/api/stream/1?token=a&b',
      mimeType: 'audio/flac',
      title: 'Rock & Roll',
      artist: 'Led Zeppelin',
      album: 'IV',
      duration: const Duration(minutes: 3, seconds: 40),
    );
    expect(didl, contains('<dc:title>Rock &amp; Roll</dc:title>'));
    expect(
      didl,
      contains('protocolInfo="http-get:*:audio/flac:*" duration="0:03:40.000">http://s/api/stream/1?token=a&amp;b'),
    );
    expect(AudioFileTypes.mimeTypeOfCodec('ALAC'), 'audio/mp4');
    expect(AudioFileTypes.mimeTypeOfCodec('FLAC'), 'audio/flac');
  });

  group('a streamer as a device', () {
    late StreamerDevice streamer;
    late List<String> played;
    late int changes;
    var goneCount = 0;
    final tracks = {
      for (final id in ['a', 'b', 'c'])
        id: TestSupport.makeServerTrack(id, 'Song $id'),
    };

    setUp(() async {
      StreamerDevice.pollInterval = const Duration(milliseconds: 40);
      played = [];
      changes = 0;
      goneCount = 0;
      streamer = StreamerDevice(
        (await upnp.describe(fake.location))!,
        upnp,
        trackOf: (id) => tracks[id],
        sourceOf: (track) async => (url: '${track.streamUrl}?token=media', cover: null),
        played: (track) => played.add(track.id),
        changed: () => changes++,
        gone: () => goneCount++,
      );
      await streamer.refresh();
    });
    tearDown(() => streamer.dispose());

    RemotePlayback state() => streamer.device.playback!;

    /// Until the streamer has been looked at since it was last told to play, as it is before a track can end.
    Future<void> looked() => until(
      () =>
          fake.actions.lastIndexWhere((a) => a.$1 == 'GetTransportInfo') >
          fake.actions.lastIndexWhere((a) => a.$1 == 'Play'),
    );

    test('plays the queue a track at a time, moves on when one ends, and counts each', () async {
      expect((state().volume, state().track), (30.0, null), reason: 'its volume, nothing of ours playing');
      streamer.execute(
        const RemoteCommand(
          RemoteAction.playTracks,
          trackIds: ['a', 'local-only', 'b'],
          index: 0,
          position: Duration(seconds: 20),
        ),
      );
      await until(() => fake.names.contains('Seek'));
      final (_, uri) = fake.actions.firstWhere((a) => a.$1 == 'SetAVTransportURI');
      expect(uri['CurrentURI'], 'http://server/api/stream/a?token=media');
      expect(uri['CurrentURIMetaData'], contains('<dc:title>Song a</dc:title>'));
      expect(fake.names, ['SetAVTransportURI', 'Play', 'Seek'], reason: 'where it was, once it plays');
      expect(state().queue, ['a', 'b']);
      expect((state().queueIndex, state().track?.id), (0, 'a'));
      await until(() => state().playing && state().position == const Duration(seconds: 20));

      // The streamer ends the track: the next one is handed over.
      await looked();
      fake.state = 'STOPPED';
      await until(() => state().track?.id == 'b' && state().playing);
      expect(played, ['a', 'b']);

      streamer.execute(const RemoteCommand(RemoteAction.pause));
      streamer.execute(const RemoteCommand(RemoteAction.volume, volume: 55));
      streamer.execute(const RemoteCommand(RemoteAction.seek, position: Duration(minutes: 1)));
      await until(() => fake.volume == 55 && fake.position == const Duration(minutes: 1));
      expect(fake.state, 'PAUSED_PLAYBACK');
      expect((state().playing, state().volume), (false, 55.0));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(state().playing, isFalse, reason: 'a pause is no end');

      // The end of the queue: it stays on the last track, stopped.
      streamer.execute(const RemoteCommand(RemoteAction.play));
      await until(() => state().playing);
      await looked();
      fake.state = 'STOPPED';
      await until(() => !state().playing);
      expect(state().track?.id, 'b');
      expect(played, ['a', 'b']);
      expect(goneCount, 0);
      expect(changes, greaterThan(0));
    });

    test('the queue is edited by its places, and repeat one plays the track again', () async {
      streamer.execute(const RemoteCommand(RemoteAction.playTracks, trackIds: ['a', 'b'], index: 0));
      await until(() => state().playing);
      streamer
        ..execute(const RemoteCommand(RemoteAction.addToQueue, trackIds: ['c']))
        ..execute(const RemoteCommand(RemoteAction.moveTrack, index: 2, toIndex: 1))
        ..execute(const RemoteCommand(RemoteAction.removeTrack, index: 2));
      await until(() => state().queue.length == 2);
      expect(state().queue, ['a', 'c']);
      expect(state().queueIndex, 0);

      streamer.execute(const RemoteCommand(RemoteAction.repeat, repeat: RepeatMode.one));
      await looked();
      fake.state = 'STOPPED';
      await until(() => played.length == 2);
      expect(played, ['a', 'a']);
      expect(state().track?.id, 'a');

      streamer.execute(const RemoteCommand(RemoteAction.next));
      await until(() => state().track?.id == 'c');
      streamer.execute(const RemoteCommand(RemoteAction.clearQueue));
      await until(() => state().queue.isEmpty);
      expect((state().playing, fake.state), (false, 'STOPPED'));
    });

    test('a streamer that stops answering is gone', () async {
      streamer.execute(const RemoteCommand(RemoteAction.playTracks, trackIds: ['a'], index: 0));
      await until(() => state().playing);
      await fake.close();
      await until(() => goneCount > 0, within: const Duration(seconds: 10));
    });
  });
}
