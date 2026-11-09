// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/remote.dart';
import 'wiretune_log.dart';

/// A UPnP (DLNA) media renderer on the network: a hi-fi streamer, an amplifier, a speaker that plays what it is given
/// by URL. [id] stays the same across searches (its UDN).
class UpnpRenderer {
  const UpnpRenderer(this.id, this.name, this.avTransport, this.renderingControl);

  final String id;
  final String name;

  /// Where its transport (what it plays, play, pause, seek) is controlled.
  final UpnpService avTransport;

  /// Where its volume is controlled; null when it has none.
  final UpnpService? renderingControl;
}

/// One service of a [UpnpRenderer]: its type (with the version it offers, for the actions' namespace) and its control
/// URL.
class UpnpService {
  const UpnpService(this.type, this.controlUrl);

  final String type;
  final Uri controlUrl;
}

/// A renderer's transport state, as `GetTransportInfo` tells it.
enum UpnpTransport { playing, paused, stopped, transitioning, noMedia }

/// A refusal or a failure of a renderer's action: its UPnP error code when it gave one.
class UpnpException implements Exception {
  const UpnpException(this.message, [this.code]);

  final String message;
  final int? code;

  @override
  String toString() => code == null ? message : '$message (UPnP $code)';
}

/// Finds UPnP renderers (SSDP) and controls them (SOAP over HTTP). What a device on the network answers is untrusted:
/// the answers are read with size and time limits, names lose control characters, and a device's control URLs must be
/// on the host its description came from.
class UpnpClient {
  UpnpClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static const String rendererType = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  static const Duration _timeout = Duration(seconds: 5);
  static const int _maxAnswer = 256 * 1024;

