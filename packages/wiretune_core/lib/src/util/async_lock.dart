// Copyright (C) 2026 Wiretune contributors. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import 'dart:async';

/// A mutual-exclusion lock for asynchronous code: one holder at a time, the others wait in arrival order.
class AsyncLock {
  Future<void> _last = Future.value();
  int _holders = 0;

  /// True while someone holds the lock or waits for it.
  bool get isLocked => _holders > 0;

  /// Runs [action] once every earlier holder has finished, and releases the lock when it completes (also on error).
  Future<T> synchronized<T>(FutureOr<T> Function() action) {
    final previous = _last;
    final done = Completer<void>();
    _last = done.future;
    _holders++;

    Future<T> run() async {
      try {
        return await action();
      } finally {
        _holders--;
        done.complete();
      }
    }

    return previous.then((_) => run());
  }
}
