// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../app_scope.dart';
import '../localization.dart';
import '../theme/app_theme.dart';
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
          SectionLabel(context.tr('SettingsServerSection'), padding: const EdgeInsets.fromLTRB(4, 8, 4, 16)),
          const _AccountCard(),
          const SizedBox(height: 16),
          const _ServerCard(),
          if (server.isLoggedIn || vm.downloads.hasAnything) ...[const SizedBox(height: 16), const _DownloadsCard()],
          if (server.isLoggedIn) ...[const SizedBox(height: 16), const _RemoteCard()],
          if (server.supportsLocalFolder) ...[const SizedBox(height: 16), const _LocalFolderCard()],
          if (server.isLoggedIn && server.isAdmin) ...[
            const SizedBox(height: 16),
            const _AdminCard(),
            const SizedBox(height: 16),
            const _UsersCard(),
          ],
        ];
        final right = <Widget>[
          SectionLabel(context.tr('SettingsAppearanceSection'), padding: const EdgeInsets.fromLTRB(4, 0, 4, 16)),
          const _AppearanceCard(),
          SectionLabel(context.tr('Lyrics'), padding: const EdgeInsets.fromLTRB(4, 24, 4, 16)),
          _SwitchCard(
            icon: Icons.lyrics_outlined,
            title: context.tr('SettingsOnlineLyrics'),
            hint: context.tr('SettingsOnlineLyricsHint'),
            value: vm.useOnlineLyrics,
            onChanged: (v) => vm.useOnlineLyrics = v,
          ),
          if (vm.audioSettings.hasDeviceChoice) ...[
            SectionLabel(context.tr('SettingsAudioSection'), padding: const EdgeInsets.fromLTRB(4, 24, 4, 16)),
            const _AudioCard(),
          ],
          const SizedBox(height: 16),
          _SwitchCard(
            icon: Icons.speed_rounded,
            title: context.tr('SettingsPerformanceStats'),
            hint: context.tr('SettingsPerformanceStatsHint'),
            value: vm.showPerformanceStats,
            onChanged: (v) => vm.showPerformanceStats = v,
          ),
          const SizedBox(height: 16),
          const _LibraryStatsCard(),
          SectionLabel(context.tr('SettingsAboutSection'), padding: const EdgeInsets.fromLTRB(4, 24, 4, 16)),
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
                          children: [...left, const SizedBox(height: 24), ...right],
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
              color: colors.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(11),
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

class _AccountCard extends StatelessWidget {
  const _AccountCard();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final server = vm.serverSettings;
    final colors = context.colors;
    if (server.isLoggedIn) {
      return GlassCard(
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: colors.accent.withValues(alpha: 0.18),
              child: Icon(
                server.isAdmin ? Icons.admin_panel_settings_outlined : Icons.person_outline,
                color: colors.accent,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    server.currentUserName,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: colors.textMain),
                  ),
                  Text(
                    '${server.currentUserRole} • ${server.serverUrl}',
                    style: TextStyle(fontSize: 12, color: colors.textMuted),
                  ),
                ],
              ),
            ),
            Tooltip(
              message: context.tr('TipSignOut'),
              child: OutlinedButton.icon(
                onPressed: vm.logout,
                icon: Icon(Icons.logout_rounded, color: colors.danger),
                label: Text(context.tr('SignOut')),
              ),
            ),
          ],
        ),
      );
    }
    return GlassCard(
      child: Row(
        children: [
          Icon(Icons.account_circle_outlined, size: 40, color: colors.textMuted),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('NotSignedIn'),
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: colors.textMain),
                ),
                Text(context.tr('NotSignedInHint'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: vm.showLoginScreen,
            icon: const Icon(Icons.login_rounded),
            label: Text(context.tr('SignIn')),
          ),
        ],
      ),
    );
  }
}

class _ServerCard extends StatefulWidget {
  const _ServerCard();

  @override
  State<_ServerCard> createState() => _ServerCardState();
}

class _ServerCardState extends State<_ServerCard> {
  late final TextEditingController _url = TextEditingController(text: context.vm.serverSettings.serverUrl);
  String _lastSynced = '';

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final server = context.vm.serverSettings;
    final colors = context.colors;
    // Follow the session's address when it changes, never while the user types.
    if (server.serverUrl != _lastSynced && server.serverUrl != _url.text) {
      _lastSynced = server.serverUrl;
      _url.text = server.serverUrl;
    }
    final badgeColor = server.isLoggedIn
        ? colors.palette.success
        : (server.isServerOffline ? colors.danger : colors.palette.warning);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            icon: Icons.dns_outlined,
            title: context.tr('Connection'),
            subtitle: server.librarySourceText,
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
        ],
      ),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardTitle(
              icon: Icons.download_for_offline_outlined,
              title: context.tr('Downloads'),
              subtitle: context.tr('DownloadsHint'),
            ),
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
  late final TextEditingController _name = TextEditingController(text: context.vm.deviceName);

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

