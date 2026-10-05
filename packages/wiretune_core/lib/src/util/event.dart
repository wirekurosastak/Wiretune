import '../services/wiretune_log.dart';

/// A synchronous event: every listener is called, in the order it subscribed, from inside [emit].
///
/// Dart's sync broadcast streams refuse an event raised from inside a listener of the same stream, and the library and
/// the session do exactly that (a refresh that changes the library raises "changed" while its own listeners run), so
/// the services use this instead. A listener that throws is logged and does not keep the others from running.
class Event<T> {
  final List<void Function(T)> _listeners = [];

  /// Subscribes [listener]; call the returned function to unsubscribe.
  void Function() listen(void Function(T value) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void emit(T value) {
    for (final listener in List.of(_listeners)) {
      try {
        listener(value);
      } catch (e, s) {
        WiretuneLog.error('Event', 'An event listener failed: $e', e, s);
      }
    }
  }
}
