// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
import '../theme/palette.dart';
import '../view_models/settings_view_models.dart';
import '../widgets/common.dart';
import '../widgets/devices.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  /// The content width from which the settings sit in two columns.
  static const double _twoColumnWidth = 860;

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    return ListenableBuilder(
      listenable: Listenable.merge([vm, vm.serverSettings, vm.audioSettings, vm.downloads.states]),
      builder: (context, _) {
        final server = vm.serverSettings;
        final left = <Widget>[
          const _AccountAndUsersCard(),
          const SizedBox(height: 16),
          const _ConnectionAndStorageCard(),
          const SizedBox(height: 16),
          const _AboutCard(),
        ];
        final right = <Widget>[
          if (vm.audioSettings.hasDeviceChoice) ...[
            const _AudioCard(),
            const SizedBox(height: 16),
          ],
          const _AppearanceCard(),
          const SizedBox(height: 16),
          const _HiddenContentCard(),
          if (server.isLoggedIn || vm.downloads.hasAnything) ...[
            const SizedBox(height: 16),
            const _DownloadsCard(),
          ],
          if (server.isLoggedIn) ...[
            const SizedBox(height: 16),
            const _RemoteCard(),
          ],
        ];
        final singleColumn = <Widget>[
          const _AccountAndUsersCard(),
          const SizedBox(height: 16),
          const _ConnectionAndStorageCard(),
          const SizedBox(height: 16),
          if (vm.audioSettings.hasDeviceChoice) ...[
            const _AudioCard(),
            const SizedBox(height: 16),
          ],
          const _AppearanceCard(),
          const SizedBox(height: 16),
          const _HiddenContentCard(),
          if (server.isLoggedIn || vm.downloads.hasAnything) ...[
            const SizedBox(height: 16),
            const _DownloadsCard(),
          ],
          if (server.isLoggedIn) ...[
            const SizedBox(height: 16),
            const _RemoteCard(),
          ],
          const SizedBox(height: 16),
          const _AboutCard(),
        ];

        return LayoutBuilder(
          builder: (context, constraints) {
            final twoColumns = constraints.maxWidth >= _twoColumnWidth;
            final narrow = constraints.maxWidth < 600;
            return ListView(
              key: const PageStorageKey('settings'),
              padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom),
              children: [
                PageHeader(title: context.tr('NavSettings'), subtitle: context.tr('SettingsSubtitle')),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 30),
                  child: twoColumns
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left),
                            ),
                            const SizedBox(width: 24),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: singleColumn,
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _CardTitle extends StatelessWidget {
  const _CardTitle({required this.icon, required this.title, this.subtitle, this.trailing});

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: colors.accent.withValues(alpha: 0.25)),
            ),
            child: Icon(icon, color: colors.accent, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    letterSpacing: -0.2,
                    fontWeight: FontWeight.w800,
                    color: colors.textMain,
                  ),
                ),
                if (subtitle != null) Text(subtitle!, style: TextStyle(fontSize: 12, color: colors.textMuted)),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine(this.text, {this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(text, style: TextStyle(fontSize: 12, color: isError ? colors.danger : colors.textMuted)),
    );
  }
}

/// A text field with its buttons, which take the field's height: side by side while the field keeps room for a path
/// next to them, otherwise under the field, at its right end.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field, required this.actions});

  final Widget field;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // About 140 px per button, and at least 280 for the field.
      if (constraints.maxWidth < 280 + 140 * actions.length) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            field,
            const SizedBox(height: 10),
            Wrap(alignment: WrapAlignment.end, spacing: 10, runSpacing: 8, children: actions),
          ],
        );
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: field),
            for (final action in actions) ...[const SizedBox(width: 10), action],
          ],
        ),
      );
    },
  );
}

class _AccountAndUsersCard extends StatefulWidget {
  const _AccountAndUsersCard();

  @override
  State<_AccountAndUsersCard> createState() => _AccountAndUsersCardState();
}

