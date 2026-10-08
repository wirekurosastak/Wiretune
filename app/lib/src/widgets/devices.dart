// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';

/// The name a device goes by: the one its user gave it, or what kind of device it is.
String deviceLabel(BuildContext context, String name, DeviceKind kind) => name.isNotEmpty
    ? name
    : context.tr(switch (kind) {
        DeviceKind.desktop => 'DeviceKindDesktop',
        DeviceKind.phone => 'DeviceKindPhone',
        DeviceKind.tablet => 'DeviceKindTablet',
        DeviceKind.tv => 'DeviceKindTv',
      });

IconData deviceIcon(DeviceKind kind) => switch (kind) {
  DeviceKind.desktop => Icons.computer_rounded,
  DeviceKind.phone => Icons.smartphone_rounded,
  DeviceKind.tablet => Icons.tablet_android_rounded,
  DeviceKind.tv => Icons.tv_rounded,
};

/// Plays on another player of the account, or on this one again: a menu of the devices that are online, with what
/// each one plays. Lit while another device is being controlled, or plays while this one is idle; there only while
/// remote control is connected (or a device is being controlled).
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
        return SizedBox.square(
          dimension: dimension,
          child: PopupMenuButton<String>(
            tooltip: remote
                ? context.trf('PlayingOn', [deviceLabel(context, player.remoteDeviceName, player.remoteDeviceKind)])
                : context.tr('TipDevices'),
            iconSize: iconSize,
            icon: Icon(
              remote ? Icons.cast_connected_rounded : Icons.cast_rounded,
              color: remote ? colors.accent : colors.textMain,
            ),
            // This device is the empty string: a null would read as "closed without a choice".
            onSelected: (id) => player.selectDevice(id.isEmpty ? null : id),
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
                    deviceLabel(context, device.name, device.kind),
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
            ],
          ),
        );
      },
    );
  }

  static String _playing(BuildContext context, RemotePlayback? playback) {
    final track = playback?.track;
    if (playback == null || track == null) return context.tr('DeviceIdle');
    final what = '${track.title} • ${track.artist}';
    return playback.playing ? what : context.trf('DevicePaused', [what]);
  }
}

/// "Playing on Living room": shown while this player controls another device.
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
        if (!player.isRemote) return const SizedBox.shrink();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cast_connected_rounded, size: fontSize + 3, color: colors.accent),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                context.trf('PlayingOn', [deviceLabel(context, player.remoteDeviceName, player.remoteDeviceKind)]),
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
