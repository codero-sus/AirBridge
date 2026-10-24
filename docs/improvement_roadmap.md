# AirBridge improvement program

The `777+` request is being treated as a multi-release engineering program, not as a claim that hundreds of untested changes can safely ship in one patch. The initial backlog listed 100 concrete work items across reliability, security, dashboard/diagnostics, and build/release; subsequent QR-pairing, versioned-release, navigation/artifact-discoverability, and encrypted-transfer waves extend it to 121. Checked items are implemented and verified; unchecked items remain planned. Later waves should add acceptance tests and preserve backward compatibility before landing.

## Wave 1 — Reliability and secure-input baseline (001–020)

- [x] **001** Add bounded exponential retry delays for outbound peer links.
- [x] **002** Add random jitter to reconnect delays to avoid synchronized retry bursts.
- [x] **003** Clear retry state when a peer changes address, expires, or the gateway stops.
- [x] **004** Bound simultaneous non-WebSocket HTTP request handlers and return `503` on overload.
- [x] **005** Bound unauthenticated WebSocket handshakes and release the slot after authentication.
- [x] **006** Reject message envelopes with unsupported protocol versions.
- [x] **007** Reject malformed non-hex HMAC values before digest comparison.
- [x] **008** Accept valid upper- or lower-case hexadecimal HMAC encodings.
- [x] **009** Serialize system log entries as stable UTC JSON records.
- [x] **010** Add a dashboard action to copy recent system logs as JSON.
- [x] **011** Add a retry action when node startup fails.
- [x] **012** Unit-test reconnect backoff growth, cap, and jitter bounds.
- [x] **013** Integration-test the unauthenticated WebSocket handshake limit.
- [x] **014** Integration-test rejection of unknown message-envelope versions.
- [x] **015** Test system-log JSON serialization.
- [x] **016** Build an Android release APK in CI in addition to the debug APK.
- [x] **017** Publish the CI release APK as a short-retention build artifact.
- [ ] **018** Add overload tests for bounded HTTP request capacity.
- [ ] **019** Add observable counters for active requests, handshakes, retries, and queue pressure.
- [ ] **020** Add a node-startup retry widget test covering port conflicts and recovery.

## Wave 2 — Discovery and mesh resilience (021–040)

- [ ] **021** Re-enumerate broadcast interfaces after network changes.
- [ ] **022** Prefer the active Wi-Fi interface over VPN and virtual adapters.
- [ ] **023** Add interface names and selected broadcast targets to diagnostics.
- [ ] **024** Add configurable discovery jitter while retaining a bounded heartbeat interval.
- [ ] **025** Test discovery across `/24`, `/20`, and point-to-point subnets.
- [ ] **026** Test stale, future-dated, malformed, and replayed beacon handling.
- [ ] **027** Sanitize peer names before logging and displaying them.
- [ ] **028** Validate peer identifiers against a documented character set.
- [ ] **029** Detect duplicate device IDs advertising from different addresses.
- [ ] **030** Add an explicit peer state model for discovered, connecting, linked, and stale.
- [ ] **031** Track last successful link time independently from last beacon time.
- [ ] **032** Add connection-attempt timeouts and reason codes to peer state.
- [ ] **033** Add deterministic retry tests for refused, timed-out, and reset sockets.
- [ ] **034** Reset retry state after a stable-connection interval, not only at handshake success.
- [ ] **035** Add bounded parallel dial scheduling for large peer sets.
- [ ] **036** Prevent stale async dials from attaching after stop/restart generations.
- [ ] **037** Reconcile peer links after Wi-Fi handoff without waiting for a full peer timeout.
- [ ] **038** Expose a manual rediscovery action in the dashboard.
- [ ] **039** Add simulated packet-loss and duplicate-beacon integration tests.
- [ ] **040** Document router isolation, VPN, firewall, and subnet diagnostics with concrete checks.

## Wave 3 — Security and protocol hardening (041–060)

