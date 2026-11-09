// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import 'dialogs.dart';
import 'friends.dart';
import 'page_parts.dart';

/// The name a device goes by: the one its user gave it, or what kind of device it is.
String deviceLabel(BuildContext context, String name, DeviceKind kind) => name.isNotEmpty
    ? name
    : context.tr(switch (kind) {
        DeviceKind.desktop => 'DeviceKindDesktop',
        DeviceKind.phone => 'DeviceKindPhone',
        DeviceKind.tablet => 'DeviceKindTablet',
        DeviceKind.tv => 'DeviceKindTv',
        DeviceKind.streamer => 'DeviceKindStreamer',
      });

/// A [device] in a list: [deviceLabel], and the account's name when it is another account's player (one that lets
/// others play on it).
String deviceTitle(BuildContext context, RemoteDevice device) {
  final label = deviceLabel(context, device.name, device.kind);
  final account = device.account;
  return account == null ? label : '$label · ${account.username}';
}

IconData deviceIcon(DeviceKind kind) => switch (kind) {
  DeviceKind.desktop => Icons.computer_rounded,
  DeviceKind.phone => Icons.smartphone_rounded,
  DeviceKind.tablet => Icons.tablet_android_rounded,
  DeviceKind.tv => Icons.tv_rounded,
  DeviceKind.streamer => Icons.speaker_rounded,
};

// The menu's entries of listening together, which no device ID can be (IDs have no control characters).
const String _listenEntry = '\u0001listen';
const String _inviteEntry = '\u0001invite';
const String _leaveEntry = '\u0001leave';

/// Plays on another player of the account, or on this one again: a menu of the devices that are online, with what
/// each one plays; and listening together with friends (starting it, inviting more, leaving it). Lit while another
/// device is being controlled, or while listening together; there only while remote control is connected (or a device
/// is being controlled).
class DevicesButton extends StatelessWidget {
  const DevicesButton({super.key, this.iconSize = 22, this.dimension = 46});

