# Anonymous desktop update test

Mac and Linux Desktop have an explicitly enabled **Public Update Test** setting under
Settings → Updates → Advanced. Its only alternate source is
`lucaskleinsteuber/Aurelia-Update-Test`. The normal source remains the private
`lucaskleinsteuber/Aurelia` repository. This setting does not change server updates.

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

1. Verify and directly install Mac/server 1.26.6 (123) and Linux Desktop 1.0.2 (8).
2. Publish the verified audio releases through the normal channels: Mac/server
   1.27.0 (124) and Linux Desktop 1.1.0 (9). Copy the exact verified downloads into
   the separate public test repository, with license notices and a short README.
   Do not copy private source, history, credentials or diagnostic files.
3. Enable Public Update Test in both apps. The owner starts the normal update
   check and approves installation; Linux uses its normal `pkexec` prompt. The
   laptop test must use the native Arch package. Do not directly install the
   target build in place of this check.
4. Verify installed bundle/package metadata, relaunch, settings and retained
   connection/sign-in state. Inspect the boolean-only request diagnostics.
5. Turn off Public Update Test, verify the normal source, and make the test
   repository private. Leave saved tokens and published regular assets intact.

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
