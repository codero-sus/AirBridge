# Airbridge Mobile Node

A single Flutter/Dart codebase for Android, iOS, Windows, Linux, and macOS. Flutter provides a native-rendered Material 3 UI; Dart's `dart:io` supplies real IPv4 UDP, HTTP, and WebSocket sockets without a separate embedded Python/Node runtime. CPU-heavy AES-GCM work and message-spool file operations run in bounded worker isolates, keeping the UI isolate responsive.

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
platform_templates/                 native permissions/entitlement overlays
```

### Runtime behavior

* `GET /status` returns node identity, role, bound address/ports, and peer count.
* `POST /pair/claim` accepts a proof for the active, single-use QR invitation. Invitations expire after five minutes and lock after five bad proofs; the response carrying a per-device HMAC key is encrypted with AES-GCM under the high-entropy invitation key.
* `POST /api/write` accepts `{"payload": ...}` and returns a message envelope. Writes always require an HMAC signature: an installation-wide `AIRBRIDGE_SHARED_SECRET`, or a paired device ID plus its per-device key.
* `WS /ws` carries mesh messages. Every link uses a challenge and HMAC authentication. If no installation-wide secret is configured, only QR-paired devices can authenticate; discovered but unpaired devices cannot open mesh links.
* Pairing is available from the dashboard. One device shows the QR and six-digit verification code; the joining device scans it (or pastes the QR text), compares the same code, and confirms. The code is a short authentication string, not a six-digit password: the QR contains a one-time random 256-bit key, so no weak PIN is sent over the LAN. Android/iOS provide camera scanning; desktop can paste the copied QR text.
* Trusted peer keys are saved in the app's private support directory so pairing survives restarts. The file is protected by the operating-system user sandbox; hardware-backed secure-storage integration remains a separate hardening task.
* UDP heartbeat/beacons bind to `0.0.0.0:47660` and are sent to limited and per-interface directed broadcast addresses. With a configured shared secret, beacons are signed; otherwise they advertise discovery metadata only. The packet advertises the DNS-SD-compatible service identifier `_airbridge._tcp.local.`. This implementation deliberately uses UDP broadcast rather than claiming to publish a Bonjour/mDNS record.
* The master is the lexicographically lowest ID among the currently visible nodes. This is a deterministic, best-effort LAN election, **not** a consensus protocol; network partitions can temporarily elect more than one master.
* The dashboard restores up to 100 recent persisted messages (subject to an 8 MiB startup-read budget) in one background worker, and lets you search by sender/payload and copy the visible results as JSON. Message history remains bounded by the spool's 5,000-record / 256 MiB retention limits.
* Peer heartbeats refresh liveness without rebuilding the dashboard or re-running the full mesh-connection reconciliation loop; peer snapshots are sorted lazily and cached until peer metadata changes.
* AES-256-GCM is used for stored and forwarded payload envelopes when `AIRBRIDGE_SHARED_SECRET` is set. The AES key is `SHA-256("airbridge-aes-gcm-v1:" + secret)`; associated data binds the message ID and sender ID. Envelopes carry Base64 `nonce`, `ciphertext`, and `mac` fields. The same high-entropy secret on every node also authenticates discovery and legacy/shared-secret HTTP clients. QR pairing authenticates each peer individually but does not encrypt mesh payloads by itself; without `AIRBRIDGE_SHARED_SECRET`, payload data travels in cleartext over an authenticated WebSocket. `/api/write` request bodies themselves arrive over cleartext HTTP before wrapping; use only a trusted LAN or add TLS for that client-to-node hop.

## Prerequisites

Install Flutter 3.24+ (with Dart 3.5+) and the native toolchain for the platform you build. On first checkout, run the platform bootstrap command in `build_instructions.md`; it generates the standard Flutter host projects and installs this repository's Android/iOS/macOS platform configuration.

The app is intended to operate while foregrounded. Mobile operating systems can suspend sockets in the background. A production always-on Android deployment should add a user-visible Android foreground service; iOS does not permit an unrestricted always-on background server.
