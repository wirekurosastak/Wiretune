// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../view_models/library_view_models.dart';
import '../widgets/badges.dart';
import '../widgets/buttons.dart';
import '../widgets/cards.dart';
import '../widgets/cover_flight.dart';
import '../widgets/cover_image.dart';
import '../widgets/dialogs.dart';
import '../widgets/downloads.dart';
import '../widgets/links.dart';
import '../widgets/page_parts.dart';
import '../widgets/track_list.dart';

/// What an empty library says, with the two ways to fill it: a server, or a folder of this computer. While a scan or a
/// download from the server is filling it, it says that instead, and in offline mode that nothing is downloaded.
class EmptyLibrary extends StatelessWidget {
  const EmptyLibrary({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) {
        if (vm.library.isScanning || vm.session.state == ServerConnectionState.connecting) {
          return EmptyState(
            icon: Icons.sync_rounded,
            title: vm.library.isScanning
                ? context.tr('FooterScanning')
                : vm.session.statusMessage ?? context.tr('SessionConnecting'),
          );
        }
        if (vm.session.isOfflineMode) {
          return EmptyState(
            icon: Icons.cloud_off_rounded,
            title: context.tr('OfflineModeEmptyTitle'),
            hint: context.tr('OfflineModeEmptyHint'),
            actions: [
              OutlinedButton.icon(
                onPressed: () => vm.navigateTo(AppSection.settings),
                icon: Icon(Icons.settings_outlined, size: 18, color: colors.accent),
                label: Text(context.tr('NavSettings')),
              ),
            ],
          );
        }
        return EmptyState(
          icon: Icons.library_music_outlined,
          title: context.tr('EmptyLibraryTitle'),
          hint: context.tr(vm.capabilities.supportsLocalFolder ? 'EmptyLibraryHint' : 'EmptyLibraryHintServer'),
          actions: [
            PressShrink(
              child: FilledButton.icon(
                onPressed: vm.showLoginScreen,
                icon: const Icon(Icons.dns_outlined, size: 18),
                label: Text(context.tr('ConnectToServer')),
              ),
            ),
            if (vm.capabilities.supportsLocalFolder)
              OutlinedButton.icon(
                onPressed: () => vm.navigateTo(AppSection.settings),
                icon: Icon(Icons.folder_open_outlined, size: 18, color: colors.accent),
                label: Text(context.tr('LocalFolder')),
              ),
          ],
        );
      },
    );
  }
}

class TracksPage extends StatelessWidget {
  const TracksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final page = context.vm.tracks;
    return ListenableBuilder(
      listenable: page,
      builder: (context, _) {
        if (page.isEmpty) return const EmptyLibrary();
        return TabPageList(
          title: context.tr('NavTracks'),
          storageKey: 'tracks',
          scrollLabel: (fraction) => _trackScrollLabel(page.tracks, page.sortField, fraction),
          header: PageHeader(
            title: context.tr('NavTracks'),
            subtitle: '${context.trf('TrackCount', [page.tracks.length])}  •  ${page.totalDuration}',
            actions: [
              // A wide table sorts by its headers; a phone's pill holds the genre too.
              if (PhoneChrome.isPhone(context))
                TrackSortButtons(page, genre: (genres: page.genres, selected: page.genre, onSelected: page.setGenre))
              else if (page.genres.isNotEmpty)
                _GenreFilter(genres: page.genres, selected: page.genre, onSelected: page.setGenre),
              PlayShuffleButtons(tracks: page.tracks, onPlay: page.playAll),
            ],
          ),
          columnHeaders: TrackColumnHeaders(sorting: page),
          slivers: [
            TrackSliver(
              tracks: page.tracks,
              sorting: page,
              columnHeaders: false,
              playingFrom: page.playingFrom,
              playingSource: page.section,
            ),
            const PageEndSpace(),
          ],
        );
      },
    );
  }
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final favorites = context.vm.favorites;
    final phone = PhoneChrome.isPhone(context);
    return ListenableBuilder(
      listenable: favorites,
      builder: (context, _) {
        if (favorites.isEmpty) {
          return EmptyState(
            icon: Icons.favorite_border,
            title: context.tr('EmptyFavoritesTitle'),
            hint: context.tr('EmptyFavoritesHint'),
          );
        }
        final menu = ListMenu.favorites(favorites.tracks, name: context.tr('NavFavorites'), onPlay: favorites.playAll);
        return TabPageList(
          title: context.tr('NavFavorites'),
          storageKey: 'favorites',
          scrollLabel: (fraction) => _trackScrollLabel(favorites.tracks, favorites.sortField, fraction),
          header: PageHeader(
            title: context.tr('NavFavorites'),
            subtitle: '${context.trf('TrackCount', [favorites.tracks.length])}  •  ${favorites.totalDuration}',
            actions: [
              // A wide table sorts by its headers; a phone's pill holds the genre too.
              if (phone)
                TrackSortButtons(
                  favorites,
                  genre: (genres: favorites.genres, selected: favorites.genre, onSelected: favorites.setGenre),
                )
              else if (favorites.genres.isNotEmpty)
                _GenreFilter(genres: favorites.genres, selected: favorites.genre, onSelected: favorites.setGenre),
              PlayShuffleButtons(
                tracks: favorites.tracks,
                onPlay: favorites.playAll,
                // A list's buttons, on a wide screen; a phone's line has no room for them beside the sort. No Add to
                // playlist on either: the favourites are a list of their own already.
                playNext: phone ? null : menu.playNextButton(),
                addToQueue: phone ? null : menu.addToQueueButton(),
                // A phone's ⋮ in the download's place: Play next, Add to queue and the download, beside the sort.
                download: phone
                    ? menu.queueAndDownloadButton()
                    : DownloadListButton.forTracks(
                        favorites.tracks,
                        name: context.tr('NavFavorites'),
                        isDownloaded: () => context.vm.downloads.areFavoritesDownloaded,
                        onPressed: context.vm.downloads.toggleFavorites,
                      ),
              ),
            ],
          ),
          columnHeaders: TrackColumnHeaders(sorting: favorites),
          slivers: [
            TrackSliver(
              tracks: favorites.tracks,
              sorting: favorites,
              columnHeaders: false,
              playingFrom: favorites.playingFrom,
              playingSource: favorites.section,
            ),
            const PageEndSpace(),
          ],
        );
      },
    );
  }
}