class _AccountAndUsersCardState extends State<_AccountAndUsersCard> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final server = context.vm.serverSettings;
        if (server.isLoggedIn && server.isAdmin) {
          server.loadUsers();
        }
      }
    });
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _add(ServerSettingsViewModel server) async {
    server
      ..newUsername = _username.text
      ..newPassword = _password.text
      ..confirmPassword = _confirm.text;
    await server.addUser();
    if (!server.hasUserManagementError) {
      _username.clear();
      _password.clear();
      _confirm.clear();
    }
    if (mounted) setState(() {});
  }

  void _openChangePasswordDialog(BuildContext context, ServerSettingsViewModel server) {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    String? error;
    bool busy = false;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final colors = ctx.colors;
          return AlertDialog(
            title: Text(ctx.tr('ChangePassword')),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: current,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: ctx.tr('CurrentPassword'),
                      hintText: ctx.tr('CurrentPassword'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: next,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: ctx.tr('NewPassword'),
                      hintText: ctx.tr('PasswordMinPlaceholder'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirm,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: ctx.tr('PasswordConfirmPlaceholder'),
                      hintText: ctx.tr('PasswordConfirmPlaceholder'),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!, style: TextStyle(color: colors.danger, fontSize: 13)),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(ctx).pop(),
                child: Text(ctx.tr('Cancel')),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setDialogState(() {
                          busy = true;
                          error = null;
                        });
                        final err = await server.changePassword(current.text, next.text, confirm.text);
                        if (err != null) {
                          setDialogState(() {
                            busy = false;
                            error = err;
                          });
                        } else {
                          if (ctx.mounted) Navigator.of(ctx).pop();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(context.tr('PasswordChanged'))),
                            );
                          }
                        }
                      },
                child: Text(ctx.tr('Save')),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openAdminResetPasswordDialog(BuildContext context, ServerSettingsViewModel server, UserInfo user) {
    final next = TextEditingController();
    final confirm = TextEditingController();
    String? error;
    bool busy = false;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final colors = ctx.colors;
          return AlertDialog(
            title: Text('${ctx.tr('ResetPassword')}: ${user.username}'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: next,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: ctx.tr('NewPassword'),
                      hintText: ctx.tr('PasswordMinPlaceholder'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirm,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: ctx.tr('PasswordConfirmPlaceholder'),
                      hintText: ctx.tr('PasswordConfirmPlaceholder'),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!, style: TextStyle(color: colors.danger, fontSize: 13)),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(ctx).pop(),
                child: Text(ctx.tr('Cancel')),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setDialogState(() {
                          busy = true;
                          error = null;
                        });
                        final err = await server.adminResetPassword(user.id, next.text, confirm.text);
                        if (err != null) {
                          setDialogState(() {
                            busy = false;
                            error = err;
                          });
                        } else {
                          if (ctx.mounted) Navigator.of(ctx).pop();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(context.tr('PasswordChanged'))),
                            );
                          }
                        }
                      },
                child: Text(ctx.tr('Save')),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final server = vm.serverSettings;
    final colors = context.colors;

    final fields = [
      TextField(
        controller: _username,
        decoration: InputDecoration(hintText: context.tr('UsernamePlaceholder')),
      ),
      TextField(
        controller: _password,
        obscureText: true,
        decoration: InputDecoration(hintText: context.tr('PasswordMinPlaceholder')),
      ),
      TextField(
        controller: _confirm,
        obscureText: true,
        decoration: InputDecoration(hintText: context.tr('PasswordConfirmPlaceholder')),
        onSubmitted: (_) => _add(server),
      ),
    ];

    return ListenableBuilder(
      listenable: server,
      builder: (context, _) => GlassCard(
        opaque: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardTitle(
              icon: Icons.person_rounded,
              title: context.tr(server.isAdmin ? 'Users' : 'TipAccount'),
            ),
            if (server.isLoggedIn) ...[
              Row(
                children: [
                  Tooltip(
                    message: context.tr('TipAccount'),
                    child: CircleAvatar(
                      radius: 22,
                      backgroundColor: colors.surface2,
                      child: Icon(
                        server.isAdmin ? Icons.admin_panel_settings_outlined : Icons.person_outline,
                        color: colors.textMain,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          server.currentUserName,
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: colors.textMain),
                        ),
                        Text(
                          '${server.currentUserRole} • ${server.serverUrl}',
                          style: TextStyle(fontSize: 12, color: colors.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Tooltip(
                    message: context.tr('TipChangePassword'),
                    child: OutlinedButton.icon(
                      onPressed: () => _openChangePasswordDialog(context, server),
                      icon: const Icon(Icons.key_rounded, size: 16),
                      label: Text(context.tr('ChangePassword')),
                    ),
                  ),
                  Tooltip(
                    message: context.tr('TipSignOut'),
                    child: OutlinedButton.icon(
                      onPressed: vm.logout,
                      icon: Icon(Icons.logout_rounded, color: colors.danger, size: 16),
                      label: Text(context.tr('SignOut')),
                    ),
                  ),
                ],
              ),
            ]
            else
              Row(
                children: [
                  Tooltip(
                    message: context.tr('TipAccount'),
                    child: Icon(Icons.account_circle_outlined, size: 40, color: colors.textMuted),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.tr('NotSignedIn'),
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: colors.textMain),
                        ),
                        Text(context.tr('NotSignedInHint'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: vm.showLoginScreen,
                    icon: const Icon(Icons.login_rounded, size: 16),
                    label: Text(context.tr('SignIn')),
                  ),
                ],
              ),
            if (server.isLoggedIn && server.isAdmin) ...[
              const SizedBox(height: 20),
              Divider(color: colors.glassBorder, height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SectionLabel(context.tr('NewUser'), padding: const EdgeInsets.fromLTRB(0, 4, 0, 8)),
                  ),
                  IconButton(
                    tooltip: context.tr('TipRefreshList'),
                    onPressed: server.loadUsers,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              LayoutBuilder(
                builder: (context, constraints) {
                  final add = FilledButton.icon(
                    onPressed: server.isAddingUser ? null : () => _add(server),
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: Text(context.tr('Add')),
                  );
                  if (constraints.maxWidth < 760) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final f in fields) Padding(padding: const EdgeInsets.only(bottom: 10), child: f),
                        Align(alignment: Alignment.centerRight, child: add),
                      ],
                    );
                  }
                  return IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final f in fields) ...[Expanded(child: f), const SizedBox(width: 10)],
                        add,
                      ],
                    ),
                  );
                },
              ),
              _StatusLine(server.userManagementErrorMessage, isError: true),
              SectionLabel(context.tr('RegisteredUsers'), padding: const EdgeInsets.fromLTRB(0, 16, 0, 4)),
              for (final user in server.serverUsers)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: colors.surface2,
                        child: Icon(
                          user.isAdmin ? Icons.admin_panel_settings_outlined : Icons.person_outline,
                          size: 18,
                          color: colors.textMain,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user.username,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: colors.textMain),
                            ),
                            Text(
                              '${context.tr(user.isAdmin ? 'RoleAdmin' : 'RoleUser')} • '
                              '${context.trf('CreatedAt', [user.createdAt])}',
                              style: TextStyle(fontSize: 12, color: colors.textMuted),
                            ),
                          ],
                        ),
                      ),
                      if (user.username != server.currentUserName) ...[
                        IconButton(
                          tooltip: context.tr('TipResetPassword'),
                          icon: Icon(Icons.lock_reset_rounded, color: colors.textMuted),
                          onPressed: () => _openAdminResetPasswordDialog(context, server, user),
                        ),
                        IconButton(
                          tooltip: context.tr('TipDeleteUser'),
                          icon: Icon(Icons.delete_outline, color: colors.danger),
                          onPressed: () => server.deleteUser(user.id),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConnectionAndStorageCard extends StatefulWidget {
  const _ConnectionAndStorageCard();

  @override
  State<_ConnectionAndStorageCard> createState() => _ConnectionAndStorageCardState();
}

class _ConnectionAndStorageCardState extends State<_ConnectionAndStorageCard> {
  late final TextEditingController _url;
  late final TextEditingController _serverFolder;
  late final TextEditingController _localPath;
  String _lastSyncedUrl = '';
  String _lastLoadedServerFolder = '';

  @override
  void initState() {
    super.initState();
    final server = context.vm.serverSettings;
    _url = TextEditingController(text: server.serverUrl);
    _serverFolder = TextEditingController(text: server.serverLibraryPath);
    _localPath = TextEditingController(text: server.localLibraryPath);
    _lastSyncedUrl = server.serverUrl;
    _lastLoadedServerFolder = server.serverLibraryPath;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final vm = context.vm.serverSettings;
        if (vm.isLoggedIn && vm.isAdmin) {
          vm.loadServerConfig();
        }
      }
    });
  }


  @override
  void dispose() {
    _url.dispose();
    _serverFolder.dispose();
    _localPath.dispose();
    super.dispose();
  }

  Future<void> _browseLocal(ServerSettingsViewModel server) async {
    final chosen = await FilePicker.getDirectoryPath(initialDirectory: server.localLibraryPath);
    if (chosen == null) return;
    _localPath.text = chosen;
    server.localLibraryPath = chosen;
  }

  @override
  Widget build(BuildContext context) {
    final server = context.vm.serverSettings;
    final colors = context.colors;

    return ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        if (server.serverUrl != _lastSyncedUrl && server.serverUrl != _url.text) {
          _lastSyncedUrl = server.serverUrl;
          _url.text = server.serverUrl;
        }
        if (server.serverLibraryPath != _lastLoadedServerFolder) {
          _lastLoadedServerFolder = server.serverLibraryPath;
          _serverFolder.text = server.serverLibraryPath;
        }
        if (server.localLibraryPath != _localPath.text) {
          _localPath.text = server.localLibraryPath;
        }

        final badgeColor = server.isLoggedIn
            ? colors.palette.success
            : (server.isServerOffline ? colors.danger : colors.palette.warning);

        return GlassCard(
          opaque: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CardTitle(
              icon: Icons.dns_outlined,
              title: context.tr('Connection'),
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  server.serverStatusBadge,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: badgeColor),
                ),
              ),
            ),
            _FieldRow(
              field: TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: context.tr('ServerUrlPlaceholder'),
                  prefixIcon: const Icon(Icons.link_rounded, size: 18),
                ),
                onChanged: (v) => server.serverUrl = v,
                onSubmitted: (_) => server.connectServer(),
              ),
              actions: [
                Tooltip(
                  message: context.tr('TipCheckConnection'),
                  child: FilledButton(
                    onPressed: server.isConnecting ? null : server.connectServer,
                    child: server.isConnecting
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(context.tr('ConnectShort')),
                  ),
                ),
              ],
            ),
            _StatusLine(server.statusMessage, isError: server.isServerOffline),

            if (server.isLoggedIn && server.isAdmin) ...[
              const SizedBox(height: 20),
              Divider(color: colors.glassBorder, height: 1),
              const SizedBox(height: 16),
              _CardTitle(
                icon: Icons.folder_shared_outlined,
                title: context.tr('ServerFolderLabel'),
              ),
              _FieldRow(
                field: TextField(
                  controller: _serverFolder,
                  decoration: InputDecoration(
                    hintText: context.tr('ServerFolderPlaceholder'),
                    helperText: context.tr('ServerFolderHelper'),
                    helperMaxLines: 2,
                    prefixIcon: const Icon(Icons.folder_outlined, size: 18),
                  ),
                  onChanged: (v) => server.serverLibraryPath = v,
                  onSubmitted: (_) => server.updateServerLibraryPath(),
                ),

                actions: [
                  Tooltip(
                    message: context.tr('TipReindex'),
                    child: OutlinedButton.icon(
                      onPressed: server.canRescanServer ? server.rescanServer : null,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(context.tr('Reindex')),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: server.isUpdatingServerConfig ? null : server.updateServerLibraryPath,
                    icon: const Icon(Icons.save_rounded, size: 18),
                    label: Text(context.tr('SaveFolder')),
                  ),
                ],
              ),
            ],

            if (server.supportsLocalFolder) ...[
              const SizedBox(height: 20),
              Divider(color: colors.glassBorder, height: 1),
              const SizedBox(height: 16),
              _CardTitle(
                icon: Icons.folder_open_rounded,
                title: context.tr('LocalFolderLabel'),
              ),
              _FieldRow(
                field: TextField(
                  controller: _localPath,
                  decoration: InputDecoration(
                    hintText: context.tr('LocalFolderPlaceholder'),
                    prefixIcon: const Icon(Icons.folder_outlined, size: 18),
                  ),
                  onChanged: (v) => server.localLibraryPath = v,
                  onSubmitted: (_) => server.startScanFolder(),
                ),
                actions: [
                  OutlinedButton.icon(
                    onPressed: () => _browseLocal(server),
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: Text(context.tr('Browse')),
                  ),
                  FilledButton.icon(
                    onPressed: server.isScanning ? null : server.startScanFolder,
                    icon: const Icon(Icons.manage_search_rounded, size: 18),
                    label: Text(context.tr('Scan')),
                  ),
                ],
              ),
              if (server.isScanning) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: server.scanProgress > 0 ? server.scanProgress / 100 : null),
              ],
            ],
          ],
        ),
      );
    },
  );
  }
}

