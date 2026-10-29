# Building

Build from the repository root with `dart tool/build.dart <target>…`. Each target's output lands in `dist/<target>/`,
replacing any earlier build. Copy an output folder as a whole, because the programs load their libraries from next to
them.

## Flutter

Every target needs Flutter 3.47 or newer, which includes Dart. On Linux and macOS, clone it and put it on the `PATH`
(with zsh on a Mac, use `~/.zshrc` instead of `~/.bashrc`):

```bash
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc
```

On Windows, follow [Flutter's installation guide](https://docs.flutter.dev/get-started/install/windows/desktop). On any
system, `flutter doctor` then lists what your targets still need.

## Server

The server needs nothing beyond Flutter, and builds on Linux, Windows and macOS for the system it runs on:

```bash
dart tool/build.dart server
```

This produces `dist/server/bin/wiretune_server` (`.exe` on Windows), with the SQLite library in `dist/server/lib/`. The
machine that runs it doesn't need Dart. To build a container image instead, see [server.md](server.md#docker).

## Linux player

```bash
sudo dnf install git clang cmake ninja-build gtk3-devel xz-devel mpv-devel ffmpeg-free rpm-build dpkg     # Fedora
sudo apt install git clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libmpv-dev ffmpeg rpm   # Debian, Ubuntu
sudo pacman -S --needed git clang cmake ninja pkgconf gtk3 xz mpv ffmpeg rpm-tools dpkg                   # Arch

dart tool/build.dart linux          # or linux-deb, linux-rpm
```

`linux` builds `dist/linux/wiretune` with its `lib/` and `data/` folders, for x64, or arm64 when built on an ARM
machine. Its `install.sh` puts it in your menu (`sudo PREFIX=/usr/local ./install.sh` for everyone, `--uninstall` to
take it out). A machine that only runs the player needs libmpv ([package names](user-guide.md#troubleshooting)), and
`ffmpeg` for the spectrum analyzer.

`linux-deb` and `linux-rpm` build it as a package instead (rpm and dpkg are only needed for those), which installs
libmpv and everything else it needs along with it:

```bash
sudo apt install ./dist/linux-deb/wiretune_*.deb      # Debian, Ubuntu
sudo dnf install ./dist/linux-rpm/wiretune-*.rpm      # Fedora
```

A package installs on systems with at least the GLib of the machine that built it. The release's packages, built on
Ubuntu 24.04, need Ubuntu 24.04, Debian 13 or Fedora 40 or later.

If you move or rename the repository, CMake stops with *The current CMakeCache.txt directory … is different*. Delete
`app/build/linux` and build again.

## Windows player

In PowerShell (FFmpeg is only needed for the spectrum analyzer, and Inno Setup only for the installer):

```powershell
winget install --id Git.Git
winget install --id Microsoft.VisualStudio.2022.Community --override "--wait --passive --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"
winget install --id Gyan.FFmpeg
winget install --id JRSoftware.InnoSetup

dart tool/build.dart windows               # or windows-installer
```

You get `dist\windows\wiretune.exe` with its DLLs, libmpv among them, and a `data\` folder. `windows-installer` also
builds `dist\windows-installer\Wiretune-<version>-windows-<processor>-setup.exe`.

## macOS player

Install [Xcode](https://apps.apple.com/app/xcode/id497799835) from the App Store and [Homebrew](https://brew.sh), then:

```bash
brew install cocoapods ffmpeg      # ffmpeg: the spectrum analyzer
dart tool/build.dart macos
```

This builds `dist/macos/Wiretune.app` and the disk image `dist/macos/Wiretune.dmg`.

### Signing and notarization

With a *Developer ID Application* identity in the keychain and a stored `notarytool` profile
(`xcrun notarytool store-credentials <profile> …`), the build signs, notarizes and staples the disk image:

```bash
WIRETUNE_MACOS_SIGN_IDENTITY="Developer ID Application: …" WIRETUNE_NOTARY_PROFILE=<profile> dart tool/build.dart macos
```

Without them the app keeps an ad-hoc signature: it runs on the Mac that built it, and on other Macs only after the user
allows it in *System Settings → Privacy & Security*. The app is deliberately not sandboxed
(`app/macos/Runner/Release.entitlements` says why), so it can't ship on the Mac App Store.

## Android player (phone, tablet, TV, car)

Install [Android Studio](https://developer.android.com/studio), which brings the Android SDK and a matching JDK; without
it, use the [command-line tools](https://developer.android.com/studio#command-line-tools-only) and JDK 17 or newer, such
as [Temurin](https://adoptium.net). Then:

```bash
flutter doctor --android-licenses
dart tool/build.dart android        # or appbundle, for Google Play
```

The build produces one APK per processor type in `dist/android/`: `app-arm64-v8a-release.apk` for nearly all phones,
tablets and recent TVs, `app-armeabi-v7a-release.apk` for older 32-bit devices and many TV boxes, and
`app-x86_64-release.apk` for the emulator. The same APK is the phone, tablet, TV and car app. `appbundle` builds
`dist/android/app-release.aab` instead. To install an APK on a device with debugging on, run
`adb install -r dist/android/app-arm64-v8a-release.apk`.

### Signing

Without a key of your own, the APKs are signed with Flutter's debug key, which is fine for trying them but not for
handing them out. Android installs an update only over an app signed with the same key, so create one once and keep it
safe:

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

## iPhone and iPad player

This needs a Mac with [Xcode](https://apps.apple.com/app/xcode/id497799835) and CocoaPods (`brew install cocoapods`).
Open `app/ios/Runner.xcworkspace` once and pick your team under *Signing & Capabilities*, then:

```bash
dart tool/build.dart ios
```

This produces `dist/ios/*.ipa`, which you upload to TestFlight or the App Store with
[Transporter](https://apps.apple.com/app/transporter/id1450874784). The bundle ID is `com.wiretune.player`.

## Samsung TV player (Tizen)

Install the [Tizen SDK with the TV extensions](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/installing-tv-sdk.html)
(or the *Tizen* extension for VS Code) and [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen):

```bash
git clone https://github.com/flutter-tizen/flutter-tizen.git ~/flutter-tizen
echo 'export PATH="$HOME/flutter-tizen/bin:$PATH"' >> ~/.bashrc     # the build looks for it on the PATH
dart tool/build.dart tizen
```

This produces `dist/tizen/*.tpk` for the TV profile of Tizen 6.0 and later, which means 2021 TVs onward. To install it:

1. In the SDK's Certificate Manager, create a **Samsung** certificate profile for TVs (it needs a Samsung account and the
   TV's DUID).
2. Turn on developer mode on the TV: open *Apps*, type 12345 on the remote, and enter your computer's address.
3. Run `sdb connect <tv-ip>`, then `flutter-tizen install` in `app/`.

The TV player has only been tried briefly, and navigating with the remote is still sluggish
([details](development.md#what-has-actually-been-tried)).

## Releases

The release workflow hasn't run yet: its Windows installer and macOS signing, disk image and notarization steps are
written but untried, since they need Windows and macOS hosts.

Wiretune has one version, kept in `WiretuneInfo.version` (`packages/wiretune_core/lib/src/about.dart`), the `version:`
of every `pubspec.yaml` (whose build number is Android's version code) and `app/tizen/tizen-manifest.xml`; a test fails
if they disagree. Pushing a tag `v<version>`, the pubspec version without its build number (`v1.0.2026` for
`1.0.2026+1`), runs `.github/workflows/release.yml`. It checks that the tag, the pubspec and the Tizen manifest agree,
then builds:

- the server for Linux (x64 and arm64), Windows and macOS, and its container image for both processors
  (`ghcr.io/<owner>/wiretune-server`);
- the players for Linux (`.deb`, `.rpm` and a `.tar.gz` with `install.sh`), Windows (installer and portable zip),
  macOS (disk image) and Android (APKs and App Bundle).

It leaves them, with a `SHA256SUMS.txt`, in a draft release for you to review and publish. iOS and Tizen aren't part of
it. The workflow needs these secrets:

| Secret | For |
|---|---|
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Signing the Android packages: the keystore in Base64 and the values `key.properties` would hold. Required, because a release is never signed with the debug key |
| `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD` | A *Developer ID Application* certificate and its key, exported as `.p12`, in Base64. Without it the disk image holds an ad-hoc signed app |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | Notarizing the macOS disk image, with an app-specific password of the Apple ID. Needs the certificate too |

## Starting clean

Delete `dist/`, run `flutter clean` in `app/`, and delete `build/` and `.dart_tool/` in `server/` and both
`packages/`, along with the packages' `pubspec.lock`.