- [ ] **041** Document a versioned envelope schema and compatibility policy.
- [ ] **042** Enforce required envelope fields and field-size bounds at every ingress point.
- [ ] **043** Validate AES-GCM nonce and authentication-tag lengths before decoding.
- [ ] **044** Reject payloads whose decoded size exceeds the configured limit.
- [ ] **045** Add adversarial JSON, deep-nesting, and invalid UTF-8 tests.
- [ ] **046** Add per-address throttling for repeated failed WebSocket authentication.
- [ ] **047** Add a bounded cooldown for repeated bad HTTP signatures.
- [ ] **048** Separate authentication failures from transport failures in logs.
- [ ] **049** Prevent secrets and authorization headers from entering logs or exports.
- [ ] **050** Add a documented high-entropy shared-secret generation command per shell.
- [ ] **051** Add an explicit UI security-mode warning with a link to setup guidance.
- [ ] **052** Add key rotation guidance and a safe multi-key transition format.
- [ ] **053** Evaluate platform secure storage for per-install secrets.
- [ ] **054** Add an optional TLS termination profile for HTTP/WebSocket clients.
- [ ] **055** Add certificate validation and hostname-mismatch tests if TLS is introduced.
- [ ] **056** Add replay-window tests at the exact timestamp boundaries.
- [ ] **057** Bound nonce-cache memory and verify expiration under sustained traffic.
- [ ] **058** Review challenge randomness, signature encoding, and comparison behavior.
- [ ] **059** Add a protocol security review checklist to pull requests.
- [ ] **060** Publish a threat model covering LAN attackers, compromised peers, and extracted app secrets.

## Wave 4 — Dashboard, onboarding, and accessibility (061–080)

- [ ] **061** Add an onboarding checklist for first launch and host permissions.
- [ ] **062** Explain why a peer is discovered but not yet WebSocket-linked.
- [ ] **063** Show actionable guidance for port conflicts and permission failures.
- [ ] **064** Add a live node-state panel with address, ports, role, and uptime.
- [ ] **065** Add filters for log level, peer ID, and time range.
- [ ] **066** Add log search and a clear-log action with confirmation.
- [ ] **067** Add message-history export with size and privacy warnings.
- [ ] **068** Add pagination or virtualized rendering for larger histories.
- [ ] **069** Add accessible labels for connection state and peer status indicators.
- [ ] **070** Support keyboard navigation and visible focus states on desktop.
- [ ] **071** Check text contrast in light and dark themes.
- [ ] **072** Respect system text scaling and narrow-screen layouts.
- [ ] **073** Add localized date/time formatting and copyable UTC timestamps.
- [ ] **074** Add a confirmation step before clearing persisted message history.
- [ ] **075** Show queue-full and payload-too-large errors without raw stack traces.
- [ ] **076** Add a copyable sanitized diagnostics bundle separate from message contents.
- [ ] **077** Add screen-reader announcements for node lifecycle transitions.
- [ ] **078** Add widget tests for empty, loading, error, and high-density peer states.
- [ ] **079** Add a settings view for display name and non-secret network options.
- [ ] **080** Add a safe secret-entry flow that never displays or exports the secret.

## Wave 5 — Storage, delivery, and performance (081–100)

- [ ] **081** Define message delivery guarantees and expose local acceptance separately from peer delivery.
- [ ] **082** Add delivery acknowledgements with bounded retry and duplicate suppression.
- [ ] **083** Persist a stable outbox state for messages queued while peers are offline.
- [ ] **084** Add explicit retention and purge controls for message history.
- [ ] **085** Make spool pruning incremental instead of rescanning the full directory per write.
- [ ] **086** Add crash-recovery tests for temporary files and partial writes.
- [ ] **087** Add filesystem quota and low-storage diagnostics.
- [ ] **088** Add migration/version metadata for stored envelopes.
- [ ] **089** Add corruption counts and recovery summaries to startup diagnostics.
- [ ] **090** Add load tests for maximum message size, queue saturation, and 5,000-record history.
- [ ] **091** Benchmark isolate startup, encryption throughput, and dashboard rebuild costs.
- [ ] **092** Reduce repeated JSON encoding for envelopes forwarded to multiple peers.
- [ ] **093** Add bounded batching for disk writes where it preserves durability.
- [ ] **094** Verify UI frame responsiveness under sustained inbound message traffic.
- [ ] **095** Add large-peer-set benchmarks for discovery and connection reconciliation.
- [ ] **096** Add memory budgets and regression thresholds to CI.
- [ ] **097** Test deterministic cleanup after cancellation and app lifecycle transitions.
- [ ] **098** Add a compatibility matrix for Android, iOS, Windows, Linux, and macOS.
- [ ] **099** Add platform-native code signing and notarization (Authenticode, Play signing, and Apple notarization); SHA-256 verification and signed GitHub provenance are delivered in Wave 7, but platform credentials are not configured.
- [ ] **100** Review the roadmap after each release and expand the next wave with measured, non-duplicative tasks.

