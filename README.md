# Airbridge

<p align="center">
  <img src="airbridge_mobile/assets/airbridge_logo.png" alt="Official Airbridge logo" width="180">
</p>

Airbridge Mobile is a Flutter/Dart implementation of an Airbridge LAN mesh node. The mobile/desktop application runs its own HTTP + WebSocket gateway, QR-based passwordless device pairing, UDP-broadcast peer discovery, AES-256-GCM-encrypted message/file transfers, and a responsive Material 3 dashboard. It includes Files, Bluetooth LE, Troubleshooting, Docs, and Settings sections; the official logo appears in the app, mobile/desktop launcher icons, and Linux window icon. LAN connectivity preserves the verified BlueStacks-to-Windows pairing flow.

Stable GitHub Releases are published from matching version tags on `main`; pre-releases can be created from an open PR head. Releases contain separate Android APK, Windows installer `.exe`, Linux AppImage, and macOS DMG downloads—with SHA-256 checksums and signed build-provenance attestations, but no ZIP asset. Official builds check the pre-release update channel in the background and install verified desktop updates without dialogs when the app folder is writable. Android and iOS remain subject to OS-managed install requirements; the app does not open a mobile install prompt. GitHub Actions runs provide the raw, unencrypted `Airbridge-All-Platforms.zip` as a convenience artifact; pull-request CI additionally includes a clearly labeled, unsigned iOS app archive for developer testing. See [`docs/releasing.md`](docs/releasing.md) for release triggers and verification; [`airbridge_mobile/README.md`](airbridge_mobile/README.md) for the architecture; [`airbridge_mobile/build_instructions.md`](airbridge_mobile/build_instructions.md) for Android, Windows, Linux, macOS, and iOS builds; and [`docs/improvement_roadmap.md`](docs/improvement_roadmap.md) for the phased improvement program.

## Credits

Created by [@codero-sus on GitHub](https://github.com/codero-sus).

- Website: [the-codero.web.app](https://the-codero.web.app)
- Website: [codero.is-a.dev](https://codero.is-a.dev)
