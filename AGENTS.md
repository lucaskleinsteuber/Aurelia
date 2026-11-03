# Aurelia Agent Rules

These rules apply to every task in this repository.

## Scope and product direction

- Aurelia is a self-hosted media server with native clients. Do not replace it
  with a browser-only product or a shortcut that merely opens localhost.
- The server also serves a browser app (`src/Aurelia.Server/WebApp`, see
  `docs/WEB_APP.md`) for devices without an Aurelia app. It is an additional
  client, not a replacement: it is plain HTML, CSS and JavaScript modules with
  no framework, build step, npm package or anything loaded from the internet;
  its credentials stay in HttpOnly cookies that scripts never read; and its
  logic is tested with `node --test "tests/WebApp/*.test.mjs"`.
- This repository's current product name is **Aurelia**. **Aurelia Classic** is
  the separate, local-only reference application and is read-only. Do not call
  the current product by its retired two-word label in user-facing text or
  active documentation. Preserve historic identifiers only when required to
  discover or migrate data and settings from older releases.
- Keep all user-facing text in English until localization is an explicit task.
- Preserve the native macOS design direction, but keep infrastructure
  milestones focused and functional.
- Media files are only ever read: never modify, move, rename, delete or copy
  them. Media remains at its original user-selected path; scans read only
  filesystem metadata and directory structure.
- Converting video live is allowed: decoding, remuxing or transcoding while a
  title plays (for example for a browser or a device that cannot play the
  original), and scrub previews decoded ahead in the background. Converted
  video is never stored: it stays in memory and is discarded when playback or
  the title ends. No transcode cache, temporary segment files or converted
  copies on disk, in Application Support or anywhere else. (The Classic app
  stored converted files in Application Support and grew to 20–30 GB.) Small
  still preview images for scrub previews may be stored in the server data
  folder, optional and with a size cap; converted video is still never stored.
- The server's live conversion (`Services/LiveConversion*.cs`) starts ffmpeg
  without a shell; it reads only the file the server checked and opened and
  writes only to its standard output, straight into the HTTP response.
  `LiveConversionTests` guards that no file appears in the data, temporary or
  media folder; keep it. The Mac app ships its own LGPL ffmpeg from
  `scripts/build-ffmpeg-macos.sh`, never a GPL build; the Linux server uses the
  distribution's ffmpeg, which Aurelia does not distribute.
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
- System-framework callbacks must have an explicit queue/actor contract. For
  callbacks that may run off-main, use nonisolated factories and `@Sendable`
  closures with Sendable captures, then hop to MainActor for UI/model access.
  Exercise the production callback from a background queue in regression tests;
  fake transports alone do not test framework adapters. See `docs/SYSTEM_CALLBACKS.md`.

## Repository and workspace hygiene

- Keep only source, migrations, versioned tests, configuration, and useful
  documentation in the repository.
- Never commit build products, result bundles, logs, caches, runtime data,
  SQLite files, artwork, media, credentials, tokens, or signing material. The one
  exception is the README screenshots in `docs/assets/screenshots/`: they come only
  from `scripts/capture-showcase.sh`, whose library, titles, names and pictures are
  invented by `scripts/make-showcase.swift`; never show a personal library.
- Generated output and private local files live in the git-ignored `Local/`
  folder of the checkout (`AURELIA_OTHER_ROOT` may select another place). Never
  commit anything from it and never remove `/Local/` from `.gitignore`. Standard
  subdirectories are `Build/`, `Package Cache/`, `Test Results/` and `Logs/`;
  `Local/` also holds icon drafts, the Linux server's SSH
  access and the archived desktop client. Build and test scripts first run
  `scripts/prune-workspace.sh`, which keeps the newest build per platform, ten
  test results and 30 days of logs; new scripts that write there should call it
  too. Builds are not kept as archives: a published Mac/server version is
  deleted locally by `scripts/publish-release.sh`, and an installed tvOS or iOS
  build folder is deleted after `refresh-signing.sh --adopt-tv` or `--adopt-iphone`.
- Runnable Mac test products must be staged under a unique
  `~/Library/Caches/Aurelia/TestRuns/<run-id>` directory. Pre-install smoke
  candidates use a unique `/private/tmp/Aurelia/<run-id>` directory. Launch the
  installed release only from `/Applications`.
- Tests use isolated synthetic media and credentials. Personal media may only
  be read in place for an explicitly requested, bounded playback check; record
  size and modification time before and after it.

## Client versions and verification

