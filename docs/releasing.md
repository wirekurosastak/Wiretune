# Releasing

The release workflow hasn't run yet. Its Windows installer and macOS signing, disk image and notarization steps are
untested (they need Windows and macOS runners).

## Steps

1. Raise the version everywhere: `WiretuneInfo.version` (`packages/wiretune_core/lib/src/about.dart`), every
   `pubspec.yaml` (the build number is Android's version code) and `app/tizen/tizen-manifest.xml`. A test fails if
   they differ.
2. Push a tag `v<version>`: the pubspec version without the build number (`v1.0.2026` for `1.0.2026+1`).
3. `.github/workflows/release.yml` checks that the tag, pubspec and Tizen manifest match, then builds:
   - the server for Linux (x64, arm64), Windows and macOS, plus a container image for both processors
     (`ghcr.io/<owner>/wiretune-server`)
   - the players for Linux (`.deb`, `.rpm`, and a `.tar.gz` with `install.sh`), Windows (installer and portable zip),
     macOS (disk image) and Android (APKs)
4. Review the draft release it creates, with a `SHA256SUMS.txt`, and publish it.

iOS and Tizen aren't included.

The players update from the latest published release. They find their file by name and check it against
`SHA256SUMS.txt` (`app/lib/src/update_installer.dart`), so renaming a release file breaks updates to it.

## Secrets

| Secret | For |
|---|---|
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Signing Android packages: the keystore in Base64 and the `key.properties` values. Required: a release is never signed with the debug key |
| `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD` | A *Developer ID Application* certificate and key, exported as `.p12`, in Base64. Without it the app is ad-hoc signed |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | Notarizing the disk image, with an app-specific password for the Apple ID. Needs the certificate too |
