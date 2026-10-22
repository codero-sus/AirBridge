# Build and deploy Airbridge Mobile

<p align="center">
  <img src="assets/airbridge_logo.png" alt="Official Airbridge logo" width="140">
</p>

## 1. Tools and platform requirements

### Required everywhere

* **Flutter stable SDK 3.24+**; it includes the matching **Dart 3.5+ SDK**. Install Flutter once and add its `bin` folder to `PATH`.
* **Git** to clone/update the repository and **Python 3** for the platform bootstrap script. An IDE is optional: VS Code with the Flutter/Dart extensions or Android Studio are convenient, but the commands below work from a terminal.
* Verify the core install with:

```bash
flutter --version
dart --version
flutter doctor -v
```

### Pick the toolchain for the artifact you want

| Artifact | Build host | Additional tools needed |
| --- | --- | --- |
| Android `.apk` | Windows, macOS, or Linux | Android Studio (recommended) with Android SDK Command-line Tools, Platform-Tools (`adb`), and Android Build Tools; a JDK supported by Flutter. Accept licenses with `flutter doctor --android-licenses`. `adb` is only needed to install/test on a device, not to compile the APK. |
| Windows `.exe` | Windows | Visual Studio 2022 with **Desktop development with C++**, MSVC C++ build tools, and a Windows 10/11 SDK. Flutter creates a release folder; ship the whole folder, not just the `.exe`. |
| Linux desktop bundle | Linux | `clang`, `cmake`, `ninja-build`, `pkg-config`, GTK 3 development headers, and a C++ standard library toolchain. |
| macOS `.app` | macOS | Xcode and CocoaPods. Xcode command-line tools must be selected and its license accepted. |
| iOS 15.5+ app / `.ipa` | macOS only | Xcode and CocoaPods. Airbridge's camera-scanning dependency requires iOS 15.5 or newer; bootstrap applies that deployment target. An unsigned build needs no signing identity; device installation or a distributable IPA requires an Apple Developer signing team/profile. Airbridge's multicast discovery also needs Apple's multicast entitlement on the App ID/profile. |

For Debian/Ubuntu, install the Linux desktop packages with:

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev
```

For macOS/iOS, install Xcode from the App Store and Homebrew, then select Xcode and install CocoaPods:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -license accept
brew install cocoapods
```

For Android, install Android Studio and use **SDK Manager** to install Android SDK Command-line Tools, Platform-Tools, and Build Tools. Then run:

```bash
flutter doctor --android-licenses
flutter doctor -v
```

For Windows, install Visual Studio 2022 (not just Visual Studio Code) and select **Desktop development with C++** in Visual Studio Installer. In the Android Studio SDK Manager, install the Android components too if you also want APKs.

> Build on the target desktop OS: Windows executables on Windows, Linux bundles on Linux, and macOS/iOS on macOS. Android APKs can be built from any supported desktop host. The Android SDK/JDK, Visual Studio C++ workload, Linux packages, Xcode, and CocoaPods are native build dependencies; Flutter and Dart alone are not sufficient.

The generated native host projects are intentionally the standard Flutter templates. The bootstrap scripts generate them and then apply the checked-in permissions, native bridge, and Apple network entitlements.

## 2. Bootstrap once

From the repository root:

### Linux / macOS

```bash
cd airbridge_mobile
chmod +x tool/bootstrap_platforms.sh
./tool/bootstrap_platforms.sh
```

### Windows PowerShell

```powershell
cd airbridge_mobile
.\tool\bootstrap_platforms.ps1
```

From a Git clone's repository root, Windows users can instead run `updater.bat`. It fetches and fast-forwards `arena/028ea2fd-airbridge`, bootstraps missing native projects, runs `flutter clean` and `flutter pub get`, then builds the Android release APK and Windows desktop bundle. It never force-resets local files. The APK requires a configured Android SDK; the Windows bundle requires Visual Studio 2022's **Desktop development with C++** workload. The script does not build Linux, macOS, or iOS targets because those require their respective host operating systems.

The scripts generate standard Flutter host projects in a temporary directory, copy in only missing native platform folders (so they cannot overwrite `lib/` or `pubspec.yaml`), apply the checked-in permissions/native bridge/Apple network entitlements, resolve dependencies, generate Android/iOS/macOS/Windows launcher icons and a Linux window icon from `assets/airbridge_logo.png`, and reapply platform settings so the iOS Podfile receives its 15.5 deployment target. They can be rerun to reapply Airbridge's platform settings. Existing native host folders are preserved; after a major Flutter template upgrade, back them up and regenerate/update them deliberately.