class _LocalFolderCard extends StatefulWidget {
  const _LocalFolderCard();

  @override
  State<_LocalFolderCard> createState() => _LocalFolderCardState();
}

class _LocalFolderCardState extends State<_LocalFolderCard> {
  late final TextEditingController _path = TextEditingController(text: context.vm.serverSettings.localLibraryPath);

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _browse(ServerSettingsViewModel server) async {
    final chosen = await FilePicker.getDirectoryPath(initialDirectory: server.localLibraryPath);
    if (chosen == null) return;
    _path.text = chosen;
    server.localLibraryPath = chosen;
  }

  @override
  Widget build(BuildContext context) {
    final server = context.vm.serverSettings;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(icon: Icons.folder_open_rounded, title: context.tr('LocalFolderLabel')),
          _FieldRow(
            field: TextField(
              controller: _path,
              decoration: InputDecoration(
                hintText: context.tr('LocalFolderPlaceholder'),
                prefixIcon: const Icon(Icons.folder_outlined, size: 18),
              ),
              onChanged: (v) => server.localLibraryPath = v,
              onSubmitted: (_) => server.startScanFolder(),
            ),
            actions: [
              OutlinedButton(onPressed: () => _browse(server), child: Text(context.tr('Browse'))),
              FilledButton.icon(
                onPressed: server.isScanning ? null : server.startScanFolder,
                icon: const Icon(Icons.manage_search_rounded),
                label: Text(context.tr('Scan')),
              ),
            ],
          ),
          if (server.isScanning) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: server.scanProgress > 0 ? server.scanProgress / 100 : null),
          ],
          _StatusLine(server.statusMessage),
        ],
      ),
    );
  }
}

class _AdminCard extends StatefulWidget {
  const _AdminCard();

  @override
  State<_AdminCard> createState() => _AdminCardState();
}

class _AdminCardState extends State<_AdminCard> {
  final TextEditingController _folder = TextEditingController();
  String _lastLoaded = '';

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final server = context.vm.serverSettings;
    if (server.serverLibraryPath != _lastLoaded) {
      _lastLoaded = server.serverLibraryPath;
      _folder.text = server.serverLibraryPath;
    }
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(icon: Icons.admin_panel_settings_outlined, title: context.tr('ServerFolderLabel')),
          _FieldRow(
            field: TextField(
              controller: _folder,
              decoration: InputDecoration(
                hintText: context.tr('ServerFolderPlaceholder'),
                prefixIcon: const Icon(Icons.folder_outlined, size: 18),
              ),
              onChanged: (v) => server.serverLibraryPath = v,
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
              FilledButton(
                onPressed: server.isUpdatingServerConfig ? null : server.updateServerLibraryPath,
                child: Text(context.tr('SaveFolder')),
              ),
            ],
          ),
          _StatusLine(server.statusMessage),
        ],
      ),
    );
  }
}

class _UsersCard extends StatefulWidget {
  const _UsersCard();

  @override
  State<_UsersCard> createState() => _UsersCardState();
}

