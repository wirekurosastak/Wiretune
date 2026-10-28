// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../platform.dart';
import '../theme/app_theme.dart';
import '../theme/palette.dart';
import '../view_models/app_section.dart';
import '../view_models/settings_view_models.dart';
import '../widgets/devices.dart';
import '../widgets/dialogs.dart';
import '../widgets/page_parts.dart';
import '../widgets/buttons.dart';

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
        // The music folders: the server's for its administrator, this computer's on a desktop.
        final library = (server.isLoggedIn && server.isAdmin) || server.supportsLocalFolder;
        final account = [const _AccountCard(), if (library) const _LibraryCard()];
        final options = [
          // The TV has neither an output to choose nor gapless playback or normalization.
          if (vm.audioSettings.hasDeviceChoice || !AppPlatform.current.isTizen) const _AudioCard(),
          const _AppearanceCard(),
          const _HiddenContentCard(),
          if (server.isLoggedIn || vm.downloads.hasAnything) const _DownloadsCard(),
          if (server.isLoggedIn) const _RemoteCard(),
        ];
        Widget column(List<Widget> cards) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, card) in cards.indexed) ...[if (i > 0) const SizedBox(height: 16), card],
          ],
        );

        return LayoutBuilder(
          builder: (context, constraints) {
            final twoColumns = constraints.maxWidth >= _twoColumnWidth;
            final narrow = constraints.maxWidth < 600;
            return PinnedTitleBar(
              title: context.tr('NavSettings'),
              child: ListView(
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
                              Expanded(child: column([...account, const _AboutCard()])),
                              const SizedBox(width: 24),
                              Expanded(child: column(options)),
                            ],
                          )
                        : column([...account, ...options, const _AboutCard()]),
                  ),
                ],
              ),
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
              borderRadius: BorderRadius.circular(Radii.medium),
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

/// The server this device uses and the account signed in to it: the address and the connection's state, who is signed
/// in (changing the password, signing out), and for an administrator the server's accounts.
class _AccountCard extends StatefulWidget {
  const _AccountCard();

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  late final TextEditingController _url;
  String _lastSyncedUrl = '';

