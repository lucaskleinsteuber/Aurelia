# Anonymous desktop update test

The anonymous Mac update test completed on 03.11.2026. The main repository is now
public and stays public. Mac 1.27.5 through 1.27.9 can still show the old Public
Update Test switch under Settings → Updates → Advanced. Mac 1.27.10 retires the
switch and may use a previously saved token. Later Mac builds use anonymous checks
and downloads from the public release feed without a token setting.

The existing Linux 1.0.2 preparation still uses the separate, artifact-only
`lucaskleinsteuber/Aurelia-Update-Test` source. It remains available for its pending
owner-operated test and returns to private afterward. Neither setting changes server
updates. Repository visibility changes always require the owner's explicit instruction.

While the test mode was enabled on Mac or is enabled on Linux, the clients do not read, send, replace or delete a saved GitHub token.
Release metadata, checksums and packages must belong to the selected repository.
Redirects retain no Authorization or Cookie headers. The bounded Linux diagnostic
records only host and whether Authorization is present; Mac records that boolean in
the `com.lucas.aurelia.media` / `UpdateTest` log. Neither records tokens or signed URLs.

Mac caches a validated release body together with its ETag per repository. A 304
reuses that release; without a usable body it retries without a validator. Linux
searches up to ten pages of 100 releases. Reaching the limit is an incomplete check,
never evidence that the installed app is current.

## Test sequence (including the completed Mac test)

1. The original Mac/server 1.26.6 (123) preparation exposed a real sandbox handoff
   failure: Launch Services discards its installer arguments. Repair that installed
   updater with Mac/server 1.27.1 (125). The next real attempt exposed a separate
   AppKit termination deadlock: the app received acknowledgement but never exited.
   Mac/server 1.27.3 (127) repaired the quit path. Its attempt to update to 1.27.4
   exposed another real failure: Launch Services force-quit the subordinate GUI
   helper as the main app exited. Mac/server 1.27.5 (129) installs the independent
   worker repair. Its main-repository attempt to update to 1.27.6 (130) also failed
   as described below. Mac/server 1.27.7 (131) is the verified preparation build. Linux Desktop uses
   the original 1.0.2 (8) preparation.
2. Publish the verified audio releases through the normal channels: Mac/server
   1.27.8 (132) and Linux Desktop 1.1.0 (9). The Mac test uses the verified regular
   release in the temporarily public main repository. The Linux test keeps the exact
   verified packages already copied into the separate public download repository,
   with license notices and a short README; never copy private history or diagnostics there.
3. Enable Public Update Test in both apps. The owner starts the normal update
   check and approves installation; Linux uses its normal `pkexec` prompt. The
   laptop test must use the native Arch package. Do not directly install the
   target build in place of this check.
4. Verify installed bundle/package metadata, relaunch, settings and retained
   connection/sign-in state. Inspect the boolean-only request diagnostics.
5. Turn off Public Update Test and verify normal authenticated behavior. After the
   historical Mac test the main repository was returned to private. The owner later
   made it public and asked to keep it public. After the independent Linux test,
   restore the download repository's private visibility.
   Leave saved tokens and published regular assets intact.

Logic tests, a real updater installation and the owner's listening check are
separate evidence. Audio verification uses settings, migration and configuration
tests; no automatic listening, synthetic signal playback or real media playback.
The owner assesses speech and loud/quiet transitions manually.

## Product versions

`docs/RELEASE_VERSIONS.json` records delivered or actually verified product versions.
Prepared future builds must not be recorded as already delivered. Existing tags,
package names, bundle IDs and independent update channels remain compatible.

The Mac installer exchanges a bounded, single-use request and matching acknowledgement
through the existing App Group. Launch arguments are not its transport. Verify the
production parser with `scripts/test-update-installer.sh` and the real, windowless
sandbox/NSWorkspace handoff with `scripts/test-update-handoff-sandbox.sh` before
building. Both use isolated invented data and create no playback engine.

Before the final AppKit quit, asynchronous cleanup runs while the initial termination
request returns `terminateCancel`. A second request returns `terminateNow` only after
cleanup finishes. Do not return `terminateLater` from the updater's MainActor task:
AppKit's nested termination loop can hold that executor and starve its cleanup task.
`scripts/test-macos-termination.sh` exercises this production coordinator in actual
sandboxed, windowless AppKit processes, including repeated quit requests.

The 1.27.5 preparation's main-repository attempt also failed: macOS unloaded the
submitted background update job after the main app quit. The old fixture falsely
passed because its caller was a background agent, unlike the real app. The corrected
control uses a normal application and the production termination properties and
reproduces the interruption.

The repaired installer launches the visible native helper directly, keeping a progress
window and menu-bar item present before acknowledging the request and throughout
replacement/relaunch. Installation runs on a background queue while that UI stays
responsive. No custom launchd job, login item or hosting preference is created.
See Apple's [background-process rules](https://developer.apple.com/documentation/appkit/managing-ongoing-background-processes-in-your-mac).

`scripts/test-update-worker.sh --build-only` compiles the optimized, signed synthetic
fixture without executing UI. A full run requires explicit per-run approval, then
`AURELIA_UPDATE_UI_TESTS=1`; it shows temporary installer/test-app windows and checks
survival, real DMG mount, identity/team/build/signature validation, replacement,
automatic relaunch, and the new app remaining alive after the installer exits.
It uses no automated input, personal App Group, server, library or media. The approved
run on 03.11.2026 passed these synthetic checks. The owner-operated 131 → 132
installation also succeeded on 03.11.2026, as confirmed by the owner and the
installer status for build 132. The main repository was returned to private.

The Aurelia menu’s Check for Updates command is available before profile unlock
and while the server is unreachable. Local update settings skip server administration
requests and errors. The optional profile session close request is bounded to two
seconds during an update.
