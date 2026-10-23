# Airbridge versioned releases

Airbridge publishes installable release assets directly to the GitHub **Releases** page. The release workflow deliberately does **not** upload ZIP files or a standalone Flutter runner executable that is missing its runtime files.

## Release assets

| Asset | What it is | Install/use |
| --- | --- | --- |
| `Airbridge-Android.apk` | Android APK for direct sideloading; built for the standard Flutter Android target architectures | Transfer to the device and open it, or run `adb install -r Airbridge-Android.apk`. Android may ask you to allow installs from that source. This is not a Play Store upload. |
| `Airbridge-Windows-Setup-X.Y.Z.exe` | x64 Inno Setup installer containing **the whole** Flutter `Release` directory, including the runner, DLLs, and `data` directory | Run the installer and launch Airbridge from the Start menu. Do not download/use only `airbridge_mobile.exe` from a raw Flutter build folder. |
| `Airbridge-Linux-x86_64.AppImage` | x86_64 AppImage made from the full Flutter bundle with its shared-library dependencies collected | Run `chmod +x Airbridge-Linux-x86_64.AppImage`, then launch it. A desktop Linux environment is required. |
| `Airbridge-macOS.dmg` | DMG containing `Airbridge.app` and an Applications shortcut | Open the DMG and drag Airbridge to Applications. |
| `SHA256SUMS.txt` | SHA-256 manifest for the four download assets | Verify after downloading; commands are below. |

The assets are not currently signed with platform-native release certificates. Windows may show SmartScreen, macOS is not notarized and may require Control-click → **Open**, and the Android APK is intended for sideloading. Each asset (including the checksum manifest) receives a signed GitHub build-provenance attestation; this authenticates the workflow/source identity but is not a substitute for Authenticode, Apple notarization, or a Play signing key. iOS is built unsigned in CI but is not published as an installable release because distribution requires an Apple signing team/profile and Apple's multicast entitlement.

## How releases are triggered

`.github/workflows/release.yml` runs only when a `vMAJOR.MINOR.PATCH` tag is pushed. Before building, it verifies that:

1. The tag exactly matches the app version in `airbridge_mobile/pubspec.yaml` (the optional `+build` suffix is ignored).
2. The tagged commit is already reachable from `main`—an unmerged branch cannot be released.
3. Every expected asset is present and non-empty, no ZIP exists, and the generated SHA-256 manifest passes verification.

All four platform builds must pass before GitHub creates the release. The release includes generated change notes, the four native download formats, checksums, and signed provenance attestations. The pull-request workflow also smoke-tests Windows installer, Linux AppImage, and macOS DMG packaging after the normal desktop builds; it never publishes release assets.

### Cutting a release

1. Update `version:` in `airbridge_mobile/pubspec.yaml` to the next `X.Y.Z+build` version in a reviewed change, and merge that change to `main` after CI passes. The tag uses only `X.Y.Z`, for example `4.0.1+2` maps to `v4.0.1`.
2. From a clean checkout after the merge, create and push the matching tag:

```bash
git switch main
git pull --ff-only origin main
git tag v4.0.1
git push origin v4.0.1
```

Replace `4.0.1` with the version that was merged. The workflow will create the GitHub Release after successful builds. The workflow does not tag or publish this open feature branch; it intentionally waits for a versioned commit on `main`.

### Verify downloads

Download `SHA256SUMS.txt` alongside the release assets, then run this from their directory:

```bash
sha256sum --check SHA256SUMS.txt
```

On PowerShell, compare a file's digest with its line in `SHA256SUMS.txt`:

```powershell
(Get-FileHash .\Airbridge-Android.apk -Algorithm SHA256).Hash.ToLowerInvariant()
```

To verify the signed GitHub provenance for a downloaded asset, install a recent GitHub CLI and run:

```bash
gh attestation verify Airbridge-Android.apk --repo codero-sus/AirBridge
```

Run the same command once for each asset, replacing the filename with that exact download name. The attestation is published by GitHub's attestation service, in addition to the SHA-256 manifest attached to the release.

## Build the release packages locally

Run the matching Flutter build on its native host, after the standard bootstrap in [`airbridge_mobile/build_instructions.md`](../airbridge_mobile/build_instructions.md). These scripts package the full desktop outputs; they do not upload or publish anything.

### Android APK (Windows, macOS, or Linux)

```bash
cd airbridge_mobile
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

### Windows installer (Windows)

Install Visual Studio 2022 with **Desktop development with C++**, build the full bundle, install Inno Setup 6, then package it. Use the current `X.Y.Z` version from `pubspec.yaml` as `-AppVersion`:

```powershell
cd airbridge_mobile
flutter build windows --release
choco install innosetup --yes --no-progress
.\tool\package_windows_installer.ps1 -AppVersion 4.0.0 -OutputDirectory .\build\release
```

The output is `build\release\Airbridge-Windows-Setup-4.0.0.exe`. Change `4.0.0` to the package version being built. The installer icon and installed shortcuts use the official Airbridge logo.

### Linux AppImage (Linux x86_64)

Install Flutter and AppImage packaging dependencies (`clang`, `cmake`, `ninja-build`, `pkg-config`, GTK 3 development headers, `patchelf`, `desktop-file-utils`, and `curl`), then:

```bash
cd airbridge_mobile
flutter build linux --release
./tool/package_linux_appimage.sh ./build/release
```

The packaging script downloads a pinned linuxdeploy release, checks its SHA-256 digest, bundles the Flutter runtime and discovered shared-library dependencies, and writes `build/release/Airbridge-Linux-x86_64.AppImage`.

### macOS DMG (macOS)

With Xcode and CocoaPods installed:

```bash
cd airbridge_mobile
flutter build macos --release
./tool/package_macos_dmg.sh ./build/release
```

The output is `build/release/Airbridge-macOS.dmg`. The DMG is unsigned and not notarized until Apple signing credentials and provisioning are configured.

For an iOS IPA, use `flutter build ipa --release` on macOS only after configuring the Apple signing team/profile and required multicast entitlement. That process is intentionally not part of the unsigned public-release workflow.