/// A detail page's way back in its header, on a phone: room for the top bar's arrow, or without a bar the arrow itself,
/// [text] (where it leads) its tooltip. Elsewhere the row over the page has it ([PinnedTitleBar]).
class BackLink extends StatelessWidget {
  const BackLink({super.key, required this.text, required this.onPressed});

  final String text;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (PhoneChrome.isPhone(context)) {
      // The top bar's arrow stands here, as in TIDAL.
      if (PinnedTitleBar.hasBar(context)) return const SizedBox(height: PinnedTitleBar.height);
      // Without one, the arrow alone where the bar's would be; where it leads is its tooltip.
      return Padding(
        padding: const EdgeInsets.only(left: 4),
        child: SizedBox(
          height: PinnedTitleBar.height,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox.square(
              dimension: 44,
              child: IconButton(
                tooltip: text,
                onPressed: onPressed,
                icon: Icon(Icons.arrow_back_rounded, size: 24, color: colors.textMain),
              ),
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink(); // the row over the page has it
  }
}

/// The header of a detail page: the [back] button, then the large artwork (with its [artworkBadge]) beside the labels,
/// the title, a line of details and the buttons (on a phone held upright the artwork sits above, centred, and the
/// labels are left out).
class DetailHeader extends StatelessWidget {
  const DetailHeader({
    super.key,
    required this.artwork,
    required this.tags,
    required this.title,
    this.artworkBadge,
    this.roundArtwork = false,
    this.artworkFlight,
    this.back,
    this.details = const [],
    this.secondaryDetails = const [],
    this.actions = const [],
    this.titleWidget,
  });

  final Widget artwork;

  /// Shown on the artwork's corner, as on the tiles: an album's or a playlist's quality tag.
  final Widget? artworkBadge;

  /// The artwork is round (an artist's picture): so is its shadow and glow.
  final bool roundArtwork;

  /// What the artwork shows, for the cover pressed on a tile or a row to fly into it ([CoverFlightTarget]).
  final String? artworkFlight;
  final Widget? back;

  /// The labels above the title on a wide screen ("ALBUM", "PLAYLIST").
  final List<Widget> tags;
  final String title;

  /// Replaces the title text (a playlist's name, which can be clicked to rename it).
  final Widget? titleWidget;

  /// The details under the title, followed by [secondaryDetails].
  final List<Widget> details;

  /// On an upright phone, the details on a line of their own under [details] when the two don't fit on one.
  final List<Widget> secondaryDetails;
  final List<Widget> actions;

  /// Below this width the artwork sits above the title; from it on (a phone held sideways, a narrow window) beside it,
  /// where the height it saves keeps the tracks in view.
  static const double sideBySideWidth = 600;

  /// Whether the page is narrower than [sideBySideWidth]: the header, and the page around it, are the upright phone's.
  static bool isNarrow(BuildContext context) => MediaQuery.sizeOf(context).width < sideBySideWidth;

  /// The framed artwork, with its shadow and its tag, as what a cover flies into: hidden whole until it lands, and the
  /// sharp artwork laid over the tile's smaller picture on the way.
  Widget _flight(Widget framed) {
    final tag = artworkFlight;
    return tag == null
        ? framed
        : CoverFlightTarget(tag: tag, radius: roundArtwork ? null : Radii.card, arrival: artwork, child: framed);
  }

  /// The title, marked for the bar over the page: one of a line the bar takes over and shrinks into its own, a longer
  /// one (or a playlist's, which renames it) fades over to it.
  Widget _pageTitle(BuildContext context, TextStyle style, {required int maxLines, TextAlign? textAlign}) {
    if (titleWidget case final widget?) return PinnedTitleBar.pageTitle(context, widget);
    return LayoutBuilder(
      builder: (context, constraints) {
        final (:text, style: fitted) = wrapByWords(context, title, style, constraints.maxWidth);
        // Measured in the font it is drawn in (the app's, which a Text takes from around it).
        final painter = TextPainter(
          text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(fitted)),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final oneLine = !painter.didExceedMaxLines;
        painter.dispose();
        return PinnedTitleBar.pageTitle(
          context,
          Text(text, textAlign: textAlign, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: fitted),
          shrinkStyle: oneLine ? fitted : null,
        );
      },
    );
  }

  /// The wide header's title style; a playlist's editable title uses it too.
  static TextStyle titleStyle(BuildContext context) => TextStyle(
    fontSize: 46,
    height: 1.05,
    letterSpacing: -1.6,
    fontWeight: FontWeight.w900,
    color: context.colors.textMain,
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final narrow = isNarrow(context);
    final dot = Text('•', style: TextStyle(color: colors.textMuted));
    final shadow = [
      BoxShadow(color: colors.palette.shadow, blurRadius: 40, spreadRadius: -8, offset: const Offset(0, 20)),
    ];
    final frame = roundArtwork
        ? BoxDecoration(shape: BoxShape.circle, boxShadow: shadow)
        : BoxDecoration(borderRadius: BorderRadius.circular(Radii.card), boxShadow: shadow);
    final badge = artworkBadge;
    final framed = badge == null
        ? artwork
        : Stack(
            fit: StackFit.expand,
            children: [
              artwork,
              Positioned(left: 10, bottom: 10, child: badge),
            ],
          );
    Widget buildRow(List<Widget> items) => Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: narrow ? WrapAlignment.center : WrapAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++) ...[if (i > 0) dot, items[i]],
      ],
    );
    final allDetails = [...details, ...secondaryDetails];
    if (narrow) {
      // The phone's top bar takes the name over once it has reached it: one of a line shrinks into the bar's title,
      // a longer one (or a playlist's, which renames it) fades over to it.
      final titleStyle = TextStyle(
        fontSize: 24,
        letterSpacing: -0.6,
        fontWeight: FontWeight.w800,
        color: colors.textMain,
      );
      final narrowTitle = _pageTitle(context, titleStyle, maxLines: 3, textAlign: TextAlign.center);
      final detailContent = details.isNotEmpty && secondaryDetails.isNotEmpty
          ? _DetailLines(
              first: buildRow(details),
              separator: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: dot),
              second: buildRow(secondaryDetails),
            )
          : allDetails.isEmpty
          ? null
          : buildRow(allDetails);
      // The phone's header: the 230 px artwork with a glow, the title and the details centred, and a line of buttons
      // as tall as Play (see PlayShuffleButtons), Play over the ⋮ of the rows below.
      return SafeArea(
        bottom: false,
        child: Column(
          children: [
            ?back,
            Padding(
              padding: EdgeInsets.fromLTRB(16, back == null ? 12 : 0, 16, 0),
              child: Column(
                children: [
                  PhoneArtworkStretch(
                    child: _flight(Container(width: 230, height: 230, decoration: frame, child: framed)),
                  ),
                  const SizedBox(height: 20),
                  if (actions.isEmpty) PinnedTitleBar.anchor(context, narrowTitle) else narrowTitle,
                  if (detailContent != null) ...[const SizedBox(height: 6), detailContent],
                ],
              ),
            ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, PhoneChrome.playEndPadding, 0),
                child: PinnedTitleBar.anchor(
                  context,
                  SizedBox(
                    height: PhoneChrome.playSize,
                    child: Row(children: [for (final action in actions) Expanded(child: action)]),
                  ),
                ),
              ),
            const SizedBox(height: 10),
          ],
        ),
      );
    }
    final detailRow = allDetails.isEmpty ? null : buildRow(allDetails);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: tags),
        const SizedBox(height: 12),
        _pageTitle(context, titleStyle(context), maxLines: 2),
        if (detailRow != null) ...[const SizedBox(height: 12), detailRow],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 22),
          PinnedTitleBar.anchor(context, Wrap(spacing: 12, runSpacing: 8, children: actions)),
        ],
      ],
    );
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?back,
        Padding(
          padding: EdgeInsets.fromLTRB(30, back == null ? 28 : 6, 30, 28),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _flight(Container(width: 210, height: 210, decoration: frame, child: framed)),
              const SizedBox(width: 30),
              Expanded(child: text),
            ],
          ),
        ),
      ],
    );
    // The phone's pages reach under the status bar (and, held sideways, a camera's cutout); the wide layout's page
    // never does.
    return PhoneChrome.isPhone(context) ? SafeArea(bottom: false, child: header) : header;
  }
}