/// What is downloaded, how much room it takes, what is being downloaded now, and a way to remove it all (after a
/// second tap: it can be gigabytes).
class _DownloadsCard extends StatefulWidget {
  const _DownloadsCard();

  @override
  State<_DownloadsCard> createState() => _DownloadsCardState();
}

class _DownloadsCardState extends State<_DownloadsCard> {
  bool _confirming = false;

  @override
  Widget build(BuildContext context) {
    final downloads = context.vm.downloads;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, _) => GlassCard(
        opaque: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardTitle(
              icon: Icons.download_for_offline_outlined,
              title: context.tr('Downloads'),
              subtitle: context.tr('DownloadsHint'),
            ),
            Text(
              context.trf('DownloadsLocation', [downloads.destinationDirectory]),
              style: TextStyle(fontSize: 12, color: colors.textMuted),
            ),
            const SizedBox(height: 6),
            Text(
              downloads.sizeText,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: colors.textMain),
            ),
            _StatusLine(downloads.statusText, isError: downloads.hasError),

            if (downloads.hasAnything) ...[
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 10,
                runSpacing: 8,
                children: _confirming
                    ? [
                        OutlinedButton(
                          onPressed: () => setState(() => _confirming = false),
                          child: Text(context.tr('Cancel')),
                        ),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: colors.danger),
                          onPressed: () async {
                            setState(() => _confirming = false);
                            await downloads.removeAll();
                          },
                          icon: const Icon(Icons.delete_forever_rounded),
                          label: Text(context.tr('DownloadsRemoveConfirm')),
                        ),
                      ]
                    : [
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(foregroundColor: colors.danger),
                          onPressed: () => setState(() => _confirming = true),
                          icon: Icon(Icons.delete_outline_rounded, color: colors.danger),
                          label: Text(context.tr('DownloadsRemoveAll')),
                        ),
                      ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Remote control: whether the account's other players see this one, and the name they show it by.
