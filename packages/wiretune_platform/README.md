# wiretune_platform

Wiretune's Android code, as a Flutter plugin. It has no Dart API; the player (`app/`) calls it over two channels:

- `wiretune/platform`: `isTelevision`, `musicDirectory`, `requestAudioAccess` (permission to read the phone's music,
  asked when a folder is scanned), `installerPackage` and `installUpdate` (in-app updates)
- `wiretune/power`: `setPlaying` (a CPU lock while music plays, a Wi-Fi lock while it streams)

It's a plugin, not activity code, because Android Auto can start the Flutter engine from the media service without an
activity, and plugins are registered on that engine too.
