// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Where covers may be requested with the sign-in token: only the Wiretune server's own address ever sees it. A cover
/// that was downloaded (with an album, a playlist ...) comes from its copy.
abstract final class CoverArt {
  static String? serverUrl;
  static String? authToken;

  /// The downloaded copy of the cover at a URL, if there is one.
  static String? Function(String url)? localCopy;

  static ImageProvider? provider(String? pathOrUrl, {int? decodeWidth}) {
    if (pathOrUrl == null || pathOrUrl.trim().isEmpty) return null;
    final copy = localCopy?.call(pathOrUrl);
    if (copy != null) pathOrUrl = copy;
    ImageProvider image;
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      final server = serverUrl;
      final token = authToken;
      final ownServer = server != null && server.isNotEmpty && pathOrUrl.startsWith(server);
      image = NetworkImage(pathOrUrl, headers: ownServer && token != null ? {'Authorization': 'Bearer $token'} : null);
    } else {
      final file = File(pathOrUrl);
      image = FileImage(file);
    }
    // Decoded at the size it is shown at: a full-size cover per row of a long list would fill the memory.
    return decodeWidth == null ? image : ResizeImage(image, width: decodeWidth, allowUpscaling: false);
  }
}

/// A cover (or artist picture) with a placeholder icon while it loads or when there is none.
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.path,
    this.size,
    this.radius = 8,
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
