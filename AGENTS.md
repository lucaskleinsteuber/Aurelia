# Aurelia Agent Rules

These rules apply to every task in this repository.

## Scope and product direction

- Aurelia is a self-hosted media server with native clients. Do not replace it
  with a browser-only product or a shortcut that merely opens localhost.
- This repository's current product name is **Aurelia**. **Aurelia Classic** is
  the separate, local-only reference application and is read-only. Do not call
  the current product by its retired two-word label in user-facing text or
  active documentation. Preserve historic identifiers only when required to
  discover or migrate data and settings from older releases.
- Keep all user-facing text in English until localization is an explicit task.
- Preserve the native macOS design direction, but keep infrastructure
  milestones focused and functional.
- Media files are only ever read: never modify, copy, convert, remux,
  transcode, hash, or store video content. Media remains at its original
  user-selected path; scans read only filesystem metadata and directory
  structure. One user-approved exception reads content without keeping it:
  scrub previews decoded live during playback and held only in memory.
- Missing or offline media must retain identity, metadata, favorites, progress,
  and collection membership unless an administrator explicitly removes it.
- Aurelia Classic, its app, database,
  `Library.store`, and Application Support data are read-only references. Never
  edit, migrate, launch for automation, or copy from them.

## Native client design contract

- Maintain one coherent native macOS visual language.
- The sidebar is a dark, blurred panel like the Apple TV app's: hero artwork
  and rails may pass beneath it softly, its labels stay legible, and Reduce
  Transparency falls back to the opaque Aurelia canvas color. Keep content
  full-height beneath native window chrome; never introduce a gray or black
  strip above the content.
- Use native macOS window controls and fullscreen behavior. Never draw fake
  traffic-light buttons.
- Editing, setup, settings, library management, details, and playback should use
  the same design system. Do not revive the Classic app's inconsistent menus.
- Keep player controls restrained, accessible, keyboard-operable, and hidden
  after inactivity only when interaction state permits it.

## Repository and workspace hygiene

- Keep only source, migrations, versioned tests, configuration, and useful
  documentation in the repository.
- Never commit build products, result bundles, logs, caches, runtime data,
  SQLite files, artwork, media, credentials, tokens, or signing material.
- Generated output belongs outside the checkout. `AURELIA_OTHER_ROOT` may select
  an existing external workspace; never rename or move that workspace. Otherwise
  use the per-user cache defaults in `scripts/workspace-paths.sh`. Standard
  subdirectories are `Build/`, `Package Cache/`, `Test Results/`, and `Logs/`.
- Runnable Mac test products must be staged under a unique
  `~/Library/Caches/Aurelia/TestRuns/<run-id>` directory. Pre-install smoke
  candidates use a unique `/private/tmp/Aurelia/<run-id>` directory. Launch the
  installed release only from `/Applications`.
- Tests use isolated synthetic media and credentials. Personal media may only
  be read in place for an explicitly requested, bounded playback check; record
  size and modification time before and after it.

## Client versions and verification

- macOS/server and tvOS are separate products with independent version/build
  counters. Confirm product names and intended versions with the user before
  changing them. The approved Mac release removing intro and credits skipping is 1.7.9 (73); the
  independent tvOS client is named Aurelia, requires tvOS 26, and the approved
  intro-skipping update is 0.3.0 (11).
- Keep tvOS in its own Xcode project with no Mac source references or shared
  Aurelia product library. A third-party playback engine is allowed.
- For tvOS, run warning-free device/simulator builds, host-executable logic tests
  and XCUITest on the dedicated tvOS 26 simulator. UI tests must use synthetic
  data and a simulated engine through the production views/control logic, with
  no real video engine, stream relay, personal credentials or server access.
  Actual playback remains the user's physical Apple TV check. Install the
  signed update on the already paired TV when reachable; preserve its data and
  configuration and report concrete blockers without resetting it.

- The 0.1.2 (3) TV update additionally authorized one explicit physical-device
  playback check of the user-approved episode, limited to five minutes. This
  opt-in check is separate from simulator tests; it may update that title's
  progress, must disable next-episode playback, and must record source size and
  modification time before/after without copying or modifying media. It does
  not authorize other titles, codec sweeps or playback soak gates.