## 3. Passwordless QR pairing and optional shared secret

By default, pair devices from the dashboard: tap **Pair a device**, show the QR, scan it from the joining Android/iOS device (or copy/paste the QR text on desktop), compare the six-digit code on both screens, then confirm. The code is a short authentication string—not a password or a six-digit network credential. The QR contains a random 256-bit, single-use key; invitations expire after five minutes and lock after five invalid proofs. Each accepted device gets a distinct HMAC key, saved in the app's private support directory. Keep the QR private until pairing completes. Without a shared secret, only paired peers can authenticate mesh links, but message payloads are not encrypted on the LAN.

For AES-256-GCM payload encryption and shared-secret authentication of discovery, optionally use the same randomly generated value on every node in one mesh. Do not commit it to Git. Example for Bash:

```bash
export AIRBRIDGE_SHARED_SECRET="$(openssl rand -hex 32)"
```

PowerShell equivalent:

```powershell
$bytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
$env:AIRBRIDGE_SHARED_SECRET = -join ($bytes | ForEach-Object { $_.ToString('x2') })
$rng.Dispose()
```

Append `--dart-define=AIRBRIDGE_SHARED_SECRET=<32-byte-random-hex>` to any `flutter build` or `flutter run` command on every peer that should use payload encryption; omit it on every peer for QR-only pairing. It is embedded in the binary, so it is not a hardware-backed secret against someone who can extract the APK; use per-install provisioning/key management for higher assurance. HTTP request bodies to `/api/write` are still cleartext on the LAN before the node wraps them in an encrypted envelope, so call that endpoint only on a trusted subnet or add TLS at the transport boundary. When a shared secret is configured, it is used for legacy/shared-secret authentication; QR-paired per-device credentials are still available.

Unpaired mesh links and unsigned HTTP writes are rejected even when `AIRBRIDGE_SHARED_SECRET` is omitted. Discovery beacons without a shared secret advertise metadata without a signature; pairing is still required before a WebSocket mesh link is accepted.

## 4. Android APK

Bootstrap once, then from `airbridge_mobile/`:

```bash
flutter build apk --debug
adb devices
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Release APK with passwordless QR pairing (no build-time secret required):

```bash
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

For AES-256-GCM payload encryption, all peers must be built with the same secret:

```bash
flutter build apk --release --dart-define=AIRBRIDGE_SHARED_SECRET="$AIRBRIDGE_SHARED_SECRET"
```

To run directly on a connected device during development:

```bash
flutter run -d <device-id>
```

The manifest requests `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `WAKE_LOCK`, and optional camera access for QR scanning; it allows cleartext LAN HTTP and installs the native `WifiManager.MulticastLock` bridge. Allow the app through the Wi-Fi network's client-isolation/firewall settings. Some access points block client-to-client UDP broadcast regardless of app permissions.

## 5. Windows

Build on Windows after installing the Visual Studio workload listed above:

```powershell
cd airbridge_mobile
flutter build windows --release
```

The executable and required runtime files are under `build\windows\x64\runner\Release\`. Windows Defender Firewall may prompt for permission to accept inbound connections; allow Airbridge on the trusted private LAN profile.

## 6. Linux

On Debian/Ubuntu, for example:

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev
cd airbridge_mobile
flutter build linux --release
```

The bundle is under `build/linux/x64/release/bundle/`. Allow the configured TCP/UDP ports in the host firewall.

## 7. macOS

Build on macOS with Xcode and CocoaPods installed:

```bash
cd airbridge_mobile
flutter build macos --release
```

The app is under `build/macos/Build/Products/Release/`. macOS may ask for Local Network access; approve it. The bootstrap adds client/server network entitlements for the generated macOS sandbox profile.

## 8. iOS

Build only on macOS with Xcode/CocoaPods:

```bash
cd airbridge_mobile
flutter build ios --release --no-codesign
```

For a signed IPA, set a team in Xcode or provide normal Flutter signing options, then run:

```bash
flutter build ipa --release
```

