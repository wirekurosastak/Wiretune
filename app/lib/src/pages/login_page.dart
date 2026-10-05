// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../view_models/app_section.dart';
import '../widgets/ambient.dart';
import '../widgets/common.dart';
import '../widgets/nav_visualizer.dart';

const Color _amber = Color(0xFFFFB703);

/// The sign-in and account screen. Signed in: the account, Sign out and Back to music. Signed out: the server's
/// address, then either the administrator setup (with the setup code from the server's log) or the sign-in, and on a
/// desktop the way on without a server.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final _url = TextEditingController(text: context.vm.serverSettings.serverUrl);
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _setupCode = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _setupCode.dispose();
    super.dispose();
  }

  void _copyFields() {
    context.vm.serverSettings
      ..serverUrl = _url.text
      ..username = _username.text
      ..password = _password.text
      ..setupCode = _setupCode.text;
  }

  void _connect() {
    _copyFields();
    context.vm.serverSettings.connectServer();
  }

  void _submit() {
    _copyFields();
    final server = context.vm.serverSettings;
    server.isSetupRequired ? server.setupAdmin() : server.login();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final server = vm.serverSettings;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: Listenable.merge([server, vm.player]),
      builder: (context, _) => Material(
        color: colors.palette.background,
        child: Stack(
          children: [
            const Positioned.fill(child: AmbientBackdrop()),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 500),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.palette.panel,
                        borderRadius: BorderRadius.circular(Radii.card + 4),
                        boxShadow: [
                          BoxShadow(
                            color: colors.palette.shadow,
                            blurRadius: 60,
                            spreadRadius: -10,
                            offset: const Offset(0, 30),
                          ),
                        ],
                      ),
                      child: GlassCard(
                        hoverColor: colors.accent,
                        padding: const EdgeInsets.fromLTRB(32, 28, 32, 30),
                        child: AutofillGroup(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _brand(context),
                              const SizedBox(height: 24),
                              if (server.isLoggedIn) ..._signedIn(context) else ..._signedOut(context),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _brand(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(width: 32),
        Expanded(
          child: Column(
            children: [
              NavVisualizer(
                waveTrigger: vm.waveTrigger,
                direction: vm.lastWaveDirection,
                color: colors.accent,
                isPlaying: vm.player.isPlaying,
                width: 52,
                height: 38,
              ),
              const SizedBox(height: 12),
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (rect) => LinearGradient(
                  colors: [colors.textMain, colors.hover, colors.accent],
                  stops: const [0.3, 0.75, 1],
                ).createShader(rect),
                child: const Text(
                  'WIRETUNE',
                  style: TextStyle(fontSize: 30, letterSpacing: 5, fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'STREAMER & PLAYER',
                style: TextStyle(fontSize: 10, letterSpacing: 2.4, fontWeight: FontWeight.w800, color: colors.accent),
              ),
            ],
          ),
        ),
        SizedBox.square(
          dimension: 32,
          child: IconButton(
            tooltip: context.tr('TipCloseToPlayer'),
            padding: EdgeInsets.zero,
            onPressed: vm.continueOffline,
            icon: Icon(Icons.close_rounded, size: 20, color: colors.textMain),
          ),
        ),
      ],
    );
  }

  List<Widget> _signedIn(BuildContext context) {
    final vm = context.vm;
    final server = vm.serverSettings;
    final colors = context.colors;
    return [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: colors.surface1, borderRadius: BorderRadius.circular(Radii.card)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.how_to_reg_rounded, size: 40, color: colors.palette.lime),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        server.currentUserName,
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: colors.textMain),
                      ),
                      Text(
                        server.currentUserRole,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.palette.lime),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(server.statusMessage, style: TextStyle(fontSize: 12, color: colors.textMuted)),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
              onPressed: vm.logout,
              icon: Icon(Icons.logout_rounded, size: 18, color: colors.danger),
              label: Text(context.tr('SignOut'), style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
              onPressed: vm.continueOffline,
              icon: const Icon(Icons.library_music_rounded, size: 18),
              label: Text(context.tr('BackToMusic')),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _signedOut(BuildContext context) {
    final vm = context.vm;
    final server = vm.serverSettings;
    final colors = context.colors;
    final setup = server.isSetupRequired;
    Widget notice(IconData icon, Widget body) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _amber.withValues(alpha: 0x28 / 255),
        border: Border.all(color: _amber.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(Radii.card - 2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: _amber),
          const SizedBox(width: 8),
          Expanded(child: body),
        ],
      ),
    );
    final field = <Widget>[
      SectionLabel(context.tr('ServerAddressLabel'), padding: const EdgeInsets.fromLTRB(2, 0, 0, 6)),
      Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 46,
              child: TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autofocus: !server.isServerReachable,
                decoration: const InputDecoration(hintText: 'http://192.168.1.10:5200'),
                onSubmitted: (_) => _connect(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: context.tr('TipCheckConnection'),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 46),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              onPressed: server.isConnecting ? null : _connect,
              icon: Icon(Icons.dns_outlined, size: 16, color: colors.palette.cyan),
              label: Text(context.tr('Connect'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
      if (server.isBusy) ...[
        const SizedBox(height: 8),
        LinearProgressIndicator(minHeight: 3, color: colors.palette.cyan),
      ],
      const SizedBox(height: 6),
      Text(server.statusMessage, style: TextStyle(fontSize: 11, color: colors.textMuted)),
    ];
    return [
      ...field,
      if (server.isServerOffline) ...[
        const SizedBox(height: 12),
        notice(
          Icons.cloud_off_rounded,
          Text(context.tr('ServerUnreachableHint'), style: TextStyle(fontSize: 12, color: colors.textMain)),
        ),
      ],
      const SizedBox(height: 16),
      if (setup) ...[
        notice(
          Icons.shield_outlined,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr('FirstRun'),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: colors.textMain),
              ),
              const SizedBox(height: 4),
              Text(context.tr('FirstRunHint'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _field(_setupCode, context.tr('SetupCodePlaceholder'), capitalize: true),
        const SizedBox(height: 12),
      ],
      _field(
        _username,
        context.tr(setup ? 'AdminUsernamePlaceholder' : 'UsernamePlaceholder'),
        autofill: AutofillHints.username,
      ),
      const SizedBox(height: 12),
      _field(
        _password,
        setup ? server.passwordHint : context.tr('PasswordPlaceholder'),
        obscure: true,
        autofill: setup ? AutofillHints.newPassword : AutofillHints.password,
        onSubmitted: _submit,
      ),
      if (!setup) ...[
        const SizedBox(height: 4),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(context.tr('StaySignedIn'), style: TextStyle(fontSize: 12, color: colors.textMain)),
          value: server.stayLoggedIn,
          onChanged: (v) => setState(() => server.stayLoggedIn = v ?? true),
        ),
      ],
      const SizedBox(height: 8),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
        onPressed: server.isAuthenticating ? null : _submit,
        icon: Icon(setup ? Icons.admin_panel_settings_outlined : Icons.login_rounded, size: 18),
        label: Text(context.tr(setup ? 'CreateAdminAndSignIn' : 'SignIn')),
      ),
      if (server.hasAuthError) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0x28FF003C),
            border: Border.all(color: colors.danger.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(Radii.card - 2),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, size: 16, color: colors.danger),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  server.authErrorMessage,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.danger),
                ),
              ),
            ],
          ),
        ),
      ],
      if (server.supportsLocalFolder) ...[
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: Divider(color: colors.glassBorder)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                context.tr('Or'),
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: colors.textMuted),
              ),
            ),
            Expanded(child: Divider(color: colors.glassBorder)),
          ],
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
          onPressed: () {
            vm.continueOffline();
            if (vm.library.tracks.isEmpty) vm.navigateTo(AppSection.settings);
          },
          icon: Icon(Icons.folder_open_outlined, size: 18, color: colors.palette.lime),
          label: Text(context.tr('ContinueWithoutServer'), style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    ];
  }

  Widget _field(
    TextEditingController controller,
    String hint, {
    bool obscure = false,
    bool capitalize = false,
    String? autofill,
    VoidCallback? onSubmitted,
  }) => SizedBox(
    height: 46,
    child: TextField(
      controller: controller,
      obscureText: obscure,
      obscuringCharacter: '•',
      textCapitalization: capitalize ? TextCapitalization.characters : TextCapitalization.none,
      autofillHints: autofill == null ? null : [autofill],
      decoration: InputDecoration(hintText: hint),
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted(),
    ),
  );
}