  final double iconSize;
  final double dimension;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final remote = player.isRemote;
        if (!player.canReachDevices && !remote) return const SizedBox.shrink();
        final here = deviceLabel(context, vm.deviceName, vm.capabilities.kind);
        Widget entry(IconData icon, String title, String subtitle) => Row(
          children: [
            Icon(icon, size: 20, color: colors.textMuted),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: colors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        );
        final group = player.listeningGroup;
        final tooltip = remote
            ? context.trf('PlayingOn', [deviceLabel(context, player.remoteDeviceName, player.remoteDeviceKind)])
            : group != null
            ? listeningLabel(context)
            : context.tr('TipDevices');
        final icon = Icon(
          group != null
              ? Icons.groups_rounded
              : remote
              ? Icons.cast_connected_rounded
              : Icons.cast_rounded,
          color: remote || group != null ? colors.accent : colors.textMain,
        );
        // Listening together: with a server account and the connection.
        final canListen = vm.friends.isAvailable && vm.together.isAvailable;
        // This device is the empty string: a null reads as "closed without a choice".
        void choose(String? id) {
          switch (id) {
            case null:
              return;
            case _listenEntry:
              unawaited(_startListening(context));
            case _inviteEntry:
              unawaited(_inviteMore(context));
            case _leaveEntry:
              vm.together.leave();
            default:
              player.selectDevice(id.isEmpty ? null : id);
          }
        }

        // What the menu has of listening together: start it, or (in a group) who is in it, invite more, leave it.
        final members = group == null
            ? ''
            : group.members.isEmpty
            ? context.tr('ListenWaiting')
            : group.members.map((m) => m.username).toSet().join(', ');
        final listening = <(String, String, String?, IconData)>[
          if (group == null && canListen) (_listenEntry, context.tr('ListenTogether'), null, Icons.groups_rounded),
          if (group != null && player.isHostingGroup) ...[
            (_inviteEntry, context.tr('ListenInviteMore'), members, Icons.person_add_alt_rounded),
            (_leaveEntry, context.tr('ListenEnd'), null, Icons.logout_rounded),
          ],
          if (group != null && player.isFollowingHost)
            (_leaveEntry, context.tr('ListenLeave'), listeningLabel(context), Icons.logout_rounded),
        ];

        // A phone's opens as a sheet, within the thumb's reach.
        if (PhoneChrome.isPhone(context)) {
          return SizedBox.square(
            dimension: dimension,
            child: IconButton(
              tooltip: tooltip,
              iconSize: iconSize,
              icon: icon,
              onPressed: () async {
                vm.searchStreamers(); // found ones show the next time
                choose(
                  await showChoiceSheet<String>(
                    context,
                    title: context.tr('DevicesTitle'),
                    choices: [
                      SheetChoice(
                        '',
                        here,
                        subtitle: context.tr('DevicesThisDevice'),
                        icon: deviceIcon(vm.capabilities.kind),
                        selected: !remote,
                      ),
                      for (final device in player.otherDevices)
                        SheetChoice(
                          device.id,
                          deviceTitle(context, device),
                          subtitle: _playing(context, device.playback),
                          icon: deviceIcon(device.kind),
                          selected: player.remoteDeviceId == device.id,
                        ),
                      for (final (id, label, subtitle, icon) in listening)
                        SheetChoice(id, label, subtitle: subtitle, icon: icon),
                    ],
                    note: player.otherDevices.isEmpty ? context.tr('DevicesNone') : null,
                  ),
                );
              },
            ),
          );
        }
        return SizedBox.square(
          dimension: dimension,
          child: PopupMenuButton<String>(
            tooltip: tooltip,
            iconSize: iconSize,
            icon: icon,
            onOpened: vm.searchStreamers, // found ones show the next time
            onSelected: choose,
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                enabled: false,
                height: 32,
                child: Text(
                  context.tr('DevicesTitle').toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w800,
                    color: colors.textMuted,
                  ),
                ),
              ),
              CheckedPopupMenuItem(
                value: '',
                checked: !remote,
                child: entry(deviceIcon(vm.capabilities.kind), here, context.tr('DevicesThisDevice')),
              ),
              for (final device in player.otherDevices)
                CheckedPopupMenuItem(
                  value: device.id,
                  checked: player.remoteDeviceId == device.id,
                  child: entry(
                    deviceIcon(device.kind),
                    deviceTitle(context, device),
                    _playing(context, device.playback),
                  ),
                ),
              if (player.otherDevices.isEmpty)
                PopupMenuItem<String>(
                  enabled: false,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(
                      context.tr('DevicesNone'),
                      style: TextStyle(fontSize: 12.5, height: 1.4, color: colors.textMuted),
                    ),
                  ),
                ),
              if (listening.isNotEmpty) const PopupMenuDivider(),
              for (final (id, label, subtitle, icon) in listening)
                PopupMenuItem<String>(value: id, child: entry(icon, label, subtitle ?? '')),
            ],
          ),
        );
      },
    );
  }

  /// Hosts a group, inviting the friends picked.
  static Future<void> _startListening(BuildContext context) async {
    final picked = await showFriendPicker(
      context,
      title: context.tr('ListenTogetherTitle'),
      action: context.tr('ListenInvite'),
    );
    if (picked != null && context.mounted) context.vm.together.start([for (final a in picked.$1) a.id]);
  }

  /// Invites more friends to the group this player hosts.
  static Future<void> _inviteMore(BuildContext context) async {
    final picked = await showFriendPicker(
      context,
      title: context.tr('ListenTogetherTitle'),
      action: context.tr('ListenInvite'),
    );
    if (picked != null && context.mounted) context.vm.together.invite([for (final a in picked.$1) a.id]);
  }

  static String _playing(BuildContext context, RemotePlayback? playback) {
    final track = playback?.track;
    if (playback == null || track == null) return context.tr('DeviceIdle');
    final what = '${track.title} • ${track.artist}';
    return playback.playing ? what : context.trf('DevicePaused', [what]);
  }
}

/// "Listening with anna": the host a member follows, or the members a host plays for.
String listeningLabel(BuildContext context) {
  final player = context.vm.player;
  final group = player.listeningGroup;
  if (group == null) return '';
  if (player.isFollowingHost) return context.trf('ListeningWith', [group.host.username]);
  final names = group.members.map((m) => m.username).toSet();
  return names.isEmpty ? context.tr('ListeningTogether') : context.trf('ListeningWith', [names.join(', ')]);
}

/// "Playing on Living room": shown while this player controls another device; "Listening with anna" while it listens
/// together.
class PlayingOnLabel extends StatelessWidget {
  const PlayingOnLabel({super.key, this.fontSize = 12});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final player = context.vm.player;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final listening = player.listeningGroup != null;
        if (!player.isRemote && !listening) return const SizedBox.shrink();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              player.isRemote ? Icons.cast_connected_rounded : Icons.groups_rounded,
              size: fontSize + 3,
              color: colors.accent,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                player.isRemote
                    ? context.trf('PlayingOn', [deviceLabel(context, player.remoteDeviceName, player.remoteDeviceKind)])
                    : listeningLabel(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, color: colors.accent),
              ),
            ),
          ],
        );
      },
    );
  }
}