Open `ios/Runner.xcworkspace` in Xcode to select the signing team and install on a device. iOS asks the user for Local Network permission. UDP broadcast/multicast discovery also requires Apple's `com.apple.developer.networking.multicast` entitlement to be enabled for the App ID and included in the provisioning profile; the bootstrap configures the entitlement file, but Apple approval/profile provisioning is an external prerequisite. The app is a foreground peer: iOS can suspend its sockets when backgrounded.

## 9. API smoke test

`/status` is public for discovery/diagnostics. Anonymous writes are rejected. Pair app devices through the QR flow; for direct HTTP writes from a trusted script, build the node with `AIRBRIDGE_SHARED_SECRET` and sign the exact request body bytes plus a timestamp and one-time nonce. The server accepts timestamps within 120 seconds and rejects a nonce replay:

```bash
BODY='{"payload":{"text":"hello from curl"}}'
TS=$(date +%s)
NONCE=$(openssl rand -hex 16)
SIG=$(printf '%s.%s.%s' "$TS" "$NONCE" "$BODY" | openssl dgst -sha256 -hmac "$AIRBRIDGE_SHARED_SECRET" | awk '{print $NF}')
curl -X POST "http://<node-ip>:8765/api/write" \
  -H 'Content-Type: application/json' \
  -H "X-Airbridge-Timestamp: $TS" \
  -H "X-Airbridge-Nonce: $NONCE" \
  -H "X-Airbridge-Signature: $SIG" \
  --data-binary "$BODY"
```

The WebSocket endpoint is `ws://<node-ip>:8765/ws`. The server first sends a random `challenge` frame. Reply with `{"type":"auth","deviceId":"<client-id>","signature":"<hex-hmac>"}`, where the signature is HMAC-SHA256 of `airbridge-ws-v1:<challenge-nonce>:<client-id>` under the configured installation-wide secret or the per-device key established by QR pairing. Unpaired IDs are rejected; there is no unsigned/open-LAN WebSocket mode. Then wait for `hello`; clients may send `{"type":"write","payload":...}`.

## Ports and network constraints

Defaults are TCP `8765` and UDP `47660`, configurable with `--dart-define=AIRBRIDGE_HTTP_PORT=...` and `--dart-define=AIRBRIDGE_UDP_PORT=...` (use the same UDP port across a LAN). Both listeners bind to `0.0.0.0`. UDP beacons advertise the service identifier `_airbridge._tcp.local.` and include the node's TCP port. Wi-Fi AP/client isolation, VPNs, host firewalls, iOS Local Network consent, and Android battery/background policies can prevent discovery or continuous availability.

## 10. Troubleshooting

### Peers do not appear

1. Put both devices on the same reachable LAN/subnet. Guest Wi-Fi, VPNs, and router/AP **client isolation** commonly block peer traffic.
2. Use the same UDP port (`47660` by default) on every peer and allow inbound UDP on that port. Also allow inbound TCP (`8765` by default) for API/WebSocket traffic.
3. If a shared secret is configured, rebuild **every peer** with the same `AIRBRIDGE_SHARED_SECRET`. Discovery beacons are authenticated; a mismatched key causes them to be ignored. Changing the environment variable does not alter an already-built app.
4. Scan the host device's one-time pairing QR and compare the six-digit verification code on both screens. Discovery can list unpaired devices, but they will not establish a mesh link. Keep the app open in the foreground while testing and check the dashboard's System log for startup or socket errors.

On Windows, inspect listeners from PowerShell:

```powershell
Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue
Get-NetUDPEndpoint -LocalPort 47660 -ErrorAction SilentlyContinue
Test-NetConnection <peer-ip> -Port 8765
```

If Windows Firewall blocks Airbridge, allow the app on the **Private** profile, or (from an elevated PowerShell prompt) add narrowly scoped rules:

```powershell
New-NetFirewallRule -DisplayName 'Airbridge TCP 8765' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8765 -Profile Private
New-NetFirewallRule -DisplayName 'Airbridge UDP 47660' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 47660 -Profile Private
```

For Linux with UFW, allow the corresponding ports with `sudo ufw allow 8765/tcp` and `sudo ufw allow 47660/udp`. On macOS, grant Local Network access and allow the app through the system firewall.

### `/status` works, but writes fail

