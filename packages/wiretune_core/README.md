# wiretune_core

The part of Wiretune that the server and the player share: models, the SQLite library index, the tag reader and
scanner, the library service, the server protocol, client and session, localization and the audio engine. Pure Dart,
with no Flutter dependency. `lib/testing.dart` holds the test doubles the other packages' tests use.

```bash
dart pub get
dart test        # the tests that read audio files need ffmpeg; without it they are skipped
```

Where everything is, and how it fits together: [../../docs/development.md](../../docs/development.md#where-is-what).