- macOS/server and tvOS are separate products with independent version/build
  counters. Every Aurelia product (Mac app and server, Linux server, tvOS, and
  any Windows or other client) follows Semantic Versioning (MAJOR.MINOR.PATCH): MAJOR for
  changes that break existing clients, servers or data; MINOR for new features;
  PATCH for fixes only. Choose the next version independently by these rules and
  state the version and reason before building. Do not ask the owner to choose or
  confirm a version; the build number rises by exactly
  one per build. The current Mac release is 1.27.10 (134); the independent tvOS
  client is named Aurelia, requires tvOS 26, and is at 1.4.0 (26).
- Keep tvOS in its own Xcode project with no Mac source references or shared
  Aurelia product library. A third-party playback engine is allowed.
- The iPhone and iPad client (`clients/ios`, preview, 1.1.0 (5)) follows the same
  rules as tvOS: its own Xcode project and version counter, code copied from the
  Apple TV app rather than linked, logic tests with `scripts/test-ios-logic.sh`, a
  warning-free simulator build with `scripts/build-ios.sh`, synthetic data only,
  no real playback in tests, and it is not published.
- Aurelia for Linux (`clients/linux`, 1.1.0 (9)) is the native Linux desktop
  app, with library browsing, playback, settings, server administration and optional hosting
  on this PC. It is meant to become the full Mac app on Linux. It is a separate product with
  its own version counter (`Version` and `AureliaLinuxBuildNumber` in
  `clients/linux/Directory.Build.props`), written in C# with Avalonia, Linux x64 only,
  with platform specifics behind small adapters. It shares only `src/Aurelia.Contracts`
  with the server and copies no Mac code. Verify it with `scripts/test-linux-app.sh`
  (formatting, warning-free build, headless Avalonia tests, which need no screen and no
  question first), build it with `scripts/build-linux-app.sh` (packages made on Linux by
  `scripts/package-linux-app.sh`) and install each verified test build on the owner's
  CachyOS laptop (`Local/LinuxLaptop/ssh_config`) with `scripts/install-linux-app.sh`
  without asking; installing replaces only the package. Synthetic data only, no real
  playback in tests. Hosting and network-trial tests use isolated server processes and temporary
  state; never start a second host over the installed server or use personal libraries for them.
  Publish its deb, rpm, Arch and Flatpak packages with `scripts/publish-release.sh --linux-app`
  under its independent `linux-app-<version>-<build>` tag, never as the Mac/server latest release.
  Verify native package lifecycle tests in Ubuntu, Fedora and Arch, the actual Flatpak bundle,
  and native Wayland/X11 startup separately from headless app tests. See `docs/LINUX_APP.md`.
- The former Windows/Linux desktop client (last 0.2.0 (6)) is archived outside the
  repository in `Local/Aurelia Desktop (archived)`. Do not
  restore, build or test it unless the user asks for it.
- For tvOS, run warning-free device/simulator builds, host-executable logic tests
  and, after asking the user (see below), XCUITest on the dedicated tvOS 26
  simulator. UI tests must use synthetic
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
- Mac and tvOS UI tests (XCUITest) take over the user's screen. Before every
  UI test run, even a single test and even within a request to "test
  everything", ask the user whether to run UI tests (yes or no) and wait for
  the answer; never start one automatically. Find failures from diagnostics and
  code first, then batch the fixes into one run. Without UI tests, verify with
  builds, unit and logic tests and headless smoke tests, and say that UI tests
  were not run.
- Treat warnings as errors, including third-party dependencies built for a package. Fix their
  sources or build configuration; do not suppress diagnostics or waive warnings for foreign code.
  Do not publish or install a failing candidate.
- The Mac app and its bundled server are built for Apple silicon (arm64) only;
  1.25.1 was the last universal release for Intel Macs. Do not add Intel slices
  back. The Linux server keeps both x64 and arm64 packages; verify both, and
  state clearly when an architecture could only be built, not executed locally.
- A successful build, signature check, or API call is evidence only for the
  path actually exercised; never claim broader UI, codec, device, or library
  coverage.

## Installation and version handling

- Publish verified macOS releases and let the owner install them through the
  Aurelia updater. Do not replace or relaunch the installed Mac app directly
  unless the owner explicitly requests a direct installation for that build.
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
- Local builds use free 7-day development profiles. The per-user job from
  `scripts/refresh-signing.sh` re-signs the installed Mac, Apple TV and iPhone
  apps before their profiles expire, keeping their versions. After installing an
  Apple TV build, run `zsh scripts/refresh-signing.sh --adopt-tv`, and after an
  iPhone build `--adopt-iphone`, so the job re-signs that build; after changing
  the script, run `--install` again.
- Do not create local app-bundle backups in `/Applications` or elsewhere as part
  of the release workflow. Git/GitHub history, tags, commits, and published
  builds are the rollback mechanism.