/// The phone header's two groups of details: on one line, [separator] between them, when that fits in the width; else
/// [second] on a line under [first], without the separator. Each line is centred.
class _DetailLines extends MultiChildRenderObjectWidget {
  _DetailLines({required Widget first, required Widget separator, required Widget second})
    : super(children: [first, separator, second]);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderDetailLines();
}

class _DetailLinesParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderDetailLines extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _DetailLinesParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _DetailLinesParentData> {
  /// The space between the two lines, as between a [Wrap]'s runs in the header.
  static const double _lineGap = 4;

  bool _oneLine = true;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _DetailLinesParentData) child.parentData = _DetailLinesParentData();
  }

  @override
  void performLayout() {
    final first = firstChild!, separator = childAfter(first)!, second = childAfter(separator)!;
    // Their widths unwrapped decide; then they are laid out in the width there is.
    double width(RenderBox child) => child.getDryLayout(const BoxConstraints()).width;
    _oneLine = width(first) + width(separator) + width(second) <= constraints.maxWidth;
    final loose = BoxConstraints(maxWidth: constraints.maxWidth);
    for (final child in [first, separator, second]) {
      child.layout(loose, parentUsesSize: true);
    }
    final Size size;
    if (_oneLine) {
      final lineWidth = first.size.width + separator.size.width + second.size.width;
      final height = [first.size.height, separator.size.height, second.size.height].reduce(math.max);
      size = constraints.constrain(Size(lineWidth, height));
      var x = (size.width - lineWidth) / 2;
      for (final child in [first, separator, second]) {
        (child.parentData! as _DetailLinesParentData).offset = Offset(x, (height - child.size.height) / 2);
        x += child.size.width;
      }
    } else {
      size = constraints.constrain(
        Size(math.max(first.size.width, second.size.width), first.size.height + _lineGap + second.size.height),
      );
      (first.parentData! as _DetailLinesParentData).offset = Offset((size.width - first.size.width) / 2, 0);
      (second.parentData! as _DetailLinesParentData).offset = Offset(
        (size.width - second.size.width) / 2,
        first.size.height + _lineGap,
      );
    }
    this.size = size;
  }

  /// The children on show: all three on one line, else the two groups.
  Iterable<RenderBox> get _shown sync* {
    final first = firstChild!, separator = childAfter(first)!;
    yield first;
    if (_oneLine) yield separator;
    yield childAfter(separator)!;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in _shown) {
      context.paintChild(child, (child.parentData! as _DetailLinesParentData).offset + offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in _shown.toList().reversed) {
      final offset = (child.parentData! as _DetailLinesParentData).offset;
      final hit = result.addWithPaintOffset(
        offset: offset,
        position: position,
        hitTest: (result, transformed) => child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) => _shown.forEach(visitor);
}

/// One of the details under a detail page's title: a count, a release year, a length.
class DetailText extends StatelessWidget {
  const DetailText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: context.colors.textMuted),
  );
}