## Wave 6 — Passwordless QR pairing (101–107)

- [x] **101** Add five-minute, single-use QR pairing invitations with a random 256-bit key.
- [x] **102** Display a six-digit short authentication string for out-of-band code comparison.
- [x] **103** Derive per-device HMAC credentials and encrypt the pairing response with AES-GCM.
- [x] **104** Persist trusted peers and require their credentials for mesh links when no shared secret is configured.
- [x] **105** Add camera QR scanning on Android/iOS and a copy/paste fallback for desktop.
- [x] **106** Reject anonymous HTTP writes and WebSocket mesh links in per-device pairing mode.
- [x] **107** Test QR parsing, expiry, replay, bad-proof lockout, persistence, and paired WebSocket links.

## Wave 7 — Versioned release delivery (108–111)

- [x] **108** Gate releases on stable `vMAJOR.MINOR.PATCH` tags that match `pubspec.yaml` and point to a commit already reachable from `main`.
- [x] **109** Publish direct Android APK, Windows installer `.exe` with its full runtime bundle, Linux x86_64 AppImage, and macOS DMG assets; reject ZIP release assets.
- [x] **110** Generate and verify a SHA-256 manifest, then attach signed GitHub build-provenance attestations to release files.
- [ ] **111** Run the first tagged public release and verify installation on clean devices; configure native platform signing/notarization when credentials and entitlements are available.

## Wave 8 — Navigation and artifact discoverability (112–113)

- [x] **112** Replace the single long dashboard with a responsive desktop sidebar/mobile drawer for Overview, Messages, Mesh peers, and Activity; add a desktop/mobile navigation widget test.
- [x] **113** Upload Android, Linux, Windows, macOS, and explicitly unsigned iOS CI build outputs, then provide a seven-day all-platforms ZIP with checksums as an Actions artifact while keeping GitHub Release assets separate and ZIP-free; CI run `39941992119` passed.

## Wave 9 — Encrypted transfers, Bluetooth, and user controls (114–121)

- [ ] **114** Seal paired-peer WebSocket messages and HTTP writes with per-peer AES-256-GCM; reject cleartext and replayed HTTP requests.
- [ ] **115** Add authenticated chunked LAN file transfer with bounded receive size, safe file names, verified length/SHA-256, and a received-file index.
- [ ] **116** Add file selection/send, receive listing, Save As export, progress, and copyable storage paths.
- [ ] **117** Add BLE scanning/GATT message and chunked-file transports using the established QR-pairing key; document OS/adapter limitations.
- [ ] **118** Persist device name, Bluetooth state, incoming-file acceptance, and the configurable receive cap in Settings.
- [ ] **119** Add visible Troubleshooting and Docs sections, actionable diagnostics, and security caveats.
- [ ] **120** Add focused AES-GCM, file-store, encrypted HTTP/WebSocket, settings, and navigation tests; validate with Flutter analyze, tests, and platform builds in CI.
- [ ] **121** Verify real-device transfers across Android/Windows, iOS/macOS, and Linux BLE limitations; protect the confirmed BlueStacks-to-Windows LAN pairing path.

## Delivery rules

1. A checked item must have an implementation and a focused test or reproducible verification.
2. Do not count cosmetic renames, repeated documentation copies, or generated boilerplate as separate improvements.
3. Keep each wave reviewable; update this file only when work is actually completed or scope is deliberately re-prioritized.
4. The larger `777+` program remains phased. This 100-item first backlog is a concrete start, not a claim that all future items are implemented.
