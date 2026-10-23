# Airbridge

<p align="center">
  <img src="airbridge_mobile/assets/airbridge_logo.png" alt="Official Airbridge logo" width="180">
</p>

Airbridge Mobile is a Flutter/Dart implementation of an Airbridge LAN mesh node. The mobile/desktop application runs its own HTTP + WebSocket gateway, QR-based passwordless device pairing, UDP-broadcast peer discovery, optionally encrypted message spool, and responsive dashboard. The official logo appears in the app, mobile/desktop launcher icons, and the Linux window icon.

The versioned GitHub Release workflow is configured to publish direct Android APK, Windows installer `.exe`, Linux AppImage, and macOS DMG downloads—no ZIP release assets—with SHA-256 checksums and signed build-provenance attestations after a versioned commit is merged to `main`. See [`docs/releasing.md`](docs/releasing.md) for the release trigger, verification commands, and local packaging steps; [`airbridge_mobile/README.md`](airbridge_mobile/README.md) for the architecture; [`airbridge_mobile/build_instructions.md`](airbridge_mobile/build_instructions.md) for Android, Windows, Linux, macOS, and iOS builds; and [`docs/improvement_roadmap.md`](docs/improvement_roadmap.md) for the phased improvement program.