- For macOS/server, `AureliaBuildNumber` in `Directory.Build.props` is authoritative. Increment it
  exactly once, only after the pre-version verification is green; never reuse
  or decrease a build number.
- Use the pinned SDK and dependencies. At minimum run restore, format
  verification, warning-free .NET and Swift builds, all relevant tests, and the
  appropriate host smoke tests.
- Do not automatically run playback tests, playback smoke tests, or native
  playback soak gates for builds, releases, or installation. Run playback
  verification only when the user explicitly requests those tests. A user's
  confirmation that playback works does not request an automated playback run.
- Treat warnings as errors. Do not publish or install a failing candidate.
- Verify arm64 and x86_64 server payloads and the universal macOS bundle. State
  clearly when an architecture could only be built, not executed locally.
- A successful build, signature check, or API call is evidence only for the
  path actually exercised; never claim broader UI, codec, device, or library
  coverage.

## Installation and version handling

- After each successful, verified, launchable macOS app build made for the user to
  test, install that build on this MacBook as `/Applications/Aurelia.app`; do
  not wait for a separate install request. Never install a failed or incomplete
  candidate. This rule applies only to the server-backed Aurelia app in this
  repository, never to Aurelia Classic.
- Installation replaces only the app bundle. Preserve the existing library
  and all Aurelia setup state across builds and updates, including the server
  database, local server data, accounts, sessions, preferences, connection
  profiles, and server settings. Do not reset installed test state, clear
  Keychain or preferences, or
  move any Aurelia data to Trash as part of a normal install. Reset or recreate
  setup only when the user explicitly asks for it.
- Never delete, edit, scan, or move user-selected media folders as part of an
  install. Never touch Aurelia Classic, `Application Support/Aurelia`,
  `Library.store`, or `com.lucas.aurelia` credentials and containers. Preserve
  OS-managed sandbox and App Group container shells rather than bypassing macOS
  container protections.
- Before replacement, read the installed bundle's real `CFBundleVersion` and
  `CFBundleShortVersionString`; never infer them from a filename.
- Stop the installed app and its owned helper/server processes cleanly before
  replacement. Preserve user data and libraries separately from the app bundle.
- Do not leave old, previous, duplicate, renamed, or backup Aurelia app bundles
  in `/Applications`. After an update, only the intended current
  `/Applications/Aurelia.app` may remain.
- Do not create local app-bundle backups in `/Applications` or elsewhere as part
  of the release workflow. Git/GitHub history, tags, commits, and published
  builds are the rollback mechanism.

## Build summary and Git discipline

- Work directly on `main` unless the user explicitly requests a branch.
- Before committing, inspect the full diff and audit it for secrets, personal or
  unportable paths, generated data, databases, binaries, media, caches, and test
  results.
- Use a short English description of the completed change as the commit subject,
  without a version/build number. The approved subject for the current TV update
  is `Release tvOS intro and credits skipping`. Push to `origin/main`
  and verify the remote hash after each independent completed change.
- Never force-push, rewrite published history, or batch unrelated completed
  product changes.
- After verification, create exactly one concise English Markdown summary in
  the external workspace's existing summary directory, or `Build Reports/`.
  Include objective, behavior, important files, verification, installation,
  known limitations, and the verified final Git hash. Do not commit that
  external summary.

## Public distribution

- Keep the README concise and user-facing. Put build/test/API details in linked
  documentation, not the README. Do not add personal names or machine paths.
- Preserve bundle IDs, App Groups, Keychain identifiers, and signing identity
  continuity; a cosmetic rename must not lose existing users' connections/data.
- A local development signature is not a public release. Public Mac packages
  must be tested for their actual distribution mode. The intended channel is a
  free GitHub download, not the App Store. Do not require paid Apple membership
  or notarization; a non-notarized package needs a documented per-app Gatekeeper
  exception and verified first launch. Do not assume the current development
  profile, App Group, or Keychain entitlements work on another user's Mac.
- Never change repository visibility, publish a release, or rewrite historical
  author information without explicit user authorization.
