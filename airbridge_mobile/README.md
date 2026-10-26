# Airbridge Mobile Node

<p align="center">
  <img src="assets/airbridge_logo.png" alt="Official Airbridge logo" width="160">
</p>

A single Flutter/Dart codebase for Android, iOS, Windows, Linux, and macOS. Flutter provides a native-rendered Material 3 UI; Dart's `dart:io` supplies real IPv4 UDP, HTTP, and WebSocket sockets without a separate embedded Python/Node runtime. Local message-spool AES-GCM work and spool file operations run in bounded worker isolates. Peer transport uses per-peer AES-GCM; large files are encrypted and written in bounded chunks.

## Downloads and releases

Stable downloads are published on the [GitHub Releases page](https://github.com/codero-sus/AirBridge/releases) from matching `vMAJOR.MINOR.PATCH` tags on `main`; pre-releases use `vMAJOR.MINOR.PATCH-label[.number...]` tags on the head of an open PR. Both publish separate native assets—Android APK, full Windows installer `.exe`, Linux x86_64 AppImage, macOS DMG, and `SHA256SUMS.txt`—with no ZIP Release assets. GitHub Actions provides the raw, unencrypted `Airbridge-All-Platforms.zip` as a seven-day artifact; PR CI also includes an explicitly unsigned iOS `.app` archive for developer inspection. iOS is not published as a public installable package. See [`docs/releasing.md`](../docs/releasing.md) for versioning, builds, install, checksum, and provenance instructions.

## Architecture

```text
lib/
  main.dart                         app bootstrap
  app.dart                          app lifecycle and theme
  config/node_config.dart           ports, identity, limits, shared secret
  models/                           peer and message records
  services/
    android_network_bridge.dart     Android WifiManager MulticastLock
    api_gateway.dart                HTTP endpoints, encrypted WebSocket and file transport
    bluetooth_packet_assembler.dart shared bounded BLE packet framing/reassembly
    bluetooth_transfer_service.dart cross-platform BLE scanning and encrypted transfers
    linux_ble_peripheral.dart       BlueZ GATT advertiser/receiver for Linux
    discovery_service.dart         UDP broadcast beacons / failover
    file_transfer_store.dart        bounded receive storage, hashes, and file history
    node_controller.dart            orchestration, shared state, UI events
    pairing_service.dart            expiring QR invites, six-digit code, peer keys
    security.dart                   HMAC-SHA256 and AES-256-GCM transport helpers
    settings_store.dart             persistent device and receive preferences
    update_service.dart             pre-release checks, checksum verification, and desktop updater
    task_worker.dart                bounded isolate queue, AES-GCM and message spool
  ui/dashboard_page.dart            responsive Material 3 dashboard sections
  ui/pairing_dialog.dart             QR display, camera scan, and manual paste
assets/airbridge_logo.png            official in-app and launcher icon source
platform_templates/                 native permissions/entitlement overlays
```

### Runtime behavior

* `GET /status` returns node identity, role, bound address/ports, and peer count.
* `POST /pair/claim` accepts a proof for the active, single-use QR invitation. Invitations expire after five minutes and lock after five bad proofs; the response carrying a per-device HMAC key is encrypted with AES-GCM under the high-entropy invitation key.
* `POST /api/write` accepts a versioned AES-256-GCM-sealed payload and returns only an acknowledgement/message ID (not the message body). Every write is HMAC-signed with the trusted peer's QR-paired key or an installation-wide `AIRBRIDGE_SHARED_SECRET`; cleartext and replayed writes are rejected.
* `POST /api/files/start`, `/api/files/chunk`, `/api/files/complete`, and `/api/files/cancel` implement authenticated, encrypted, ordered file transfer. Metadata and every chunk use AES-256-GCM with transfer-specific associated data; the receiver verifies the announced length and SHA-256 digest before listing a file.
* `WS /ws` carries mesh messages. Every link uses a challenge and HMAC authentication, and message envelopes are encrypted separately for each recipient with AES-256-GCM. If no installation-wide secret is configured, only QR-paired devices can authenticate; discovered but unpaired devices cannot open mesh links.
* **Files** supports selecting a local file, sending it to a trusted LAN peer, receiving it into the app's private data folder, Save As export, and copying a saved path/folder. Settings lets the user reject incoming transfers and set a 1 MiB–1 GiB receive cap (100 MiB default); the receiver verifies ordered chunks, length, and SHA-256 before exposing the file.
* **Bluetooth LE** is an optional transport for encrypted messages and files. Both devices must first be trusted through the existing QR/six-digit flow. Android, iOS, macOS, Windows, and Linux use the same Airbridge GATT service and encrypted packet protocol. Linux peripheral advertising/receiving is implemented with a BlueZ-backed GATT server; universal_ble continues to provide the central/client transport. Linux requires BlueZ, a running system D-Bus/Bluetooth service, and a powered LE-capable adapter. BlueZ may need `ControllerMode = le` to connect reliably to dual-mode Apple BLE peers. As on every OS, the adapter and system permissions must allow BLE operation. BlueStacks BLE passthrough varies by emulator/host configuration; the already verified BlueStacks-to-Windows LAN pairing continues to use Wi-Fi/LAN.
* The dashboard provides visible **Troubleshooting**, **Docs**, and **Settings** sections alongside Overview, Messages, Peers, Files, Bluetooth, and Activity. Settings persist device name, Bluetooth enablement, incoming-file acceptance, and receive limit.
* Tagged GitHub builds check the pre-release channel in the background, validate desktop packages against the release SHA-256 manifest, and apply updates on the next launch without an app dialog. Windows per-user installs, writable macOS app bundles, and the Linux AppImage can self-update; Android sideloads and iOS require OS-managed installation and are never silently prompted from the app.
* Pairing is available from the dashboard. Both devices must be on the same reachable Wi-Fi/LAN; mobile data alone, VPNs, guest Wi-Fi, and router client isolation can prevent the connection. If the network changes, create a fresh QR. One device shows the QR and six-digit verification code; the joining device scans it (or pastes the QR text), compares the same code, and confirms. The code is a short authentication string, not a six-digit password: the QR contains a one-time random 256-bit key, so no weak PIN is sent over the LAN. Android, iOS, and macOS use native camera scanning with retry and alternate-scanner controls. Windows and Linux can select a connected USB/wired webcam and decode QR frames locally; pasted QR text remains available as a manual fallback.
* Trusted peer keys are saved in the app's private support directory so pairing survives restarts. The file is protected by the operating-system user sandbox; hardware-backed secure-storage integration remains a separate hardening task.
* UDP heartbeat/beacons bind to `0.0.0.0:47660` and are sent to limited and per-interface directed broadcast addresses. With a configured shared secret, beacons are signed; otherwise they advertise discovery metadata only. The packet advertises the DNS-SD-compatible service identifier `_airbridge._tcp.local.`. This implementation deliberately uses UDP broadcast rather than claiming to publish a Bonjour/mDNS record.
* The master is the lexicographically lowest ID among the currently visible nodes. This is a deterministic, best-effort LAN election, **not** a consensus protocol; network partitions can temporarily elect more than one master.
* The dashboard restores up to 100 recent persisted messages (subject to an 8 MiB startup-read budget) in one background worker, and lets you search by sender/payload and copy the visible results as JSON. Message history remains bounded by the spool's 5,000-record / 256 MiB retention limits.
* Peer heartbeats refresh liveness without rebuilding the dashboard or re-running the full mesh-connection reconciliation loop; peer snapshots are sorted lazily and cached until peer metadata changes.
* Content encryption in transit is mandatory for paired-peer messages, file metadata, and file chunks—even when `AIRBRIDGE_SHARED_SECRET` is omitted. Each recipient link uses its pairwise QR credential (or the configured high-entropy shared secret) to derive a domain-separated AES-256-GCM key; Base64 `nonce`, `ciphertext`, and `mac` values are bound to sender, recipient, and transfer/message context. Cleartext WebSocket messages and writes are rejected. HMAC-SHA256 authenticates peer handshakes and signed HTTP requests; timestamped one-time nonces prevent HTTP replay.
* The listener still uses HTTP/WebSocket on the local network, not TLS: encrypted content stays confidential and authenticated, but network observers can see connection metadata such as peer IPs, timing, and unencrypted discovery/status fields. UDP beacons and `/status` intentionally expose discovery metadata. Local message-spool encryption remains optional via `AIRBRIDGE_SHARED_SECRET`; without it, received/local history is stored as JSON in the OS-private application directory. Received files are SHA-256-verified, but are not encrypted at rest.

### Pairing deep links and camera access

Pairing invitations use the `airbridge://pair?...` scheme and are opened by the app into its existing invitation-validation/join flow; they are never treated as arbitrary routes. Platform bootstrap registers the Android, iOS, and macOS scheme declarations, camera/Bluetooth usage descriptions, and the macOS Bluetooth entitlement. The Android manifest keeps the required local-network/multicast permissions, optional camera and BLE hardware, BLE runtime permissions, and cleartext LAN access; Android startup also acquires `WifiManager.MulticastLock`. The Windows installer registers the protocol in the user-visible Windows URL handler registry.

On Windows and Linux, open **Pair a device → Scan QR** to choose a webcam (including a wired USB webcam); frames are decoded locally. If scanning is unavailable, paste the copied one-time QR text. On mobile/macOS, grant camera access in system settings; the scan screen provides retry, camera switching, flashlight controls where supported, and an alternate scanning engine. On Windows, also enable **Settings → Privacy & security → Camera → Let desktop apps access your camera**. On Linux, grant your desktop user access to the webcam device (often through the `video` group; if needed run `sudo usermod -aG video "$USER"` and sign out/in).

The Linux AppImage contains an `x-scheme-handler/airbridge` desktop entry. To register it with your desktop environment, run:

```bash
chmod +x "$HOME/Downloads/Airbridge-Linux-x86_64.AppImage"
./airbridge_mobile/tool/register_linux_url_scheme.sh "$HOME/Downloads/Airbridge-Linux-x86_64.AppImage"
```

Replace the path with the actual location of the downloaded AppImage. The script installs a per-user launcher and makes it the default for `airbridge://` URLs; use `xdg-mime uninstall "${XDG_DATA_HOME:-$HOME/.local/share}/applications/airbridge.desktop"` to undo the registration. macOS registers its scheme when the app bundle is installed; the Windows installer registers it automatically.

## Prerequisites

Install Flutter 3.38+ (with Dart 3.10+) and the native toolchain for the platform you build. Airbridge's iOS camera-scanning plugin requires iOS 15.5 or newer; bootstrap applies that deployment target. On first checkout, run the platform bootstrap command in `build_instructions.md`; it generates the standard Flutter host projects, applies Android networking/multicast/BLE permissions and iOS/macOS network, camera, Bluetooth, and deep-link configuration, generates Android/iOS/macOS/Windows launcher icons, and sets the Linux window icon from the official logo asset. The Windows installer registers the custom URL scheme.

The app is intended to operate while foregrounded. Mobile operating systems can suspend sockets in the background. A production always-on Android deployment should add a user-visible Android foreground service; iOS does not permit an unrestricted always-on background server.

## Credits

Created by [@codero-sus on GitHub](https://github.com/codero-sus).

- Website: [the-codero.web.app](https://the-codero.web.app)
- Website: [codero.is-a.dev](https://codero.is-a.dev)
