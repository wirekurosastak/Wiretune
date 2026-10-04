# Building

Every command to build Wiretune: the server, and the player for each platform. Commands are run from the repository's
root unless a `cd` says otherwise. Running the server is in [server.md](server.md); testing and debugging are in
[development.md](development.md).

| What | Build on | Command (from the folder) | Result |
|---|---|---|---|
| Server | Linux, Windows or macOS | `server/`: `dart build cli -o build` | `server/build/bundle/` |
| Player for Linux | Linux | `app/`: `flutter build linux --release` | `app/build/linux/x64/release/bundle/` |
| Player for Windows | Windows | `app/`: `flutter build windows --release` | `app\build\windows\x64\runner\Release\` |
| Player for macOS | macOS | `app/`: `flutter build macos --release` | `app/build/macos/Build/Products/Release/Wiretune.app` |
| Player for Android, Android TV, Android Auto | Linux, Windows or macOS | `app/`: `flutter build apk --release --split-per-abi` | `app/build/app/outputs/flutter-apk/` |
| Player for Google Play | Linux, Windows or macOS | `app/`: `flutter build appbundle --release` | `app/build/app/outputs/bundle/release/app-release.aab` |
| Player for iPhone and iPad | macOS | `app/`: `flutter build ipa --release` | `app/build/ios/ipa/` |
| Player for Samsung TVs (Tizen) | Linux, Windows or macOS | `app/`: `flutter-tizen build tpk --release` | `app/build/tizen/tpk/` |

A desktop player can only be built on its own operating system; Android and Tizen can be built anywhere.

## 1. Install Flutter (once)

Flutter 3.47 or newer brings Dart, which is all the server needs.

```bash
git clone https://github.com/flutter/flutter.git -b stable ~/development/flutter
echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
flutter doctor            # lists what each platform still needs
```

On Windows and macOS, follow [Flutter's installation guide](https://docs.flutter.dev/get-started/install) instead,
then run `flutter doctor`.

## 2. Fetch the dependencies

```bash
(cd packages/wiretune_core && dart pub get)
(cd server && dart pub get)
(cd app && flutter pub get)
```

`flutter build` and `flutter run` fetch them by themselves too; this step only makes the first build quicker.

## Server

Needs nothing but Flutter (or the Dart SDK alone). SQLite is downloaded by the `sqlite3` package during the build.

```bash
cd server
dart run bin/wiretune_server.dart --Wiretune:LibraryPath=/path/to/music   # run it straight from the source
dart build cli -o build                                                    # build a standalone executable
build/bundle/bin/wiretune_server --Wiretune:LibraryPath=/path/to/music     # run the build
```

The build is `build/bundle/bin/wiretune_server` (`wiretune_server.exe` on Windows) and the SQLite library next to it
in `build/bundle/lib/`. Copy the whole `bundle` folder to the machine that runs the server, which must have the same
operating system and processor architecture as the one that built it. `dart compile exe` does not work for this
project, because SQLite comes through a build hook. Settings, a systemd unit and a reverse proxy are in
[server.md](server.md).

## Linux player

```bash
sudo dnf install clang cmake ninja-build gtk3-devel mpv-devel                        # Fedora
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev          # Debian, Ubuntu
sudo pacman -S --needed clang cmake ninja pkgconf gtk3 mpv                           # Arch

cd app
flutter run -d linux                  # run in debug mode
flutter build linux --release         # build/linux/x64/release/bundle/wiretune
tar -czf wiretune-linux-x64.tar.gz -C build/linux/x64/release bundle    # to copy it elsewhere
```

The computer that runs the player needs libmpv (`mpv-libs` on Fedora, `libmpv2` on Debian and Ubuntu, `mpv` on Arch),
and, optionally, `ffmpeg` for the spectrum analyser and `pw-reserve` (part of PipeWire) for exclusive mode
([audio.md](audio.md#desktop-linux-windows-macos)). On an ARM computer the folder is `build/linux/arm64/`.

## Windows player

Install [Visual Studio 2022](https://visualstudio.microsoft.com/) (not VS Code) with the *Desktop development with
C++* workload, and Git. Then, in a terminal:

```bat
cd app
flutter run -d windows
flutter build windows --release
```

The player is `build\windows\x64\runner\Release\wiretune.exe`; copy the whole `Release` folder, which holds libmpv and
the other libraries. With `ffmpeg` on the `PATH` the spectrum analyser works.

## macOS player

Install Xcode from the App Store and CocoaPods (`brew install cocoapods`), then:

```bash
cd app
flutter run -d macos
flutter build macos --release      # build/macos/Build/Products/Release/Wiretune.app
```

To hand it to other Macs, sign it with a Developer ID and notarise it: open `macos/Runner.xcworkspace` in Xcode, set
the team under *Signing & Capabilities*, then *Product → Archive → Distribute App → Developer ID*. The app is not
sandboxed on purpose (see `macos/Runner/Release.entitlements`), so it is distributed outside the Mac App Store.

## Android player (phones, tablets, Android TV, Android Auto)

Install Android Studio (or the Android command-line tools) and a JDK 17 or newer; `flutter doctor` says when the
licences still need accepting (`flutter doctor --android-licenses`).

```bash
cd app
flutter devices                                  # a phone with USB debugging on, or an emulator
flutter run -d <device>                          # run in debug mode
flutter build apk --release --split-per-abi      # one APK per processor type
flutter build apk --release                      # or one APK for all of them (bigger)
flutter build appbundle --release                # for Google Play
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Which APK: `app-arm64-v8a-release.apk` for almost every phone, tablet and recent TV; `app-armeabi-v7a-release.apk`
for older 32-bit devices, including many TV boxes and televisions; `app-x86_64-release.apk` for the emulator. The
same APK is the phone, tablet, Android TV and Android Auto app.