class _RemoteCard extends StatefulWidget {
  const _RemoteCard();

  @override
  State<_RemoteCard> createState() => _RemoteCardState();
}

class _RemoteCardState extends State<_RemoteCard> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: context.vm.deviceName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final player = vm.player;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final others = player.otherDevices.length;
        final status = !vm.isRemoteEnabled
            ? context.tr('RemoteStatusOff')
            : (player.canReachDevices
                  ? context.trf('RemoteStatusConnected', [others])
                  : context.tr('RemoteStatusConnecting'));
        return GlassCard(
          opaque: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CardTitle(
                icon: Icons.cast_rounded,
                title: context.tr('RemoteControl'),
                subtitle: context.tr('RemoteControlHint'),
                trailing: Switch(value: vm.isRemoteEnabled, onChanged: (value) => vm.isRemoteEnabled = value),
              ),
              TextField(
                controller: _name,
                enabled: vm.isRemoteEnabled,
                maxLength: RemoteRules.maxDeviceNameLength,
                decoration: InputDecoration(
                  counterText: '',
                  labelText: context.tr('DeviceNameLabel'),
                  hintText: deviceLabel(context, '', vm.capabilities.kind),
                  prefixIcon: Icon(deviceIcon(vm.capabilities.kind), size: 18),
                ),
                onChanged: (value) => vm.deviceName = value,
              ),
              _StatusLine(status),
            ],
          ),
        );
      },
    );
  }
}

