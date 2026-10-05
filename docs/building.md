# Building

Every piece of Wiretune, built and put where it runs. The [README](../README.md#building) has the short version; this
page adds what to install first, signing, and getting the result onto phones and TVs. Running the server is in
[server.md](server.md), testing in [development.md](development.md).

Desktop players build only on their own system. The server builds on Linux, Windows and macOS, each time for the
system it's built on. Android and Tizen build anywhere.

## Release builds

`tool/build.dart` makes the release build of every target you name and copies what ships into `dist/`, replacing what
an earlier build of that target left there. The commands on this page run from the repository's root.

```bash
dart tool/build.dart server linux android
dart tool/build.dart --help                  # the targets
```

| Target | In `dist/` |
|---|---|
| `server` | `server/bin/wiretune_server` (`.exe` on Windows) and the SQLite library in `server/lib/` |
| `linux` | `linux/wiretune` with its `lib/` and `data/` |
| `windows` | `windows/wiretune.exe` with its DLLs (libmpv among them) and `data/` |
| `macos` | `macos/Wiretune.app` |
| `android` | `android/app-<processor>-release.apk`, one per processor type |
| `appbundle` | `android/app-release.aab`, for Google Play |
| `ios` | `ios/*.ipa` |
| `tizen` | `tizen/*.tpk` |

The builds themselves run in `server/build/` and `app/build/`. git ignores those folders and `dist/`.

## Flutter

[Flutter](https://docs.flutter.dev/get-started/install) 3.47 or newer brings Dart, which is all the server needs. On
Linux:

```bash
git clone https://github.com/flutter/flutter.git -b stable ~/development/flutter
echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
flutter doctor        # what each platform still needs
```

On Windows and macOS follow Flutter's own installation guide, then run `flutter doctor`. There's no separate
`pub get` step: `flutter run`, `dart run` and `tool/build.dart` fetch the packages themselves.

## Server

```bash
(cd server && dart run bin/wiretune_server.dart --library /path/to/music)   # straight from the source

dart tool/build.dart server                                               # a standalone build
dist/server/bin/wiretune_server --library /path/to/music                  # run that build
```

Copy the whole `dist/server` folder to the machine that runs it. That machine needs no Dart, but it must have the same
operating system and processor architecture. `dart compile exe` won't do here, because SQLite comes in through a build
hook.

## Linux player

```bash
sudo dnf install clang cmake ninja-build gtk3-devel mpv-devel                 # Fedora
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev   # Debian, Ubuntu
sudo pacman -S --needed clang cmake ninja pkgconf gtk3 mpv                    # Arch

(cd app && flutter run -d linux)                     # a debug run
dart tool/build.dart linux                           # → dist/linux/ (x64, or arm64 on ARM)
tar -czf wiretune-linux.tar.gz -C dist linux         # to take it elsewhere
```

The computer that runs the player needs libmpv (`mpv-libs` on Fedora, `libmpv2` on Debian and Ubuntu, `mpv` on Arch),
plus `ffmpeg` for the spectrum if you want it ([audio.md](audio.md#desktop)).

Moved or renamed the repository? CMake remembers the old path, and the build stops with *The current CMakeCache.txt
directory … is different*. Delete `app/build/linux` (or run `flutter clean` in `app/`) and build again.

## Windows player

Install [Visual Studio 2022](https://visualstudio.microsoft.com/) (not VS Code) with the *Desktop development with
C++* workload, and Git. Then:

```bat
cd app
flutter run -d windows
cd ..
dart tool/build.dart windows
```

The player is `dist\windows\wiretune.exe`. Copy the whole `dist\windows` folder: libmpv and the other libraries live
in it. With `ffmpeg` on the `PATH` the spectrum works.

## macOS player

Install Xcode from the App Store and CocoaPods (`brew install cocoapods`), then:

```bash
(cd app && flutter run -d macos)
dart tool/build.dart macos            # → dist/macos/Wiretune.app
```

To hand it to other Macs, sign it with a Developer ID and notarise it: open `app/macos/Runner.xcworkspace` in Xcode,
set the team under *Signing & Capabilities*, then *Product → Archive → Distribute App → Developer ID*. The app isn't
sandboxed, on purpose (`app/macos/Runner/Release.entitlements` says why), so it ships outside the Mac App Store.

## Android player (phones, tablets, TV, Auto)

Install Android Studio (or just the command-line tools) and a JDK 17 or newer. If `flutter doctor` complains about
licences, run `flutter doctor --android-licenses`.

```bash
(cd app && flutter run -d <device>)              # a phone with USB debugging on, or an emulator
dart tool/build.dart android                     # one APK per processor type, in dist/android/
dart tool/build.dart appbundle                   # for Google Play
adb install -r dist/android/app-arm64-v8a-release.apk
```

Which APK: `arm64-v8a` for almost every phone, tablet and recent TV, `armeabi-v7a` for older 32-bit devices (plenty of
TV boxes among them), `x86_64` for the emulator. The same APK is the phone, tablet, TV and car app.

### Signing

A release is signed with the key that `app/android/key.properties` names. Without that file it's signed with Flutter's
debug key, which is fine for trying it out, but Android only installs an update over an app signed with the same key.
So make a key once and look after it:

```bash
keytool -genkey -v -keystore ~/wiretune-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias wiretune
```

```properties
# app/android/key.properties (git ignores it, and every keystore)
storeFile=/home/you/wiretune-upload.jks
storePassword=…
keyAlias=wiretune
keyPassword=…
```

### Android Auto without a car

Install the *Android Auto Desktop Head Unit Emulator* (Android Studio → SDK Manager → *SDK Tools*). On the phone, open
Android Auto's settings, tap the version ten times for developer mode, allow *Unknown sources* (for an APK that isn't
from Google Play) and choose *Start head unit server*. Then:

```bash
adb forward tcp:5277 tcp:5277
$ANDROID_HOME/extras/google/auto/desktop-head-unit
```

### Android TV

The Android TV emulator image (API 30 or newer) works, or a real TV with network debugging: `adb connect <tv-ip>`,
then `flutter run -d <tv-ip>:5555` or `adb install -r …`.

## iPhone and iPad player

On a Mac with Xcode and CocoaPods:

```bash
open app/ios/Runner.xcworkspace                          # once: set your team under Signing & Capabilities
(cd app && flutter run -d <iphone>)
dart tool/build.dart ios                                 # → dist/ios/, for TestFlight or the App Store
(cd app && flutter build ios --release --no-codesign)    # only checks that it builds, as CI does
```

The bundle ID is `com.wiretune.player`. Upload the `.ipa` with Xcode's Organizer or Apple's Transporter.

## Samsung TV player (Tizen)

Built with [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen), a Flutter for Tizen that follows
Flutter's releases, and Samsung's Tizen SDK (the *Tizen Extension for VS Code*, or Tizen Studio with the *TV
Extensions*). Nobody has built this one yet, so expect rough edges, and please report them.

```bash
git clone https://github.com/flutter-tizen/flutter-tizen.git ~/flutter-tizen
export PATH="$HOME/flutter-tizen/bin:$PATH"     # tool/build.dart looks for flutter-tizen on the PATH
flutter-tizen doctor                            # checks the Tizen SDK
```

In the SDK's Certificate Manager, create a **Samsung** certificate profile for TVs (it needs a Samsung account and the
TV's DUID). On the TV, turn on developer mode (open *Apps*, then type 12345 on the remote) and enter your computer's
IP address. Then:

```bash
sdb connect <tv-ip>
(cd app && flutter-tizen run -d <tv-ip>:26101)    # run on the TV
dart tool/build.dart tizen                        # → dist/tizen/ (TV profile)
(cd app && flutter-tizen install)                 # install it on the connected TV
```

The package targets Tizen 6.0 and later (2021 TVs onwards). If a TV refuses the SQLite library the build bundles, add
this to `app/pubspec.yaml` for the Tizen build only (Android and Windows have no usable system SQLite), so the TV's own
is used:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: system
```

## Odds and ends

| | |
|---|---|
| Version | `version:` in `app/pubspec.yaml` (`2.0.0+2`: the name, then the build number, which is Android's version code), or `--build-name 2.0.1 --build-number 3` on a `flutter build` of your own |
| App icons | `cd app && dart run flutter_launcher_icons` regenerates them from `app/assets/wiretune.png` |
| A clean slate | Delete `dist/`, run `flutter clean` in `app/`, and delete the `build/` and `.dart_tool/` of the server and the core |
| Builds from CI | Every CI run (each pull request, each push to `main`) builds through `tool/build.dart` and keeps `dist/server` and the APKs as artifacts on its *Actions* page |