/// A list page's genre filter: the genres there are, the one chosen (null for all of them), and what choosing does.
typedef GenreChoice = ({List<String> genres, String? selected, ValueChanged<String?> onSelected});

/// The sort buttons of a list page ("Sort by: ABC ↑ | Released") as one segmented pill; the active segment is filled with
/// the accent. On a phone one pill holds the sort and the [genre] filter together ("ABC ↑ · Jazz"), opening one sheet
/// with both, so the line keeps room for Play and the rest; a wider screen has the genre's own button beside these.
class SortButtons extends StatefulWidget {
  const SortButtons({super.key, required this.buttons, this.genre});

  final List<(String label, bool selected, VoidCallback onTap)> buttons;

  /// The genre filter a phone's pill holds too; null, or no genres, for none.
  final GenreChoice? genre;

  @override
  State<SortButtons> createState() => _SortButtonsState();
}

class _SortButtonsState extends State<SortButtons> {
  /// What a phone's open sheet shows: the sorts and the genres as the page has them now.
  late final ValueNotifier<List<ChoiceSection<Object>>> _sheet = ValueNotifier(const []);

  List<(String label, bool selected, VoidCallback onTap)> get buttons => widget.buttons;
  GenreChoice? get genre => widget.genre;

  @override
  void didUpdateWidget(SortButtons oldWidget) {
    super.didUpdateWidget(oldWidget);
    // After the frame: the sheet is another route, not to be rebuilt while this one builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sheet.value = _sections(context);
    });
  }

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  /// A sort's number or a genre's name ('' for all of them), under their titles.
  List<ChoiceSection<Object>> _sections(BuildContext context) {
    final genres = genre?.genres ?? const <String>[];
    final chosenGenre = genre?.selected;
    return [
      (
        title: context.tr('SortBy'),
        choices: [
          for (final (i, (label, selected, _)) in buttons.indexed) SheetChoice<Object>(i, label, selected: selected),
        ],
      ),
      if (genres.isNotEmpty)
        (
          title: context.tr('Genre'),
          choices: [
            SheetChoice<Object>('', context.tr('AllGenres'), selected: chosenGenre == null),
            for (final g in genres) SheetChoice<Object>(g, g, selected: equalsIgnoreCase(g, chosenGenre)),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (PhoneChrome.isPhone(context)) {
      // The active field with its direction, as on every other sort control; then the chosen genre.
      final active = buttons.firstWhere((b) => b.$2, orElse: () => buttons.first);
      final genre = this.genre;
      final genres = genre?.genres ?? const <String>[];
      final chosenGenre = genre?.selected;
      final style = TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: colors.accent);
      return SizedBox(
        width: double.infinity,
        height: PhoneChrome.controlHeight,
        // The label is the order alone ("ABC ↑"): the tooltip, and a screen reader, say what the button is.
        child: Tooltip(
          message: context.tr(genres.isEmpty ? 'TipSortBy' : 'TipSortAndGenre'),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              backgroundColor: colors.surface1,
              side: BorderSide(color: colors.glassBorder),
              shape: const StadiumBorder(),
            ),
            // The sheet stays open while a sort and a genre are chosen, the list behind following each choice.
            onPressed: () {
              _sheet.value = _sections(context);
              showLiveChoiceSections<Object>(
                context,
                sections: _sheet,
                onChoose: (chosen) {
                  switch (chosen) {
                    case final int sort:
                      buttons[sort].$3();
                    case final String name:
                      genre?.onSelected(name.isEmpty ? null : name);
                  }
                },
              );
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(child: SortLabel(active.$1, style: style)),
                if (chosenGenre != null) ...[
                  Text('  ·  ', style: style.copyWith(color: colors.textMuted)),
                  Flexible(
                    child: Text(chosenGenre, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          context.tr('SortBy'),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.textMuted),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: colors.surface1,
                borderRadius: BorderRadius.circular(Radii.pill),
                border: Border.all(color: colors.glassBorder),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (label, selected, onTap) in buttons)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        color: selected ? colors.accent : Colors.transparent,
                        borderRadius: BorderRadius.circular(Radii.pill),
                        boxShadow: selected ? colors.accentGlow(0.5) : const [],
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          customBorder: const StadiumBorder(),
                          onTap: onTap,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            child: SortLabel(
                              label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: selected ? colors.onAccent : colors.textMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The sort buttons of a list of tracks on a phone (a wide table sorts by its headers).
class TrackSortButtons extends StatelessWidget {
  const TrackSortButtons(this.sorting, {super.key, this.genre});

  final TrackSorting sorting;

  /// The genre filter the phone's pill holds too ([SortButtons.genre]).
  final GenreChoice? genre;

  @override
  Widget build(BuildContext context) {
    context.tr('SortBy'); // the labels follow the language
    return SortButtons(
      genre: genre,
      buttons: [
        for (final field in TrackSortField.values)
          (sorting.sortLabel(field), sorting.sortField == field, () => sorting.setSortField(field)),
      ],
    );
  }
}

/// The genre filter of a computer's list page: a pill naming the chosen genre (or "All genres"), opening a menu of the
/// page's genres, the chosen one in the accent. A phone's sort pill holds it instead ([SortButtons.genre]).
class _GenreFilter extends StatelessWidget {
  const _GenreFilter({required this.genres, required this.selected, required this.onSelected});

  final List<String> genres;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final active = selected != null;
    final color = active ? colors.accent : colors.textMuted;
    final pill = Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: active ? colors.accent.withValues(alpha: 0.16) : colors.surface1,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: active ? colors.accent.withValues(alpha: 0.6) : colors.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.filter_list_rounded, size: 16, color: color),
          const SizedBox(width: 6),
          // A long genre is cut short.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              selected ?? context.tr('AllGenres'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: active ? colors.accent : colors.textMain,
              ),
            ),
          ),
          const SizedBox(width: 2),
          Icon(Icons.expand_more_rounded, size: 18, color: color),
        ],
      ),
    );
    return PopupMenuButton<String>(
      tooltip: context.tr('TipGenreFilter'),
      position: PopupMenuPosition.under,
      // The menu's "all" entry has the empty string as its value: a null reads as "closed without a choice".
      onSelected: (value) => onSelected(value.isEmpty ? null : value),
      // The chosen one in the accent, with its tick, as the phone's sheet shows it.
      itemBuilder: (context) {
        PopupMenuItem<String> item(String value, String label, bool chosen) => PopupMenuItem(
          value: value,
          child: Row(
            children: [
              SizedBox(width: 28, child: chosen ? Icon(Icons.check_rounded, size: 18, color: colors.accent) : null),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(color: chosen ? colors.accent : null, fontWeight: chosen ? FontWeight.w700 : null),
                ),
              ),
            ],
          ),
        );
        return [
          item('', context.tr('AllGenres'), !active),
          const PopupMenuDivider(),
          for (final genre in genres) item(genre, genre, equalsIgnoreCase(genre, selected)),
        ];
      },
      child: pill,
    );
  }
}

