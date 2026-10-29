// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wiretune_core/wiretune_core.dart';

import '../update_installer.dart';

/// Looks for a newer release when the player starts and every 24 hours while it stays open, offers it in a banner,
/// and downloads and installs it when the user presses Update. Nothing installs on its own.
class UpdateViewModel extends ChangeNotifier {
  /// [check] and [installer] null: this copy isn't updated from releases (a debug build, iOS, Tizen, …).
  /// [isOffline] skips the check in offline mode; [notify] shows a notice; [quit] ends the player for the install.
  UpdateViewModel(
    this._check,
    this._installer, {
    required bool Function() isOffline,
    required void Function(String message, {bool isError}) notify,
    required Future<void> Function({String? relaunch}) quit,
  }) : _isOffline = isOffline,
       _notify = notify,
       _quit = quit;

  static const Duration interval = Duration(hours: 24);

  final UpdateCheck? _check;
  final UpdateInstaller? _installer;
  final bool Function() _isOffline;
  final void Function(String message, {bool isError}) _notify;
  final Future<void> Function({String? relaunch}) _quit;

  Timer? _timer;
  Release? _release;
  String? _file;
  bool _dismissed = false;
  bool _enabled = true;
  bool _disposed = false;

  /// What share of the download has arrived (0 to 1) while it runs; null otherwise.
  double? progress;

  /// The download is done and the new version is going in.
  bool installing = false;

  /// Whether this copy can be updated from a release at all; the switch in Settings shows only then.
  bool get isSupported => _check != null && _installer != null;

  /// The setting: whether to look for updates (on by default).
  bool get isEnabled => _enabled;
  set isEnabled(bool value) {
    _enabled = value;
    if (!value) _release = null;
    notifyListeners();
  }

  /// The newer version on offer, while the banner shows it.
  String? get version => _release?.version;

  bool get isBannerVisible => _release != null && !_dismissed;
  bool get isBusy => progress != null || installing;

  /// Looks now, then every [interval].
  void start() {
    if (!isSupported) return;
    unawaited(checkNow());
    _timer = Timer.periodic(interval, (_) => checkNow());
  }

  /// Asks GitHub for a newer release that has a file for this copy. A failure is only logged: the next check comes.
  Future<void> checkNow() async {
    final check = _check;
    final installer = _installer;
    if (check == null || installer == null || !_enabled || _isOffline() || isBusy) return;
    if (!UpdateCheck.isAllowedByEnvironment) return;
    try {
      final release = await check.newer();
      final file = release == null ? null : installer.fileFor(release);
      if (release != null && file == null) {
        WiretuneLog.info('Updates', 'Wiretune ${release.version} has no file for this copy (${installer.kind.name}).');
      }
      _release = file == null ? null : release;
      _file = file;
      _dismissed = false; // "Later" lasts until the next check
    } on UpdateException catch (e) {
      WiretuneLog.warn('Updates', 'Could not look for updates: $e');
    }
    notifyListeners();
  }

  /// Hides the banner until the next check.
  void later() {
    _dismissed = true;
    notifyListeners();
  }

  /// Downloads the new version, checks it, and installs it, which restarts the player on a computer.
  Future<void> update() async {
    final check = _check;
    final installer = _installer;
    final release = _release;
    final file = _file;
    if (check == null || installer == null || release == null || file == null || isBusy) return;
    progress = 0;
    notifyListeners();
    try {
      final downloaded = await check.download(
        release,
        file,
        await installer.downloadFolder(),
        onProgress: (share) {
          progress = share;
          notifyListeners();
        },
      );
      progress = null;
      installing = true;
      notifyListeners();
      await installer.install(downloaded, _quit);
      if (installer.kind == InstallKind.macosApp) _notify(Localizer.get('UpdateDiskImageOpened'));
    } on Exception catch (e, s) {
      WiretuneLog.error('Updates', 'Updating to ${release.version} failed', e, s);
      _notify(Localizer.get('UpdateFailed'), isError: true);
    } finally {
      progress = null;
      installing = false;
      notifyListeners();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _check?.close();
    super.dispose();
  }
}
