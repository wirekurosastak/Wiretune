// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import 'dialogs.dart';
import 'page_parts.dart';

/// Opens [track]'s credits: a sheet on a phone, a dialog elsewhere.
Future<void> showCredits(BuildContext context, Track track) async {
  final title = '${track.title} • ${track.artist}';
  if (PhoneChrome.isPhone(context)) {
    await showPhoneSheet<void>(
      context,
      builder: (sheet) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
          child: Text(
            sheet.tr('Credits'),
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: sheet.colors.textMain),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(title, style: TextStyle(fontSize: 13, color: sheet.colors.textMuted)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: CreditsList(track: track),
        ),
      ],
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialog) => AppDialog(
      title: dialog.tr('Credits'),
      content: DialogScroll(
        maxHeight: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: TextStyle(fontSize: 13, color: dialog.colors.textMuted)),
            const SizedBox(height: 12),
            CreditsList(track: track),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(dialog.tr('Close')))],
    ),
  );
}

/// Who did what on [track], by role (an instrument by its name): what the server has (its tags and MusicBrainz), or
/// for a file only this device has, the composer its tags name. Says so when nothing is known.
class CreditsList extends StatefulWidget {
  const CreditsList({super.key, required this.track});

  final Track track;

  @override
  State<CreditsList> createState() => _CreditsListState();
}

class _CreditsListState extends State<CreditsList> {
  late final Future<List<Credit>> _credits = _load();

  Future<List<Credit>> _load() async {
    final vm = context.vm;
    final track = widget.track;
    final id = vm.friends.serverIdOf(track);
    if (id != null && vm.session.isLoggedIn) {
      try {
        return await vm.session.getCredits(id);
      } catch (e) {
        WiretuneLog.debug('Credits', 'The server had no credits to give: $e');
      }
    }
    return [
      for (final name in (track.details.composer ?? '').split(RegExp(r'\s*[;/]\s*')))
        if (name.isNotEmpty) Credit(CreditRoles.composer, name),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<List<Credit>>(
      future: _credits,
      builder: (context, snapshot) {
        final credits = snapshot.data;
        if (credits == null) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        if (credits.isEmpty) {
          return Text(context.tr('CreditsNone'), style: TextStyle(fontSize: 13, color: colors.textMuted));
        }
        // One line per role (per instrument), its names joined, in the order the credits come.
        final lines = <String, List<String>>{};
        for (final credit in credits) {
          final label = credit.role == CreditRoles.instrument
              ? (credit.detail ?? context.tr('CreditInstrument'))
              : context.tr(_labels[credit.role] ?? 'CreditPerformer');
          (lines[label] ??= []).add(credit.name);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final MapEntry(key: label, value: names) in lines.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.textMuted),
                    ),
                    Text(names.join(', '), style: TextStyle(fontSize: 14, color: colors.textMain)),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  static const Map<String, String> _labels = {
    CreditRoles.composer: 'CreditComposer',
    CreditRoles.lyricist: 'CreditLyricist',
    CreditRoles.writer: 'CreditWriter',
    CreditRoles.producer: 'CreditProducer',
    CreditRoles.arranger: 'CreditArranger',
    CreditRoles.vocal: 'CreditVocals',
    CreditRoles.performer: 'CreditPerformer',
    CreditRoles.programming: 'CreditProgramming',
    CreditRoles.remixer: 'CreditRemixer',
    CreditRoles.mix: 'CreditMix',
    CreditRoles.engineer: 'CreditEngineer',
    CreditRoles.recording: 'CreditRecording',
  };
}
