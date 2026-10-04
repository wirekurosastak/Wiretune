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
import '../view_models/main_view_model.dart';

/// Local HTTP endpoint for scripted UI testing, the same routes as the C# player's. It exists in debug builds only
/// ([isEnabled] is false in a release or profile build, whatever the environment says), stays off unless
/// `WIRETUNE_UI_AUTOMATION=1` is set, listens on loopback only, and turns away requests that come from a web page.
class UiAutomationServer {
  UiAutomationServer(this._vm, {this.port = 5201});

  static const String enableEnvironmentVariable = 'WIRETUNE_UI_AUTOMATION';

  /// Wraps the whole app, so a screenshot shows what the window shows.
  static final GlobalKey screenshotKey = GlobalKey(debugLabel: 'wiretune-screenshot');

  static bool get isEnabled => kDebugMode && !kIsWeb && Platform.environment[enableEnvironmentVariable] == '1';

  final MainViewModel _vm;
  final int port;
  HttpServer? _server;

  Future<void> start() async {
    try {
      final server = _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      server.listen(_handle);
      WiretuneLog.info('UiAutomation', 'UI automation server started on http://127.0.0.1:$port/');
    } catch (e) {
      WiretuneLog.warn('UiAutomation', 'Could not start UI automation server on port $port: $e');
    }
  }

