# wiretune_platform

Wiretune's own Android code, as a Flutter plugin: it answers the `wiretune/platform` channel (`isTelevision`) and the
`wiretune/power` channel (`setPlaying`: a CPU and a Wi-Fi lock while music plays). It is a plugin rather than code in
the activity because Android Auto can start the app's Flutter engine from the media service, with no activity at all,
and a plugin is registered on that engine too. The player (`app/`) depends on it; it has no Dart API of its own.
