# Build and deploy Airbridge Mobile

<p align="center">
  <img src="assets/airbridge_logo.png" alt="Official Airbridge logo" width="140">
</p>

## 1. Tools and platform requirements

### Required everywhere

* **Flutter stable SDK 3.38+**; it includes the matching **Dart 3.10+ SDK** required by the current file-picker dependency and desktop webcam scanner. Install Flutter once and add its `bin` folder to `PATH`.
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
| Windows installer `.exe` | Windows | Visual Studio 2022 with **Desktop development with C++**, MSVC C++ build tools, and a Windows 10/11 SDK. Install Inno Setup 6 to package the complete Flutter release folder into one installer executable. |
| Linux `.AppImage` | Linux x86_64 | `clang`, `cmake`, `ninja-build`, `pkg-config`, GTK 3 development headers, `patchelf`, `desktop-file-utils`, `xdg-utils` (for `xdg-mime` protocol registration), `curl`, `libfuse2`, ImageMagick, and a C++ standard library toolchain. The release packager downloads a pinned linuxdeploy AppImage and verifies its SHA-256 digest. |
| macOS `.dmg` | macOS | Xcode and CocoaPods. Xcode command-line tools must be selected and its license accepted. The current public DMG is unsigned and not notarized. |
| iOS 15.5+ app / `.ipa` | macOS only | Xcode and CocoaPods. Airbridge's camera-scanning dependency requires iOS 15.5 or newer; bootstrap applies that deployment target. An unsigned build needs no signing identity; device installation or a distributable IPA requires an Apple Developer signing team/profile. Airbridge's multicast discovery also needs Apple's multicast entitlement on the App ID/profile. |

For Debian/Ubuntu, install the Linux desktop packages with:

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev patchelf desktop-file-utils xdg-utils curl libfuse2 imagemagick
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

The generated native host projects are intentionally the standard Flutter templates. The bootstrap scripts generate them and apply the checked-in network/camera permissions, native bridge, Apple entitlements and URL declarations, plus Windows/Linux single-instance URL forwarding; they also install the official app icons.

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

Pair devices from the dashboard: tap **Pair a device**, show the QR, scan it from the joining Android/iOS device (or copy/paste the QR text on desktop), compare the six-digit code on both screens, then confirm. The code is a short authentication string—not a password or a six-digit network credential. The QR contains a random 256-bit, single-use key; invitations expire after five minutes and lock after five invalid proofs. Each accepted device gets a distinct pairwise credential saved in the app's private support directory. Keep the QR private until pairing completes. Paired messages, file metadata, file chunks, Bluetooth messages, and Bluetooth file chunks are encrypted with AES-256-GCM in transit by default; no build-time secret or encryption switch is required.

An installation-wide `AIRBRIDGE_SHARED_SECRET` remains optional. It can authenticate unpaired legacy/shared-secret mesh peers and sign discovery beacons, and it enables encryption of the local message spool at rest. Do not commit it to Git. Use the same randomly generated value on every node that participates in that shared-secret mode. Example for Bash:

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

Append `--dart-define=AIRBRIDGE_SHARED_SECRET=<32-byte-random-hex>` to `flutter run` or a build only when intentionally enabling shared-secret mode. The secret is embedded in the binary and is not hardware-backed; QR pairing is the recommended default. Transport payloads remain encrypted even when the define is omitted. HTTP/WS carry only sealed content plus non-secret routing metadata, but they are not TLS: IP addresses, timing, and discovery/status metadata remain visible on the LAN. Local message-spool encryption is optional and uses this shared secret; without it, message history is stored as JSON in the OS-private app directory. Incoming files are integrity-checked but are not encrypted at rest.

Unpaired writes and mesh links are rejected unless shared-secret mode is intentionally configured. Discovery beacons without a shared secret advertise metadata without a signature; they do not carry message/file contents.

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

QR-paired messages and file transfers are encrypted by default; this standard release build requires no shared-secret define. Only if intentionally enabling installation-wide shared-secret mode, build every participating peer with the same value:

```bash
flutter build apk --release --dart-define=AIRBRIDGE_SHARED_SECRET="$AIRBRIDGE_SHARED_SECRET"
```

To run directly on a connected device during development:

```bash
flutter run -d <device-id>
```

