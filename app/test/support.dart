import 'package:wiretune/src/view_models/main_view_model.dart';
import 'package:wiretune_core/testing.dart';
import 'package:wiretune_core/wiretune_core.dart';

export 'package:wiretune_core/testing.dart';

MainViewModel createMainViewModel(LibraryService library, [WiretuneAudioEngine? engine]) =>
    MainViewModel(engine ?? TestSupport.createEngine(), library, ServerSession(library, MockRepository()));

LibraryService createLibrary([List<Track> tracks = const []]) {
  final repo = MockRepository()..saveTracks(tracks);
  return LibraryService(repo, MetadataScanner(), coverCacheDirectory: '/nonexistent');
}

/// Waits (briefly) until [condition] holds; true when it does.
Future<bool> waitUntil(bool Function() condition) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return condition();
}