// ── Albums ──────────────────────────────────────────────────────────────────────────────────────────

class AlbumsPage extends StatelessWidget {
  const AlbumsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final albums = context.vm.albums;
    return ListenableBuilder(
      listenable: albums,
      builder: (context, _) {
        final selected = albums.selectedAlbum;
        if (selected != null) return AlbumDetail(album: selected);
        if (albums.displayedAlbums.isEmpty) {
          return const EmptyLibrary(); // nothing to list means nothing in the library
        }
        return TabPageList(
          title: context.tr('NavAlbums'),
          storageKey: 'albums',
          scrollLabel: (fraction) => _scrollLabel(albums.displayedAlbums, fraction, switch (albums.sortField) {
            AlbumSortField.title => (Album album) => scrollLetter(album.title),
            AlbumSortField.artist => (Album album) => scrollLetter(album.artist),
            AlbumSortField.released => (Album album) => album.releaseYear?.toString(),
            _ => null,
          }),
          header: PageHeader(
            title: context.tr('NavAlbums'),
            subtitle: context.trf('AlbumCount', [albums.displayedAlbums.length]),
            actions: [
              SortButtons(
                genre: (genres: albums.genres, selected: albums.genre, onSelected: albums.setGenre),
                buttons: [
                  for (final field in AlbumSortField.values)
                    (albums.sortLabel(field), albums.sortField == field, () => albums.setSortField(field)),
                ],
              ),
              // A phone's sort pill holds the genre.
              if (albums.genres.isNotEmpty && !PhoneChrome.isPhone(context))
                _GenreFilter(genres: albums.genres, selected: albums.genre, onSelected: albums.setGenre),
            ],
          ),
          slivers: [
            AlbumsSliver(albums: albums.displayedAlbums, onOpen: albums.openAlbum, onPlay: albums.playAlbum),
            const PageEndSpace(),
          ],
        );
      },
    );
  }
}

