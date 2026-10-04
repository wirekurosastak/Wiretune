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

  /// Runs [action] only when nobody holds the lock; returns null without running it otherwise.
  Future<T?> tryRun<T>(Future<T> Function() action) async {
    if (isLocked) return null;
    return synchronized(action);
  }
}
