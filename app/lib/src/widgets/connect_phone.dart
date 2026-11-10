// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../connect_link.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import 'dialogs.dart';

/// Two QR codes for a phone's camera, side by side: the server's address alone (for someone new, who signs in with
/// their own account), and the address with a one-time sign-in code for the account signed in here.
Future<void> showConnectPhoneDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _ConnectPhoneDialog());

class _ConnectPhoneDialog extends StatefulWidget {
  const _ConnectPhoneDialog();

  @override
  State<_ConnectPhoneDialog> createState() => _ConnectPhoneDialogState();
}

class _ConnectPhoneDialogState extends State<_ConnectPhoneDialog> {
  String? _server;
  SignInCode? _code;
  String? _error;

  /// A new code once the one on show runs out.
  Timer? _renew;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _renew?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final session = context.vm.session;
    final server = await ConnectLink.reachable(session.serverUrl);
    if (!mounted) return;
    setState(() => _server = server);
    try {
      final code = await session.createSignInCode();
      if (!mounted) return;
      setState(() {
        _code = code;
        _error = null;
      });
      _renew = Timer(code.expiresAt.difference(DateTime.now().toUtc()), _load);
    } on ServerRequestException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final server = _server;
    final code = _code;
    final error = _error;
    Widget qr(String? data, String title, String detail) => SizedBox(
      width: 168,
      child: Column(
        children: [
          Container(
            width: 168,
            height: 168,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(Radii.medium)),
            child: data == null
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black54))
                : QrImageView(data: data, padding: EdgeInsets.zero),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: colors.textMain),
          ),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: colors.textMuted),
          ),
        ],
      ),
    );

    return AppDialog(
      title: context.tr('ConnectPhone'),
      subtitle: context.tr('ConnectPhoneHint'),
      content: Center(
        child: Wrap(
          spacing: 24,
          runSpacing: 20,
          alignment: WrapAlignment.center,
          children: [
            qr(server == null ? null : ConnectLink.build(server), context.tr('ConnectPhoneServer'), server ?? ''),
            if (error != null)
              SizedBox(
                width: 168,
                height: 168,
                child: Center(
                  child: Text(
                    context.trf('ConnectPhoneNoCode', [error]),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: colors.danger),
                  ),
                ),
              )
            else
              qr(
                server == null || code == null ? null : ConnectLink.build(server, code: code.code),
                context.trf('ConnectPhoneSignIn', [context.vm.serverSettings.currentUserName]),
                context.tr('ConnectPhoneOnce'),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.tr('Close')))],
    );
  }
}
