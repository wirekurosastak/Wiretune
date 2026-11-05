// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import 'ambient.dart';
import 'buttons.dart';
import 'cover_image.dart';
import 'dialogs.dart';
import 'page_parts.dart';

/// The bell: what friends (the server's other accounts) sent, with a count of what came since it was last opened.
/// There while signed in to a server.
class FriendsButton extends StatelessWidget {
  const FriendsButton({super.key, this.iconSize = 22, this.dimension = 46});

  final double iconSize;
  final double dimension;

  @override
  Widget build(BuildContext context) {
    final friends = context.vm.friends;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: friends,
      builder: (context, _) {
        if (!friends.isAvailable) return const SizedBox.shrink();
        final count = friends.unseenCount;
        return SizedBox.square(
          dimension: dimension,
          child: IconButton(
            tooltip: context.tr('FromFriends'),
            iconSize: iconSize,
            onPressed: () => showFromFriends(context),
            icon: Badge(
              isLabelVisible: count > 0,
              backgroundColor: colors.neutral,
              textColor: colors.onAccent,
              label: Text(count > 99 ? '99+' : '$count'),
              child: Icon(Icons.notifications_none_rounded, color: colors.textMain),
            ),
          ),
        );
      },
    );
  }
}

/// Opens what friends sent: a sheet on a phone, a dialog elsewhere. What is there now counts as seen.
Future<void> showFromFriends(BuildContext context) async {
  final friends = context.vm.friends;
  friends.opened();
  if (PhoneChrome.isPhone(context)) {
    await showPhoneSheet<void>(
      context,
      builder: (sheet) => [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(
            sheet.tr('FromFriends'),
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: sheet.colors.textMain),
          ),
        ),
        _FromFriendsList(close: () => Navigator.pop(sheet), padding: 24),
      ],
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialog) => AppDialog(
      title: dialog.tr('FromFriends'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420, minWidth: 360),
        child: SingleChildScrollView(child: _FromFriendsList(close: () => Navigator.pop(dialog), padding: 0)),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(dialog.tr('Close')))],
    ),
  );
}

/// The invites to listen together, then the recommendations, the newest first; a tap on one plays the track or
/// opens the album or the artist.
class _FromFriendsList extends StatelessWidget {
  const _FromFriendsList({required this.close, required this.padding});

  final VoidCallback close;
  final double padding;

  @override
  Widget build(BuildContext context) {
    final friends = context.vm.friends;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: friends,
      builder: (context, _) {
        final items = friends.items;
        final invites = friends.invites;
        if (items.isEmpty && invites.isEmpty) {
          return Padding(
            padding: EdgeInsets.fromLTRB(padding, 8, padding, 8),
            child: Text(context.tr('FromFriendsNone'), style: TextStyle(fontSize: 13, color: colors.textMuted)),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final invite in invites) _inviteRow(context, invite),
            for (final item in items) _recommendationRow(context, item),
          ],
        );
      },
    );
  }

  Widget _inviteRow(BuildContext context, ListeningInvite invite) {
    final friends = context.vm.friends;
    final colors = context.colors;
    return ListTile(
      contentPadding: EdgeInsets.only(left: padding, right: padding),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: context.wash.withValues(alpha: 0.18),
        child: Icon(Icons.groups_rounded, color: context.wash),
      ),
      title: Text(context.trf('ListenInvitedYou', [invite.host.username]), maxLines: 2),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            onPressed: () {
              close();
              friends.join(invite);
            },
            child: Text(context.tr('ListenJoin')),
          ),
          IconButton(
            tooltip: context.tr('Remove'),
            iconSize: 18,
            icon: Icon(Icons.close_rounded, color: colors.textMuted),
            onPressed: () => friends.dismissInvite(invite),
          ),
        ],
      ),
    );
  }

  Widget _recommendationRow(BuildContext context, Recommendation recommendation) {
    final vm = context.vm;
    final friends = vm.friends;
    final colors = context.colors;
    const size = 44.0;
    final track = friends.trackOf(recommendation);
    final album = friends.albumOf(recommendation);
    final artist = friends.artistOf(recommendation);
    final (Widget cover, String title) = switch ((track, album, artist)) {
      (final track?, _, _) => (
        CoverImage(path: track.coverArtPath, size: size, placeholderIcon: Icons.music_note),
        '${track.title} • ${track.artist}',
      ),
      (_, final album?, _) => (
        CoverImage(path: album.coverArtPath, size: size, placeholderIcon: Icons.album),
        '${album.title} • ${album.artist}',
      ),
      (_, _, final artist?) => (
        CoverImage(path: artist.picturePath, size: size, circle: true, placeholderIcon: Icons.person),
        artist.name,
      ),
      _ => (const SizedBox.square(dimension: size), ''),
    };
    final from = recommendation.from.username;
    return ListTile(
      contentPadding: EdgeInsets.only(left: padding, right: padding == 0 ? 0 : padding - 12),
      leading: cover,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        recommendation.note.isEmpty ? from : '$from: ${recommendation.note}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.5, color: colors.textMuted),
      ),
      trailing: IconButton(
        tooltip: context.tr('Remove'),
        iconSize: 18,
        icon: Icon(Icons.close_rounded, color: colors.textMuted),
        onPressed: () => friends.dismiss(recommendation),
      ),
      onTap: () {
        close();
        if (track != null) vm.player.playQueue([track], track);
        if (album != null) vm.openAlbum(album);
        if (artist != null) vm.openArtist(artist);
      },
    );
  }
}

