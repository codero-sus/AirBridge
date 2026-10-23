# Airbridge

<p align="center">
  <img src="airbridge_mobile/assets/airbridge_logo.png" alt="Official Airbridge logo" width="180">
</p>

Airbridge Mobile is a Flutter/Dart implementation of an Airbridge LAN mesh node. The mobile/desktop application runs its own HTTP + WebSocket gateway, QR-based passwordless device pairing, UDP-broadcast peer discovery, optionally encrypted message spool, and responsive dashboard. The UI uses a persistent desktop sidebar and a mobile navigation drawer to separate the overview, messages, peers, and activity; the official logo appears in the app, mobile/desktop launcher icons, and Linux window icon.

The versioned GitHub Release publishes separate Android APK, Windows installer `.exe`, Linux AppImage, and macOS DMG downloads—with SHA-256 checksums and signed build-provenance attestations, but no ZIP Release asset. GitHub Actions runs also provide an `Airbridge-All-Platforms.zip` convenience artifact containing those four downloads and checksums; pull-request CI additionally includes a clearly labeled, unsigned iOS app archive for developer testing. See [`docs/releasing.md`](docs/releasing.md) for release triggers and verification; [`airbridge_mobile/README.md`](airbridge_mobile/README.md) for the architecture; [`airbridge_mobile/build_instructions.md`](airbridge_mobile/build_instructions.md) for Android, Windows, Linux, macOS, and iOS builds; and [`docs/improvement_roadmap.md`](docs/improvement_roadmap.md) for the phased improvement program.
