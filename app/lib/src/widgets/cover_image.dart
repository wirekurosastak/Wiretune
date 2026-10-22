// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:wiretune_core/wiretune_core.dart';

import '../theme/app_theme.dart';

/// Where covers may be requested with the sign-in token: only the Wiretune server's own address ever sees it. A cover
/// that was downloaded (with an album, a playlist ...) comes from its copy.
abstract final class CoverArt {
  static String? serverUrl;
  static String? authToken;

  /// The downloaded copy of the cover at a URL, if there is one.
  static String? Function(String url)? localCopy;

  /// Where the server's covers are kept once shown, so that they appear at once, also offline; null keeps them in
  /// memory only.
  static String? cacheDirectory;

  /// What the kept covers may take on disk; past it, the ones kept longest go first.
  static const int _cacheLimitBytes = 300 << 20;

  /// What the kept covers are downloaded with. Tests replace it.
  static http.Client client = http.Client();

  static ImageProvider? provider(String? pathOrUrl, {int? decodeWidth}) {
    if (pathOrUrl == null || pathOrUrl.trim().isEmpty) return null;
    final copy = localCopy?.call(pathOrUrl);
    if (copy != null) pathOrUrl = copy;
    ImageProvider image;
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      final server = serverUrl;
      final token = authToken;
      final ownServer = server != null && server.isNotEmpty && pathOrUrl.startsWith(server);
      final headers = ownServer && token != null ? {'Authorization': 'Bearer $token'} : null;
      final cache = cacheDirectory;
      image = ownServer && cache != null
          ? _KeptCover(pathOrUrl, p.join(cache, '${stableId(pathOrUrl)}.img'), headers)
          : NetworkImage(pathOrUrl, headers: headers);
    } else {
      final file = File(pathOrUrl);
      image = FileImage(file);
    }
    // Decoded at the size it is shown at: a full-size cover per row of a long list would fill the memory.
    return decodeWidth == null ? image : ResizeImage(image, width: decodeWidth, allowUpscaling: false);
  }

  /// Keeps the kept covers within their limit: the oldest go first.
  static Future<void> trimCache() async {
    final cache = cacheDirectory;
    if (cache == null) return;
    try {
      final files = [
        await for (final entity in Directory(cache).list())
          if (entity is File) (file: entity, stat: await entity.stat()),
      ]..sort((a, b) => b.stat.modified.compareTo(a.stat.modified));
      var total = 0;
      for (final (:file, :stat) in files) {
        total += stat.size;
        if (total > _cacheLimitBytes) await file.delete();
      }
    } on FileSystemException {
      // Not there yet, or not readable: nothing to trim.
    }
  }
}

/// A cover from the server, kept on disk: downloaded once, then read from the file. Its address carries the cover's
/// version, so a cover that changed is another file, never a stale one.
class _KeptCover extends ImageProvider<_KeptCover> {
  const _KeptCover(this.url, this.path, this.headers);

  final String url;
  final String path;
  final Map<String, String>? headers;

  // One download per cover, however many sizes of it are asked for at once.
  static final Map<String, Future<Uint8List>> _downloads = {};

  @override
  Future<_KeptCover> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_KeptCover key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1, debugLabel: url);

  Future<ui.Codec> _load(_KeptCover key, ImageDecoderCallback decode) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        try {
          return await decode(await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes()));
        } catch (_) {
          await file.delete(); // damaged: downloaded again below
        }
      }
      return await decode(await ui.ImmutableBuffer.fromUint8List(await (_downloads[url] ??= _download())));
    } catch (_) {
      // Not remembered as broken: the next showing tries again (the server may be back by then).
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  Future<Uint8List> _download() async {
    try {
      final response = await CoverArt.client.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 30));
      final isImage = (response.headers['content-type'] ?? '').startsWith('image/');
      if (response.statusCode != 200 || !isImage || response.bodyBytes.isEmpty) {
        throw NetworkImageLoadException(statusCode: response.statusCode, uri: Uri.parse(url));
      }
      final bytes = response.bodyBytes;
      try {
        await Directory(p.dirname(path)).create(recursive: true);
        final part = File('$path.${newId()}.part');
        await part.writeAsBytes(bytes, flush: true);
        await part.rename(path);
      } on FileSystemException catch (e) {
        WiretuneLog.debug('CoverArt', 'Could not keep a cover: $e'); // shown all the same, only not kept
      }
      return bytes;
    } finally {
      _downloads.remove(url);
    }
  }

  @override
  bool operator ==(Object other) => other is _KeptCover && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// A cover (or artist picture) with a placeholder icon while it loads or when there is none.
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.path,
    this.size,
    this.radius = Radii.small,
    this.placeholderIcon = Icons.music_note,
    this.circle = false,
    this.decodeWidth,
    this.placeholderColor,
  });

  final String? path;
  final double? size;
  final double radius;
  final IconData placeholderIcon;
  final bool circle;
  final int? decodeWidth;

  /// The placeholder icon's colour; the section's accent when not given.
  final Color? placeholderColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final width = decodeWidth ?? (size == null ? 512 : (size! * ratio).round());
    final provider = CoverArt.provider(path, decodeWidth: width);

    Widget placeholder() => Container(
      color: colors.surface2,
      alignment: Alignment.center,
      child: LayoutBuilder(
        builder: (context, constraints) => Icon(
          placeholderIcon,
          color: placeholderColor ?? colors.accent.withValues(alpha: 0.8),
          size: (constraints.biggest.shortestSide.isFinite ? constraints.biggest.shortestSide : 48) * 0.42,
        ),
      ),
    );

    final image = provider == null
        ? placeholder()
        : Image(
            image: provider,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            frameBuilder: (context, child, frame, sync) => frame == null && !sync ? placeholder() : child,
            errorBuilder: (context, error, stack) => placeholder(),
          );

    final clipped = circle
        ? ClipOval(child: image)
        : ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
    return size == null ? clipped : SizedBox.square(dimension: size, child: clipped);
  }
}
