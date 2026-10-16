// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../view_models/app_section.dart';
import '../view_models/library_view_models.dart';
import '../view_models/main_view_model.dart';

/// Local HTTP endpoint for scripted UI testing. It exists in debug builds only ([isEnabled] is false in a release or
/// profile build, whatever the environment says), stays off unless `WIRETUNE_UI_AUTOMATION=1` is set, listens on
/// loopback only, and turns away requests that come from a web page.
class UiAutomationServer {
  UiAutomationServer(this._vm, {this.port = 5201});

  static const String enableEnvironmentVariable = 'WIRETUNE_UI_AUTOMATION';

  /// Wraps the whole app, so a screenshot shows what the window shows.
  static final GlobalKey screenshotKey = GlobalKey(debugLabel: 'wiretune-screenshot');

  static bool get isEnabled => kDebugMode && !kIsWeb && Platform.environment[enableEnvironmentVariable] == '1';

  final MainViewModel _vm;
  final int port;

  Future<void> start() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      server.listen(_handle);
      WiretuneLog.info('UiAutomation', 'UI automation server started on http://127.0.0.1:$port/');
    } catch (e) {
      WiretuneLog.warn('UiAutomation', 'Could not start UI automation server on port $port: $e');
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final headers = request.headers;
    // A web page can reach a loopback port: fetch/XHR carry an Origin, plain <img>/<a> requests a Sec-Fetch-Site, and a
    // page on a name that resolves to 127.0.0.1 (DNS rebinding) a foreign Host header.
    final fetchSite = headers.value('sec-fetch-site');
    if ((headers.value('origin') ?? '').isNotEmpty ||
        (fetchSite != null && fetchSite.isNotEmpty && fetchSite != 'none')) {
      return await _json(request, 403, {'error': 'Cross-origin requests are not allowed.'});
    }
    final host = headers.value('host');
    if (host != '127.0.0.1:$port' && host != 'localhost:$port') {
      return await _json(request, 403, {'error': 'Unexpected Host header.'});
    }

    try {
      final path = request.uri.path.toLowerCase();
      final query = request.uri.queryParameters;
      switch (path) {
        case '/api/ui/state':
          return await _json(request, 200, _state());
        case '/api/ui/navigate':
          final section = AppSection.values.where((s) => s.name.toLowerCase() == query['section']?.toLowerCase());
          if (section.isEmpty) break;
          _vm.navigateTo(section.first);
          return await _json(request, 200, {'success': true, 'section': section.first.name});
        case '/api/ui/screenshot':
          // Only a file name is accepted; screenshots always go to the temp directory.
          var name = p.basename(query['name'] ?? 'wiretune_ui_screenshot.png');
          if (!name.toLowerCase().endsWith('.png')) name = '$name.png';
          final savePath = p.join(Directory.systemTemp.path, name);
          await _screenshot(savePath);
          return await _json(request, 200, {'success': true, 'path': savePath});
        case '/api/ui/resize':
          final width = double.tryParse(query['width'] ?? '');
          final height = double.tryParse(query['height'] ?? '');
          if (width == null || height == null) break;
          if (await windowManager.isMaximized()) await windowManager.unmaximize();
          // Below the user's 720 px minimum too, so a script can look at the phone layout.
          await windowManager.setMinimumSize(const Size(320, 480));
          await windowManager.setSize(Size(width, height));
          return await _json(request, 200, {'success': true});
        case '/api/ui/language':
          final code = query['code'];
          if (code == null || code.isEmpty) break;
          _vm.changeLanguage(code);
          return await _json(request, 200, {'success': true, 'language': code});
        case '/api/ui/theme':
          final mode = query['mode'];
          if (mode != 'light' && mode != 'dark') break;
          _vm.setTheme(light: mode == 'light', persist: false);
          return await _json(request, 200, {'success': true, 'theme': mode});
        case '/api/ui/sort':
          // ?list=tracks|favorites|albums|artists&field=<the field's name>; the active field flips its direction.
          final field = query['field'];
          T? named<T extends Enum>(List<T> values) => values.where((f) => f.name == field).firstOrNull;
          switch ((query['list'], named(TrackSortField.values), named(AlbumSortField.values))) {
            case ('tracks', final TrackSortField f, _):
              _vm.tracks.setSortField(f);
            case ('favorites', final TrackSortField f, _):
              _vm.favorites.setSortField(f);
            case ('albums', _, final AlbumSortField f):
              _vm.albums.setSortField(f);
            case ('artists', _, _) when named(ArtistSortField.values) != null:
              _vm.artists.setSortField(named(ArtistSortField.values)!);
            default:
              return await _json(request, 404, {'error': 'Unknown list or field'});
          }
          return await _json(request, 200, {'success': true});
        case '/api/ui/search':
          _vm.searchQuery = query['q'] ?? '';
          return await _json(request, 200, {'success': true, 'query': query['q'] ?? ''});
        case '/api/ui/play-track':
          final id = query['id'];
          final title = query['title']?.toLowerCase();
          final track = _vm.library.tracks
              .where(
                (t) =>
                    (id != null && id.isNotEmpty && t.id == id) ||
                    (title != null && title.isNotEmpty && t.title.toLowerCase().contains(title)),
              )
              .firstOrNull;
          if (track == null) return await _json(request, 404, {'error': 'Track not found'});
          _vm.player.playQueue([track], track);
          return await _json(request, 200, {'success': true, 'id': track.id, 'title': track.title});
        case '/api/ui/connect':
          final url = query['url'];
          if (url == null || url.isEmpty) break;
          _vm.serverSettings.serverUrl = url;
          await _vm.serverSettings.connectServer();
          return await _json(request, 200, {
            'success': true,
            'state': _vm.session.state.name,
            'statusMessage': _vm.session.statusMessage,
          });
        case '/api/ui/login':
          final user = query['user'];
          if (user == null || user.isEmpty) break;
          _vm.serverSettings
            ..username = user
            ..password = query['password'] ?? '';
          await _vm.serverSettings.login();
          final error = _vm.serverSettings.hasAuthError ? _vm.serverSettings.authErrorMessage : null;
          return await _json(request, 200, {'success': error == null, 'error': error, 'state': _vm.session.state.name});
        case '/api/ui/logout':
          await _vm.logout();
          return await _json(request, 200, {'success': true, 'state': _vm.session.state.name});
        case '/api/ui/continue-offline':
          _vm.continueOffline();
          return await _json(request, 200, {'success': true});
        case '/api/ui/playlist/new':
          _vm.playlists.openCreateDialog();
          _vm.playlists.newPlaylistName = query['name'] ?? '';
          return await _json(request, 200, {'success': true});
        case '/api/ui/playlist/create':
          await _vm.playlists.createPlaylist();
          return await _json(request, 200, {'success': true, 'count': _vm.library.playlists.length});
        case '/api/ui/playlist/add-current':
          _vm.addToPlaylist(_vm.player.currentTrack);
          return await _json(request, 200, {'success': true});
        case '/api/ui/playlist/add-to':
          final name = query['name'];
          if (name == null || name.isEmpty) break;
          await _vm.playlists.addPendingTrackTo(_vm.library.playlists.where((pl) => pl.name == name).firstOrNull);
          return await _json(request, 200, {'success': true});
        case '/api/ui/play-pause':
          await _vm.player.togglePlayPause();
          return await _json(request, 200, {'success': true});
        case '/api/ui/next':
          _vm.player.nextTrack();
          return await _json(request, 200, {'success': true});
        case '/api/ui/prev':
          _vm.player.previousTrack();
          return await _json(request, 200, {'success': true});
        case '/api/ui/seek':
          final seconds = double.tryParse(query['seconds'] ?? '');
          if (seconds == null) break;
          await _vm.audioEngine.seek(Duration(milliseconds: (seconds * 1000).round()));
          return await _json(request, 200, {'success': true, 'seconds': seconds});
        case '/api/ui/volume':
          final level = double.tryParse(query['level'] ?? '');
          if (level == null) break;
          _vm.player.setVolume(level);
          return await _json(request, 200, {'success': true, 'volume': level});
        case '/api/ui/toggle-favorite':
          final trackId = query['trackId'];
          if (trackId == null || trackId.isEmpty) break;
          _vm.library.toggleFavorite(trackId);
          return await _json(request, 200, {'success': true, 'trackId': trackId});
        case '/api/ui/toggle-queue':
          _vm.player.toggleQueue();
          return await _json(request, 200, {'success': true, 'isQueueOpen': _vm.player.isQueueOpen});
        case '/api/ui/open-album':
          final title = query['title']?.toLowerCase();
          if (title == null || title.isEmpty) break;
          final album = _vm.library.albums.where((a) => a.title.toLowerCase().contains(title)).firstOrNull;
          if (album == null) return await _json(request, 404, {'error': 'Album not found'});
          _vm.openAlbum(album);
          return await _json(request, 200, {'success': true, 'title': album.title});
        case '/api/ui/back':
          return await _json(request, 200, {'success': _vm.tryNavigateBack()});
        case '/api/ui/open-playlist':
          final name = query['name'];
          final playlist = _vm.library.playlists.where((pl) => pl.name == name).firstOrNull;
          if (playlist == null) return await _json(request, 404, {'error': 'Playlist not found'});
          _vm.navigateTo(AppSection.playlists);
          _vm.playlists.openPlaylist(playlist);
          return await _json(request, 200, {'success': true, 'name': playlist.name});
        case '/api/ui/open-artist':
          final name = query['name']?.toLowerCase();
          if (name == null || name.isEmpty) break;
          final artist = _vm.library.artists.where((a) => a.name.toLowerCase().contains(name)).firstOrNull;
          if (artist == null) return await _json(request, 404, {'error': 'Artist not found'});
          _vm.openArtist(artist);
          return await _json(request, 200, {'success': true, 'name': artist.name});
      }
      return await _json(request, 404, {'error': 'Not found or invalid parameters', 'path': path});
    } catch (e, s) {
      WiretuneLog.error('UiAutomation', 'Request handling error: $e', e, s);
      try {
        await _json(request, 500, {'error': '$e'});
      } catch (_) {}
    }
  }

  Map<String, Object?> _state() {
    final engine = _vm.audioEngine;
    final track = engine.currentTrack;
    return {
      'section': _vm.selectedSection.name,
      'searchQuery': _vm.searchQuery,
      'statusText': _vm.statusText,
      'isLoginViewActive': _vm.isLoginViewActive,
      'serverState': _vm.session.state.name,
      'serverMessage': _vm.session.statusMessage,
      'playbackState': engine.state.name,
      'playerError': _vm.player.errorMessage,
      'currentTrack': track == null
          ? null
          : {
              'id': track.id,
              'title': track.title,
              'artist': track.artist,
              'album': track.album,
              'isFavorite': _vm.library.isFavorite(track.id),
            },
      'currentPositionSeconds': engine.currentPosition.inMilliseconds / 1000,
      'volume': engine.volume,
      'isMuted': engine.isMuted,
      'isBitperfect': engine.isBitperfect,
      'isExclusive': engine.isExclusiveMode,
      'repeatMode': _vm.player.repeatMode.name,
      'isShuffle': _vm.player.isShuffle,
      'isQueueOpen': _vm.player.isQueueOpen,
      'remoteDevice': _vm.player.isRemote ? _vm.player.remoteDeviceName : null,
      'audioDevices': [
        for (final d in _vm.audioSettings.availableDevices)
          {'id': d.id, 'name': d.name, 'exclusive': d.isExclusiveSupported, 'bitPerfect': d.isBitperfectSupported},
      ],
      'selectedDevice': _vm.audioSettings.selectedDevice?.id,
      'isExclusiveAvailable': _vm.audioSettings.isExclusiveAvailable,
      'isBitperfectAvailable': _vm.audioSettings.isBitperfectAvailable,
      'spectrumPeak': _vm.player.spectrum.value.fold<double>(0, (a, b) => a > b ? a : b),
      'tracksCount': _vm.library.tracks.length,
      'albumsCount': _vm.library.albums.length,
      'artistsCount': _vm.library.artists.length,
      'playlistsCount': _vm.library.playlists.length,
      'favoritesCount': _vm.library.favorites.length,
    };
  }

  static Future<void> _screenshot(String savePath) async {
    // Wait for the frame that shows the latest change.
    await WidgetsBinding.instance.endOfFrame;
    final boundary = screenshotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) throw StateError('Nothing to capture yet.');
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File(savePath).writeAsBytes(bytes!.buffer.asUint8List());
  }

  static Future<void> _json(HttpRequest request, int status, Object data) async {
    final response = request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json;
    response.write(const JsonEncoder.withIndent('  ').convert(data));
    await response.close();
  }
}
