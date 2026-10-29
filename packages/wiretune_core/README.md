# wiretune_core

The code shared by the server and the player: models, the SQLite library index, tag reader and scanner, library
service, server protocol, client and session, update check, localization and audio engine. Pure Dart, no Flutter.
`lib/testing.dart` has the test doubles the other packages' tests use.

```bash
dart pub get
dart test        # tests that read audio files need ffmpeg; without it they're skipped
```

Code layout: [docs/development.md](../../docs/development.md#where-is-what).