/// The audio settings: output device, audiophile mode switches, and signal path in one unified frame.
class _AudioCard extends StatelessWidget {
  const _AudioCard();

  @override
  Widget build(BuildContext context) {
    final audio = context.vm.audioSettings;
    final colors = context.colors;
    final palette = colors.palette;

    final player = context.vm.player;

    return ListenableBuilder(
      listenable: Listenable.merge([audio, player]),
      builder: (context, _) {
        final devices = audio.availableDevices;

        Widget mode(
          String title,
          String badgeText,
          QualityTier tier,
          String description,
          bool value,
          bool available,
          ValueChanged<bool> onChanged,
          String tip,
        ) {
          final fg = MedalColors.fg(tier);
          final border = value ? fg.withValues(alpha: 0.6) : colors.glassBorder;
          return Tooltip(
            message: '$title: ${context.tr(tip)}',
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.surface1,
                borderRadius: BorderRadius.circular(Radii.small + 2),
                border: Border.all(color: border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: MedalColors.bg(tier),
                          border: Border.all(color: MedalColors.border(tier)),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          badgeText,
                          style: TextStyle(
                            color: fg,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Switch(
                        value: value,
                        activeTrackColor: fg,
                        onChanged: available ? onChanged : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(description, style: TextStyle(fontSize: 11.5, height: 1.35, color: colors.textMuted)),
                  if (!available) ...[
                    const SizedBox(height: 6),
                    Text(context.tr('ExclusiveUnavailable'), style: TextStyle(fontSize: 10, color: palette.warning)),
                  ],
                ],
              ),
            ),
          );
        }

        return GlassCard(
          opaque: true,
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardTitle(
            icon: Icons.volume_up_rounded,
            title: context.tr('SettingsAudioSection'),
            trailing: IconButton(
              tooltip: context.tr('Refresh'),
              onPressed: audio.refreshDevices,
              icon: const Icon(Icons.refresh_rounded, size: 18),
            ),
          ),
          Text(
            context.tr('OutputDevice'),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: colors.textMuted),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: devices.any((d) => d.id == audio.selectedDevice?.id) ? audio.selectedDevice?.id : null,
            isExpanded: true,
            items: [
              for (final d in devices)
                DropdownMenuItem(
                  value: d.id,
                  child: Row(
                    children: [
                      Icon(Icons.speaker_outlined, size: 16, color: colors.textMain),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          d.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (d.driverType.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            '[${d.driverType}]',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: colors.textMuted),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
            onChanged: (id) => audio.selectDevice(devices.where((d) => d.id == id).firstOrNull),
          ),
          const SizedBox(height: 8),
          Text(audio.hardwareStatusText, style: TextStyle(fontSize: 11.5, color: colors.textMuted)),

          const SizedBox(height: 18),
          Divider(color: colors.glassBorder, height: 1),
          const SizedBox(height: 14),

          LayoutBuilder(
            builder: (context, constraints) {
              final exclusive = mode(
                context.tr('ExclusiveLabel'),
                'EXCLUSIVE',
                QualityTier.silver,
                context.tr('ExclusiveDescription'),
                audio.isExclusiveMode,
                audio.isExclusiveAvailable,
                audio.setExclusiveMode,
                'TipExclusive',
              );
              final bitperfect = mode(
                context.tr('ModeBitPerfect'),
                'BIT-PERFECT',
                QualityTier.gold,
                context.tr('BitPerfectDescription'),
                audio.isBitperfect,
                audio.isBitperfectAvailable,
                audio.setBitperfect,
                'TipBitPerfect',
              );
              if (constraints.maxWidth < 420) {
                return Column(children: [exclusive, const SizedBox(height: 10), bitperfect]);
              }
              return Row(
                children: [
                  Expanded(child: exclusive),
                  const SizedBox(width: 10),
                  Expanded(child: bitperfect),
                ],
              );
            },
          ),

          const SizedBox(height: 18),
          Divider(color: colors.glassBorder, height: 1),
          const SizedBox(height: 14),

          Text(
            context.tr('SignalPath'),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: colors.textMuted),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: colors.surface1, borderRadius: BorderRadius.circular(Radii.small + 2)),
            child: Text(
              audio.signalPath,
              style: TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['JetBrains Mono', 'Consolas', 'DejaVu Sans Mono', 'Courier New'],
                fontSize: 11.5,
                height: 18 / 11.5,
                color: palette.lime,
              ),
            ),
          ),
        ],
      ),
    );
  },
);
  }
}