The manifest requests `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `WAKE_LOCK`, optional camera access, and Android Bluetooth permissions (legacy Bluetooth/location on older versions plus scan/connect/advertise on Android 12+); camera and BLE hardware are optional. It allows cleartext LAN HTTP/WebSocket while peer content itself is AES-GCM sealed, registers `airbridge://pair`, and installs the native `WifiManager.MulticastLock` and active Wi-Fi IPv4-address bridges. BLE permissions are requested when Bluetooth is enabled. Test a scheme launch with `adb shell am start -a android.intent.action.VIEW -d 'airbridge://pair?test=1'`; the app should open the pairing dialog and report that the test invitation is invalid. Allow the app through the Wi-Fi network's client-isolation/firewall settings. Some access points block client-to-client UDP broadcast regardless of app permissions.

## 5. Windows

Build on Windows after installing the Visual Studio workload listed above:

```powershell
cd airbridge_mobile
flutter build windows --release
```

The runner executable and its required runtime files are under `build\windows\x64\runner\Release\`; the `.exe` alone is not a usable portable download. To create a single installer executable, install Inno Setup 6 and run the packaging script with the app's `X.Y.Z` version:

```powershell
choco install innosetup --yes --no-progress
.\tool\package_windows_installer.ps1 -AppVersion 4.0.0 -OutputDirectory .\build\release
```

Replace `4.0.0` with the version in `pubspec.yaml`. The installer is `build\release\Airbridge-Windows-Setup-4.0.0.exe` and contains the entire Flutter `Release` folder. It registers the `airbridge://` URL protocol and removes that registration on uninstall. Test it after installation with `Start-Process 'airbridge://pair?test=1'`. For webcam scanning, choose the wired camera from the scanner's camera menu and enable **Settings → Privacy & security → Camera → Let desktop apps access your camera**. Windows Defender Firewall may prompt for permission to accept inbound connections; allow Airbridge on the trusted private LAN profile.

## 6. Linux

On Debian/Ubuntu, for example:

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev patchelf desktop-file-utils xdg-utils curl libfuse2 imagemagick bluez
cd airbridge_mobile
flutter build linux --release
```

The full Flutter bundle is under `build/linux/x64/release/bundle/`. Linux uses the BlueZ D-Bus backend to implement the same Airbridge GATT service and encrypted packet protocol used by the other supported platforms. Make sure the system D-Bus and BlueZ Bluetooth service are running, and power on an LE-capable adapter (check with `bluetoothctl show`; enable it with `bluetoothctl power on`). The app runs as the desktop user; do not run the GUI as root. To enable the service at boot, run `sudo systemctl enable --now bluetooth`. For central connections to dual-mode Apple BLE peers, BlueZ may require `ControllerMode = le` in `/etc/bluetooth/main.conf`; see Troubleshooting below.

To package a directly launchable x86_64 AppImage (no ZIP), run:

```bash
./tool/package_linux_appimage.sh ./build/release
```

The script downloads the pinned linuxdeploy tool, verifies its SHA-256 digest, and produces `build/release/Airbridge-Linux-x86_64.AppImage`. To register the custom scheme with the desktop environment (the AppImage itself is not automatically installed as the default URL handler), run:

```bash
chmod +x "$HOME/Downloads/Airbridge-Linux-x86_64.AppImage"
./tool/register_linux_url_scheme.sh "$HOME/Downloads/Airbridge-Linux-x86_64.AppImage"
xdg-open 'airbridge://pair?test=1'
```

Adjust the first command's path to where you saved the AppImage. The AppImage scanner lets you select a wired USB webcam. Ensure the camera is accessible as your desktop user; on systems that use the `video` group, run `sudo usermod -aG video "$USER"` and then sign out/in. Permit the configured TCP/UDP ports in the host firewall.

## 7. macOS

Build on macOS with Xcode and CocoaPods installed:

```bash
cd airbridge_mobile
flutter build macos --release
```

The app is under `build/macos/Build/Products/Release/`. Package it as a drag-to-Applications disk image with:

```bash
./tool/package_macos_dmg.sh ./build/release
```

The output is `build/release/Airbridge-macOS.dmg`. It is not code-signed or notarized yet. The bundle registers `airbridge://` and declares camera/network access; macOS may ask for Camera and Local Network permissions, which must be approved for QR scanning and peer connections. After copying Airbridge into Applications, test with `open 'airbridge://pair?test=1'`. The bootstrap adds client/server network and camera entitlements for the generated macOS sandbox profile.

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

Open `ios/Runner.xcworkspace` in Xcode to select the signing team and install on a device. The app registers the `airbridge://` scheme and declares its camera purpose string; iOS asks the user for Camera and Local Network permission when those features are first used. UDP broadcast/multicast discovery also requires Apple's `com.apple.developer.networking.multicast` entitlement to be enabled for the App ID and included in the provisioning profile; the bootstrap configures the entitlement file, but Apple approval/profile provisioning is an external prerequisite. The app is a foreground peer: iOS can suspend its sockets when backgrounded.