/// Recommends an artist, an album or a track ([label] in the dialog and the notice) to the friends the user picks.
Future<void> showRecommendDialog(
  BuildContext context, {
  required RecommendationKind kind,
  required String itemId,
  required String label,
}) async {
  final picked = await showFriendPicker(
    context,
    title: context.tr('RecommendTo'),
    subtitle: label,
    action: context.tr('Send'),
    withNote: true,
  );
  if (picked == null || !context.mounted) return;
  await context.vm.friends.recommend(kind, itemId, picked.$1, note: picked.$2);
}

/// Asks which friends (the server's other accounts) something is for, and with [withNote] what to tell them. Null when
/// the user cancels.
Future<(List<AccountInfo>, String)?> showFriendPicker(
  BuildContext context, {
  required String title,
  String? subtitle,
  required String action,
  bool withNote = false,
}) => showDialog<(List<AccountInfo>, String)>(
  context: context,
  builder: (_) => _FriendPicker(title: title, subtitle: subtitle, action: action, withNote: withNote),
);

class _FriendPicker extends StatefulWidget {
  const _FriendPicker({required this.title, required this.subtitle, required this.action, required this.withNote});

  final String title;
  final String? subtitle;
  final String action;
  final bool withNote;

  @override
  State<_FriendPicker> createState() => _FriendPickerState();
}

class _FriendPickerState extends State<_FriendPicker> {
  late final Future<List<AccountInfo>> _accounts = context.vm.friends.otherAccounts();
  final Set<String> _chosen = {};
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<List<AccountInfo>>(
      future: _accounts,
      builder: (context, snapshot) {
        final accounts = snapshot.data;
        final Widget list;
        if (snapshot.hasError) {
          list = Text('${snapshot.error}', style: TextStyle(color: colors.danger, fontSize: 13));
        } else if (accounts == null) {
          list = const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        } else if (accounts.isEmpty) {
          list = Text(context.tr('FriendsNone'), style: TextStyle(color: colors.textMuted, fontSize: 13));
        } else {
          list = ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final account in accounts)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _chosen.contains(account.id),
                    title: Text(account.username),
                    onChanged: (on) =>
                        setState(() => on == true ? _chosen.add(account.id) : _chosen.remove(account.id)),
                  ),
              ],
            ),
          );
        }
        return AppDialog(
          title: widget.title,
          subtitle: widget.subtitle,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              list,
              if (widget.withNote && (accounts?.isNotEmpty ?? false))
                TextField(
                  controller: _note,
                  maxLength: RecommendationRules.maxNoteLength,
                  decoration: InputDecoration(hintText: context.tr('RecommendNote'), counterText: ''),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
            PressShrink(
              child: FilledButton(
                onPressed: _chosen.isEmpty
                    ? null
                    : () => Navigator.pop(context, (
                        [
                          for (final account in accounts!)
                            if (_chosen.contains(account.id)) account,
                        ],
                        _note.text,
                      )),
                child: Text(widget.action),
              ),
            ),
          ],
        );
      },
    );
  }
}
