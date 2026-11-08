// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart' show Hct, QuantizerCelebi, Score;

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

  /// The covers softened last, a few, for the next wash of them: the full-screen player's, rising over a page that
  /// washes in the same cover or rose before, has its colours from its first frame, rather than fading them in over
  /// itself as it rises.
  static final Map<String, ui.Image> _softened = {};

  static void _remember(String path, ui.Image image) {
    _softened.remove(path)?.dispose();
    _softened[path] = image.clone();
    if (_softened.length > 4) _softened.remove(_softened.keys.first)!.dispose();
  }

  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _image;

  static const Duration _fade = Duration(milliseconds: 900);

  /// The images replaced, which the switcher still fades out (and lays out again when the area resizes); each goes once
  /// its fade is over. Released at once, a rebuild of the fading one failed ("Cannot clone a disposed image").
  final Set<ui.Image> _fading = {};

  void _retire(ui.Image? image) {
    if (image == null) return;
    _fading.add(image);
    Timer(_fade + const Duration(milliseconds: 100), () {
      if (_fading.remove(image)) image.dispose();
    });
  }

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
    for (final image in _fading) {
      image.dispose();
    }
    _fading.clear();
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
    if (_softened.remove(path) case final softened?) {
      _softened[path!] = softened; // the latest again
      // Before this frame's build: no fade.
      _retire(_image);
      _image = softened.clone();
      return;
    }
    final listener = ImageStreamListener(
      (info, _) {
        _soften(info.image)
            .then((image) {
              _remember(path!, image);
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
      _retire(_image);
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
        duration: _fade,
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
  const AmbientBackdrop({super.key, this.colour = 0.55, this.nowPlaying = false});

  final double colour;

  /// The colours of the track that plays, whatever page is open: behind the full-screen player, and around the black
  /// pages of the Dark theme, where the open album's or artist's cover glows at the top instead ([FrameWash]).
  final bool nowPlaying;

  /// The cover whose colours wash the backdrop: the album's or the artist's whose page is open (unless [nowPlaying]),
  /// else the cover of the track that plays, the one the player shows (none when it has none).
  static String? activeCoverPath(MainViewModel vm, {bool nowPlaying = false}) =>
      (nowPlaying ? null : viewedCoverPath(vm)) ?? _cover(vm.player.currentTrack?.coverArtPath);

  /// The cover of the album or the artist whose page is open; null on any other page, or for one without a cover.
  static String? viewedCoverPath(MainViewModel vm) {
    final artist = vm.artists.selectedArtist;
    return switch (vm.selectedSection) {
      AppSection.albums when vm.albums.isAlbumDetailOpen => _cover(vm.albums.selectedAlbum?.coverArtPath),
      AppSection.artists when vm.artists.isArtistDetailOpen => _cover(
        artist?.picturePath ?? artist?.albums.firstOrNull?.coverArtPath,
      ),
      _ => null,
    };
  }

  static String? _cover(String? path) => path == null || path.isEmpty ? null : path;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final platform = AppPlatform.current;
    final colors = context.colors;
    final base = colors.palette.background;
    // The less colour, the thicker the veil.
    final veil = [0.5 - 0.35 * colour, 0.75 - 0.4 * colour, 0.85 - 0.1 * colour];

    return ListenableBuilder(
      listenable: Listenable.merge([vm, player, vm.albums, vm.artists]),
      builder: (context, _) {
        final cover = activeCoverPath(vm, nowPlaying: nowPlaying);
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedContainer(duration: const Duration(milliseconds: 450), color: base),
            AmbientArtwork(path: cover, drift: player.isPlaying && platform.isDesktop, opacity: colour),
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

/// The top of a black page of the Dark theme ([WiretuneTheme.dark]) on an album's or an artist's page: washed in
/// the colours of its cover, fading out downwards over about the page's header, and leaving with the header as the
/// page scrolls ([FrameWashScope]). Nothing on any other page, or in the Airy theme.
class FrameWash extends StatelessWidget {
  const FrameWash({super.key});

  /// How far down the wash reaches, at most.
  static const double height = 380;

  /// How far short of the wash's edge its picture ends.
  static const double _edgeRoom = 8;

  /// Where it stays without a [FrameWashScope] around it.
  static final ValueNotifier<double> _unscrolled = ValueNotifier(0);

  /// Whether an album's or an artist's page is on show in the Dark theme, with no search or queue over it.
  static bool isOn(MainViewModel vm) =>
      vm.theme == WiretuneTheme.dark &&
      !vm.isSearchActive &&
      !vm.isSearchOpen &&
      !vm.player.isQueueOpen &&
      switch (vm.selectedSection) {
        AppSection.albums => vm.albums.isAlbumDetailOpen,
        AppSection.artists => vm.artists.isArtistDetailOpen,
        _ => false,
      };

  /// The cover it shows: the open album's or artist's while [isOn].
  static String? coverPath(MainViewModel vm) => isOn(vm) ? AmbientBackdrop.viewedCoverPath(vm) : null;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final scrolled = context.findAncestorStateOfType<_FrameWashScopeState>()?._scrolled ?? _unscrolled;
    return ListenableBuilder(
      listenable: Listenable.merge([vm, vm.player, vm.albums, vm.artists]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) => ValueListenableBuilder(
          valueListenable: scrolled,
          // Up as far as the page has scrolled, as its header goes. Pulled down past its top (a phone's page gives, as
          // an iPhone's does) it stays at the top and stretches down with the header, leaving no black above it.
          // In whole pixels of the screen, so that its edges never fall between two.
          builder: (context, offset, child) {
            final ratio = MediaQuery.devicePixelRatioOf(context);
            double pixels(double value) => (value * ratio).roundToDouble() / ratio;
            return Transform.translate(
              offset: Offset(0, -pixels(math.max(offset, 0.0))),
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: double.infinity,
                  height: pixels(math.min(height, constraints.maxHeight * 0.6) + math.max(-offset, 0.0)),
                  child: child,
                ),
              ),
            );
          },
          child: RepaintBoundary(
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                // Fully gone a little before its edge.
                colors: [Colors.black, Colors.black54, Colors.transparent, Colors.transparent],
                stops: [0, 0.55, 0.95, 1],
              ).createShader(rect),
              // The picture ends short of the mask's edge, where the mask has made it clear: its own clipped edge
              // can round out by a row of pixels, and a row past the mask would show unmasked, a hairline of the
              // cover's colour across the page (seen on a phone under an album's title).
              child: Padding(
                padding: const EdgeInsets.only(bottom: _edgeRoom),
                child: AmbientArtwork(path: coverPath(vm), opacity: 0.6),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Around the page and its [FrameWash]: how far the page has scrolled, from its own list (the outermost one under this,
/// going up and down; not a row of tiles going sideways), as soon as it is laid out and as it scrolls.
class FrameWashScope extends StatefulWidget {
  const FrameWashScope({super.key, required this.child});

  final Widget child;

  @override
  State<FrameWashScope> createState() => _FrameWashScopeState();
}

class _FrameWashScopeState extends State<FrameWashScope> {
  final ValueNotifier<double> _scrolled = ValueNotifier(0);

  @override
  void dispose() {
    _scrolled.dispose();
    super.dispose();
  }

  bool _follow(Notification notification) {
    final (metrics, depth) = switch (notification) {
      ScrollNotification(:final metrics, :final depth) => (metrics, depth),
      ScrollMetricsNotification(:final metrics, :final depth) => (metrics, depth),
      _ => (null, -1),
    };
    if (metrics != null && depth == 0 && metrics.axis == Axis.vertical) _scrolled.value = metrics.pixels;
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener(onNotification: _follow, child: widget.child);
}

/// The Albums or the Artists page, in the accent of the album or the artist it has open (the cover that washes it,
/// in either theme): its Play button, its slider, the song that plays in its list. The players around it keep the
/// colour of the song that plays, and the page takes it back when the album or the artist closes. The accent and its
/// blend are the [ViewedAccentScope]'s, above the pages: an album opened from its artist's page (another section's)
/// blends on from the artist's accent, not from the song's.
class ViewedAccent extends StatelessWidget {
  const ViewedAccent({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    Theme.of(context); // rebuilt with the app's theme
    final viewed = context.dependOnInheritedWidgetOfExactType<_ViewedTheme>()?.data;
    // The app's theme as given, not localized as Theme.of gives it, so that it blends with one built here.
    return Theme(data: viewed ?? context.findAncestorWidgetOfExactType<Theme>()!.data, child: child);
  }
}

/// Where the open album's or artist's accent is kept, and blended over as it changes, for the [ViewedAccent] pages
/// under it: above them, so that one page giving way to another (an artist's to its album's, a section to another)
/// blends from the accent that was on show, and keeps it while the next cover's colour is read.
class ViewedAccentScope extends StatefulWidget {
  const ViewedAccentScope({super.key, required this.child});

  final Widget child;

  @override
  State<ViewedAccentScope> createState() => _ViewedAccentScopeState();
}

class _ViewedAccentScopeState extends State<ViewedAccentScope> {
  late final Listenable _views;
  String? _path;

  /// The open album's or artist's cover colour; null: the page has the app's accent (the song's).
  ({Color? colour})? _viewed;

  /// Whether the pages have the app's own theme as it is: no album or artist open, and the blend back from one over.
  bool _plain = true;

  @override
  void initState() {
    super.initState();
    final vm = context.vm;
    _views = Listenable.merge([vm, vm.albums, vm.artists])..addListener(_follow);
    _follow();
  }

  @override
  void dispose() {
    _views.removeListener(_follow);
    super.dispose();
  }

  void _follow() {
    final vm = context.vm;
    final path = AmbientBackdrop.viewedCoverPath(vm);
    if (path == _path) return;
    _path = path;
    if (path == null) return _show(null);
    if (CoverColor.isKnown(path)) return _show((colour: CoverColor.known(path)));
    // Until its colour is read, the accent on show stays.
    CoverColor.read(path).then((colour) {
      if (mounted && _path == path) _show((colour: colour));
    });
  }

  void _show(({Color? colour})? viewed) {
    if (viewed == _viewed) return;
    setState(() {
      _viewed = viewed;
      if (viewed != null) _plain = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    Theme.of(context); // rebuilt with the app's theme
    // The app's theme as given, not localized as Theme.of gives it, so that it blends with one built here.
    final inherited = context.findAncestorWidgetOfExactType<Theme>()!.data;
    final viewed = _viewed;
    final platform = AppPlatform.current;
    final target = viewed == null
        ? inherited
        : cachedTheme(
            accent: context.colors.palette.accentOf(viewed.colour),
            isTv: platform.isTv,
            desktopFonts: platform.isDesktop,
          );
    // From the theme on show to the new one, as the app's own theme blends (`MaterialApp.themeAnimationDuration`); the
    // first one at once.
    return TweenAnimationBuilder<ThemeData>(
      tween: ThemeDataTween(end: target),
      duration: const Duration(milliseconds: 350),
      onEnd: () {
        if (_viewed == null && !_plain) setState(() => _plain = true);
      },
      // Null while the pages have the app's own theme.
      builder: (context, data, child) => _ViewedTheme(data: _plain ? null : data, child: child!),
      child: widget.child,
    );
  }
}

class _ViewedTheme extends InheritedWidget {
  const _ViewedTheme({required this.data, required super.child});

  final ThemeData? data;

  @override
  bool updateShouldNotify(_ViewedTheme oldWidget) => data != oldWidget.data;
}

/// The colour of a cover, what the accent is made of (`Palette.accentOf`): read once, from the same small decoding as
/// its wash, and kept for the covers seen last.
abstract final class CoverColor {
  static final Map<String, Color?> _known = {};
  static final Map<String, Future<Color?>> _reading = {};

  /// Whether the colour of the cover at [path] has been read: [known] then gives it.
  static bool isKnown(String path) => _known.containsKey(path);

  /// The colour of the cover at [path], as read; null for a grey one, one that couldn't be read, or one not read yet.
  static Color? known(String path) => _known[path];

  /// Reads the colour of the cover at [path] (see [of]).
  static Future<Color?> read(String path) {
    if (_known.containsKey(path)) return Future.value(_known[path]);
    return _reading[path] ??= () async {
      Color? colour;
      final provider = CoverArt.provider(path, decodeWidth: 64);
      if (provider != null) {
        final done = Completer<Color?>();
        final stream = provider.resolve(ImageConfiguration.empty);
        final listener = ImageStreamListener(
          (info, _) {
            if (done.isCompleted) return info.dispose();
            info.image
                .toByteData()
                .then((rgba) async => done.complete(rgba == null ? null : await of(rgba)))
                .catchError((Object _) => done.complete(null))
                .whenComplete(info.dispose);
          },
          // A cover that cannot be read leaves the accent neutral, as it leaves the wash out.
          onError: (error, stack) {
            if (!done.isCompleted) done.complete(null);
          },
        );
        stream.addListener(listener);
        colour = await done.future;
        stream.removeListener(listener);
      }
      _reading.remove(path);
      _known[path] = colour;
      if (_known.length > 48) _known.remove(_known.keys.first);
      return colour;
    }();
  }

  /// The colour of a cover from its pixels ([rgba], four bytes each), as Android takes a wallpaper's (Material You):
  /// its colours grouped, those near black left out (their tint is the file's noise or a vignette), and of the rest
  /// the one scored first (the most of the cover, the more colourful the better) that is a colour rather than a tinted
  /// grey. Null for a grey cover, or one whose colour is only a speck.
  static Future<Color?> of(ByteData rgba) async {
    final pixels = <int>[];
    for (var i = 0; i + 3 < rgba.lengthInBytes; i += 4) {
      if (rgba.getUint8(i + 3) < 128) continue;
      pixels.add(0xFF000000 | rgba.getUint8(i) << 16 | rgba.getUint8(i + 1) << 8 | rgba.getUint8(i + 2));
    }
    if (pixels.isEmpty) return null;
    final groups = await QuantizerCelebi().quantize(pixels, 128);
    final lit = {
      for (final MapEntry(:key, :value) in groups.colorToCount.entries)
        if (Hct.fromInt(key).tone >= _leastTone) key: value,
    };
    if (lit.isEmpty) return null;
    // The scorer's fallback when nothing passes, which no cover's colour is.
    const none = 0x00000000;
    final best = Score.score(
      lit,
      desired: 4,
      fallbackColorARGB: none,
    ).where((colour) => colour != none && Hct.fromInt(colour).chroma >= _leastChroma).firstOrNull;
    return best == null ? null : Color(best);
  }

  /// Darker than this a colour group is near black (Material's tone, 0 black to 100 white).
  static const double _leastTone = 20;

  /// Less colourful than this a colour group is a tinted grey (Material's chroma).
  static const double _leastChroma = 20;
}
