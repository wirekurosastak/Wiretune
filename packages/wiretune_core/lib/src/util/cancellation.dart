// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

/// Thrown by operations that were cancelled through a [CancellationToken].
class OperationCanceledException implements Exception {
  const OperationCanceledException([this.message = 'The operation was cancelled.']);

  final String message;

  @override
  String toString() => 'OperationCanceledException: $message';
}

/// Asks long-running work to stop. The work checks [isCancelled] (or calls [throwIfCancelled]) at convenient points.
class CancellationToken {
  CancellationToken();

  /// A token that is never cancelled.
  static final CancellationToken none = CancellationToken();

  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when the token is cancelled.
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const OperationCanceledException();
  }
}
