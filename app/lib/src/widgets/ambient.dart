// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../view_models/main_view_model.dart';
import 'cover_image.dart';

/// A cover turned into a soft wash of its colours: decoded tiny, blurred and saturated once into a 96 px bitmap, then
/// stretched over the whole area (so nothing is blurred per frame). With [drift] two copies of it turn slowly against
/// each other and the colours seem to flow. A new cover fades in over the old one; without a cover nothing is drawn.
class AmbientArtwork extends StatefulWidget {
  const AmbientArtwork({super.key, required this.path, this.drift = false, this.opacity = 1});

  final String? path;
  final bool drift;
  final double opacity;

  @override
  State<AmbientArtwork> createState() => _AmbientArtworkState();
}

class _AmbientArtworkState extends State<AmbientArtwork> with SingleTickerProviderStateMixin {
  static const int _size = 96;

  // Saturation × 1.6 (Rec. 709 luminance), so even muted covers give a vivid wash.
  static const List<double> _saturate = [
    1.4724, -0.4291, -0.0433, 0, 0, //
    -0.1276, 1.1709, -0.0433, 0, 0, //
    -0.1276, -0.4291, 1.5567, 0, 0, //
    0, 0, 0, 1, 0,
  ];

  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(seconds: 48));
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _image;
  String? _requested;
  bool _resolved = false;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
    _updateDrift();
  }

  @override
  void didUpdateWidget(AmbientArtwork old) {
    super.didUpdateWidget(old);
    _resolve();
    _updateDrift();
  }

  @override
  void dispose() {
    _stopListening();
    _drift.dispose();
    _image?.dispose();
    super.dispose();
  }

  void _updateDrift() {
    if (!mounted) return;
    final animate = widget.drift && _image != null && !MediaQuery.disableAnimationsOf(context);
    if (animate && !_drift.isAnimating) {
      _drift.repeat();
    } else if (!animate && _drift.isAnimating) {
      _drift.stop();
    }
  }

  void _resolve() {
    final path = widget.path;
    if (_resolved && path == _requested) return;
    _resolved = true;
    _requested = path;
    _stopListening();
    final generation = ++_generation;
    final provider = CoverArt.provider(path, decodeWidth: 64);
    if (provider == null) {
      _show(null);
      return;
    }
    final listener = ImageStreamListener(
      (info, _) {
        _soften(info.image)
            .then((image) {
              if (!mounted || generation != _generation) {
                image.dispose();
              } else {
                _show(image);
              }
            })
            .whenComplete(info.dispose);
      },
      // A cover that cannot be read just leaves the wash out; the cover itself shows its placeholder.
      onError: (error, stack) {
        if (mounted && generation == _generation) _show(null);
      },
    );
    _stream = provider.resolve(createLocalImageConfiguration(context))..addListener(listener);
    _listener = listener;
  }

  void _stopListening() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  void _show(ui.Image? image) {
    if (image == null && _image == null) return;
    // The widgets hold clones of the bitmap; this handle is ours to release.
    setState(() {
      _image?.dispose();
      _image = image;
    });
    _updateDrift();
  }

  static Future<ui.Image> _soften(ui.Image source) {
    final recorder = ui.PictureRecorder();
    final src = Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble());
    // Drawn a little past the edges, so the blur has colour to pull in there instead of transparency.
    Canvas(recorder).drawImageRect(
      source,
      src,
      Rect.fromLTWH(-12, -12, _size + 24.0, _size + 24.0),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..imageFilter = ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9)
        ..colorFilter = const ColorFilter.matrix(_saturate),
    );
    final picture = recorder.endRecording();
    return picture.toImage(_size, _size).whenComplete(picture.dispose);
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 900),
        child: image == null
            ? const SizedBox.expand()
            : RepaintBoundary(
                key: ObjectKey(image),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // A square as wide as the area's diagonal covers it at any angle.
                    final size = constraints.biggest;
                    final diagonal = size.isFinite
                        ? math.sqrt(size.width * size.width + size.height * size.height)
                        : 0.0;
                    return Stack(
                      fit: StackFit.expand,
                      children: [_layer(image, diagonal, 1, 1), _layer(image, diagonal * 1.25, -1, 0.5)],
                    );
                  },
                ),
              ),
      ),
    );
  }

  /// One turning copy, a [side] px square around the centre; the second is mirrored and turns the other way, so the two
  /// mix into shapes neither has.
  Widget _layer(ui.Image image, double side, double direction, double alpha) => OverflowBox(
    minWidth: side,
    maxWidth: side,
    minHeight: side,
    maxHeight: side,
    child: AnimatedBuilder(
      animation: _drift,
      builder: (context, child) => Transform.rotate(angle: direction * _drift.value * 2 * math.pi, child: child),
      child: Transform.flip(
        flipX: direction < 0,
        child: RawImage(
          image: image,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.medium,
          opacity: AlwaysStoppedAnimation(widget.opacity * alpha),
        ),
      ),
    ),
  );
}

