# Airbridge versioned releases

Airbridge publishes installable release assets directly to the GitHub **Releases** page. Those release assets stay as separate native installers/packages; no ZIP is attached to a GitHub Release. For convenience, the pull-request CI run and versioned release workflow also expose an `Airbridge-All-Platforms.zip` as a seven-day **Actions artifact**, not a Release asset. The CI artifact is the raw `Airbridge-All-Platforms.zip` file, containing the four native downloads, an explicitly unsigned iOS `.app` archive, and `SHA256SUMS.txt`; the versioned release run provides a raw `Airbridge-All-Platforms.zip` with the four native downloads and checksums only. These are ordinary, unencrypted ZIP files; the Actions artifact wrapper is disabled so the downloaded file is the actual bundle. The unsigned iOS build is for CI/developer inspection, not direct installation.

## Release assets

| Asset | What it is | Install/use |
| --- | --- | --- |
| `Airbridge-Android.apk` | Android APK for direct sideloading; built for the standard Flutter Android target architectures | Transfer to the device and open it, or run `adb install -r Airbridge-Android.apk`. Android may ask you to allow installs from that source. This is not a Play Store upload. |
| `Airbridge-Windows-Setup-X.Y.Z.exe` | x64 per-user Inno Setup installer containing **the whole** Flutter `Release` directory, including the runner, DLLs, and `data` directory | Run the installer and launch Airbridge from the Start menu. Official releases can install verified updates silently in a writable per-user folder; a protected legacy machine-wide installation is never elevated. Do not download/use only `airbridge_mobile.exe` from a raw Flutter build folder. |
| `Airbridge-Linux-x86_64.AppImage` | x86_64 AppImage made from the full Flutter bundle with its shared-library dependencies collected | Run `chmod +x Airbridge-Linux-x86_64.AppImage`, then launch it. A desktop Linux environment is required. |
| `Airbridge-macOS.dmg` | DMG containing `Airbridge.app` and an Applications shortcut | Open the DMG and copy Airbridge to a writable Applications folder. A per-user `~/Applications` install can self-update without administrator approval; a protected system `/Applications` install may not. |
| `SHA256SUMS.txt` | SHA-256 manifest for the four download assets | Verify after downloading; commands are below. |

The assets are not currently signed with platform-native release certificates. Windows may show SmartScreen, macOS is not notarized and may require Control-click → **Open**, and the Android APK is intended for sideloading. Each asset (including the checksum manifest) receives a signed GitHub build-provenance attestation; this authenticates the workflow/source identity but is not a substitute for Authenticode, Apple notarization, or a Play signing key. iOS is built unsigned in CI but is not published as an installable release because distribution requires an Apple signing team/profile and Apple's multicast entitlement.

## Automatic update policy

Release builds embed their exact Git tag and check the GitHub **pre-release** channel at startup and every twelve hours. The updater downloads a platform package, compares its SHA-256 digest with that release's `SHA256SUMS.txt`, and stages it without displaying an update dialog. Windows, macOS, and the official Linux AppImage apply a verified package automatically on the next launch. Updates are attempted only when the current install path is writable; no UAC/admin dialog or privilege escalation is requested. Windows installers are per-user. macOS direct-download builds are unsandboxed so a writable app bundle can be replaced; for installs in a protected system `/Applications` folder, use a per-user `~/Applications` location if silent updates are required. Linux automatic replacement is supported only for an app launched from the official x86_64 AppImage. The updater does not bypass SmartScreen, Gatekeeper, antivirus, or other OS security checks; unsigned/unnotarized packages may be blocked or require the OS to approve the app first.

Android direct APK sideloads cannot be silently installed by an ordinary consumer app, so Airbridge reports a newer pre-release but deliberately does not open the Android package installer. iOS updates must be delivered by the App Store/TestFlight or device management; Airbridge cannot replace its iOS app bundle. No silent mobile update is claimed: a no-touch deployment requires an OS-managed store or managed-device channel. The current GitHub release workflow publishes no iOS installable package. Existing binaries built before this updater was added need one normal manual update; an installed app cannot retroactively acquire new updater code. SHA-256 verifies the download against the release manifest; users requiring independent provenance validation should also verify the GitHub attestation with `gh attestation verify`.

## Pairing links and cameras in release builds

All native packages include the `airbridge://pair?...` handler and the QR-scanning configuration. Android/iOS/macOS register the scheme in their app metadata. The Windows installer registers the protocol and forwards a second launch to the running Airbridge instance. On Linux, the AppImage declares the XDG handler; after downloading it, mark the file executable and register it once from a checkout of this repository:

```bash
chmod +x "$HOME/Downloads/Airbridge-Linux-x86_64.AppImage"
./airbridge_mobile/tool/register_linux_url_scheme.sh "$HOME/Downloads/Airbridge-Linux-x86_64.AppImage"
```

To smoke-test the OS handler, run `Start-Process 'airbridge://pair?test=1'` in PowerShell, `xdg-open 'airbridge://pair?test=1'` on Linux after registration, or `open 'airbridge://pair?test=1'` on macOS. The sample token is intentionally invalid; success means Airbridge opens the pairing flow and displays an invalid-invitation message. The Android equivalent is `adb shell am start -a android.intent.action.VIEW -d 'airbridge://pair?test=1'`.

