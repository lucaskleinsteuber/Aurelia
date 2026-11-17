# Aurelia Rules for Subagents

> **This file is for Codex, Antigravity and every other model or agent except
> Claude Code.** Claude Code follows `CLAUDE.md` and only opens this file to edit
> it. If you are Claude Code, do not follow these rules; use `CLAUDE.md`.
>
> If you are any other agent, these rules are binding for every task in this
> repository. When anything else (a task, a plan, a comment, a script, another
> document) contradicts them, these rules win.

## Your role

Claude Code is the main agent of this repository. You step in when Claude Code is
not available, usually because its usage limit is reached. You work directly with
the owner, Lucas. Claude Code reviews your branch later and decides with the owner
whether and how it reaches `main`.

You cannot reach Claude Code. **Whenever something is unclear, ask the owner and
wait for the answer.** Do not guess on things that matter: which clients a feature
is for, how something should behave, whether a risky change is wanted. Small
implementation details inside a clear task you decide yourself.

## Git: hard rules

1. **Work only on your own branch.** If the owner named a branch, use it. If not,
   create `agent/<tool>-<short-name>` from the current `main` (for example
   `agent/codex-playlist-sort`), tell the owner its name, and stay on it.
2. **Commit only to your branch.** Never commit to `main`. Never merge, rebase onto,
   or cherry-pick into `main` or any other branch.
3. **Never push.** No `git push`, no pull requests, no GitHub releases, no changes
   to anything on GitHub.
4. **No destructive Git commands.** No `git reset --hard`, no force operations, no
   deleting branches, no rewriting history.
5. Commit in sensible steps with short English commit subjects that describe the
   change, without version numbers.

## Versions: hard rules

You never make a new version. That means you never:

- change version or build numbers (`clients/macos/Configuration/BuildNumber.xcconfig`,
  `Version` and `AureliaBuildNumber` in `Directory.Build.props`, `Version` and
  `AureliaLinuxBuildNumber` in `clients/linux/Directory.Build.props`, or the version
  fields of the tvOS and iOS Xcode projects)
- edit `CHANGELOG.md` or `docs/RELEASE_VERSIONS.json`
- create tags or releases
- run `scripts/publish-release.sh`

New versions are made only by Claude Code after the owner agrees.

## Devices and the owner's screen

- **Never run UI tests** (XCUITest on Mac or Apple TV, the update worker fixture,
  or anything else that opens windows or takes over the screen).
- **Never run playback tests**, playback smoke tests or soak gates.
- **Installing needs the owner's yes.** Before installing anything on the owner's
  devices (the CachyOS laptop via `scripts/install-linux-app.sh`, the Apple TV, the
  Mac app in `/Applications`), ask the owner and wait. Never touch the owner's own
  Aurelia server.

## Definition of done

A task is only done when all of these are true:

1. Everything you touched builds without errors **and without warnings**.
   Warnings count as errors, including in third-party code; fix the cause, never
   suppress the warning.
2. Formatting checks pass.
3. All relevant existing tests pass.
4. New behaviour has tests where that is reasonably possible.
5. You actually exercised the change with the headless or logic tests and, where
   possible, by starting the server or a headless app. Compiling alone is not
   testing.
6. Every problem you found while testing is fixed and tested again. Repeat this
   loop until everything works.
7. Everything the owner asked for is done.

Never do any of this to get a green result:

- delete, comment out or skip tests
- weaken assertions so they match broken behaviour
- catch errors and silently ignore them
- claim something was tested when it was not

If something cannot be solved after several honest attempts, stop, tell the owner
what you tried and ask how to continue.

### Verification commands

Run what fits the parts you changed:

