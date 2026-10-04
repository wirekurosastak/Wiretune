/// Wiretune's Android side. It has no Dart API: the app talks to it over two method channels,
/// `wiretune/platform` (`isTelevision`) and `wiretune/power` (`setPlaying`).
///
/// It is a plugin rather than code in the activity because Android Auto can start the app's Flutter engine from the
/// media service, with no activity at all; a plugin is registered on that engine too.
library;