  /// The description URLs of the renderers that answer a search within [wait]. [to] and [port] are SSDP's multicast
  /// group unless given (tests answer on their own address).
  Future<Set<Uri>> search({InternetAddress? to, int port = 1900, Duration wait = const Duration(seconds: 3)}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final found = <Uri>{};
    socket.multicastHops = 4;
    final listening = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null || datagram.data.length > 8192) return;
      final location = locationOf(utf8.decode(datagram.data, allowMalformed: true));
      if (location != null) found.add(location);
    });
    final message = utf8.encode(
      'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\n'
      'ST: $rendererType\r\n\r\n',
    );
    final target = to ?? InternetAddress('239.255.255.250');
    try {
      // Twice: a datagram can be lost.
      socket.send(message, target, port);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      socket.send(message, target, port);
      await Future<void>.delayed(wait);
    } finally {
      await listening.cancel();
      socket.close();
    }
    return found;
  }

  /// The description URL an SSDP answer gives (its `LOCATION`), for a renderer; null for anything else.
  static Uri? locationOf(String answer) {
    final lines = answer.split(RegExp(r'\r?\n'));
    if (lines.isEmpty || !lines.first.toUpperCase().startsWith('HTTP/1.1 200')) return null;
    String? header(String name) {
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon > 0 && line.substring(0, colon).trim().toLowerCase() == name) {
          return line.substring(colon + 1).trim();
        }
      }
      return null;
    }

    final st = header('st') ?? '';
    if (!st.startsWith('urn:schemas-upnp-org:device:MediaRenderer:')) return null;
    final location = Uri.tryParse(header('location') ?? '');
    return location != null && location.isScheme('http') && location.host.isNotEmpty ? location : null;
  }

  /// The renderer [location] describes; null when it is no renderer Wiretune can control (no transport).
  Future<UpnpRenderer?> describe(Uri location) async {
    final response = await _http.get(location).timeout(_timeout);
    if (response.statusCode != 200) throw UpnpException('The description answered ${response.statusCode}.');
    return parseDescription(_limited(response), location);
  }

  /// A renderer from its description [xml], fetched from [location].
  static UpnpRenderer? parseDescription(String xml, Uri location) {
    final urlBase = xmlText(xml, 'URLBase') ?? '';
    final base = (urlBase.isEmpty ? null : Uri.tryParse(urlBase)) ?? location;
    UpnpService? service(String kind) {
      for (final block in xmlElements(xml, 'service')) {
        final type = xmlText(block, 'serviceType') ?? '';
        final control = Uri.tryParse(xmlText(block, 'controlURL') ?? '');
        if (!type.startsWith('urn:schemas-upnp-org:service:$kind:') || control == null) continue;
        final url = base.resolveUri(control);
        // Only on the host that described it: a device on the network can't send Wiretune's requests elsewhere.
        if (url.host != location.host || !url.isScheme('http')) continue;
        return UpnpService(type, url);
      }
      return null;
    }

    final transport = service('AVTransport');
    final udn = xmlText(xml, 'UDN');
    if (transport == null || udn == null || udn.isEmpty) return null;
    final name = RemoteRules.cleanName(xmlText(xml, 'friendlyName'));
    return UpnpRenderer('upnp:$udn', name, transport, service('RenderingControl'));
  }

  // ── Control ──────────────────────────────────────────────────────────────────────────────────────

  /// Has [renderer] play [url] next, described by [metadata] (DIDL-Lite), in place of what it plays.
  Future<void> setUri(UpnpRenderer renderer, String url, String metadata) =>
      _transport(renderer, 'SetAVTransportURI', {'CurrentURI': url, 'CurrentURIMetaData': metadata});

  Future<void> play(UpnpRenderer renderer) => _transport(renderer, 'Play', {'Speed': '1'});

  Future<void> pause(UpnpRenderer renderer) => _transport(renderer, 'Pause', const {});

  Future<void> stop(UpnpRenderer renderer) => _transport(renderer, 'Stop', const {});

  Future<void> seek(UpnpRenderer renderer, Duration position) =>
      _transport(renderer, 'Seek', {'Unit': 'REL_TIME', 'Target': formatTime(position)});

  Future<UpnpTransport> transport(UpnpRenderer renderer) async {
    final answer = await _transport(renderer, 'GetTransportInfo', const {});
    return switch (xmlText(answer, 'CurrentTransportState')) {
      'PLAYING' => UpnpTransport.playing,
      'PAUSED_PLAYBACK' || 'PAUSED_RECORDING' => UpnpTransport.paused,
      'TRANSITIONING' => UpnpTransport.transitioning,
      'NO_MEDIA_PRESENT' => UpnpTransport.noMedia,
      _ => UpnpTransport.stopped,
    };
  }

  /// Where in its track [renderer] is, and how long the track is (zero when it doesn't say).
  Future<({Duration position, Duration duration})> position(UpnpRenderer renderer) async {
    final answer = await _transport(renderer, 'GetPositionInfo', const {});
    return (
      position: parseTime(xmlText(answer, 'RelTime')) ?? Duration.zero,
      duration: parseTime(xmlText(answer, 'TrackDuration')) ?? Duration.zero,
    );
  }

  /// [renderer]'s volume, 0 to 100; null when it has no volume control.
  Future<int?> volume(UpnpRenderer renderer) async {
    final control = renderer.renderingControl;
    if (control == null) return null;
    final answer = await _call(control, 'GetVolume', {'InstanceID': '0', 'Channel': 'Master'});
    return int.tryParse(xmlText(answer, 'CurrentVolume') ?? '')?.clamp(0, 100);
  }

  Future<void> setVolume(UpnpRenderer renderer, int volume) async {
    final control = renderer.renderingControl;
    if (control == null) return;
    await _call(control, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '${volume.clamp(0, 100)}',
    });
  }

  Future<void> setMute(UpnpRenderer renderer, bool muted) async {
    final control = renderer.renderingControl;
    if (control == null) return;
    await _call(control, 'SetMute', {'InstanceID': '0', 'Channel': 'Master', 'DesiredMute': muted ? '1' : '0'});
  }

  Future<String> _transport(UpnpRenderer renderer, String action, Map<String, String> arguments) =>
      _call(renderer.avTransport, action, {'InstanceID': '0', ...arguments});

  /// Calls [action] of [service]; its answer's body.
  Future<String> _call(UpnpService service, String action, Map<String, String> arguments) async {
    final body = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ')
      ..write('s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>')
      ..write('<u:$action xmlns:u="${xmlEscape(service.type)}">');
    for (final MapEntry(:key, :value) in arguments.entries) {
      body.write('<$key>${xmlEscape(value)}</$key>');
    }
    body.write('</u:$action></s:Body></s:Envelope>');
    final response = await _http
        .post(
          service.controlUrl,
          headers: {'content-type': 'text/xml; charset="utf-8"', 'soapaction': '"${service.type}#$action"'},
          body: utf8.encode(body.toString()),
        )
        .timeout(_timeout);
    final answer = _limited(response);
    if (response.statusCode != 200) {
      final code = int.tryParse(xmlText(answer, 'errorCode') ?? '');
      final description = xmlText(answer, 'errorDescription');
      throw UpnpException('$action failed${description == null ? '' : ': $description'}.', code);
    }
    return answer;
  }

  static String _limited(http.Response response) {
    if (response.bodyBytes.length > _maxAnswer) throw const UpnpException('The device answered too much.');
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  void close() => _http.close();

  // ── Text ─────────────────────────────────────────────────────────────────────────────────────────

  /// The contents of each [tag] element of [xml], whatever its namespace prefix.
  static Iterable<String> xmlElements(String xml, String tag) => RegExp(
    '<(?:[\\w.-]+:)?$tag(?:\\s[^>]*)?>(.*?)</(?:[\\w.-]+:)?$tag\\s*>',
    dotAll: true,
  ).allMatches(xml).map((m) => m[1]!);

  /// The text of the first [tag] element of [xml], unescaped and trimmed; null when there is none.
  static String? xmlText(String xml, String tag) {
    final text = xmlElements(xml, tag).firstOrNull;
    return text == null ? null : xmlUnescape(text).trim();
  }

  static String xmlEscape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String xmlUnescape(String text) => text.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|\w+);'), (m) {
    final entity = m[1]!;
    if (entity.startsWith('#')) {
      final code = entity.startsWith('#x')
          ? int.tryParse(entity.substring(2), radix: 16)
          : int.tryParse(entity.substring(1));
      return code == null || code > 0x10FFFF ? m[0]! : String.fromCharCode(code);
    }
    return switch (entity) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      'apos' => "'",
      _ => m[0]!,
    };
  });

  /// UPnP's `H:MM:SS` (with fractions of a second); null for anything else (`NOT_IMPLEMENTED`).
  static Duration? parseTime(String? text) {
    final match = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})(?:\.(\d+))?').firstMatch(text ?? '');
    if (match == null) return null;
    final fraction = match[4] ?? '0';
    return Duration(
      hours: int.parse(match[1]!),
      minutes: int.parse(match[2]!),
      seconds: int.parse(match[3]!),
      milliseconds: int.parse(fraction.padRight(3, '0').substring(0, 3)),
    );
  }

  static String formatTime(Duration time) {
    final seconds = time.inSeconds;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${seconds ~/ 3600}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}';
  }

  /// The DIDL-Lite that describes a track to a renderer: [url] of [mimeType], with its names, length and cover.
  static String didl({
    required String url,
    required String mimeType,
    required String title,
    required String artist,
    required String album,
    required Duration duration,
    String? coverUrl,
  }) {
    final e = xmlEscape;
    final length = '${formatTime(duration)}.${(duration.inMilliseconds % 1000).toString().padLeft(3, '0')}';
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="1" parentID="0" restricted="1">'
        '<dc:title>${e(title)}</dc:title><dc:creator>${e(artist)}</dc:creator>'
        '<upnp:artist>${e(artist)}</upnp:artist><upnp:album>${e(album)}</upnp:album>'
        '${coverUrl == null ? '' : '<upnp:albumArtURI>${e(coverUrl)}</upnp:albumArtURI>'}'
        '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
        '<res protocolInfo="http-get:*:${e(mimeType)}:*" duration="$length">${e(url)}</res>'
        '</item></DIDL-Lite>';
  }

  /// Logs [error] of [renderer] once, quietly: a device on the network goes away now and then.
  static void logFailure(UpnpRenderer renderer, Object error) =>
      WiretuneLog.debug('Upnp', '${renderer.name.isEmpty ? renderer.id : renderer.name}: $error');
}
