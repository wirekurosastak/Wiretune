# Building

One command builds every part of Wiretune: `dart tool/build.dart <target>…`, run from the repository's root. What
ships lands in `dist/<target>/`, replacing what an earlier build left there. Copy a result folder as a whole: the
programs load their libraries from next to them.

For each system below: what to install first, the build command, and what you get. Signing and releases are at the
end. Running the server is in [server.md](server.md); working on the code in [development.md](development.md).

## Flutter, for everything

Flutter 3.47 or newer. It brings Dart, which is all the server needs.

```bash
# Linux and macOS: clone it, and put it on the PATH (zsh on a Mac: ~/.zshrc instead of ~/.bashrc)
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc
```

On Windows, follow [Flutter's installation guide](https://docs.flutter.dev/get-started/install/windows/desktop).
Then, on any system, `flutter doctor` says what the targets you want still need.

## Server

Nothing beyond Flutter. Builds on Linux, Windows and macOS, each time for the system and processor it runs on.

```bash
dart tool/build.dart server
```

You get `dist/server/bin/wiretune_server` (`.exe` on Windows) and the SQLite library in `dist/server/lib/`. The
machine that runs it needs no Dart.

Or skip Dart altogether and build the container image (from the repository's root, which holds the core package too):

```bash
docker build -f server/Dockerfile -t wiretune-server .
```

## Linux player

```bash
sudo dnf install git clang cmake ninja-build gtk3-devel xz-devel mpv-devel ffmpeg-free                # Fedora
sudo apt install git clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libmpv-dev ffmpeg  # Debian, Ubuntu
sudo pacman -S --needed git clang cmake ninja pkgconf gtk3 xz mpv ffmpeg                            # Arch

dart tool/build.dart linux
```

You get `dist/linux/wiretune` with its `lib/` and `data/`, for x64 (or arm64 on an ARM machine). A computer that only
runs it needs libmpv (`mpv-libs` on Fedora, `libmpv2` on Debian and Ubuntu, `mpv` on Arch). `ffmpeg` is for the
spectrum and can be left out.

Moved or renamed the repository? CMake remembers the old path and stops with *The current CMakeCache.txt directory … is
different*. Delete `app/build/linux` and build again.

## Windows player

In PowerShell (the last two only if you want them):

```powershell
winget install --id Git.Git
winget install --id Microsoft.VisualStudio.2022.Community --override "--wait --passive --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"
winget install --id Gyan.FFmpeg            # the spectrum
winget install --id JRSoftware.InnoSetup   # the installer

dart tool/build.dart windows               # or windows-installer
```

You get `dist\windows\wiretune.exe` with its DLLs (libmpv among them) and `data\`. `windows-installer` also makes
`dist\windows-installer\Wiretune-<version>-windows-<processor>-setup.exe`.

## macOS player

Install [Xcode](https://apps.apple.com/app/xcode/id497799835) from the App Store and [Homebrew](https://brew.sh), then:

```bash
brew install cocoapods ffmpeg      # ffmpeg: the spectrum
dart tool/build.dart macos
```

You get `dist/macos/Wiretune.app` and `dist/macos/Wiretune.dmg`. Unsigned, it runs on the Mac that built it; for other
Macs, [sign and notarize it](#macos).

## Android player (phone, tablet, TV, car)

Install [Android Studio](https://developer.android.com/studio), which brings the Android SDK and a JDK that fits
(without it: the [command-line tools](https://developer.android.com/studio#command-line-tools-only) and a JDK 17 or newer
such as [Temurin](https://adoptium.net)). Then accept the licenses and build:

```bash
flutter doctor --android-licenses
dart tool/build.dart android        # or appbundle, for Google Play
```

You get `dist/android/app-<processor>-release.apk`, one per processor type: `arm64-v8a` for almost every phone, tablet
and recent TV, `armeabi-v7a` for older 32-bit devices (many TV boxes among them), `x86_64` for the emulator. The same
APK is the phone, tablet, TV and car app. `appbundle` makes `dist/android/app-release.aab`. To put an APK on a device
with USB or network debugging on: `adb install -r dist/android/app-arm64-v8a-release.apk`.

Unsigned, it's signed with Flutter's debug key: fine for trying, but [sign your own](#android) before you hand it out.

## iPhone and iPad player

On a Mac with [Xcode](https://apps.apple.com/app/xcode/id497799835) and CocoaPods (`brew install cocoapods`). Open
`app/ios/Runner.xcworkspace` once and choose your team under *Signing & Capabilities*, then:

```bash
dart tool/build.dart ios
```

You get `dist/ios/*.ipa`, for TestFlight or the App Store: upload it with
[Transporter](https://apps.apple.com/app/transporter/id1450874784). The bundle ID is `com.wiretune.player`.

## Samsung TV player (Tizen)

Install the [Tizen SDK with the TV extensions](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/installing-tv-sdk.html)
(or the *Tizen* extension for VS Code), and [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen), the
Flutter for Tizen:

```bash
git clone https://github.com/flutter-tizen/flutter-tizen.git ~/flutter-tizen
echo 'export PATH="$HOME/flutter-tizen/bin:$PATH"' >> ~/.bashrc     # the build looks for it on the PATH
dart tool/build.dart tizen
```

You get `dist/tizen/*.tpk` (TV profile, Tizen 6.0 and later, so 2021 TVs onwards). To install it: in the SDK's
Certificate Manager create a **Samsung** certificate profile for TVs (it needs a Samsung account and the TV's DUID),
turn on developer mode on the TV (open *Apps*, type 12345 on the remote, enter your computer's address), then
`sdb connect <tv-ip>` and `flutter-tizen install` in `app/`.

It has only been tried quickly, on a 2024 Samsung (Tizen 8.0): it works, but moving around with the remote is sluggish
and needs more work.

The TV uses its own SQLite: the one the sqlite3 package downloads for Linux on ARM doesn't load there. The build
script adds that setting to `app/pubspec.yaml` for the Tizen build only, and takes it out again.

## Signing

### Android

A release is signed with the key that `app/android/key.properties` names. Android only installs an update over an app
signed with the same key, so make one once and look after it:

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

### macOS

With a *Developer ID Application* identity in the keychain and a `notarytool` profile stored
(`xcrun notarytool store-credentials <profile> …`), the build signs, notarizes and staples the disk image:

```bash
WIRETUNE_MACOS_SIGN_IDENTITY="Developer ID Application: …" WIRETUNE_NOTARY_PROFILE=<profile> dart tool/build.dart macos
```

Without them the app keeps an ad-hoc signature: it runs on the Mac that built it, or elsewhere after the user allows
it in *System Settings → Privacy & Security*. It isn't sandboxed, on purpose (`app/macos/Runner/Release.entitlements`
says why), so it ships outside the Mac App Store.

## Releases

Pushing a tag `v<version>` (the `version:` of `app/pubspec.yaml` without its build number: `v1.0.2026` for
`1.0.2026+1`) runs `.github/workflows/release.yml`. It checks that the tag, the pubspec and the Tizen manifest agree,
builds the server (Linux x64 and arm64, Windows, macOS), the server image for both processors
(`ghcr.io/<owner>/wiretune-server`), and the Linux, Windows (installer and portable zip), macOS (disk image) and Android
(APKs and App Bundle) players, and leaves them with a `SHA256SUMS.txt` in a draft release to read over and publish. iOS
and Tizen aren't part of it.

| Secret | For |
|---|---|
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Signing the Android packages: the keystore in Base64 and what `key.properties` would hold. Required: a release is never signed with the debug key |
| `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD` | A *Developer ID Application* certificate with its key, exported as `.p12`, in Base64. Without it the disk image holds an ad-hoc signed app |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | Notarizing the macOS disk image (an app-specific password of the Apple ID). Needs the certificate too |

The workflow hasn't run yet: the Windows installer and the macOS signing, disk image and notarization are written but
untried (they need a Windows and a macOS host).

## Odds and ends

- **The version** is one for everything, `1.0.2026.1`: `WiretuneInfo.version` in
  `packages/wiretune_core/lib/src/about.dart`, the `version:` of every `pubspec.yaml` (`1.0.2026+1`: the build number
  is Android's version code) and `app/tizen/tizen-manifest.xml` (`1.0.2026`). A test fails when they disagree.
- **App icons** are made from `app/assets/wiretune.png`: `dart run flutter_launcher_icons` in `app/`.
- **A clean slate**: delete `dist/`, run `flutter clean` in `app/`, and delete the `build/` and `.dart_tool/` of the
  server and the core.
- **Builds from CI**: every CI run builds through `tool/build.dart` and keeps `dist/server` and the APKs as artifacts on
  its *Actions* page.