class AlbumDetail extends StatelessWidget {
  const AlbumDetail({super.key, required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final albums = vm.albums;
    final colors = context.colors;
    final menu = ListMenu.album(album, onPlay: albums.playAlbum);
    return PinnedTitleBar(
      title: album.title,
      onBack: albums.closeAlbumDetail,
      backText: albums.backText,
      menu: menu.topBarButton(),
      child: CustomScrollView(
        key: PageStorageKey('album-${album.id}-${albums.pageVisit}'),
        slivers: [
          PinnedTitleBar.room,
          SliverToBoxAdapter(
            child: DetailHeader(
              back: BackLink(text: albums.backText, onPressed: albums.closeAlbumDetail),
              artwork: CoverImage(
                path: album.coverArtPath,
                radius: Radii.card,
                decodeWidth: 640,
                placeholderIcon: Icons.album,
              ),
              artworkFlight: 'album:${album.id}',
              artworkBadge: QualityTag(tier: album.quality.tier, spec: album.quality.spec, fontSize: 11),
              tags: [TagBadge(context.tr('ColAlbum'), color: colors.accent)],
              title: album.title,
              details: [
                ArtistLinks(
                  album.artistNames,
                  onOpen: vm.openArtistByName,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: colors.accent),
                ),
              ],
              secondaryDetails: [
                if (album.releaseYear != null) DetailText('${album.releaseYear}'),
                DetailText(context.trf('TrackCount', [album.trackCount])),
                DetailText(album.formattedTotalDuration),
              ],
              actions: [
                PlayShuffleButtons(
                  tracks: album.tracks,
                  onPlay: () => albums.playAlbum(),
                  playNext: menu.playNextButton(),
                  addToQueue: menu.addToQueueButton(),
                  addToPlaylist: menu.addToPlaylistButton(),
                  download: DownloadListButton.forTracks(
                    album.tracks,
                    name: album.title,
                    isDownloaded: () => vm.downloads.isAlbumDownloaded(album),
                    onPressed: () => vm.downloads.toggleAlbum(album),
                  ),
                  remove: menu.removeButton(),
                ),
              ],
            ),
          ),
          TrackSliver(
            tracks: album.tracks,
            kind: TrackTableKind.album,
            playingFrom: () => album.title,
            playingSource: album,
          ),
          _AlbumFooter(album: album),
          _albumShelf(context, context.trf('LabelMoreBy', [album.artist]), Related.moreByOf(album, vm.library.albums)),
          _albumShelf(context, context.tr('LabelSimilarAlbums'), Related.albumsOf(album, vm.library.albums)),
          const PageEndSpace(),
        ],
      ),
    );
  }
}

