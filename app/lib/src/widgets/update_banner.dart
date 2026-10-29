// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import 'buttons.dart';

/// "Wiretune 1.1 is available", with Update and a way to put it off until the next check; then how far the download
/// is. It stands where the server's banner does, in the accent rather than in red, and takes no room while there is
/// nothing to offer.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.phone, required this.margin});

  /// The phone's size of banner, under its search bar; else the wide layout's, under the header.
  final bool phone;

  /// The room the layout keeps around its banners.
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final updates = context.vm.updates;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        if (!updates.isBannerVisible) return const SizedBox.shrink();
        final colors = context.colors;
        final version = updates.version!;
        final progress = updates.progress;
        final message = updates.installing
            ? context.trf('UpdateInstalling', [version])
            : progress != null
            ? context.trf('UpdateDownloading', [version, (progress * 100).round()])
            : context.trf('UpdateAvailable', [version]);
        final update = updates.isBusy ? null : updates.update;
        final banner = Container(
          margin: margin,
          padding: phone ? const EdgeInsets.fromLTRB(12, 8, 4, 8) : const EdgeInsets.fromLTRB(18, 8, 8, 8),
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(color: colors.accent.withValues(alpha: phone ? 0.45 : 0.55)),
          ),
          child: Row(
            children: [
              Icon(Icons.system_update_alt_rounded, color: colors.accent, size: 20),
              SizedBox(width: phone ? 10 : 12),
              Expanded(
                child: Text(
                  message,
                  maxLines: phone ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: phone
                      ? TextStyle(fontSize: 12, color: colors.textMain)
                      : TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: colors.textMain),
                ),
              ),
              if (phone)
                TextButton(onPressed: update, child: Text(context.tr('Update')))
              else ...[
                const SizedBox(width: 16),
                PressShrink(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    onPressed: update,
                    icon: const Icon(Icons.download_rounded, size: 16),
                    label: Text(context.tr('Update'), style: const TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              IconButton(
                tooltip: context.tr('Later'),
                onPressed: updates.isBusy ? null : updates.later,
                iconSize: phone ? 18 : 16,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        );
        return phone ? SafeArea(bottom: false, child: banner) : banner;
      },
    );
  }
}
