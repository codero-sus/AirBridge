# Airbridge Mobile Node

<p align="center">
  <img src="assets/airbridge_logo.png" alt="Official Airbridge logo" width="160">
</p>

A single Flutter/Dart codebase for Android, iOS, Windows, Linux, and macOS. Flutter provides a native-rendered Material 3 UI; Dart's `dart:io` supplies real IPv4 UDP, HTTP, and WebSocket sockets without a separate embedded Python/Node runtime. CPU-heavy AES-GCM work and message-spool file operations run in bounded worker isolates, keeping the UI isolate responsive.

## Downloads and releases

Versioned, installable downloads will be published on the [GitHub Releases page](https://github.com/codero-sus/AirBridge/releases) after a matching release tag is pushed for a commit on `main`: Android APK, Windows installer `.exe`, Linux x86_64 AppImage, macOS DMG, and `SHA256SUMS.txt`. Release assets stay separate (no ZIPs); GitHub Actions runs additionally provide a seven-day `Airbridge-All-Platforms.zip` artifact containing the four downloads and checksums; pull-request CI also includes a clearly labeled, unsigned iOS `.app` archive for developer inspection. The Windows installer includes Flutter's adjacent runtime files rather than shipping only the runner executable. Releases are triggered only by matching `vMAJOR.MINOR.PATCH` tags on commits already merged into `main`; see [`docs/releasing.md`](../docs/releasing.md) for versioning, build, install, checksum, and provenance instructions. iOS remains unsigned; its CI-only archive is not installable and is never published as a public release package.

## Architecture

```text
lib/
  main.dart                         app bootstrap
  app.dart                          app lifecycle and theme
  config/node_config.dart           ports, identity, limits, shared secret
  models/                           peer and message records
  services/
    android_network_bridge.dart     Android WifiManager MulticastLock
    api_gateway.dart                HTTP endpoints, WebSocket mesh links
    discovery_service.dart          UDP broadcast beacons / failover
    node_controller.dart            orchestration, shared state, UI events
    pairing_service.dart            expiring QR invites, six-digit code, peer keys
    security.dart                   HMAC-SHA256 helpers
    task_worker.dart                bounded isolate queue, AES-GCM and spool
  ui/dashboard_page.dart            responsive dark dashboard
  ui/pairing_dialog.dart             QR display, camera scan, and manual paste
assets/airbridge_logo.png            official in-app and launcher icon source
platform_templates/                 native permissions/entitlement overlays
```

### Runtime behavior

* `GET /status` returns node identity, role, bound address/ports, and peer count.
* `POST /pair/claim` accepts a proof for the active, single-use QR invitation. Invitations expire after five minutes and lock after five bad proofs; the response carrying a per-device HMAC key is encrypted with AES-GCM under the high-entropy invitation key.
* `POST /api/write` accepts `{"payload": ...}` and returns a message envelope. Writes always require an HMAC signature: an installation-wide `AIRBRIDGE_SHARED_SECRET`, or a paired device ID plus its per-device key.
* `WS /ws` carries mesh messages. Every link uses a challenge and HMAC authentication. If no installation-wide secret is configured, only QR-paired devices can authenticate; discovered but unpaired devices cannot open mesh links.
* Pairing is available from the dashboard. Both devices must be on the same reachable Wi-Fi/LAN; mobile data alone, VPNs, guest Wi-Fi, and router client isolation can prevent the connection. If the network changes, create a fresh QR. One device shows the QR and six-digit verification code; the joining device scans it (or pastes the QR text), compares the same code, and confirms. The code is a short authentication string, not a six-digit password: the QR contains a one-time random 256-bit key, so no weak PIN is sent over the LAN. Android, iOS, and macOS use native camera scanning with retry and alternate-scanner controls. Windows and Linux can select a connected USB/wired webcam and decode QR frames locally; pasted QR text remains available as a manual fallback.
* Trusted peer keys are saved in the app's private support directory so pairing survives restarts. The file is protected by the operating-system user sandbox; hardware-backed secure-storage integration remains a separate hardening task.
* UDP heartbeat/beacons bind to `0.0.0.0:47660` and are sent to limited and per-interface directed broadcast addresses. With a configured shared secret, beacons are signed; otherwise they advertise discovery metadata only. The packet advertises the DNS-SD-compatible service identifier `_airbridge._tcp.local.`. This implementation deliberately uses UDP broadcast rather than claiming to publish a Bonjour/mDNS record.
* The master is the lexicographically lowest ID among the currently visible nodes. This is a deterministic, best-effort LAN election, **not** a consensus protocol; network partitions can temporarily elect more than one master.
* The dashboard restores up to 100 recent persisted messages (subject to an 8 MiB startup-read budget) in one background worker, and lets you search by sender/payload and copy the visible results as JSON. Message history remains bounded by the spool's 5,000-record / 256 MiB retention limits.
* Peer heartbeats refresh liveness without rebuilding the dashboard or re-running the full mesh-connection reconciliation loop; peer snapshots are sorted lazily and cached until peer metadata changes.
* AES-256-GCM is used for stored and forwarded payload envelopes when `AIRBRIDGE_SHARED_SECRET` is set. The AES key is `SHA-256("airbridge-aes-gcm-v1:" + secret)`; associated data binds the message ID and sender ID. Envelopes carry Base64 `nonce`, `ciphertext`, and `mac` fields. The same high-entropy secret on every node also authenticates discovery and legacy/shared-secret HTTP clients. QR pairing authenticates each peer individually but does not encrypt mesh payloads by itself; without `AIRBRIDGE_SHARED_SECRET`, payload data travels in cleartext over an authenticated WebSocket. `/api/write` request bodies themselves arrive over cleartext HTTP before wrapping; use only a trusted LAN or add TLS for that client-to-node hop.

### Pairing deep links and camera access

Pairing invitations use the `airbridge://pair?...` scheme and are opened by the app into its existing invitation-validation/join flow; they are never treated as arbitrary routes. Platform bootstrap registers the Android, iOS, and macOS scheme declarations and camera-purpose text. The Android manifest keeps local-network permissions, optional camera hardware, and cleartext LAN access, and the Windows installer registers the protocol in the user-visible Windows URL handler registry.

On Windows and Linux, open **Pair a device → Scan QR** to choose a webcam (including a wired USB webcam); frames are decoded locally. If scanning is unavailable, paste the copied one-time QR text. On mobile/macOS, grant camera access in system settings; the scan screen provides retry, camera switching, flashlight controls where supported, and an alternate scanning engine. On Windows, also enable **Settings → Privacy & security → Camera → Let desktop apps access your camera**. On Linux, grant your desktop user access to the webcam device (often through the `video` group; if needed run `sudo usermod -aG video "$USER"` and sign out/in).

The Linux AppImage contains an `x-scheme-handler/airbridge` desktop entry. To register it with your desktop environment, run:

```bash
chmod +x "$HOME/Downloads/Airbridge-Linux-x86_64.AppImage"
./airbridge_mobile/tool/register_linux_url_scheme.sh "$HOME/Downloads/Airbridge-Linux-x86_64.AppImage"
```

Replace the path with the actual location of the downloaded AppImage. The script installs a per-user launcher and makes it the default for `airbridge://` URLs; use `xdg-mime uninstall "${XDG_DATA_HOME:-$HOME/.local/share}/applications/airbridge.desktop"` to undo the registration. macOS registers its scheme when the app bundle is installed; the Windows installer registers it automatically.

## Prerequisites

Install Flutter 3.27+ (with Dart 3.6+) and the native toolchain for the platform you build. Airbridge's iOS camera-scanning plugin requires iOS 15.5 or newer; bootstrap applies that deployment target. On first checkout, run the platform bootstrap command in `build_instructions.md`; it generates the standard Flutter host projects, applies Android/iOS/macOS/Linux network, camera, and deep-link configuration, generates Android/iOS/macOS/Windows launcher icons, and sets the Linux window icon from the official logo asset. The Windows installer registers the custom URL scheme.

The app is intended to operate while foregrounded. Mobile operating systems can suspend sockets in the background. A production always-on Android deployment should add a user-visible Android foreground service; iOS does not permit an unrestricted always-on background server.