  @override
  void initState() {
    super.initState();
    final server = context.vm.serverSettings;
    _url = TextEditingController(text: server.serverUrl);
    _lastSyncedUrl = server.serverUrl;
    // The accounts as they are now, also when another device changed them since the sign-in loaded them; after the
    // frame, as loading tells the listeners at once. It does nothing for anyone but an administrator.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.vm.serverSettings.loadUsers();
    });
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    _url.dispose();
    super.dispose();
  }

  /// Connects to the address typed; first asks when that leaves the server this device is signed in to.
  Future<void> _connect(ServerSettingsViewModel server) async {
    if (server.wouldSwitchServer(_url.text)) {
      final confirmed = await confirmAction(
        context,
        title: context.tr('SwitchServerConfirm'),
        message: context.trf('SwitchServerConfirmHint', [server.connectedServerUrl]),
        confirmLabel: context.tr('ConnectShort'),
        destructive: true,
      );
      if (!confirmed) return;
    }
    server.serverUrl = _url.text;
    await server.connectServer();
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

  /// Asks for a new password twice and hands it to [submit], which answers what is wrong with it, or null; then the
  /// notice [done]. The signed-in account's Change password and an administrator's reset of another account's.
  void _openPasswordDialog(
    BuildContext context, {
    required String title,
    required Future<String?> Function(String password, String confirm) submit,
    required String done,
  }) {
    final next = TextEditingController();
    final confirm = TextEditingController();
    String? error;
    bool busy = false;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final colors = ctx.colors;
          Future<void> save() async {
            setDialogState(() {
              busy = true;
              error = null;
            });
            final err = await submit(next.text, confirm.text);
            if (err != null) {
              setDialogState(() {
                busy = false;
                error = err;
              });
            } else {
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (context.mounted) context.vm.showNotice(done);
            }
          }

          // While it saves, neither Back nor a tap beside it closes it (Cancel can't either).
          return PopScope(
            canPop: !busy,
            child: AppDialog(
              title: title,
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The caret starts here, and Enter goes on to the second field, where it saves.
                    TextField(
                      controller: next,
                      autofocus: true,
                      obscureText: true,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: ctx.tr('NewPassword'),
                        hintText: ctx.tr('PasswordMinPlaceholder'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: confirm,
                      obscureText: true,
                      decoration: InputDecoration(labelText: ctx.tr('PasswordConfirmPlaceholder')),
                      onSubmitted: (_) => busy ? null : save(),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(error!, style: TextStyle(color: colors.danger, fontSize: 13)),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: busy ? null : () => Navigator.of(ctx).pop(), child: Text(ctx.tr('Cancel'))),
                PressShrink(
                  child: FilledButton(onPressed: busy ? null : save, child: Text(ctx.tr('Save'))),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Deleting an account takes its data with it, so it is asked once more.
  Future<void> _confirmDeleteUser(BuildContext context, ServerSettingsViewModel server, UserInfo user) async {
    final confirmed = await confirmAction(
      context,
      title: context.trf('DeleteUserConfirm', [user.username]),
      message: context.tr('DeleteUserConfirmHint'),
      confirmLabel: context.tr('Delete'),
      destructive: true,
    );
    if (confirmed) await server.deleteUser(user.id);
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
      builder: (context, _) {
        if (server.serverUrl != _lastSyncedUrl && server.serverUrl != _url.text) {
          _lastSyncedUrl = server.serverUrl;
          _url.text = server.serverUrl;
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
                icon: Icons.person_rounded,
                title: context.tr('AccountAndConnection'),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(Radii.pill),
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
                  onSubmitted: (_) => _connect(server),
                ),
                actions: [
                  PressShrink(
                    child: FilledButton(
                      onPressed: server.isConnecting ? null : () => _connect(server),
                      child: server.isConnecting
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(context.tr('ConnectShort')),
                    ),
                  ),
                ],
              ),
              _StatusLine(server.statusMessage, isError: server.isServerOffline),
              const SizedBox(height: 16),
              Divider(color: colors.glassBorder, height: 1),
              const SizedBox(height: 16),
              if (server.isLoggedIn) ...[
                Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: colors.surface2,
                      child: Icon(
                        server.isAdmin ? Icons.admin_panel_settings_outlined : Icons.person_outline,
                        color: colors.textMain,
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
                          Text(server.currentUserRole, style: TextStyle(fontSize: 12, color: colors.textMuted)),
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
                    OutlinedButton.icon(
                      onPressed: () => _openPasswordDialog(
                        context,
                        title: context.tr('ChangePassword'),
                        submit: server.changePassword,
                        done: context.tr('PasswordChangedOthersSignedOut'),
                      ),
                      icon: const Icon(Icons.key_rounded, size: 16),
                      label: Text(context.tr('ChangePassword')),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => confirmAndSignOut(context),
                      icon: Icon(Icons.logout_rounded, color: colors.danger, size: 16),
                      label: Text(context.tr('SignOut')),
                    ),
                  ],
                ),
              ] else
                Row(
                  children: [
                    Icon(Icons.account_circle_outlined, size: 40, color: colors.textMuted),
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
                    PressShrink(
                      child: FilledButton.icon(
                        onPressed: vm.showLoginScreen,
                        icon: const Icon(Icons.login_rounded, size: 16),
                        label: Text(context.tr('SignIn')),
                      ),
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
                    final add = PressShrink(
                      child: FilledButton.icon(
                        onPressed: server.isAddingUser ? null : () => _add(server),
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: Text(context.tr('Add')),
                      ),
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
                            tooltip: context.tr('ResetPassword'),
                            icon: Icon(Icons.lock_reset_rounded, color: colors.textMuted),
                            onPressed: () => _openPasswordDialog(
                              context,
                              title: '${context.tr('ResetPassword')}: ${user.username}',
                              submit: (password, confirm) => server.adminResetPassword(user.id, password, confirm),
                              done: context.trf('PasswordResetDone', [user.username]),
                            ),
                          ),
                          IconButton(
                            tooltip: context.tr('TipDeleteUser'),
                            icon: Icon(Icons.delete_outline_rounded, color: colors.danger),
                            onPressed: () => _confirmDeleteUser(context, server, user),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Where the music is: the server's folder (for its administrator) and this computer's (on a desktop).
class _LibraryCard extends StatefulWidget {
  const _LibraryCard();

  @override
  State<_LibraryCard> createState() => _LibraryCardState();
}

class _LibraryCardState extends State<_LibraryCard> {
  late final TextEditingController _serverFolder;
  late final TextEditingController _localPath;
  String _lastLoadedServerFolder = '';

  @override
  void initState() {
    super.initState();
    final server = context.vm.serverSettings;
    _serverFolder = TextEditingController(text: server.serverFolder);
    _localPath = TextEditingController(text: server.localFolder);
    _lastLoadedServerFolder = server.serverFolder;
    // The folder, and what is wrong with it, as they are now (a drive may have gone since the sign-in); after the
    // frame, as loading tells the listeners at once. It does nothing for anyone but an administrator.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.vm.serverSettings.loadServerFolder();
    });
  }

  @override
  void dispose() {
    _serverFolder.dispose();
    _localPath.dispose();
    super.dispose();
  }

  /// Saves the server's music folder; first asks, since every account's library changes with it.
  Future<void> _saveServerFolder(ServerSettingsViewModel server) async {
    server.serverFolder = _serverFolder.text;
    if (server.serverFolderChanged && server.serverFolder.trim().isNotEmpty) {
      final confirmed = await confirmAction(
        context,
        title: context.tr('ServerFolderConfirm'),
        message: context.trf('ServerFolderConfirmHint', [server.serverFolder.trim()]),
        confirmLabel: context.tr('SaveFolder'),
      );
      if (!confirmed) return;
    }
    await server.saveServerFolder();
  }

  Future<void> _browseLocal(ServerSettingsViewModel server) async {
    final chosen = await FilePicker.getDirectoryPath(initialDirectory: server.localFolder);
    if (chosen == null) return;
    _localPath.text = chosen;
    server.localFolder = chosen;
  }

  @override
  Widget build(BuildContext context) {
    final server = context.vm.serverSettings;
    final colors = context.colors;

    return ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        if (server.serverFolder != _lastLoadedServerFolder) {
          _lastLoadedServerFolder = server.serverFolder;
          _serverFolder.text = server.serverFolder;
        }
        if (server.localFolder != _localPath.text) {
          _localPath.text = server.localFolder;
        }

        final admin = server.isLoggedIn && server.isAdmin;
        return GlassCard(
          opaque: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CardTitle(icon: Icons.library_music_outlined, title: context.tr('SettingsLibrarySection')),
              if (admin) ...[
                SectionLabel(context.tr('ServerFolderLabel'), padding: const EdgeInsets.fromLTRB(0, 4, 0, 10)),
                _FieldRow(
                  field: TextField(
                    controller: _serverFolder,
                    decoration: InputDecoration(
                      hintText: context.tr('ServerFolderPlaceholder'),
                      prefixIcon: const Icon(Icons.folder_outlined, size: 18),
                    ),
                    onChanged: (v) => server.serverFolder = v,
                    onSubmitted: (_) => _saveServerFolder(server),
                  ),

                  actions: [
                    Tooltip(
                      message: context.tr('TipReindex'),
                      child: OutlinedButton.icon(
                        onPressed: server.canReindexServer ? server.reindexServer : null,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(context.tr('Reindex')),
                      ),
                    ),
                    PressShrink(
                      child: FilledButton.icon(
                        onPressed: server.isUpdatingServerConfig ? null : () => _saveServerFolder(server),
                        icon: const Icon(Icons.save_rounded, size: 18),
                        label: Text(context.tr('SaveFolder')),
                      ),
                    ),
                  ],
                ),
                // Under the row, not in the field: the buttons beside it are as tall as the field alone.
                _StatusLine(context.tr('ServerFolderHelper')),
                _StatusLine(server.serverFolderProblem, isError: true),
                _StatusLine(server.serverFolderMessage, isError: server.serverFolderIsError),
              ],

              if (server.supportsLocalFolder) ...[
                if (admin) ...[
                  const SizedBox(height: 20),
                  Divider(color: colors.glassBorder, height: 1),
                  const SizedBox(height: 12),
                ],
                SectionLabel(context.tr('LocalFolder'), padding: const EdgeInsets.fromLTRB(0, 4, 0, 10)),
                _FieldRow(
                  field: TextField(
                    controller: _localPath,
                    decoration: InputDecoration(
                      hintText: context.tr('LocalFolderPlaceholder'),
                      prefixIcon: const Icon(Icons.folder_outlined, size: 18),
                    ),
                    onChanged: (v) => server.localFolder = v,
                    onSubmitted: (_) => server.scanLocalFolder(),
                  ),
                  actions: [
                    OutlinedButton.icon(
                      onPressed: () => _browseLocal(server),
                      icon: const Icon(Icons.folder_open_rounded, size: 18),
                      label: Text(context.tr('Browse')),
                    ),
                    PressShrink(
                      child: FilledButton.icon(
                        onPressed: server.isScanning ? null : server.scanLocalFolder,
                        icon: const Icon(Icons.manage_search_rounded, size: 18),
                        label: Text(context.tr('Scan')),
                      ),
                    ),
                  ],
                ),
                if (server.isScanning) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: server.scanProgress > 0 ? server.scanProgress / 100 : null),
                ],
                _StatusLine(server.localFolderMessage, isError: server.localFolderIsError),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// What is downloaded, how much room it takes, what is being downloaded now, and a way to remove it all (asked first:
/// it can be gigabytes).
class _DownloadsCard extends StatelessWidget {
  const _DownloadsCard();

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
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('DownloadsSyncMode'),
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: colors.textMain),
                      ),
                      Text(
                        context.tr('DownloadsSyncModeHint'),
                        style: TextStyle(fontSize: 12, color: colors.textMuted),
                      ),
                    ],
                  ),
                ),
                Switch(value: downloads.isSyncModeEnabled, onChanged: (v) => downloads.setSyncModeEnabled(v)),
              ],
            ),

            if (downloads.hasAnything) ...[
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: colors.danger),
                  onPressed: () async {
                    final confirmed = await confirmAction(
                      context,
                      title: context.tr('DownloadsRemoveAll'),
                      message: context.trf('DownloadsRemoveAllConfirm', [downloads.copyCount, downloads.sizeLabel]),
                      confirmLabel: context.tr('DownloadsRemoveConfirm'),
                      destructive: true,
                    );
                    if (confirmed) downloads.removeAll();
                  },
                  icon: Icon(Icons.delete_outline_rounded, color: colors.danger),
                  label: Text(context.tr('DownloadsRemoveAll')),
                ),
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
      listenable: Listenable.merge([player, vm]),
      // The status follows the session (the view model) and the devices in reach (the player).
      builder: (context, _) {
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
              _StatusLine(vm.remoteStatus, isError: vm.hasRemoteProblem),
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
    final vm = context.vm;
    final audio = vm.audioSettings;
    final colors = context.colors;
    final palette = colors.palette;

    return ListenableBuilder(
      listenable: Listenable.merge([vm, audio]),
      builder: (context, _) {
        final devices = audio.availableDevices;
        final tv = AppPlatform.current.isTizen;
        TextStyle heading() => TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: colors.textMain);
        TextStyle hint() => TextStyle(fontSize: 12, color: colors.textMuted);

        Widget mode(
          String badgeText,
          QualityTier tier,
          String description,
          bool value,
          bool available,
          ValueChanged<bool> onChanged,
        ) {
          final fg = MedalColors.fg(tier);
          final border = value ? fg.withValues(alpha: 0.6) : colors.glassBorder;
          return Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.surface1,
              borderRadius: BorderRadius.circular(Radii.small),
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
                        borderRadius: BorderRadius.circular(Radii.tag),
                      ),
                      child: Text(
                        badgeText,
                        style: TextStyle(color: fg, fontSize: 10.5, fontWeight: FontWeight.w900, letterSpacing: 0.6),
                      ),
                    ),
                    const Spacer(),
                    Switch(value: value, activeTrackColor: fg, onChanged: available ? onChanged : null),
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
                trailing: audio.hasDeviceChoice
                    ? IconButton(
                        tooltip: context.tr('Refresh'),
                        onPressed: audio.refreshDevices,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                      )
                    : null,
              ),
              // The TV's player starts each track on its own and reads no ReplayGain tags.
              if (!tv) ...[
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(context.tr('SettingsGapless'), style: heading()),
                          Text(context.tr('SettingsGaplessHint'), style: hint()),
                        ],
                      ),
                    ),
                    Switch(value: vm.isGaplessEnabled, onChanged: (v) => vm.isGaplessEnabled = v),
                  ],
                ),
                const SizedBox(height: 14),
                Text(context.tr('SettingsNormalization'), style: heading()),
                Text(context.tr('SettingsNormalizationHint'), style: hint()),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (mode, key) in const [
                      (VolumeNormalization.off, 'NormalizationOff'),
                      (VolumeNormalization.track, 'NormalizationTrack'),
                      (VolumeNormalization.album, 'NormalizationAlbum'),
                    ])
                      _choice(
                        context.tr(key),
                        selected: mode == vm.normalization,
                        // Bit-perfect output is never normalized.
                        onPressed: audio.isBitPerfect ? null : () => vm.normalization = mode,
                      ),
                  ],
                ),
              ],
              if (audio.hasDeviceChoice) ...[
                if (!tv) ...[
                  const SizedBox(height: 18),
                  Divider(color: colors.glassBorder, height: 1),
                  const SizedBox(height: 14),
                ],
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
                      'EXCLUSIVE',
                      QualityTier.silver,
                      context.tr('ExclusiveDescription'),
                      audio.isExclusiveMode,
                      audio.isExclusiveAvailable,
                      audio.setExclusiveMode,
                    );
                    final bitPerfect = mode(
                      'BIT-PERFECT',
                      QualityTier.gold,
                      context.tr('BitPerfectDescription'),
                      audio.isBitPerfect,
                      audio.isBitPerfectAvailable,
                      audio.setBitPerfect,
                    );
                    if (constraints.maxWidth < 420) {
                      return Column(children: [exclusive, const SizedBox(height: 10), bitPerfect]);
                    }
                    return Row(
                      children: [
                        Expanded(child: exclusive),
                        const SizedBox(width: 10),
                        Expanded(child: bitPerfect),
                      ],
                    );
                  },
                ),
              ],

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
                decoration: BoxDecoration(color: colors.surface1, borderRadius: BorderRadius.circular(Radii.small)),
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

