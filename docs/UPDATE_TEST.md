# Anonymous desktop update test

Mac and Linux Desktop have an explicitly enabled **Public Update Test** setting under
Settings → Updates → Advanced. On 03.11.2026 the owner requested the main
`lucaskleinsteuber/Aurelia` repository for the next anonymous Mac test: they make it
public temporarily, and it returns to private after that test. Mac 1.27.5 and later
use this fixed main source when the setting is enabled. Disabling it restores normal
authenticated behavior without deleting the saved token.

The existing Linux 1.0.2 preparation still uses the separate, artifact-only
`lucaskleinsteuber/Aurelia-Update-Test` source. It remains available for its pending
owner-operated test and returns to private afterward. Neither setting changes server
updates. Repository visibility changes always require the owner's explicit instruction.

While enabled, the clients do not read, send, replace or delete a saved GitHub token.
Release metadata, checksums and packages must belong to the selected repository.
Redirects retain no Authorization or Cookie headers. The bounded Linux diagnostic
records only host and whether Authorization is present; Mac records that boolean in
the `com.lucas.aurelia.media` / `UpdateTest` log. Neither records tokens or signed URLs.

Mac caches a validated release body together with its ETag per repository. A 304
reuses that release; without a usable body it retries without a validator. Linux
searches up to ten pages of 100 releases. Reaching the limit is an incomplete check,
never evidence that the installed app is current.

## Test sequence

1. The original Mac/server 1.26.6 (123) preparation exposed a real sandbox handoff
   failure: Launch Services discards its installer arguments. Repair that installed
   updater with Mac/server 1.27.1 (125). The next real attempt exposed a separate
   AppKit termination deadlock: the app received acknowledgement but never exited.
   Mac/server 1.27.3 (127) repaired the quit path. Its attempt to update to 1.27.4
   exposed another real failure: Launch Services force-quit the subordinate GUI
   helper as the main app exited. Mac/server 1.27.5 (129) installs the independent
   worker repair; the next normal update targets 1.27.6 (130). Linux Desktop uses
   the original 1.0.2 (8) preparation.
2. Publish the verified audio releases through the normal channels: Mac/server
   1.27.6 (130) and Linux Desktop 1.1.0 (9). The Mac test uses the verified regular
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
   main-repository Mac test restore the main repository's private visibility; after
   the independent Linux test restore the download repository's private visibility.
   Leave saved tokens and published regular assets intact.

Logic tests, a real updater installation and the owner's listening check are
separate evidence. Audio verification uses settings, migration and configuration
tests; no automatic listening, synthetic signal playback or real media playback.
The owner assesses speech and loud/quiet transitions manually.

## Product versions

`docs/RELEASE_VERSIONS.json` records delivered or actually verified product versions.
`scripts/release-versions.py --readme` renders that record in the README. Both release
publishers render the same four rows, overriding only their own verified candidate.
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

The AppKit helper submits a one-shot worker through launchd, then exits. Only that
independent command-line role claims and acknowledges the request, installs, and
relaunches the app; it removes its exact transient job afterward. No job file, login
item or background-host preference is installed. `scripts/test-update-worker.sh`
checks worker survival after its sandboxed parent exits, then performs the complete
production transaction on signed invented bundles: request, real DMG mount, identity,
team/build and signature checks, replacement, automatic relaunch and job cleanup.
It creates no windows and accesses no personal App Group, server, library or media.
