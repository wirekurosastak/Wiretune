# Building

Run `dart tool/build.dart <target>…` from the repository root. Each target's output goes to `dist/<target>/` and
replaces the previous build. Copy output folders whole: the programs load their libraries from next to them.

## Flutter

All targets need Flutter 3.47 or newer (it includes Dart). On Linux and macOS (with zsh, use `~/.zshrc`):

```bash
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc
```

On Windows, follow [Flutter's installation guide](https://docs.flutter.dev/get-started/install/windows/desktop).
`flutter doctor` lists what's still missing.

## Server

Needs only Flutter. Builds on Linux, Windows and macOS, for the system it runs on:

```bash
dart tool/build.dart server
```

Output: `dist/server/bin/wiretune_server` (`.exe` on Windows) and the SQLite library in `dist/server/lib/`. The machine
that runs it doesn't need Dart. For a container image, see [server.md](server.md#docker).

## Linux player

```bash
sudo dnf install git clang cmake ninja-build gtk3-devel xz-devel mpv-devel ffmpeg-free rpm-build dpkg     # Fedora
sudo apt install git clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libmpv-dev ffmpeg rpm   # Debian, Ubuntu
sudo pacman -S --needed git clang cmake ninja pkgconf gtk3 xz mpv ffmpeg rpm-tools dpkg                   # Arch

dart tool/build.dart linux          # or linux-deb, linux-rpm
```

`linux` builds `dist/linux/` (x64, or arm64 on an ARM machine). To add it to the menu, run `./install.sh` in that
folder (`sudo PREFIX=/usr/local ./install.sh` for all users, `--uninstall` to remove it). To run, the machine needs
libmpv ([package names](user-guide.md#troubleshooting)), and `ffmpeg` for the spectrum analyzer.

`linux-deb` and `linux-rpm` build a package instead, which brings libmpv and the other dependencies along. rpm and dpkg
are only needed for these.

```bash
sudo apt install ./dist/linux-deb/wiretune_*.deb      # Debian, Ubuntu
sudo dnf install ./dist/linux-rpm/wiretune-*.rpm      # Fedora
```

A package needs at least the GLib version of the machine that built it. Release packages are built on Ubuntu 24.04 and
need Ubuntu 24.04, Debian 13 or Fedora 40 or later.

If you move or rename the repository, CMake fails with *The current CMakeCache.txt directory … is different*. Delete
`app/build/linux` and build again.

## Windows player

In PowerShell (FFmpeg is only for the spectrum analyzer, Inno Setup only for the installer):

```powershell
winget install --id Git.Git
winget install --id Microsoft.VisualStudio.2022.Community --override "--wait --passive --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"
winget install --id Gyan.FFmpeg
winget install --id JRSoftware.InnoSetup

dart tool/build.dart windows               # or windows-installer
```

Output: `dist\windows\wiretune.exe` with its DLLs (libmpv included) and a `data\` folder. `windows-installer` also
builds `dist\windows-installer\Wiretune-<version>-windows-<processor>-setup.exe`.

## macOS player

Install [Xcode](https://apps.apple.com/app/xcode/id497799835) and [Homebrew](https://brew.sh), then:

```bash
brew install cocoapods ffmpeg      # ffmpeg: the spectrum analyzer
dart tool/build.dart macos
```

Output: `dist/macos/Wiretune.app` and `dist/macos/Wiretune.dmg`.

### Signing and notarization

With a *Developer ID Application* identity in the keychain and a saved `notarytool` profile
(`xcrun notarytool store-credentials <profile> …`), the build signs, notarizes and staples the disk image:

```bash
WIRETUNE_MACOS_SIGN_IDENTITY="Developer ID Application: …" WIRETUNE_NOTARY_PROFILE=<profile> dart tool/build.dart macos
```

Without them the app is ad-hoc signed: it runs on the Mac that built it, and on other Macs only after allowing it in
*System Settings → Privacy & Security*.

## Android player (phone, tablet, TV, car)

Install [Android Studio](https://developer.android.com/studio), which brings the SDK and a JDK. Or use the
[command-line tools](https://developer.android.com/studio#command-line-tools-only) with JDK 17 or newer, such as
[Temurin](https://adoptium.net). Then:

```bash
flutter doctor --android-licenses
dart tool/build.dart android
```

Output: one APK per processor in `dist/android/`:

- `app-arm64-v8a-release.apk`: almost all phones, tablets and recent TVs
- `app-armeabi-v7a-release.apk`: older 32-bit devices and many TV boxes
- `app-x86_64-release.apk`: the emulator

The same APK covers phone, tablet, TV and car.

To install on a device with USB debugging on: `adb install -r dist/android/app-arm64-v8a-release.apk`.

### Signing

Without your own key, the APKs are signed with Flutter's debug key: fine for testing, not for distribution. Android
only installs an update signed with the same key, so create one once and keep it safe:

```bash
keytool -genkey -v -keystore ~/wiretune-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias wiretune
```

```properties
# app/android/key.properties (ignored by git, like every keystore)
storeFile=/home/you/wiretune-upload.jks
storePassword=…
keyAlias=wiretune
keyPassword=…
```

## iPhone and iPad player

Needs a Mac with [Xcode](https://apps.apple.com/app/xcode/id497799835) and CocoaPods (`brew install cocoapods`). Open
`app/ios/Runner.xcworkspace` once and pick your team under *Signing & Capabilities*, then:

```bash
dart tool/build.dart ios
```

Output: `dist/ios/*.ipa`. Bundle ID: `com.wiretune.player`.

## Samsung TV player (Tizen)

Install the [Tizen SDK with the TV extensions](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/installing-tv-sdk.html)
and [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen):

```bash
git clone https://github.com/flutter-tizen/flutter-tizen.git ~/flutter-tizen
echo 'export PATH="$HOME/flutter-tizen/bin:$PATH"' >> ~/.bashrc     # the build looks for it on the PATH
dart tool/build.dart tizen
```

Output: `dist/tizen/*.tpk`, for Tizen 6.0 and later (2021 TVs onward). To install it:

1. In the SDK's Certificate Manager, create a **Samsung** TV certificate profile (needs a Samsung account and the TV's
   DUID).
2. Turn on developer mode on the TV: open *Apps*, type 12345 on the remote, and enter your computer's IP address.
3. Run `sdb connect <tv-ip>`, then `flutter-tizen install` in `app/`.

The TV player has only been tried briefly, and remote navigation is still slow
([details](development.md#what-has-actually-been-tried)).

## Releases

The release workflow hasn't run yet. Its Windows installer and macOS signing, disk image and notarization steps are
untested (they need Windows and macOS runners).

The version is kept in `WiretuneInfo.version` (`packages/wiretune_core/lib/src/about.dart`), in every `pubspec.yaml`
(the build number is Android's version code) and in `app/tizen/tizen-manifest.xml`. A test fails if they differ.

Pushing a tag `v<version>` (the pubspec version without the build number: `v1.0.2026` for `1.0.2026+1`) runs
`.github/workflows/release.yml`. It checks that the tag, pubspec and Tizen manifest match, then builds:

- the server for Linux (x64, arm64), Windows and macOS, plus a container image for both processors
  (`ghcr.io/<owner>/wiretune-server`)
- the players for Linux (`.deb`, `.rpm`, and a `.tar.gz` with `install.sh`), Windows (installer and portable zip),
  macOS (disk image) and Android (APKs)

The result is a draft release with a `SHA256SUMS.txt`, for you to review and publish. iOS and Tizen aren't included.

The players update from the latest published release. They find their file by name and check it against
`SHA256SUMS.txt` (`app/lib/src/update_installer.dart`), so renaming a release file breaks updates to it.

The workflow needs these secrets:

| Secret | For |
|---|---|
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Signing Android packages: the keystore in Base64 and the `key.properties` values. Required: a release is never signed with the debug key |
| `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD` | A *Developer ID Application* certificate and key, exported as `.p12`, in Base64. Without it the app is ad-hoc signed |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | Notarizing the disk image, with an app-specific password for the Apple ID. Needs the certificate too |

## Starting clean

Delete `dist/`, run `flutter clean` in `app/`, and delete `build/` and `.dart_tool/` in `server/` and both
`packages/`, plus the packages' `pubspec.lock`.