* `401 Unauthorized`: direct HTTP writes require a valid HMAC. Check the exact body bytes, current Unix timestamp in seconds, a fresh nonce, and the configured shared secret; app-to-app HTTP writes must also identify a paired device. Requests older than 120 seconds, unpaired identities, and reused nonces are rejected. See the signed `curl` example above.
* `400 Bad Request`: send a JSON object with a `payload` field, for example `{"payload":{"text":"hello"}}`.
* `413 Payload Too Large`: the encoded payload exceeds `AIRBRIDGE_MAX_PAYLOAD_BYTES` (1 MiB by default). Increase it at build time only if needed; the supported range is 1 KiB to 16 MiB.
* `503 Service Unavailable`: the bounded worker queue, HTTP request capacity, or pending WebSocket-handshake limit is full. Retry shortly; repeated responses can indicate sustained load or an unauthenticated client flood.

### Port already in use / node fails to start

The dashboard log should show the bind error. On Windows, find the process using a port with `netstat -ano | findstr :8765` or `netstat -ano | findstr :47660`, then stop that process or rebuild with alternate ports, for example `--dart-define=AIRBRIDGE_HTTP_PORT=8766 --dart-define=AIRBRIDGE_UDP_PORT=47661`. Configure the same UDP port on every peer. Ports below 1024 are rejected.

### WebSocket does not connect

The client must connect to `ws://<peer-ip>:8765/ws`, read the server's first `challenge` frame, reply with the HMAC-authenticated `auth` frame described above, then wait for `hello`. Check that TCP `8765` is reachable and that the devices completed QR pairing, or that both were built with the same installation-wide secret. Unpaired peers are rejected.

### Android SDK is not found on Windows

Install Android Studio, open **Tools → SDK Manager**, and install Android SDK Platform-Tools, Android SDK Build-Tools, Android SDK Command-line Tools (latest), and at least one Android SDK Platform. The default SDK folder is `%LOCALAPPDATA%\Android\Sdk`. In PowerShell, configure Flutter and the environment (if Android Studio shows a different SDK Location, set `$sdk` to that path):

```powershell
$sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
if (-not (Test-Path $sdk)) { throw "Android SDK not found at $sdk. Check SDK Manager's SDK Location." }
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $sdk, 'User')
$env:ANDROID_HOME = $sdk
flutter config --android-sdk $sdk
flutter doctor --android-licenses
flutter doctor -v
```

Close and reopen PowerShell after setting the user environment variable. A message that newer package versions exist but are outside dependency constraints is informational; it is not the cause of an Android SDK error, and `flutter pub upgrade` is not required.

### Windows desktop target is not configured

From the `airbridge_mobile` project folder (the one containing `pubspec.yaml`), run the bootstrap once before building. It creates the native Windows runner and applies Airbridge's platform settings; Python 3 and Flutter must be installed first:

```powershell
.\tool\bootstrap_platforms.ps1
flutter build windows --release
```

If PowerShell says scripts are disabled, run `Set-ExecutionPolicy -Scope Process Bypass` in that PowerShell window and retry the script. Also install Visual Studio 2022's **Desktop development with C++** workload.

### Build command is unsupported on this host

This is expected when the target OS differs from the build host. Run `flutter build linux --release` from Linux (or a Linux Flutter installation inside WSL2), and run `flutter build macos --release` / `flutter build ios --release --no-codesign` from macOS with Xcode installed. A Windows Flutter installation cannot produce Linux, macOS, or iOS builds. On the target machine, check `flutter --version` (stable 3.24+ is required) and `flutter doctor -v` if Flutter still rejects the build-mode option.

### Platform-specific build problems

* **Windows:** confirm Visual Studio 2022's Desktop development with C++ workload is installed. If Flutter reports symlink permission errors, enable Windows Developer Mode and rerun the bootstrap script. Deploy the entire `build\windows\x64\runner\Release\` folder, not just the `.exe`.
* **Android:** if discovery stops when backgrounded, exempt the app from aggressive battery optimization while testing. The MulticastLock is acquired while the app runs, but this build does not install a persistent Android foreground service.
* **iOS:** grant Local Network permission. A configured entitlement file alone is insufficient for multicast; the App ID and provisioning profile must have Apple's multicast entitlement. Keep the app foregrounded.
* **Linux/macOS:** install the prerequisites in sections 1 and 6/7; on macOS, approve the Local Network prompt and use Xcode signing for a distributable app.
* **After dependency or Flutter changes:** from `airbridge_mobile/`, run `flutter clean`, `flutter pub get`, then rerun `tool/bootstrap_platforms.ps1` on Windows or `tool/bootstrap_platforms.sh` on Linux/macOS to reapply native configuration.
