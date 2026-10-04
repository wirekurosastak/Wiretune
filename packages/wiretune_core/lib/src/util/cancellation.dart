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
  final List<void Function()> _callbacks = [];

  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when the token is cancelled.
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (_cancelled.isCompleted) return;
    _cancelled.complete();
    for (final callback in List.of(_callbacks)) {
      try {
        callback();
      } catch (_) {}
    }
    _callbacks.clear();
  }

  /// Runs [callback] when the token is cancelled (at once if it already is). Returns a function that unregisters it.
  void Function() register(void Function() callback) {
    if (isCancelled) {
      callback();
      return () {};
    }
    _callbacks.add(callback);
    return () => _callbacks.remove(callback);
  }

  void throwIfCancelled() {
    if (isCancelled) throw const OperationCanceledException();
  }

  /// Cancels after [delay].
  static CancellationToken after(Duration delay) {
    final token = CancellationToken();
    Timer(delay, token.cancel);
    return token;
  }
}
