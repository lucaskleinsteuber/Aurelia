# Aurelia Home Agent Rules

These rules apply to every task in this repository.

## Scope and product direction

- Never modify `/Users/lucas/Documents/Aurelia` while working on Aurelia Home.
- Aurelia Home is a real self-hosted server with native apps as its primary
  clients. Never replace that architecture with a browser-only UI or a menu-bar
  shortcut whose main purpose is opening localhost. A responsive optional web
  client for devices without a native app may be added in a dedicated later
  milestone.
- Keep all user-facing product text in English until localization is a planned
  task.
- Preserve the clean Aurelia visual direction when the native client is added,
  but prioritize a working server and playback path before UI refinement.
- The server must never copy, convert, remux, transcode, or cache video files.
  Media stays at its original path.

## Repository hygiene

- Keep only source code, migrations, versioned tests, configuration, and the
  minimum useful documentation in this repository.
- Do not put compiled builds, test results, runtime logs, temporary files,
  package caches, media, databases, or generated artwork in the repository.
- Test source belongs in `tests/` and remains versioned so verification is
  reproducible. Generated test data and results do not belong in the repository.
- Use `/Users/lucas/Documents/Aurelia Home Other` for generated development
  material. The standard locations are:
  - `Build/` for compiler and publish output
  - `Package Cache/` for restored packages
  - `Test Runs/` and `Test Results/` for generated test data and reports
  - `Logs/` for development logs
  - `Aurelia Home - Build Backup/` for replaced installed app bundles
  - `Aurelia Home Build summarys/` for the single English summary per build
- Never copy the Breaking Bad or El Camino test media into the repository,
  Application Support, a build, or a test folder. Read it in place only when a
  later media milestone explicitly needs it.
- Keep generated server data small. Do not perform a full-library scan or create
  large caches without an explicit task and a bounded representative test first.

## Build and verification

- `AureliaHomeBuildNumber` in `Directory.Build.props` is the authoritative build
  number. Increment it exactly once for each completed task that changes the
  product. Never reuse or decrease a build number.
- Build and test using the pinned SDK. At minimum run restore, a warning-free
  build, all tests, formatting verification, and the relevant smoke test.
- Treat warnings as errors. Do not install or publish a candidate that fails any
  required check.
- Verify both Apple Silicon and Intel macOS publish targets when the changed
  deliverable supports both. Clearly record anything that could only be built,
  not run, on the current hardware.
- Do not claim that compilation, signing, or a successful API request proves an
  untested UI, playback path, physical device, or complete media library.

## Installed macOS app and backups

- Once a real native `Aurelia Home.app` target exists, every completed product
  task must produce a fresh app bundle and replace `/Applications/Aurelia Home.app`
  only after verification. Do not install a fake wrapper for a server-only build.
- Before replacement, read the installed bundle's `CFBundleVersion`. Do not guess
  its build number.
- Stop the installed app and its owned server processes, then copy the complete
  old bundle to `Aurelia Home - Build Backup/Aurelia Home Build <old-build>.app`.
  Never merge bundles and never overwrite an existing backup silently.
- Copy the complete verified candidate into `/Applications`, verify its version,
  architecture, signature, and launch behavior there, and retain the backup for
  rollback.
- Never touch Aurelia's app bundle, data store, or rollback bundles during this
  workflow.

## Build summary

- After verification and installation, create exactly one concise English
  Markdown file in `/Users/lucas/Documents/Aurelia Home Other/Aurelia Home Build summarys`.
- Name it `Aurelia Home Build <build> - YYYY-MM-DD.md` and include: objective,
  changed behavior, important files, verification results, installation and
  backup status, known limitations or untested areas, and the final Git commit.
- A server-only milestone must explicitly say that no app bundle was installed.
  Do not invent an application backup when no prior app exists.

## Git discipline

- Work directly on `main`; do not create task branches unless Lucas explicitly
  requests one.
- After every completed change, inspect the diff, check for secrets, credentials,
  local paths that should not be portable, generated files, databases, and media.
- Commit each completed change with a clear English message and push it to
  `origin/main` immediately. Do not batch unrelated completed changes.
- Never force-push, rewrite published history, or commit credentials, tokens,
  personal media, generated builds, runtime data, or the external build summary.
- A local commit is not completion: verify that the exact commit exists on
  `origin/main` and record its hash in the build summary.