## Changelog and Git discipline

- Work directly on `main` unless the user explicitly requests a branch.
- Before committing, inspect the full diff and audit it for secrets, personal or
  unportable paths, generated data, databases, binaries, media, caches, and test
  results.
- Use a short English description of the completed change as the commit subject,
  without a version/build number. Add `[skip ci]` as requested by the owner to avoid
  starting GitHub server test runs; perform the relevant verification locally. Push to `origin/main`
  and verify the remote hash after each independent completed change.
- Never force-push, rewrite published history, or batch unrelated completed
  product changes.
- Keep one concise English `CHANGELOG.md` in the repository root, following
  Keep a Changelog 1.1.0 (https://keepachangelog.com/en/1.1.0/). Use an Unreleased
  section for pending work, dated versions in reverse chronological order and only
  relevant Added, Changed, Deprecated, Removed, Fixed or Security sections.
  Use DD.MM.YYYY for changelog dates, as explicitly requested by the owner.
  Identify the product because Mac/server, Linux, tvOS and iOS versions are independent.
  Preserve historical version numbers; new versions follow Semantic Versioning 2.0.0
  (https://semver.org/spec/v2.0.0.html). Describe notable user-visible changes in a few
  concrete bullets (typically two to six), using historical commits and release notes
  to cover all recorded builds from Build 1; never invent missing builds or release
  dates. Omit test logs, file inventories and Git commit dumps. Never create
  separate Markdown build summaries. Private diagnostics and test receipts stay in
  the ignored `Local/Logs/` and `Local/Test Results/` directories.

## Public distribution

- Keep independent MAJOR.MINOR.PATCH product versions. Track verified releases in
  `docs/RELEASE_VERSIONS.json`. Keep cross-product version tables out of the README
  and release descriptions. Mac/server stays Latest; Linux keeps its own tags.
- The owner amended the anonymous Mac updater test on 03.11.2026: use the main
  `lucaskleinsteuber/Aurelia` repository while they explicitly make it public, then
  restore its private visibility after the test. The existing Linux preparation
  still uses `lucaskleinsteuber/Aurelia-Update-Test`; keep that artifact-only source
  available until its real test finishes, then make it private too. The Mac test is
  complete. Mac builds retire the old test setting and use the normal release feed.
  Linux Public Update Test skips loading or sending saved tokens and preserves them.
  Never copy private history into the artifact-only repository. The owner operates
  the real Mac/Arch update dialogs; restore normal sources after verification.
  During these tests keep the preparation installed until the app updater installs
  the target; never install the target directly to claim a successful update.
  Never rely on NSWorkspace launch arguments from the sandboxed Mac app. Use the
  bounded App Group request and matching acknowledgement before quitting; verify
  changes with `scripts/test-update-installer.sh` and the windowless real-sandbox
  `scripts/test-update-handoff-sandbox.sh`.
  Finish asynchronous application cleanup before the final AppKit quit; do not
  enter `terminateLater` from the updater's MainActor task. Verify the real,
  windowless AppKit termination with `scripts/test-macos-termination.sh`.
  The installer must retain visible UI (progress window and menu-bar item) through
  replacement and relaunch. macOS can kill both invisible helpers and submitted
  background update jobs after the app quits. Launch the visible native helper directly.
  `scripts/test-update-worker.sh --build-only` compiles its complete signed synthetic
  fixture without UI. Running the fixture shows installer/test-app windows, requires
  the per-run UI-test approval above, and uses `AURELIA_UPDATE_UI_TESTS=1` only after
  that approval. Match the real app's normal application type, termination properties
  and optimized compilation; testing an agent/background caller can falsely pass.
  Client updates must remain available before profile unlock and while the server is
  unreachable. Local update settings must not fetch server administration or depend on
  its errors. No personal app state, server, credentials or media may be used by fixtures.
  See `docs/UPDATE_TEST.md`. Audio acceptance uses logic/configuration/migration
  tests and the owner's listening check; no automatic signal or hearing tests.
  Keep the four clients’ independent speech EQ/compressor presets aligned with
  `docs/AUDIO_PROCESSING.md`, preserving legacy Night Mode settings and full filter chains.
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
- Never change repository visibility or rewrite historical author information
  without explicit user authorization.
- The owner wants every Mac/server version that is installed for them published
  as a GitHub Release with `scripts/publish-release.sh`: the Apple silicon Mac DMG,
  the Linux server packages and GitHub's source archives. Push first, build the
  Linux packages of the same version, publish, and verify the downloads. Then
  update the owner's Linux server to that release with `sudo aurelia update
  --yes`, without asking. tvOS builds are not published; they are
  development-signed for one Apple TV.