class _UsersCardState extends State<_UsersCard> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

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
  }

  @override
  Widget build(BuildContext context) {
    final server = context.vm.serverSettings;
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
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            icon: Icons.group_outlined,
            title: context.tr('Users'),
            subtitle: context.tr('UsersSubtitle'),
            trailing: IconButton(
              tooltip: context.tr('TipRefreshList'),
              onPressed: server.loadUsers,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ),
          Text(
            context.tr('NewUser'),
            style: TextStyle(fontWeight: FontWeight.w700, color: colors.textMain),
          ),
          const SizedBox(height: 8),
          // In a row with the button where each field still shows its hint, otherwise one under the other.
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
                    backgroundColor: colors.accent.withValues(alpha: 0.14),
                    child: Icon(
                      user.isAdmin ? Icons.admin_panel_settings_outlined : Icons.person_outline,
                      size: 18,
                      color: colors.accent,
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
                  if (user.username != server.currentUserName)
                    IconButton(
                      tooltip: context.tr('TipDeleteUser'),
                      icon: Icon(Icons.delete_outline, color: colors.danger),
                      onPressed: () => server.deleteUser(user.id),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The audio output: the two mode cards side by side, the output device, and the signal path.
class _AudioCard extends StatelessWidget {
  const _AudioCard();

  @override
  Widget build(BuildContext context) {
    final audio = context.vm.audioSettings;
    final colors = context.colors;
    final palette = colors.palette;
    final devices = audio.availableDevices;
    Widget mode(
      String title,
      String description,
      bool value,
      bool available,
      ValueChanged<bool> onChanged,
      Color color,
    ) => MetricCard(
      accent: color,
      onTap: available ? () => onChanged(!value) : () {},
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color),
                ),
              ),
              Switch(value: value, activeTrackColor: color, onChanged: available ? onChanged : null),
            ],
          ),
          const SizedBox(height: 4),
          Text(description, style: TextStyle(fontSize: 12, height: 1.35, color: colors.textMuted)),
          if (!available) ...[
            const SizedBox(height: 8),
            Text(context.tr('ExclusiveUnavailable'), style: TextStyle(fontSize: 10, color: palette.warning)),
          ],
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final exclusive = mode(
              context.tr('ExclusiveLabel'),
              context.tr('ExclusiveDescription'),
              audio.isExclusiveMode,
              audio.isExclusiveAvailable,
              audio.setExclusiveMode,
              palette.lime,
            );
            final bitperfect = mode(
              context.tr('ModeBitPerfect'),
              context.tr('BitPerfectDescription'),
              audio.isBitperfect,
              audio.isBitperfectAvailable,
              audio.setBitperfect,
              palette.purple,
            );
            if (constraints.maxWidth < 440) {
              return Column(children: [exclusive, const SizedBox(height: 12), bitperfect]);
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: exclusive),
                  const SizedBox(width: 12),
                  Expanded(child: bitperfect),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        GlassCard(
          hoverColor: palette.cyan,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('OutputDevice'),
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: colors.textMain),
                    ),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    onPressed: audio.refreshDevices,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: Text(context.tr('Refresh')),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: devices.any((d) => d.id == audio.selectedDevice?.id) ? audio.selectedDevice?.id : null,
                isExpanded: true,
                items: [
                  for (final d in devices)
                    DropdownMenuItem(
                      value: d.id,
                      child: Row(
                        children: [
                          Icon(Icons.speaker_outlined, size: 16, color: palette.cyan),
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
              const SizedBox(height: 16),
              Text(audio.hardwareStatusText, style: TextStyle(fontSize: 12, color: colors.textMuted)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        GlassCard(
          hoverColor: palette.lime,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr('SignalPath'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: colors.textMain),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: colors.surface1, borderRadius: BorderRadius.circular(Radii.small + 2)),
                child: Text(
                  audio.signalPath,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontFamilyFallback: const ['JetBrains Mono', 'Consolas', 'DejaVu Sans Mono', 'Courier New'],
                    fontSize: 12,
                    height: 20 / 12,
                    color: palette.lime,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard();

  @override
  Widget build(BuildContext context) {
    final vm = context.vm;
    final colors = context.colors;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            icon: Icons.translate_rounded,
            title: context.tr('Language'),
            subtitle: context.tr('SettingsLanguageHint'),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final l in Localizer.languages)
                l.code == vm.language
                    ? FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 34),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        onPressed: () => vm.changeLanguage(l.code),
                        child: Text(l.nativeName),
                      )
                    : OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 34),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        onPressed: () => vm.changeLanguage(l.code),
                        child: Text(l.nativeName),
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
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: colors.textMain),
                    ),
                    Text(context.tr('SettingsThemeHint'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
                  ],
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                onPressed: vm.toggleTheme,
                icon: Icon(vm.isLight ? Icons.dark_mode_outlined : Icons.light_mode_outlined, size: 16),
                label: Text(context.tr('Theme')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SwitchCard extends StatelessWidget {
  const _SwitchCard({
    required this.icon,
    required this.title,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => GlassCard(
    child: _CardTitle(
      icon: icon,
      title: title,
      subtitle: hint,
      trailing: Switch(value: value, onChanged: onChanged),
    ),
  );
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            icon: Icons.info_outline_rounded,
            title: 'Wiretune',
            subtitle: context.trf('AboutVersion', [WiretuneInfo.version]),
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

class _LibraryStatsCard extends StatelessWidget {
  const _LibraryStatsCard();

  @override
  Widget build(BuildContext context) {
    final server = context.vm.serverSettings;
    final colors = context.colors;
    Widget stat(String label, int value) => Column(
      children: [
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: colors.accentGradient.createShader,
          child: Text('$value', style: const TextStyle(fontSize: 30, letterSpacing: -1, fontWeight: FontWeight.w900)),
        ),
        Text(
          label.toUpperCase(),
          style: TextStyle(fontSize: 10.5, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: colors.textMuted),
        ),
      ],
    );
    return GlassCard(
      child: Wrap(
        alignment: WrapAlignment.spaceAround,
        spacing: 24,
        runSpacing: 12,
        children: [
          stat(context.tr('NavArtists'), server.totalArtistsCount),
          stat(context.tr('NavAlbums'), server.totalAlbumsCount),
          stat(context.tr('NavTracks'), server.totalTracksCount),
          stat(context.tr('NavFavorites'), server.totalFavoritesCount),
          stat(context.tr('NavPlaylists'), server.totalPlaylistsCount),
        ],
      ),
    );
  }
}