class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) => GlassCard(
        opaque: true,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardTitle(
            icon: Icons.palette_outlined,
            title: context.tr('SettingsAppearanceSection'),
          ),
          Text(
            context.tr('Language'),
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: colors.textMain),
          ),
          const SizedBox(height: 2),
          Text(context.tr('SettingsLanguageHint'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final l in Localizer.languages)
                Tooltip(
                  message: context.tr('TipLanguage'),
                  child: l.code == vm.language
                      ? FilledButton(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          ),
                          onPressed: () => vm.changeLanguage(l.code),
                          child: Text(l.nativeName),
                        )
                      : OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          ),
                          onPressed: () => vm.changeLanguage(l.code),
                          child: Text(l.nativeName),
                        ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr('Theme'),
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: colors.textMain),
                    ),
                    Text(context.tr('SettingsThemeHint'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
                  ],
                ),
              ),
              Tooltip(
                message: context.tr('TipToggleTheme'),
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  onPressed: vm.toggleTheme,
                  icon: Icon(vm.isLight ? Icons.dark_mode_outlined : Icons.light_mode_outlined, size: 16),
                  label: Text(context.tr('Theme')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(color: colors.glassBorder, height: 1),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr('SettingsOnlineLyrics'),
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: colors.textMain),
                    ),
                    Text(context.tr('SettingsOnlineLyricsHint'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
                  ],
                ),
              ),
              Switch(
                value: vm.useOnlineLyrics,
                onChanged: (v) => vm.useOnlineLyrics = v,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr('SettingsPerformanceStats'),
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: colors.textMain),
                    ),
                    Text(context.tr('SettingsPerformanceStatsHint'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
                  ],
                ),
              ),
              Switch(
                value: vm.showPerformanceStats,
                onChanged: (v) => vm.showPerformanceStats = v,
              ),
            ],
          ),
        ],
      ),
    ),
    );
  }
}