/// A line of [albums] at the end of an album's page, each opening its own page.
Widget _albumShelf(BuildContext context, String title, List<Album> albums) {
  final vm = context.vm;
  return TileShelf(
    title: title,
    kind: TileKind.album,
    count: albums.length,
    tile: (context, index) => AlbumCard(
      album: albums[index],
      onOpen: () => vm.openAlbum(albums[index]),
      onPlay: () => vm.albums.playAlbum(albums[index]),
    ),
  );
}

/// The end of an album's page, as in TIDAL: its label and its ℗ line, in small type, as its tracks give them (a label
/// the server looked up counts; [TrackDetails.releaseLines]); nothing when they give neither. A tap on them lists the
/// label's albums in the library.
class _AlbumFooter extends StatelessWidget {
  const _AlbumFooter({required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final label = labelOf(album);
    final lines = TrackDetails.releaseLines(
      label: label,
      copyright: album.tracks.map((track) => track.details.copyright).nonNulls.firstOrNull,
      year: album.releaseYear,
    );
    if (lines.isEmpty) return const SliverToBoxAdapter();
    final edge = PhoneChrome.isPhone(context) ? PhoneChrome.edge : 30.0;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Text(line, style: TextStyle(fontSize: 12.5, height: 1.5, color: context.colors.textMuted)),
      ],
    );
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(edge - 6, 14, edge - 6, 0),
      sliver: SliverToBoxAdapter(
        child: Align(
          alignment: Alignment.centerLeft,
          child: label == null
              ? Padding(padding: const EdgeInsets.all(6), child: text)
              : InkWell(
                  borderRadius: BorderRadius.circular(Radii.small),
                  onTap: () => showLabelAlbums(context, label),
                  child: Padding(padding: const EdgeInsets.all(6), child: text),
                ),
        ),
      ),
    );
  }

  /// The label [album]'s tracks name (or the server looked up); null when none does.
  static String? labelOf(Album album) =>
      album.tracks.map((track) => track.details.label?.trim()).where((l) => l != null && l.isNotEmpty).firstOrNull;
}

/// The library's albums on the record label [label], newest first, each leading to its page: a sheet on a phone, a
/// dialog elsewhere.
Future<void> showLabelAlbums(BuildContext context, String label) async {
  final vm = context.vm;
  final albums = vm.library.albums.where((album) => equalsIgnoreCase(_AlbumFooter.labelOf(album), label)).toList()
    ..sort((a, b) => (b.releaseYear ?? 0).compareTo(a.releaseYear ?? 0));
  Widget list(BuildContext context, VoidCallback close) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final album in albums)
        InkWell(
          borderRadius: BorderRadius.circular(Radii.medium),
          onTap: () {
            close();
            vm.openAlbum(album);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                CoverImage(path: album.coverArtPath, size: 48, placeholderIcon: Icons.album),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: context.colors.textMain),
                      ),
                      Text(
                        [album.artist, if (album.releaseYear case final year?) '$year'].join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: context.colors.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );
  final count = context.trf('AlbumCount', [albums.length]);
  if (PhoneChrome.isPhone(context)) {
    await showPhoneSheet<void>(
      context,
      builder: (sheet) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 2),
          child: Text(
            label,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: sheet.colors.textMain),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(count, style: TextStyle(fontSize: 13, color: sheet.colors.textMuted)),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: list(sheet, () => Navigator.pop(sheet))),
      ],
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialog) => AppDialog(
      title: label,
      subtitle: count,
      content: DialogScroll(maxHeight: 460, child: list(dialog, () => Navigator.pop(dialog))),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(dialog.tr('Close')))],
    ),
  );
}

// ── Artists ─────────────────────────────────────────────────────────────────────────────────────────

class ArtistsPage extends StatelessWidget {
  const ArtistsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final artists = context.vm.artists;
    return ListenableBuilder(
      listenable: artists,
      builder: (context, _) {
        final selected = artists.selectedArtist;
        if (selected != null) return ArtistDetail(artist: selected);
        if (artists.displayedArtists.isEmpty) {
          return const EmptyLibrary(); // nothing to list means nothing in the library
        }
        return TabPageList(
          title: context.tr('NavArtists'),
          storageKey: 'artists',
          scrollLabel: (fraction) => _scrollLabel(
            artists.displayedArtists,
            fraction,
            artists.sortField == ArtistSortField.name ? (Artist artist) => scrollLetter(artist.name) : null,
          ),
          header: PageHeader(
            title: context.tr('NavArtists'),
            subtitle: context.trf('ArtistCount', [artists.displayedArtists.length]),
            actions: [
              SortButtons(
                genre: (genres: artists.genres, selected: artists.genre, onSelected: artists.setGenre),
                buttons: [
                  for (final field in ArtistSortField.values)
                    (artists.sortLabel(field), artists.sortField == field, () => artists.setSortField(field)),
                ],
              ),
              // A phone's sort pill holds the genre.
              if (artists.genres.isNotEmpty && !PhoneChrome.isPhone(context))
                _GenreFilter(genres: artists.genres, selected: artists.genre, onSelected: artists.setGenre),
            ],
          ),
          slivers: [
            ArtistsSliver(artists: artists.displayedArtists, onOpen: artists.openArtist, onPlay: artists.playArtist),
            const PageEndSpace(),
          ],
        );
      },
    );
  }
}

