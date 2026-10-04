# Wiretune server

Indexes one music folder and serves it to the Wiretune players over HTTP, with accounts and per-account favourites,
play counts and playlists.

```bash
dart run bin/wiretune_server.dart --library /path/to/music   # run from the source
dart build cli -o build                                      # standalone build: build/bundle/
dart test
```

Options, accounts and running it as a service: [../docs/server.md](../docs/server.md). The HTTP API:
[../docs/api.md](../docs/api.md).