/// The version, the copyright, the license and where the source is: the GNU AGPL's "Appropriate Legal Notices". A version
/// of Wiretune that someone else modifies has to keep showing them, and to say that it is based on Wiretune (NOTICE.md).
class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = TextStyle(fontSize: 12.5, height: 1.45, color: colors.textMuted);
    return GlassCard(
      opaque: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            icon: Icons.info_outline_rounded,
            title: context.tr('SettingsAboutSection'),
            subtitle: 'Wiretune • ${context.trf('AboutVersion', [WiretuneInfo.version])}',
          ),
          Text(WiretuneInfo.copyright, style: text),
          const SizedBox(height: 4),
          Text(context.tr('AboutLicense'), style: text),
          const SizedBox(height: 4),
          // Selectable, so that it can be copied (the app opens no browser).
          SelectableText.rich(
            TextSpan(
              children: [
                TextSpan(text: '${context.tr('AboutSource')}: '),
                TextSpan(
                  text: WiretuneInfo.sourceUrl,
                  style: TextStyle(color: colors.accent),
                ),
              ],
            ),
            style: text,
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'Wiretune',
              applicationVersion: WiretuneInfo.version,
              applicationLegalese:
                  '${WiretuneInfo.copyright}\n${context.tr('AboutLicense')}\n'
                  '${context.tr('AboutSource')}: ${WiretuneInfo.sourceUrl}',
            ),
            icon: Icon(Icons.description_outlined, size: 18, color: colors.accent),
            label: Text(context.tr('AboutLicenses')),
          ),
        ],
      ),
    );
  }
}

