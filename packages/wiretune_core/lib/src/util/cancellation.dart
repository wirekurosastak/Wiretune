// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

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

  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (isCancelled) throw const OperationCanceledException();
  }
}
