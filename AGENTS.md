# Aurelia Agent Rules

These rules apply to every task in this repository.

## Scope and product direction

- Aurelia is a self-hosted media server with native clients. Do not replace it
  with a browser-only product or a shortcut that merely opens localhost.
- Keep all user-facing text in English until localization is an explicit task.
- Preserve the native Apple TV/macOS design direction, but keep infrastructure
  milestones focused and functional.
- Never copy, convert, remux, transcode, hash, analyse, or cache video content.
  Media remains at its original user-selected path; scans read only filesystem
  metadata and directory structure.
- Missing or offline media must retain identity, metadata, favorites, progress,
  and collection membership unless an administrator explicitly removes it.
- `/Users/lucaskleinsteuber/Documents/Aurelia Classic`, its app, database,
  `Library.store`, and Application Support data are read-only references. Never
  edit, migrate, launch for automation, or copy from them.

## Native client design contract

- Maintain one coherent Apple TV and macOS visual language.
- Content extends beneath the transparent sidebar; never introduce a gray or
  black strip above the content.
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
- Generated output remains in the adjacent historical external workspace
  `/Users/lucaskleinsteuber/Documents/Aurelia Home Other`; do not rename or move
  that directory merely to change the product name. Its standard subdirectories
  are `Build/`, `Package Cache/`, `Test Results/`, `Logs/`, and
  `Aurelia Build summarys/`.
- Runnable Mac test products must be staged under a unique
  `~/Library/Caches/Aurelia/TestRuns/<run-id>` directory. Pre-install smoke
  candidates use a unique `/private/tmp/Aurelia/<run-id>` directory. Launch the
  installed release only from `/Applications`.
- Tests use isolated synthetic media and credentials. Personal media may only
  be read in place for an explicitly requested, bounded playback check; record
  size and modification time before and after it.

## Build and verification

- `AureliaBuildNumber` in `Directory.Build.props` is authoritative. Increment it
  exactly once, only after the pre-version verification is green; never reuse
  or decrease a build number.
- Use the pinned SDK and dependencies. At minimum run restore, format
  verification, warning-free .NET and Swift builds, all relevant tests, and the
  appropriate host/playback smoke tests.
- Treat warnings as errors. Do not publish or install a failing candidate.
- Verify arm64 and x86_64 server payloads and the universal macOS bundle. State
  clearly when an architecture could only be built, not executed locally.
- A successful build, signature check, or API call is evidence only for the
  path actually exercised; never claim broader UI, codec, device, or library
  coverage.

## Installation and version handling

- Install the verified release as `/Applications/Aurelia.app`.
- While Aurelia is in Lucas's pre-release tester phase, every version installed
  by an agent must be a clean test installation unless Lucas explicitly asks to
  preserve the current setup. Before installing the verified app, run
  `scripts/reset-installed-test-state.sh --confirm-clean-test-install` and
  verify that the next launch shows the first-run setup. This is an installation
  workflow rule, not behavior that may be added to the production app.
- A clean test installation removes only Aurelia-owned accounts, sessions,
  preferences, connection profiles, transient host state, logs, databases, and
  the legacy Aurelia Home migration source that would otherwise restore an old
  setup. It must never delete, edit, scan, or move user-selected media folders.
  It must never touch Aurelia Classic, `Application Support/Aurelia`,
  `Library.store`, or `com.lucas.aurelia` credentials and containers. Reset
  sandbox preferences through macOS preferences services; preserve the
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

- Work directly on `main` unless Lucas explicitly requests a branch.
- Before committing, inspect the full diff and audit it for secrets, personal or
  unportable paths, generated data, databases, binaries, media, caches, and test
  results.
- Commit a completed build with exactly its product version as the message
  (for example `1.0.14`), push to `origin/main`, and verify the remote hash.
- Never force-push, rewrite published history, or batch unrelated completed
  product changes.
- After verification, create exactly one concise English Markdown summary in
  `/Users/lucaskleinsteuber/Documents/Aurelia Home Other/Aurelia Build summarys`.
  Include objective, behavior, important files, verification, installation,
  known limitations, and the verified final Git hash. Do not commit that
  external summary.