/// The window's backdrop: a neutral base and, over it, the colours of the cover that is playing or viewed (flowing
/// while it plays, on a desktop), under a veil that keeps what is on top readable. [colour] sets how much of the cover
/// shows: a little behind the phone's pages, more behind the wide layout, all of it behind the full-screen player.
class AmbientBackdrop extends StatelessWidget {
  const AmbientBackdrop({super.key, this.colour = 0.55});

  final double colour;

  static String? activeCoverPath(MainViewModel vm) {
    // 1. Only navigating inside an album or artist overrides the playing track's cover,
    // and only while that section is currently selected.
    if (vm.selectedSection == AppSection.albums && vm.albums.isAlbumDetailOpen && vm.albums.selectedAlbum != null) {
      final path = vm.albums.selectedAlbum?.coverArtPath;
      if (path != null && path.isNotEmpty) return path;
    }
    if (vm.selectedSection == AppSection.artists &&
        vm.artists.isArtistDetailOpen &&
        vm.artists.selectedArtist != null) {
      final artist = vm.artists.selectedArtist;
      final path = artist?.picturePath ?? artist?.albums.firstOrNull?.coverArtPath;
      if (path != null && path.isNotEmpty) return path;
    }

    // 2. Default: always current playing song's cover.
    final track = vm.player.currentTrack;
    if (track != null) {
      if (track.coverArtPath != null && track.coverArtPath!.isNotEmpty) {
        return track.coverArtPath;
      }
      for (final album in vm.albums.displayedAlbums) {
        if (album.id == track.albumId || (album.title == track.album && album.artist == track.artist)) {
          if (album.coverArtPath != null && album.coverArtPath!.isNotEmpty) {
            return album.coverArtPath;
          }
        }
      }
      for (final t in vm.tracks.displayedTracks) {
        if (t.id == track.id && t.coverArtPath != null && t.coverArtPath!.isNotEmpty) {
          return t.coverArtPath;
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final platform = AppPlatform.current;
    final colors = context.colors;
    final isDark = colors.palette.isDark;
    final base = colors.palette.background;
    // The less colour, the thicker the veil. In light mode a gentle pastel wash keeps readability crisp.
    final veil = isDark
        ? [0.5 - 0.35 * colour, 0.75 - 0.4 * colour, 0.85 - 0.1 * colour]
        : [0.68 - 0.22 * colour, 0.82 - 0.18 * colour, 0.92 - 0.12 * colour];
    final artworkOpacity = isDark ? colour : (colour * 0.42).clamp(0.0, 0.36);

    return ListenableBuilder(
      listenable: Listenable.merge([vm, player, vm.albums, vm.artists]),
      builder: (context, _) {
        final cover = activeCoverPath(vm);
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedContainer(duration: const Duration(milliseconds: 450), color: base),
            AmbientArtwork(
              path: cover,
              drift: player.isPlaying && !platform.isTv && !platform.isMobile,
              opacity: artworkOpacity,
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [for (final alpha in veil) base.withValues(alpha: alpha)],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