## 9. Versioned GitHub releases

Stable releases are published from matching `vMAJOR.MINOR.PATCH` tags on `main`; pre-releases may be published from matching `vMAJOR.MINOR.PATCH-label[.number...]` tags on an open PR head. GitHub Releases contain the separate native Android APK, Windows setup `.exe` (including the full Flutter runtime bundle), Linux x86_64 AppImage, macOS DMG, SHA-256 checksums, and signed provenance attestations—never a ZIP. CI and release runs upload the raw, unencrypted `Airbridge-All-Platforms.zip` as a seven-day Actions artifact; PR CI also includes an explicitly unsigned iOS `.app` archive for developer inspection. iOS requires Apple signing/profile setup and is never included as an installable public release. See [`docs/releasing.md`](../docs/releasing.md) for exact tag commands, package builds, installation, and checksum/attestation verification.

## 10. API smoke test

`GET /status` is public for discovery/diagnostics. Anonymous writes are rejected. To send an HTTP test message, first build the node with `AIRBRIDGE_SHARED_SECRET` and install the optional Python AES-GCM helper dependency:

```bash
python -m pip install cryptography
```

The following Python 3 example seals the JSON payload, signs the exact request bytes with a timestamp and one-time nonce, and receives only an acknowledgement (the message contents are never echoed in cleartext):

```python
import base64, hashlib, hmac, json, os, time, urllib.request
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

node = 'http://<node-ip>:8765'
secret = os.environ['AIRBRIDGE_SHARED_SECRET']
status = json.load(urllib.request.urlopen(node + '/status'))
recipient_id = status['deviceId']
sender_id = 'trusted-script-client'  # Shared-secret mode authenticates this with the same secret.
payload = {'text': 'hello from an encrypted client'}
key = hashlib.sha256(('airbridge-peer-aes-gcm-v1:' + secret).encode()).digest()
nonce = os.urandom(12)
aad = f'airbridge-http-write-v1:{sender_id}:{recipient_id}'.encode()
cleartext = json.dumps({'payload': payload, 'senderName': 'Python script'}, separators=(',', ':')).encode()
sealed = AESGCM(key).encrypt(nonce, cleartext, aad)
body = json.dumps({
    'version': 1, 'senderId': sender_id, 'recipientId': recipient_id,
    'sealed': {
        'algorithm': 'AES-256-GCM',
        'nonce': base64.b64encode(nonce).decode(),
        'ciphertext': base64.b64encode(sealed[:-16]).decode(),
        'mac': base64.b64encode(sealed[-16:]).decode(),
    },
}, separators=(',', ':')).encode()
timestamp = str(int(time.time()))
request_nonce = base64.urlsafe_b64encode(os.urandom(24)).decode().rstrip('=')
signed = f'{timestamp}.{request_nonce}.{sender_id}.'.encode() + body
signature = hmac.new(secret.encode(), signed, hashlib.sha256).hexdigest()
request = urllib.request.Request(node + '/api/write', data=body, headers={
    'Content-Type': 'application/json',
    'X-Airbridge-Device-Id': sender_id,
    'X-Airbridge-Timestamp': timestamp,
    'X-Airbridge-Nonce': request_nonce,
    'X-Airbridge-Signature': signature,
}, method='POST')
print(urllib.request.urlopen(request).read().decode())
```

For a production client without the installation-wide secret, use the pairwise credential established by QR pairing instead; do not extract or share another peer's key. HTTP signatures cover the device ID, exact body, timestamp, and one-time nonce. The server accepts a 120-second clock window and rejects replayed nonces.

The WebSocket endpoint is `ws://<node-ip>:8765/ws`. The server first sends a random `challenge` frame. Reply with `{"type":"auth","deviceId":"<client-id>","signature":"<hex-hmac>"}`, where the signature is HMAC-SHA256 of `airbridge-ws-v1:<challenge-nonce>:<client-id>` under the configured shared secret or the pairwise QR credential. Unpaired IDs are rejected unless shared-secret mode is configured. Then wait for `hello`. A client `write` frame must identify `senderId` and `recipientId` and contain an AES-256-GCM `sealed` object; its decrypted JSON has `payload` and optional `senderName`, and its associated data is `airbridge-ws-write-v1:<sender-id>:<recipient-id>`. Incoming mesh `message` frames use protocol version 2 and recipient-specific encrypted envelopes; cleartext frames are rejected.

## Ports and network constraints

