# Aurelia TV client

- This is an independent native tvOS client, not a target in the Mac project.
  Do not link Mac application sources or introduce a shared Aurelia product
  library. Platform-neutral TV files under `AureliaTV/Core` are compiled directly
  into the hostless macOS logic-test target.
- The approved initial identity is **Aurelia**, bundle ID
  `com.lucas.aurelia.tvos`, version **0.1**, build **1**, minimum **tvOS 26**.
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
- Build only the Apple TV device target. Run the independent hostless macOS
  logic tests; do not install or run a simulator, automated UI test, video
  engine test or playback gate. The user checks the UI and real playback on
  their Apple TV. Report build, installation and user acceptance separately.
- Do not reset a paired device, personal settings, server data or profiles.
  Test with synthetic metadata and credentials. Development installation does
  not establish public distribution readiness.