class ArtistDetail extends StatelessWidget {
  const ArtistDetail({super.key, required this.artist});

  final Artist artist;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final artists = vm.artists;
    final albums = artist.albums; // the newest first, as the library orders them
    final colors = context.colors;
    final narrow = DetailHeader.isNarrow(context);
    final albumTracks = [for (final album in albums) ...album.tracks];
    final menu = ListMenu.artist(artist, onPlay: artists.playArtist);
    return PinnedTitleBar(
      title: artist.name,
      onBack: artists.closeArtistDetail,
      backText: artists.backText,
      menu: menu.topBarButton(),
      child: CustomScrollView(
        key: PageStorageKey('artist-${artist.id}-${artists.pageVisit}'),
        slivers: [
          PinnedTitleBar.room,
          SliverToBoxAdapter(
            child: DetailHeader(
              back: BackLink(text: artists.backText, onPressed: artists.closeArtistDetail),
              artwork: CoverImage(path: artist.picturePath, circle: true, placeholderIcon: Icons.person),
              artworkFlight: 'artist:${artist.id}',
              roundArtwork: true,
              tags: [TagBadge(context.tr('ColArtist'), color: colors.accent)],
              title: artist.name,
              details: [
                DetailText(context.trf('AlbumCount', [artist.albumCount])),
                DetailText(context.trf('TrackCount', [artist.trackCount])),
              ],
              actions: [
                PlayShuffleButtons(
                  tracks: artist.tracks,
                  onPlay: () => artists.playArtist(),
                  playNext: menu.playNextButton(),
                  addToQueue: menu.addToQueueButton(),
                  addToPlaylist: menu.addToPlaylistButton(),
                  // The artist's albums, also the ones that arrive later.
                  download: DownloadListButton.forTracks(
                    albumTracks,
                    name: artist.name,
                    isDownloaded: () => vm.downloads.isArtistDownloaded(artist),
                    onPressed: () => vm.downloads.toggleArtist(artist),
                  ),
                  remove: menu.removeButton(),
                ),
              ],
            ),
          ),
          if (albums.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 26),
                child: SectionLabel(context.tr('LabelAlbums'), padding: const EdgeInsets.fromLTRB(4, 4, 4, 10)),
              ),
            ),
            AlbumsSliver(albums: albums, onOpen: vm.openAlbum, onPlay: vm.albums.playAlbum, withArtist: false),
          ],
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 26),
              child: SectionLabel(context.tr('LabelAllTracks'), padding: const EdgeInsets.fromLTRB(4, 24, 4, 8)),
            ),
          ),
          TrackSliver(
            tracks: artist.tracks,
            kind: TrackTableKind.artist,
            playingFrom: () => artist.name,
            playingSource: artist,
          ),
          Builder(
            builder: (context) {
              final related = Related.artistsOf(artist, vm.library.artists, vm.library.tracks);
              return TileShelf(
                title: context.tr('LabelRelatedArtists'),
                kind: TileKind.twoLines,
                count: related.length,
                tile: (context, index) => ArtistCard(
                  artist: related[index],
                  onOpen: () => vm.openArtist(related[index]),
                  onPlay: () => vm.artists.playArtist(related[index]),
                ),
              );
            },
          ),
          const PageEndSpace(),
        ],
      ),
    );
  }
}

/// What a list's thumb says at [fraction] of the way down [items] ([FastScroller]): [labelOf] the item there; nothing
/// for an order without one.
String? _scrollLabel<T>(List<T> items, double fraction, String? Function(T item)? labelOf) {
  if (items.isEmpty || labelOf == null) return null;
  return labelOf(items[(fraction * (items.length - 1)).round()]);
}

/// [_scrollLabel] for tracks in the order of [field]: a name's first letter, or the year.
String? _trackScrollLabel(List<Track> tracks, TrackSortField field, double fraction) =>
    _scrollLabel(tracks, fraction, switch (field) {
      TrackSortField.title => (Track track) => scrollLetter(track.title),
      TrackSortField.artist => (Track track) => scrollLetter(track.artist),
      TrackSortField.album => (Track track) => scrollLetter(track.album),
      TrackSortField.released => (Track track) => track.releaseYear?.toString(),
      _ => null,
    });