  Future<void> stop() async => _server?.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final headers = request.headers;
    // A web page can reach a loopback port: fetch/XHR carry an Origin, plain <img>/<a> requests a Sec-Fetch-Site, and a
    // page on a name that resolves to 127.0.0.1 (DNS rebinding) a foreign Host header.
    final fetchSite = headers.value('sec-fetch-site');
    if ((headers.value('origin') ?? '').isNotEmpty ||
        (fetchSite != null && fetchSite.isNotEmpty && fetchSite != 'none')) {
      return await _json(request, 403, {'Error': 'Cross-origin requests are not allowed.'});
    }
    final host = headers.value('host');
    if (host != '127.0.0.1:$port' && host != 'localhost:$port') {
      return await _json(request, 403, {'Error': 'Unexpected Host header.'});
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
          return await _json(request, 200, {'Success': true, 'Section': _pascal(section.first.name)});
        case '/api/ui/screenshot':
          // Only a file name is accepted; screenshots always go to the temp directory.
          var name = p.basename(query['name'] ?? 'wiretune_ui_screenshot.png');
          if (!name.toLowerCase().endsWith('.png')) name = '$name.png';
          final savePath = p.join(Directory.systemTemp.path, name);
          await _screenshot(savePath);
          return await _json(request, 200, {'Success': true, 'Path': savePath});
        case '/api/ui/resize':
          final width = double.tryParse(query['width'] ?? '');
          final height = double.tryParse(query['height'] ?? '');
          if (width == null || height == null) break;
          if (await windowManager.isMaximized()) await windowManager.unmaximize();
          // Below the user's 720 px minimum too, so a script can look at the phone layout.
          await windowManager.setMinimumSize(const Size(320, 480));
          await windowManager.setSize(Size(width, height));
          return await _json(request, 200, {'Success': true});
        case '/api/ui/search':
          _vm.searchQuery = query['q'] ?? '';
          return await _json(request, 200, {'Success': true, 'Query': query['q'] ?? ''});
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
          if (track == null) return await _json(request, 404, {'Error': 'Track not found'});
          _vm.player.playQueue([track], track);
          return await _json(request, 200, {'Success': true, 'Id': track.id, 'Title': track.title});
        case '/api/ui/connect':
          final url = query['url'];
          if (url == null || url.isEmpty) break;
          _vm.serverSettings.serverUrl = url;
          await _vm.serverSettings.connectServer();
          return await _json(request, 200, {
            'Success': true,
            'State': _pascal(_vm.session.state.name),
            'StatusMessage': _vm.session.statusMessage,
          });
        case '/api/ui/login':
          final user = query['user'];
          if (user == null || user.isEmpty) break;
          _vm.serverSettings
            ..username = user
            ..password = query['password'] ?? '';
          await _vm.serverSettings.login();
          final error = _vm.serverSettings.hasAuthError ? _vm.serverSettings.authErrorMessage : null;
          return await _json(request, 200, {
            'Success': error == null,
            'Error': error,
            'State': _pascal(_vm.session.state.name),
          });
        case '/api/ui/logout':
          await _vm.logout();
          return await _json(request, 200, {'Success': true, 'State': _pascal(_vm.session.state.name)});
        case '/api/ui/continue-offline':
          _vm.continueOffline();
          return await _json(request, 200, {'Success': true});
        case '/api/ui/playlist/new':
          _vm.playlists.openCreateDialog();
          _vm.playlists.newPlaylistName = query['name'] ?? '';
          return await _json(request, 200, {'Success': true});
        case '/api/ui/playlist/create':
          await _vm.playlists.createPlaylist();
          return await _json(request, 200, {'Success': true, 'Count': _vm.library.playlists.length});
        case '/api/ui/playlist/add-current':
          _vm.addToPlaylist(_vm.player.currentTrack);
          return await _json(request, 200, {'Success': true});
        case '/api/ui/playlist/add-to':
          final name = query['name'];
          if (name == null || name.isEmpty) break;
          await _vm.playlists.addPendingTrackTo(_vm.library.playlists.where((pl) => pl.name == name).firstOrNull);
          return await _json(request, 200, {'Success': true});
        case '/api/ui/play-pause':
          await _vm.player.togglePlayPause();
          return await _json(request, 200, {'Success': true});
        case '/api/ui/next':
          _vm.player.nextTrack();
          return await _json(request, 200, {'Success': true});
        case '/api/ui/prev':
          _vm.player.previousTrack();
          return await _json(request, 200, {'Success': true});
        case '/api/ui/seek':
          final seconds = double.tryParse(query['seconds'] ?? '');
          if (seconds == null) break;
          await _vm.audioEngine.seek(Duration(milliseconds: (seconds * 1000).round()));
          return await _json(request, 200, {'Success': true, 'Seconds': seconds});
        case '/api/ui/volume':
          final level = double.tryParse(query['level'] ?? '');
          if (level == null) break;
          _vm.player.setVolume(level);
          return await _json(request, 200, {'Success': true, 'Volume': level});
        case '/api/ui/toggle-favorite':
          final trackId = query['trackid'];
          if (trackId == null || trackId.isEmpty) break;
          await _vm.library.toggleFavorite(trackId);
          return await _json(request, 200, {'Success': true, 'TrackId': trackId});
        case '/api/ui/toggle-queue':
          _vm.player.toggleQueue();
          return await _json(request, 200, {'Success': true, 'IsQueueOpen': _vm.player.isQueueOpen});
        case '/api/ui/open-album':
          final title = query['title']?.toLowerCase();
          if (title == null || title.isEmpty) break;
          final album = _vm.library.albums.where((a) => a.title.toLowerCase().contains(title)).firstOrNull;
          if (album == null) return await _json(request, 404, {'Error': 'Album not found'});
          _vm.openAlbum(album);
          return await _json(request, 200, {'Success': true, 'Title': album.title});
        case '/api/ui/open-artist':
          final name = query['name']?.toLowerCase();
          if (name == null || name.isEmpty) break;
          final artist = _vm.library.artists.where((a) => a.name.toLowerCase().contains(name)).firstOrNull;
          if (artist == null) return await _json(request, 404, {'Error': 'Artist not found'});
          _vm.openArtist(artist);
          return await _json(request, 200, {'Success': true, 'Name': artist.name});
      }
      return await _json(request, 404, {'Error': 'Not found or invalid parameters', 'Path': path});
    } catch (e, s) {
      WiretuneLog.error('UiAutomation', 'Request handling error: $e', e, s);
      try {
        await _json(request, 500, {'Error': '$e'});
      } catch (_) {}
    }
  }

  Map<String, Object?> _state() {
    final engine = _vm.audioEngine;
    final track = engine.currentTrack;
    return {
      'Section': _pascal(_vm.selectedSection.name),
      'SearchQuery': _vm.searchQuery,
      'StatusText': _vm.statusText,
      'IsLoginViewActive': _vm.isLoginViewActive,
      'ServerState': _pascal(_vm.session.state.name),
      'ServerMessage': _vm.session.statusMessage,
      'PlaybackState': _pascal(engine.state.name),
      'PlayerError': _vm.player.errorMessage,
      'CurrentTrack': track == null
          ? null
          : {
              'Id': track.id,
              'Title': track.title,
              'Artist': track.artist,
              'Album': track.album,
              'IsFavorite': track.isFavorite,
            },
      'CurrentPositionSeconds': engine.currentPosition.inMilliseconds / 1000,
      'Volume': engine.volume,
      'IsMuted': engine.isMuted,
      'IsBitperfect': engine.isBitperfect,
      'IsExclusive': engine.isExclusiveMode,
      'RepeatMode': _pascal(_vm.player.repeatMode.name),
      'IsShuffle': _vm.player.isShuffle,
      'IsQueueOpen': _vm.player.isQueueOpen,
      'AudioDevices': [
        for (final d in _vm.audioSettings.availableDevices)
          {'Id': d.id, 'Name': d.name, 'Exclusive': d.isExclusiveSupported, 'BitPerfect': d.isBitperfectSupported},
      ],
      'SelectedDevice': _vm.audioSettings.selectedDevice?.id,
      'IsExclusiveAvailable': _vm.audioSettings.isExclusiveAvailable,
      'IsBitperfectAvailable': _vm.audioSettings.isBitperfectAvailable,
      'SpectrumPeak': _vm.player.spectrum.value.fold<double>(0, (a, b) => a > b ? a : b),
      'TracksCount': _vm.library.tracks.length,
      'AlbumsCount': _vm.library.albums.length,
      'ArtistsCount': _vm.library.artists.length,
      'PlaylistsCount': _vm.library.playlists.length,
      'FavoritesCount': _vm.library.favorites.length,
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

  static String _pascal(String name) => name.isEmpty ? name : name[0].toUpperCase() + name.substring(1);

  static Future<void> _json(HttpRequest request, int status, Object data) async {
    final response = request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json;
    response.write(const JsonEncoder.withIndent('  ').convert(data));
    await response.close();
  }
}
