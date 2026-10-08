# Build and deploy Airbridge Mobile

## 1. Toolchains

* Flutter **3.24 or newer** and its matching Dart SDK (Dart 3.5+).
* Android: Android SDK/platform tools and a JDK supported by the installed Flutter SDK.
* Windows: build on Windows with Visual Studio 2022 and the **Desktop development with C++** workload.
* Linux: build on Linux with `clang`, `cmake`, `ninja-build`, GTK 3 development headers, and `pkg-config`.
* macOS/iOS: build on macOS with Xcode and CocoaPods. An iOS device/App Store build additionally needs a valid Apple signing team/profile.

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

The scripts generate standard Flutter host projects in a temporary directory, copy in only missing native platform folders (so they cannot overwrite `lib/` or `pubspec.yaml`), apply the checked-in permissions/native bridge/Apple network entitlements, then run `flutter pub get`. They can be rerun to reapply Airbridge's platform settings. Existing native host folders are preserved; after a major Flutter template upgrade, back them up and regenerate/update them deliberately.

## 3. Shared mesh secret (recommended)

Use the same randomly generated value on every node in one mesh. Do not commit it to Git. Example for Bash:

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

Pass it at build time. The secret encrypts message envelopes and authenticates discovery, WebSocket handshakes, and signed HTTP writes. It is embedded in the binary, so it is not a hardware-backed secret against someone who can extract the APK; use per-install provisioning/key management for higher assurance. HTTP request bodies to `/api/write` are still cleartext on the LAN before the node wraps them in an encrypted envelope, so call that endpoint only on a trusted subnet or add TLS at the transport boundary.

For a quick open-LAN development build, omit the define. In that mode payload data, discovery beacons, and WebSocket links are unauthenticated/unencrypted. Do not use open-LAN mode on an untrusted network.

## 4. Android APK

Bootstrap once, then from `airbridge_mobile/`:

```bash
flutter build apk --debug
adb devices
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Release APK (all peers must use the same secret):

```bash
flutter build apk --release --dart-define=AIRBRIDGE_SHARED_SECRET="$AIRBRIDGE_SHARED_SECRET"
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

To run directly on a connected device during development:

```bash
flutter run -d <device-id> --dart-define=AIRBRIDGE_SHARED_SECRET="$AIRBRIDGE_SHARED_SECRET"
```

The manifest requests `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, and `WAKE_LOCK`, allows cleartext LAN HTTP, and installs the native `WifiManager.MulticastLock` bridge. Allow the app through the Wi-Fi network's client-isolation/firewall settings. Some access points block client-to-client UDP broadcast regardless of app permissions.

## 5. Windows

Build on Windows after installing the Visual Studio workload listed above:

```powershell
cd airbridge_mobile
flutter build windows --release --dart-define=AIRBRIDGE_SHARED_SECRET="$env:AIRBRIDGE_SHARED_SECRET"
```

The executable and required runtime files are under `build\windows\x64\runner\Release\`. Windows Defender Firewall may prompt for permission to accept inbound connections; allow Airbridge on the trusted private LAN profile.

## 6. Linux

On Debian/Ubuntu, for example:

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev
cd airbridge_mobile
flutter build linux --release --dart-define=AIRBRIDGE_SHARED_SECRET="$AIRBRIDGE_SHARED_SECRET"
```

The bundle is under `build/linux/x64/release/bundle/`. Allow the configured TCP/UDP ports in the host firewall.

## 7. macOS

Build on macOS with Xcode and CocoaPods installed:

```bash
cd airbridge_mobile
flutter build macos --release --dart-define=AIRBRIDGE_SHARED_SECRET="$AIRBRIDGE_SHARED_SECRET"
```

The app is under `build/macos/Build/Products/Release/`. macOS may ask for Local Network access; approve it. The bootstrap adds client/server network entitlements for the generated macOS sandbox profile.

## 8. iOS

Build only on macOS with Xcode/CocoaPods:

```bash
cd airbridge_mobile
flutter build ios --release --no-codesign --dart-define=AIRBRIDGE_SHARED_SECRET="$AIRBRIDGE_SHARED_SECRET"
```

For a signed IPA, set a team in Xcode or provide normal Flutter signing options, then run:

```bash
flutter build ipa --release --dart-define=AIRBRIDGE_SHARED_SECRET="$AIRBRIDGE_SHARED_SECRET"
```

Open `ios/Runner.xcworkspace` in Xcode to select the signing team and install on a device. iOS asks the user for Local Network permission. UDP broadcast/multicast discovery also requires Apple's `com.apple.developer.networking.multicast` entitlement to be enabled for the App ID and included in the provisioning profile; the bootstrap configures the entitlement file, but Apple approval/profile provisioning is an external prerequisite. The app is a foreground peer: iOS can suspend its sockets when backgrounded.

## 9. API smoke test

Without a configured secret:

```bash
curl http://<node-ip>:8765/status
curl -X POST http://<node-ip>:8765/api/write \
  -H 'Content-Type: application/json' \
  -d '{"payload":{"text":"hello from curl"}}'
```

When built with a shared secret, sign the exact request body bytes plus a timestamp and one-time nonce. The server accepts timestamps within 120 seconds and rejects a nonce replay:

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

The WebSocket endpoint is `ws://<node-ip>:8765/ws`. The server first sends a random `challenge` frame. Reply with `{"type":"auth","deviceId":"<client-id>","signature":"<hex-hmac>"}`, where the signature is HMAC-SHA256 of `airbridge-ws-v1:<challenge-nonce>:<client-id>`. Then wait for `hello`; clients may send `{"type":"write","payload":...}`.

## Ports and network constraints

Defaults are TCP `8765` and UDP `47660`, configurable with `--dart-define=AIRBRIDGE_HTTP_PORT=...` and `--dart-define=AIRBRIDGE_UDP_PORT=...` (use the same UDP port across a LAN). Both listeners bind to `0.0.0.0`. UDP beacons advertise the service identifier `_airbridge._tcp.local.` and include the node's TCP port. Wi-Fi AP/client isolation, VPNs, host firewalls, iOS Local Network consent, and Android battery/background policies can prevent discovery or continuous availability.