Defaults are TCP `8765` and UDP `47660`, configurable with `--dart-define=AIRBRIDGE_HTTP_PORT=...` and `--dart-define=AIRBRIDGE_UDP_PORT=...` (use the same UDP port across a LAN). Both listeners bind to `0.0.0.0`. UDP beacons advertise the service identifier `_airbridge._tcp.local.` and include the node's TCP port. Wi-Fi AP/client isolation, VPNs, host firewalls, iOS Local Network consent, and Android battery/background policies can prevent discovery or continuous availability.

## 11. Troubleshooting

### Peers do not appear

1. Put both devices on the same reachable Wi-Fi/LAN/subnet. Mobile data alone cannot make a phone reachable from the PC; guest Wi-Fi, VPNs, and router/AP **client isolation** commonly block peer traffic. After changing networks, create a fresh QR so it contains the current address.
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

* `401 Unauthorized`: direct HTTP writes require both a valid HMAC and an AES-256-GCM sealed body. Check the exact body bytes, current Unix timestamp in seconds, fresh nonce, and shared or pairwise key; app-to-app HTTP writes must identify a paired device. Requests older than 120 seconds, invalid identities, cleartext bodies, and reused nonces are rejected. See the Python AES-GCM example above.
* `400 Bad Request`: the request must be a JSON object with version 1, `senderId`, this node's `recipientId`, and a valid `sealed` AES-256-GCM object. Do not send a cleartext `payload` directly.
* `413 Payload Too Large`: the encoded payload exceeds `AIRBRIDGE_MAX_PAYLOAD_BYTES` (1 MiB by default). Increase it at build time only if needed; the supported range is 1 KiB to 16 MiB.
* `503 Service Unavailable`: the bounded worker queue, HTTP request capacity, or pending WebSocket-handshake limit is full. Retry shortly; repeated responses can indicate sustained load or an unauthenticated client flood.

### File transfer fails or a received file is missing

Confirm the peer was QR-paired, **Accept files from paired peers** is enabled on the receiver, the sender's device is online, and the file fits the receiver's configured Settings limit (100 MiB default; 1 GiB maximum). Keep both apps open on a reachable LAN and ensure enough free disk space. Files become visible only after all encrypted chunks arrive and both the exact file length and SHA-256 digest validate; incomplete transfers stay hidden and can be cancelled/retried.

### Bluetooth scan or transfer fails

Enable Bluetooth in Settings on both devices, grant Bluetooth permissions, keep the Bluetooth tab open to scan, and pair the devices using the normal QR/six-digit flow first. Bluetooth LE is not Bluetooth Classic. Confirm both adapters support BLE. On Linux, check `systemctl is-active bluetooth`, `bluetoothctl show`, and `bluetoothctl power on`; Airbridge uses BlueZ over the system D-Bus for GATT advertising and receiving. If Linux central connections to dual-mode Apple peers fail, add `[General]` and `ControllerMode = le` to `/etc/bluetooth/main.conf`, then run `sudo systemctl restart bluetooth`. BlueStacks Bluetooth pass-through varies by emulator and host; the demonstrated BlueStacks-to-Windows connection should continue over Wi-Fi/LAN even when emulator BLE is unavailable.

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

This is expected when the target OS differs from the build host. Run `flutter build linux --release` from Linux (or a Linux Flutter installation inside WSL2), and run `flutter build macos --release` / `flutter build ios --release --no-codesign` from macOS with Xcode installed. A Windows Flutter installation cannot produce Linux, macOS, or iOS builds. On the target machine, check `flutter --version` (stable 3.38+ is required) and `flutter doctor -v` if Flutter still rejects the build-mode option.

### Platform-specific build problems

* **Windows:** confirm Visual Studio 2022's Desktop development with C++ workload is installed. If Flutter reports symlink permission errors, enable Windows Developer Mode and rerun the bootstrap script. Deploy the entire `build\windows\x64\runner\Release\` folder, not just the `.exe`.
* **Android:** if discovery stops when backgrounded, exempt the app from aggressive battery optimization while testing. The MulticastLock is acquired while the app runs, but this build does not install a persistent Android foreground service.
* **iOS:** grant Local Network permission. A configured entitlement file alone is insufficient for multicast; the App ID and provisioning profile must have Apple's multicast entitlement. Keep the app foregrounded.
* **Linux/macOS:** install the prerequisites in sections 1 and 6/7; on macOS, approve the Local Network prompt and use Xcode signing for a distributable app.
* **After dependency or Flutter changes:** from `airbridge_mobile/`, run `flutter clean`, `flutter pub get`, then rerun `tool/bootstrap_platforms.ps1` on Windows or `tool/bootstrap_platforms.sh` on Linux/macOS to reapply native configuration.
