# Building

Build from the repository root with `dart tool/build.dart <target>…`. Output goes to `dist/<target>/`, replacing any
earlier build. Copy result folders whole: the programs load libraries from next to them.

Per target below: prerequisites, command, output. Signing and releases are at the end. Running the server:
[server.md](server.md). Working on the code: [development.md](development.md).

## Flutter

Flutter 3.47 or newer (includes Dart, which is all the server needs).

```bash
# Linux and macOS: clone and add to PATH (zsh on a Mac: ~/.zshrc instead of ~/.bashrc)
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc
```

On Windows, follow [Flutter's installation guide](https://docs.flutter.dev/get-started/install/windows/desktop). On any
system, `flutter doctor` lists what your targets still need.

## Server

Needs only Flutter. Builds on Linux, Windows and macOS, for the host's system and processor.

```bash
dart tool/build.dart server
```

Output: `dist/server/bin/wiretune_server` (`.exe` on Windows) and the SQLite library in `dist/server/lib/`. The host
that runs it needs no Dart.

Or build the container image (from the repository root, which holds the core package too):

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

Output: `dist/linux/wiretune` with `lib/` and `data/`, x64 (arm64 on ARM hosts). Machines that only run it need libmpv
(`mpv-libs` Fedora, `libmpv2` Debian/Ubuntu, `mpv` Arch). `ffmpeg` is optional (spectrum).

Moved or renamed the repository? CMake fails with *The current CMakeCache.txt directory … is different*. Delete
`app/build/linux` and rebuild.

## Windows player

In PowerShell (the last two only if you want them):

```powershell
winget install --id Git.Git
winget install --id Microsoft.VisualStudio.2022.Community --override "--wait --passive --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"
winget install --id Gyan.FFmpeg            # the spectrum
winget install --id JRSoftware.InnoSetup   # the installer

dart tool/build.dart windows               # or windows-installer
```

Output: `dist\windows\wiretune.exe` with its DLLs (including libmpv) and `data\`. `windows-installer` also produces
`dist\windows-installer\Wiretune-<version>-windows-<processor>-setup.exe`.

## macOS player

Install [Xcode](https://apps.apple.com/app/xcode/id497799835) from the App Store and [Homebrew](https://brew.sh), then:

```bash
brew install cocoapods ffmpeg      # ffmpeg: the spectrum
dart tool/build.dart macos
```

Output: `dist/macos/Wiretune.app` and `dist/macos/Wiretune.dmg`. Unsigned builds run only on the Mac that built them;
for other Macs, [sign and notarize](#macos).

## Android player (phone, tablet, TV, car)

Install [Android Studio](https://developer.android.com/studio) (brings the Android SDK and a matching JDK), or the
[command-line tools](https://developer.android.com/studio#command-line-tools-only) plus JDK 17+ such as
[Temurin](https://adoptium.net). Then:

```bash
flutter doctor --android-licenses
dart tool/build.dart android        # or appbundle, for Google Play
```

Output: `dist/android/app-<processor>-release.apk`, one per ABI: `arm64-v8a` (nearly all phones, tablets, recent TVs),
`armeabi-v7a` (older 32-bit devices, many TV boxes), `x86_64` (emulator). The same APK is the phone, tablet, TV and car
app. `appbundle` produces `dist/android/app-release.aab`. Install on a device with debugging on:
`adb install -r dist/android/app-arm64-v8a-release.apk`.

Without a key, the build is signed with Flutter's debug key: fine for testing; [sign your own](#android) to distribute.

## iPhone and iPad player

Needs a Mac with [Xcode](https://apps.apple.com/app/xcode/id497799835) and CocoaPods (`brew install cocoapods`). Open
`app/ios/Runner.xcworkspace` once and pick your team under *Signing & Capabilities*, then:

```bash
dart tool/build.dart ios
```

Output: `dist/ios/*.ipa` for TestFlight or the App Store (upload with
[Transporter](https://apps.apple.com/app/transporter/id1450874784)). Bundle ID: `com.wiretune.player`.

## Samsung TV player (Tizen)

Install the [Tizen SDK with the TV extensions](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/installing-tv-sdk.html)
(or the *Tizen* extension for VS Code) and [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen):

```bash
git clone https://github.com/flutter-tizen/flutter-tizen.git ~/flutter-tizen
echo 'export PATH="$HOME/flutter-tizen/bin:$PATH"' >> ~/.bashrc     # the build looks for it on the PATH
dart tool/build.dart tizen
```

Output: `dist/tizen/*.tpk` (TV profile, Tizen 6.0+, so 2021 TVs onward). To install:

1. In the SDK's Certificate Manager, create a **Samsung** certificate profile for TVs (needs a Samsung account and the
   TV's DUID).
2. Enable developer mode on the TV: open *Apps*, type 12345 on the remote, enter your computer's address.
3. `sdb connect <tv-ip>`, then `flutter-tizen install` in `app/`.

Only briefly tried, on a 2024 Samsung (Tizen 8.0): works, but navigating with the remote is sluggish.

The TV needs its own SQLite, because the sqlite3 package's Linux ARM download doesn't load there. The build script sets
that in `app/pubspec.yaml` for the Tizen build only and reverts it afterwards.

## Signing

### Android

Releases are signed with the key named in `app/android/key.properties`. Android installs updates only over an app signed
with the same key, so create one once and keep it safe:

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

Without them the app is ad-hoc signed: it runs on the building Mac, or elsewhere after the user allows it in *System
Settings → Privacy & Security*. It is deliberately not sandboxed (see `app/macos/Runner/Release.entitlements`), so it
can't ship on the Mac App Store.

## Releases

Pushing a tag `v<version>` runs `.github/workflows/release.yml`. The version is the `version:` of `app/pubspec.yaml`
without the build number (`v1.0.2026` for `1.0.2026+1`). The workflow:

- checks that the tag, pubspec and Tizen manifest agree;
- builds the server (Linux x64/arm64, Windows, macOS), the server image for both processors
  (`ghcr.io/<owner>/wiretune-server`), and the Linux, Windows (installer and portable zip), macOS (disk image) and
  Android (APKs, App Bundle) players;
- attaches everything plus `SHA256SUMS.txt` to a draft release for you to review and publish.

iOS and Tizen are not included.

| Secret | For |
|---|---|
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Android signing: the keystore in Base64 and the `key.properties` values. Required; releases are never signed with the debug key |
| `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD` | *Developer ID Application* certificate and key as Base64 `.p12`. Without it the disk image holds an ad-hoc signed app |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | macOS notarization (app-specific password of the Apple ID). Needs the certificate too |

The workflow hasn't run yet. The Windows installer and the macOS signing, disk image and notarization are written but
untried (they need Windows and macOS hosts).

## Odds and ends

- **Version**: one version everywhere, `1.0.2026.1`. It lives in `WiretuneInfo.version`
  (`packages/wiretune_core/lib/src/about.dart`), the `version:` of every `pubspec.yaml` (`1.0.2026+1`; the build number
  is Android's version code) and `app/tizen/tizen-manifest.xml` (`1.0.2026`). A test fails if they disagree.
- **App icons**: generated from `app/assets/wiretune.png` with `dart run flutter_launcher_icons` in `app/`.
- **Clean slate**: delete `dist/`, run `flutter clean` in `app/`, delete `build/` and `.dart_tool/` in the server and
  core packages.
- **CI builds**: every CI run builds through `tool/build.dart` and keeps `dist/server` and the APKs as artifacts on the
  *Actions* page.
