# Aurelia TV client

- This is an independent native tvOS client, not a target in the Mac project.
  Do not link Mac application sources or introduce a shared Aurelia product
  library. Platform-neutral TV files under `AureliaTV/Core` are compiled directly
  into the hostless macOS logic-test target.
- The approved client identity is **Aurelia**, bundle ID
  `com.lucas.aurelia.tvos`, version **0.3.0**, build **11**, minimum **tvOS 26**.
  `Configuration/BuildNumber.xcconfig` owns the TV version. Confirm later product
  name or release-version changes with the user before editing them.
- Keep UI text in English. Use Aurelia's opaque `#202326` canvas, large artwork,
  restrained controls, native focus behavior and remote navigation. Focus alone
  must never start playback.
- Do not add server or account administration to this client. Device approval
  remains on an already connected Mac; selecting a profile is a separate step.
- Keep device credentials in the TV client's Keychain and profile credentials
  in memory. Never log credentials, pairing codes, secrets or private URLs.
- Video remains at the server's original location. A relay may stream bounded
  byte buffers, but must never persist or cache video files.
- Prepare pinned TVVLCKit with `scripts/prepare-tvvlckit.sh`. Dependencies,
  derived products, logs and test results belong outside Git.
- Run warning-free Apple TV device and simulator builds, the hostless macOS
  logic tests, and the TV UI-test target on the dedicated tvOS 26 simulator.
  UI tests use the production views/controller with Debug-only synthetic data,
  an isolated memory/defaults outbox and simulated engine/relay. Never access
  the user's
  Keychain/server or start a real video engine/stream relay in these tests.
  Keep the fixture entry point unavailable in Release builds. The 0.1.2 update
  added a separate explicitly invoked physical-device check
  may play the user-approved episode for at most five minutes with next-episode
  playback disabled, preserving media and measuring only source size/mtime.
  Keep it out of ordinary tests; no other codec or playback gates are authorized.
  Report simulator UI, signed installation and user acceptance separately.
- Do not reset a paired device, personal settings, server data or profiles.
  Test with synthetic metadata and credentials. Development installation does
  not establish public distribution readiness.
