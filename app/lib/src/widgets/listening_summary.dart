// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import 'buttons.dart';
import 'cover_image.dart';
import 'dialogs.dart';
import 'page_parts.dart';

/// The card at the top of Playlists that opens the listening summary.
class ListeningSummaryCard extends StatelessWidget {
  const ListeningSummaryCard({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final phone = PhoneChrome.isPhone(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(phone ? PhoneChrome.edge : 20, 4, phone ? PhoneChrome.edge : 20, 12),
      child: Material(
        color: colors.surface1,
        // The hairline edge the sort and filter pills have.
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.card),
          side: BorderSide(color: colors.glassBorder),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.card),
          onTap: () => showListeningSummary(context),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.insights_rounded, color: colors.accent, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('ListeningSummary'),
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: colors.textMain),
                      ),
                      Text(
                        context.tr('ListeningSummaryHint'),
                        style: TextStyle(fontSize: 12.5, color: colors.textMuted),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: colors.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the listening summary: a sheet on a phone, a dialog elsewhere.
Future<void> showListeningSummary(BuildContext context) async {
  if (PhoneChrome.isPhone(context)) {
    await showPhoneSheet<void>(
      context,
      builder: (sheet) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          // A route of its own, outside the phone layout: marked a phone's again, for its title and full-width choices.
          child: PhoneChrome(child: ListeningSummaryView(close: () => Navigator.pop(sheet))),
        ),
      ],
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialog) => AppDialog(
      title: dialog.tr('ListeningSummary'),
      content: DialogScroll(maxHeight: 560, child: ListeningSummaryView(close: () => Navigator.pop(dialog))),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(dialog.tr('Close')))],
    ),
  );
}

/// What the account (or this device, without one) listened to most: this month or this year, from the server's play
/// log (or from the play counts, when the account was made within that time), or all time, from the play counts.
/// Nothing hidden counts. A tap on an artist, an album or a track opens or plays it.
class ListeningSummaryView extends StatefulWidget {
  const ListeningSummaryView({super.key, required this.close});

  /// Closes the sheet or the dialog the view is in, before what it opens.
  final VoidCallback close;

  @override
  State<ListeningSummaryView> createState() => _ListeningSummaryViewState();
}

/// The time a listening summary covers: this month or this year (from the server's play log), or all time.
enum _Period { month, year, allTime }

class _ListeningSummaryViewState extends State<ListeningSummaryView> {
  /// A month or a year needs the server's play log; without a server, all time is what there is.
  late _Period _period = context.vm.session.isLoggedIn ? _Period.year : _Period.allTime;
  late Future<({ListeningSummary summary, DateTime? since})> _summary = _load();

  Future<({ListeningSummary summary, DateTime? since})> _load() async {
    final vm = context.vm;
    final library = vm.library;
    final now = DateTime.now();
    final start = switch (_period) {
      _Period.month => DateTime(now.year, now.month),
      _Period.year => DateTime(now.year),
      _Period.allTime => null,
    };
    // An account made within the time has played nothing before it: its counts are the time's, complete, also the plays
    // from before the log began (as for every account while Wiretune was younger than a year).
    final made = vm.session.currentUser?.createdAt;
    if (start == null || (made != null && !made.isBefore(start))) {
      return (
        // What the library shows: nothing hidden.
        summary: ListeningSummary.of({for (final track in library.tracks) track: library.playCount(track.id)}),
        since: null,
      );
    }
    final (:plays, :since) = await vm.session.getPlays(start, now.add(const Duration(minutes: 1)));
    final tracks = library.resolveTracks(plays.keys).where((track) => !library.isTrackHidden(track));
    return (
      summary: ListeningSummary.of({for (final track in tracks) track: plays[library.sharedId(track)] ?? 0}),
      // The log began within the time: what it counts is from then.
      since: since != null && since.isAfter(start) ? since.toLocal() : null,
    );
  }

  void _choose(_Period period) {
    if (period == _period) return;
    setState(() {
      _period = period;
      _summary = _load();
    });
  }