| Part | Commands |
|---|---|
| Server and shared .NET code | restore, format verification, warning-free build, all tests |
| Browser app (`src/Aurelia.Server/WebApp`) | `node --test "tests/WebApp/*.test.mjs"` |
| Linux app (`clients/linux`) | `scripts/test-linux-app.sh`, `scripts/build-linux-app.sh` (without a package host it makes only the archive; the deb, rpm, Arch and Flatpak packages are made by Claude Code on the owner's server, never on the laptop) |
| iPhone and iPad (`clients/ios`) | `scripts/test-ios-logic.sh`, `scripts/build-ios.sh` |
| Apple TV | warning-free simulator build and host logic tests |
| Mac app | warning-free Swift build and unit and logic tests |

Details are in the files under `docs/`. Never claim more coverage than the path
you actually ran.

## Project rules you must know

### Product

- Aurelia is a self-hosted media server with native clients: Mac, Linux, browser,
  iPhone and iPad, Apple TV. Never replace a native client with a browser-only
  shortcut.
- For a new feature, ask the owner which clients it should come to before you plan
  or build it.
- The product is called **Aurelia**. **Aurelia Classic** is a separate old app:
  never edit, migrate, launch or copy from it, its database, `Library.store` or its
  Application Support data.
- All user-facing text stays in English.

### Media is only ever read

- Never modify, move, rename or delete media files. Scans read only filesystem
  metadata and folder structure.
- Converted video is never stored on the server: no transcode cache, no temporary
  segment files, no converted copies. Live conversion stays in memory and goes
  straight into the HTTP response. Keep `LiveConversionTests`.
- The only allowed copy is an offline download that a person explicitly starts. It
  lives in that app's own data folder, shows its size and can be removed.
- Background analysis (intro and credits detection, speech recognition, file check)
  keeps audio, pictures and fingerprints in memory only; only timestamps, finished
  subtitles or short findings are stored. ffmpeg and whisper.cpp run without a
  shell and at low priority, and pause while anyone watches.
- Missing or offline media keeps its metadata, favorites, progress and collections.
- Tests use synthetic media and credentials only. Never use the owner's personal
  library.

### Repository hygiene

- Commit only source, migrations, tests, configuration and useful documentation.
- Never commit build products, logs, caches, test results, SQLite files, artwork,
  media, credentials, tokens or signing material.
- Generated output belongs in the git-ignored `Local/` folder. Never commit
  anything from it and never change its entry in `.gitignore`.
- Before every commit, read your full diff and check it for secrets, personal or
  machine-specific paths and generated files.
- Do not touch `Local/Aurelia Desktop (archived)`.

### Design

- One coherent native macOS look across setup, settings, library, details and
  player.
- The sidebar is a dark, blurred panel like in the Apple TV app; with Reduce
  Transparency it becomes the opaque Aurelia canvas color. No gray or black strip
  above the content.
- Use real macOS window controls and fullscreen. Never draw fake traffic-light
  buttons.
- Player controls stay restrained, accessible and keyboard-operable.
- System callbacks need a clear thread contract; see `docs/SYSTEM_CALLBACKS.md`.

### Platforms

- **Browser app:** plain HTML, CSS and JavaScript modules. No framework, no build
  step, no npm packages, nothing loaded from the internet. Credentials stay in
  HttpOnly cookies that scripts never read.
- **Apple TV and iPhone/iPad:** each has its own Xcode project. No Mac source
  references and no shared product library; code is copied, not linked.
- **Linux app:** C# with Avalonia for x64 and arm64. It shares only
  `src/Aurelia.Contracts` with the server and copies no Mac code.
- **Mac and Linux:** one build per architecture, no universal Mac build.
- Use the pinned SDKs and dependencies. Do not add new dependencies without asking
  the owner.
- Keep bundle IDs, App Groups, Keychain identifiers and signing settings unchanged.

## Report

When you finish, give the owner a short report in the chat and save the same text
to `Local/Agent Reports/<branch-name>.md` (git-ignored, never commit it), so Claude
Code can read it during the review:

- **Branch:** name and number of commits
- **Done:** what was implemented
- **Tested:** which commands ran and their results, and what was exercised beyond
  compiling
- **Fixed during testing:** problems found and how they were solved
- **Open:** what is not done or did not work, and why
- **Notes:** decisions the reviewer should know about
- **Not run:** UI tests, playback tests and installation are never run by you;
  say so explicitly