**Signing.** A release is signed with the key named in `app/android/key.properties`, or with Flutter's debug key when
that file is missing (fine for trying it out). Make a key once and keep it safe, because an update installs only
over an app signed with the same key:

```bash
keytool -genkey -v -keystore ~/wiretune-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias wiretune
```

```properties
# app/android/key.properties (.gitignore keeps it, and every keystore, out of git)
storeFile=/home/you/wiretune-upload.jks
storePassword=…
keyAlias=wiretune
keyPassword=…
```

To install over the C# version of the app, sign with the key that signed it. The C# app had no signing
configuration, so it was signed with .NET's debug keystore: `~/.local/share/Xamarin/Mono for Android/debug.keystore`
on Linux and macOS, `%LOCALAPPDATA%\Xamarin\Mono for Android\debug.keystore` on Windows, alias `androiddebugkey`, both
passwords `android`. Otherwise uninstall the old app first; its local data goes with it, and a server library comes
back after signing in.

**Android Auto without a car.** Install the *Android Auto Desktop Head Unit Emulator* (Android Studio → SDK Manager →
*SDK Tools*). On the phone, open the Android Auto settings, tap the version ten times to turn on developer mode, allow
*Unknown sources* (for an APK that is not from Google Play) and choose *Start head unit server*. Then:

```bash
adb forward tcp:5277 tcp:5277
$ANDROID_HOME/extras/google/auto/desktop-head-unit
```

**Android TV.** Use the Android TV emulator image (API 30 or newer), or a TV with ADB over the network:
`adb connect <tv-ip>`, then `flutter run -d <tv-ip>:5555` or `adb install -r …`.

## iPhone and iPad player

On a Mac with Xcode and CocoaPods:

```bash
cd app
open ios/Runner.xcworkspace                 # once: set your team under Signing & Capabilities
flutter run -d <iphone>                     # run on a connected iPhone
flutter build ipa --release                 # build/ios/ipa/, for TestFlight or the App Store
flutter build ios --release --no-codesign   # only checks that it builds (as CI does)
```

The bundle ID is `com.wiretune.player`. Upload the `.ipa` with Xcode's Organizer or Apple's Transporter app.

## Samsung TV player (Tizen)

Tizen apps are built with [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen), a Flutter for Tizen that
follows the Flutter releases, and Samsung's Tizen SDK (the *Tizen Extension for VS Code*, or Tizen Studio with the
*TV Extensions*).

```bash
git clone https://github.com/flutter-tizen/flutter-tizen.git ~/flutter-tizen      # once
~/flutter-tizen/bin/flutter-tizen doctor                                           # checks the Tizen SDK
```

In the Tizen SDK's Certificate Manager, create a **Samsung** certificate profile for TVs (it needs a Samsung account
and the TV's DUID). On the TV, turn on developer mode (*Apps*, then type 12345 on the remote) and enter your computer's
IP address. Then:

```bash
sdb connect <tv-ip>
cd app
~/flutter-tizen/bin/flutter-tizen run -d <tv-ip>:26101       # run on the TV
~/flutter-tizen/bin/flutter-tizen build tpk --release         # build/tizen/tpk/*.tpk (TV profile by default)
~/flutter-tizen/bin/flutter-tizen install                     # install that package on the connected TV
```

The package targets Tizen 6.0 and later (2021 TVs onwards). If a TV refuses the SQLite library that the build bundles,
add this to `app/pubspec.yaml` for the Tizen build only (Android and Windows have no usable system SQLite), so that
the TV's own is used:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: system
```

## Before a commit

```bash
dart format --output none --set-exit-if-changed packages server app/lib app/test
(cd packages/wiretune_core && dart analyze --fatal-infos && dart test)
(cd server && dart analyze --fatal-infos && dart test)
(cd app && flutter analyze --fatal-infos && flutter test)
```

Run `dart format packages server app/lib app/test` to fix the formatting. The tests that
read audio files need `ffmpeg`; without it they are reported as skipped.

## Housekeeping

| Task | Command |
|---|---|
| Change the version | Edit `version:` in `app/pubspec.yaml` (`2.0.0+2`: the name, then the build number, which is Android's version code), or pass `--build-name 2.0.1 --build-number 3` to a build |
| Regenerate the app icons from `app/assets/wiretune.png` | `cd app && dart run flutter_launcher_icons` |
| Start a build from scratch | `cd app && flutter clean`; for the server and the core, delete their `build/` and `.dart_tool/` |
| Get the builds CI made | Every CI run (each pull request, each push to `main`) keeps the server executables and the APKs as artifacts on its *Actions* page |