class _HiddenContentCard extends StatelessWidget {
  const _HiddenContentCard();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final lib = vm.library;
    final colors = context.colors;

    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) {
        final hiddenTracks = lib.hiddenTracks;
        final hiddenAlbums = lib.hiddenAlbums;
        final hiddenArtists = lib.hiddenArtists;
        final totalHidden = hiddenTracks.length + hiddenAlbums.length + hiddenArtists.length;

        return GlassCard(
          opaque: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CardTitle(
                icon: Icons.visibility_off_outlined,
                title: context.tr('HiddenContent'),
                subtitle: context.tr('HiddenContentHint'),
              ),
              if (totalHidden == 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    context.tr('HiddenContentEmpty'),
                    style: TextStyle(color: colors.textMuted, fontSize: 13),
                  ),
                )
              else ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final id in hiddenArtists) ...[
                        _hiddenRow(
                          context,
                          icon: Icons.person_outline_rounded,
                          label: lib.rawTracks
                                  .where((t) =>
                                      stableId(t.artist.toLowerCase()) == id ||
                                      stableId(t.effectiveAlbumArtist.toLowerCase()) == id)
                                  .firstOrNull
                                  ?.effectiveAlbumArtist ??
                              id,
                          onUnhide: () => lib.unhideArtist(id),
                        ),
                        Divider(color: colors.glassBorder, height: 1),
                      ],
                      for (final id in hiddenAlbums) ...[
                        _hiddenRow(
                          context,
                          icon: Icons.album_outlined,
                          label: () {
                            final track = lib.rawTracks.where((t) => t.albumId == id).firstOrNull;
                            return track != null ? '${track.album} • ${track.effectiveAlbumArtist}' : id;
                          }(),
                          onUnhide: () => lib.unhideAlbum(id),
                        ),
                        Divider(color: colors.glassBorder, height: 1),
                      ],
                      for (final id in hiddenTracks) ...[
                        _hiddenRow(
                          context,
                          icon: Icons.music_note_outlined,
                          label: () {
                            final track = lib.getTrack(id);
                            return track != null ? '${track.title} • ${track.artist}' : id;
                          }(),
                          onUnhide: () => lib.unhideTrack(id),
                        ),
                        Divider(color: colors.glassBorder, height: 1),
                      ],
                    ],
                  ),
                ),
                if (totalHidden > 1) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: () => lib.unhideAll(),
                      icon: const Icon(Icons.visibility_rounded, size: 16),
                      label: Text(context.tr('UnhideAll')),
                    ),
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _hiddenRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onUnhide,
  }) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: colors.textMain),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onUnhide,
            child: Text(context.tr('Unhide'), style: TextStyle(color: colors.accent, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}