/// One of a few options side by side: filled when chosen.
Widget _choice(String label, {required bool selected, VoidCallback? onPressed}) {
  final style = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
  );
  return selected
      ? PressShrink(
          child: FilledButton(style: style, onPressed: onPressed, child: Text(label)),
        )
      : OutlinedButton(style: style, onPressed: onPressed, child: Text(label));
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
            _CardTitle(icon: Icons.palette_outlined, title: context.tr('SettingsAppearanceSection')),
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
                  _choice(l.nativeName, selected: l.code == vm.language, onPressed: () => vm.changeLanguage(l.code)),
              ],
            ),
            const SizedBox(height: 14),
            // The two themes as choices, like the languages.
            Text(
              context.tr('Theme'),
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: colors.textMain),
            ),
            const SizedBox(height: 2),
            Text(context.tr('SettingsThemeHint'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (light, key) in const [(false, 'ThemeDark'), (true, 'ThemeLight')])
                  _choice(
                    context.tr(key),
                    selected: vm.isLight == light,
                    onPressed: () => vm.setTheme(light: light),
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
                      Text(
                        context.tr('SettingsOnlineLyricsHint'),
                        style: TextStyle(fontSize: 12, color: colors.textMuted),
                      ),
                    ],
                  ),
                ),
                Switch(value: vm.useOnlineLyrics, onChanged: (v) => vm.useOnlineLyrics = v),
              ],
            ),
            // The full-screen player is the phone's.
            if (PhoneChrome.isPhone(context)) ...[
              const SizedBox(height: 14),
              Text(
                context.tr('SettingsPlayerSwipe'),
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: colors.textMain),
              ),
              Text(context.tr('SettingsPlayerSwipeHint'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (choice, key) in [
                    (PlayerSwipe.tracks, 'PlayerSwipeTracks'),
                    (PlayerSwipe.tabs, 'PlayerSwipeTabs'),
                  ])
                    _choice(
                      context.tr(key),
                      selected: vm.playerSwipe == choice,
                      onPressed: () => vm.playerSwipe = choice,
                    ),
                ],
              ),
            ],
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
                      Text(
                        context.tr('SettingsPerformanceStatsHint'),
                        style: TextStyle(fontSize: 12, color: colors.textMuted),
                      ),
                    ],
                  ),
                ),
                Switch(value: vm.showPerformanceStats, onChanged: (v) => vm.showPerformanceStats = v),
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
    final colors = context.colors;

    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) {
        final hidden = vm.hiddenItems;
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
              if (hidden.isEmpty)
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
                      for (final item in hidden) ...[
                        _hiddenRow(
                          context,
                          icon: switch (item.kind) {
                            HiddenKind.artist => Icons.person_outline_rounded,
                            HiddenKind.album => Icons.album_outlined,
                            HiddenKind.track => Icons.music_note_outlined,
                          },
                          label: item.label,
                          onUnhide: () => vm.unhide(item),
                        ),
                        Divider(color: colors.glassBorder, height: 1),
                      ],
                    ],
                  ),
                ),
                if (hidden.length > 1) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final confirmed = await confirmAction(
                          context,
                          title: context.tr('UnhideAllConfirm'),
                          message: context.trf('UnhideAllConfirmHint', [hidden.length]),
                          confirmLabel: context.tr('UnhideAll'),
                        );
                        if (confirmed) vm.library.unhideAll();
                      },
                      icon: const Icon(Icons.visibility_outlined, size: 16),
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