  Widget _periodButton(BuildContext context, _Period period, String key) {
    const style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, 32)),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
    );
    final label = Text(context.tr(key), maxLines: 1, overflow: TextOverflow.ellipsis);
    return period == _period
        ? PressShrink(
            child: FilledButton(style: style, onPressed: () => _choose(period), child: label),
          )
        : OutlinedButton(style: style, onPressed: () => _choose(period), child: label);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final server = context.vm.session.isLoggedIn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (PhoneChrome.isPhone(context))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              context.tr('ListeningSummary'),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: colors.textMain),
            ),
          ),
        // The period, as Settings' choices are: the chosen one filled. A phone's span the sheet in equal parts, so the
        // three fit in any language.
        if (server)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final (i, (period, key)) in const [
                (_Period.month, 'SummaryThisMonth'),
                (_Period.year, 'SummaryThisYear'),
                (_Period.allTime, 'SummaryAllTime'),
              ].indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                if (PhoneChrome.isPhone(context))
                  Expanded(child: _periodButton(context, period, key))
                else
                  _periodButton(context, period, key),
              ],
            ],
          ),
        const SizedBox(height: 16),
        FutureBuilder(
          future: _summary,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text(
                context.trf('SummaryLoadError', ['${snapshot.error}']),
                style: TextStyle(fontSize: 13, color: colors.danger),
              );
            }
            final data = snapshot.data;
            if (data == null) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))),
              );
            }
            return _summaryOf(context, data.summary, data.since);
          },
        ),
      ],
    );
  }

  Widget _summaryOf(BuildContext context, ListeningSummary summary, DateTime? since) {
    final vm = context.vm;
    final colors = context.colors;
    if (summary.isEmpty) {
      return Text(context.tr('SummaryNone'), style: TextStyle(fontSize: 13, color: colors.textMuted));
    }
    TextStyle big = TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: colors.accent);
    Widget section(String label) => SectionLabel(label, padding: const EdgeInsets.fromLTRB(0, 18, 0, 6));
    Widget row({
      required Widget picture,
      required String title,
      String? subtitle,
      required int plays,
      VoidCallback? onTap,
    }) => InkWell(
      borderRadius: BorderRadius.circular(Radii.medium),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            picture,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colors.textMain),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: colors.textMuted),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(context.trf('SummaryPlays', [plays]), style: TextStyle(fontSize: 12.5, color: colors.textMuted)),
          ],
        ),
      ),
    );
    void open(VoidCallback action) {
      widget.close();
      action();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 28,
          runSpacing: 8,
          children: [
            Text(context.trf('SummaryMinutes', [summary.listened.inMinutes]), style: big),
            Text(context.trf('SummaryPlays', [summary.plays]), style: big),
          ],
        ),
        if (since != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(context.trf('SummarySince', [since]), style: TextStyle(fontSize: 12, color: colors.textMuted)),
          ),
        section(context.tr('SummaryTopArtists')),
        for (final (:name, :plays) in summary.artists)
          row(
            picture: CoverImage(
              path: vm.library.getArtistByName(name)?.picturePath,
              size: 40,
              circle: true,
              placeholderIcon: Icons.person,
            ),
            title: name,
            plays: plays,
            onTap: () => open(() => vm.openArtistByName(name)),
          ),
        section(context.tr('SummaryTopAlbums')),
        for (final (:albumId, :plays) in summary.albums)
          if (vm.library.getAlbum(albumId) case final album?)
            row(
              picture: CoverImage(path: album.coverArtPath, size: 40, placeholderIcon: Icons.album),
              title: album.title,
              subtitle: album.artist,
              plays: plays,
              onTap: () => open(() => vm.openAlbum(album)),
            ),
        section(context.tr('SummaryTopTracks')),
        for (final (:track, :plays) in summary.tracks)
          row(
            picture: CoverImage(path: track.coverArtPath, size: 40, placeholderIcon: Icons.music_note),
            title: track.title,
            subtitle: track.artist,
            plays: plays,
            onTap: () => open(() => vm.player.playQueue([track], track)),
          ),
        if (summary.genres.isNotEmpty) ...[
          section(context.tr('SummaryTopGenres')),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (:name, :plays) in summary.genres)
                Chip(label: Text('$name  ·  ${context.trf('SummaryPlays', [plays])}')),
            ],
          ),
        ],
      ],
    );
  }
}