Windows and Linux release builds scan with selectable connected webcams (including wired USB webcams); mobile/macOS use the native scanner with an alternate camera engine if needed. Grant camera access in OS settings before scanning. GitHub Releases remain separate native assets—these setup steps do not introduce ZIP Release assets.

## How releases are triggered

`.github/workflows/release.yml` runs when a `v*` tag is pushed and distinguishes stable releases from pre-releases:

- Stable tags use `vMAJOR.MINOR.PATCH`, must match `airbridge_mobile/pubspec.yaml` (the optional `+build` suffix is ignored), and must point to a commit already reachable from `main`.
- Pre-release tags use `vMAJOR.MINOR.PATCH-label[.number...]`, such as `v4.0.0-preview.1`. Their `MAJOR.MINOR.PATCH` portion must match the app version, and the tagged commit must be the head of an open pull request.

Both paths verify that the four installable platform assets are present and non-empty, reject ZIP files as release assets, and verify a generated SHA-256 manifest. All four platform builds must pass before GitHub publishes. Each release contains separate native downloads, checksums, generated notes, and signed provenance attestations. The workflow also creates an all-platforms ZIP as an Actions artifact only (not a Releases asset). Pull-request CI separately provides a combined ZIP that includes the unsigned iOS `.app` archive for developer inspection; iOS is not a Release download.

### Cutting a release

1. Update `version:` in `airbridge_mobile/pubspec.yaml` to the next `X.Y.Z+build` version in a reviewed change, and merge that change to `main` after CI passes. The tag uses only `X.Y.Z`, for example `4.0.1+2` maps to `v4.0.1`.
2. From a clean checkout after the merge, create and push the matching tag:

```bash
git switch main
git pull --ff-only origin main
git tag v4.0.1
git push origin v4.0.1
```

Replace `4.0.1` with the version that was merged. The workflow creates the stable GitHub Release after successful builds. Stable release tags must point to commits on `main`.

### Cutting a pull-request pre-release

After CI passes, a pre-release can be published from the exact head commit of an open PR. Use the app version's `MAJOR.MINOR.PATCH` with a preview suffix; for the current `4.0.0+1` version, the first preview tag is `v4.0.0-preview.1`:

```bash
git tag v4.0.0-preview.1
git push origin v4.0.0-preview.1
```

The tag must point to the current head of an open PR. The workflow builds the four native packages, marks the GitHub Release as a pre-release, and leaves the combined ZIP as an Actions artifact only. For later previews on the same version, increment the suffix (for example, `v4.0.0-preview.2`).

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

Run the matching Flutter build on its native host, after the standard bootstrap in [`airbridge_mobile/build_instructions.md`](../airbridge_mobile/build_instructions.md). These scripts package the full desktop outputs; they do not upload or publish anything. To participate in the automatic pre-release updater, embed the exact Git tag in each package using `--dart-define=AIRBRIDGE_RELEASE_TAG=v4.0.0-preview.1` (replace it with the tag being built). The release workflow injects its actual tag automatically; builds without this define do not run the updater.

### Android APK (Windows, macOS, or Linux)

```bash
cd airbridge_mobile
flutter build apk --release --dart-define=AIRBRIDGE_RELEASE_TAG=v4.0.0-preview.1
# Output: build/app/outputs/flutter-apk/app-release.apk
```

### Windows installer (Windows)

Install Visual Studio 2022 with **Desktop development with C++**, build the full bundle, install Inno Setup 6, then package it. Use the current `X.Y.Z` version from `pubspec.yaml` as `-AppVersion`:

```powershell
cd airbridge_mobile
flutter build windows --release --dart-define=AIRBRIDGE_RELEASE_TAG=v4.0.0-preview.1
choco install innosetup --yes --no-progress
.\tool\package_windows_installer.ps1 -AppVersion 4.0.0 -OutputDirectory .\build\release
```

The output is `build\release\Airbridge-Windows-Setup-4.0.0.exe`. Change `4.0.0` to the package version being built. The installer icon and installed shortcuts use the official Airbridge logo.

### Linux AppImage (Linux x86_64)

Install Flutter and AppImage packaging dependencies (`clang`, `cmake`, `ninja-build`, `pkg-config`, GTK 3 development headers, `patchelf`, `desktop-file-utils`, `curl`, `libfuse2`, and ImageMagick), then:

```bash
cd airbridge_mobile
flutter build linux --release --dart-define=AIRBRIDGE_RELEASE_TAG=v4.0.0-preview.1
./tool/package_linux_appimage.sh ./build/release
```

The packaging script downloads a pinned linuxdeploy release, checks its SHA-256 digest, bundles the Flutter runtime and discovered shared-library dependencies, and writes `build/release/Airbridge-Linux-x86_64.AppImage`.

### macOS DMG (macOS)

With Xcode and CocoaPods installed:

```bash
cd airbridge_mobile
flutter build macos --release --dart-define=AIRBRIDGE_RELEASE_TAG=v4.0.0-preview.1
./tool/package_macos_dmg.sh ./build/release
```

The output is `build/release/Airbridge-macOS.dmg`. The DMG is unsigned and not notarized until Apple signing credentials and provisioning are configured.

For an iOS IPA, use `flutter build ipa --release` on macOS only after configuring the Apple signing team/profile and required multicast entitlement. That process is intentionally not part of the unsigned public-release workflow.
