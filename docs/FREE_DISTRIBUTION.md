# Free Mac distribution: feasibility boundary

The intended download channel is GitHub, without requiring paid Apple membership
or an App Store release. A per-app Gatekeeper exception is appropriate only for
a trusted, intact non-notarized download; it cannot repair missing entitlements.

The standard development bundle uses a team-scoped App Group for the private
app/helper channel and declares restricted Keychain access groups. The existing
connection code uses the ordinary Mac file-based Keychain, not the Data Protection
Keychain or an explicitly selected access group. Container and credential
continuity must be verified for any signing-mode change. Removing sandboxing,
changing the signing team or writing tokens to plaintext is not a packaging fix.

`zsh scripts/probe-free-macos-entitlements.sh` builds a tiny ad-hoc-signed
diagnostic with an isolated synthetic group and credential. It never re-signs
the installed app, accesses its groups, or changes its accounts. The result is
bounded feasibility evidence, not a complete downloaded-app first-launch test.
An OS denial or failed group/Keychain access means this entitlement shape cannot
simply be assumed portable. Review the log; the script does not label a denial
as an application launch pass.

Apple documents that team-prefixed Mac App Groups require the signing team to
match, and restricted Keychain entitlements require profile authorization:
[App Group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers),
[provisioning profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles),
[Mac Keychain implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

A free packaging implementation may need a separately designed secure local
app/helper rendezvous and a credential migration policy. That is an architectural
security/data-continuity change, not a silent signing-flag substitution. Agree
on that design before modifying these boundaries. Preserve sandboxing, private
files, authenticated fixed host commands and protected credentials.

Until that route passes helper/Keychain/background-hosting checks and first launch
in a clean user or VM with Gatekeeper enabled, do not publish the local development
bundle as a portable public beta. The optional notarized packaging script remains
separate; it is not a prerequisite or the chosen release channel.

## Profileless local-development feasibility

Team-prefixed Mac App Groups do not themselves require a provisioning profile,
provided the signing team's identity matches. Restricted Keychain access-group
entitlements do require authorization. Tarven's existing Keychain query does not
explicitly select an access group or force the Data Protection Keychain.

`TARVEN_SIGNING_IDENTITY=<matching-development-identity> zsh scripts/probe-profileless-macos-signing.sh`
therefore tests an ordinary synthetic Keychain write/read/delete and an isolated
team-prefixed App Group in a correctly bundled, sandboxed app with no profile.
It does not read an existing connection, change the installed app or certify
credential migration, helper/background hosting or clean-machine distribution.

The local bundled probe passed on 2026-10-07. This is evidence for a possible
profileless development build, not permanent free distribution: the probe still
uses an Apple-issued development certificate. Retain this distinction when
evaluating a longer-lived local build versus a profile- and Apple-certificate-
independent public package.

## Explicit profileless local build mode

`build-macos-release.sh` supports an opt-in **local development** mode:

```sh
TARVEN_DISTRIBUTION=profileless-development \
TARVEN_SIGNING_IDENTITY=<matching-Apple-Development-SHA-1> \
zsh scripts/build-macos-release.sh
```

Setting `TARVEN_TEST_EDITION=1` builds **Tarven Test** (a side-by-side test edition with its own
bundle identifier, App Group, Keychain entry and launch agents, no self-updates, and Reset App Data
in Settings), which automatically uses `profileless-development`. When `TARVEN_SIGNING_IDENTITY`
is unset in `profileless-development` mode, `build-macos-release.sh` selects the first valid
*Apple Development* identity in the Keychain matching `TARVEN_TEAM_ID`; set
`TARVEN_SIGNING_IDENTITY` explicitly if you have multiple identities or want to pin one.

Find available identities with `security find-identity -v -p codesigning`. The
identity must belong to the existing signing team; no profile is selected or
embedded in this mode. The script checks the actual signing team and certificate
validity before building. It retains the bundle IDs, team-prefixed App Group,
application sandbox, selected-file permissions, network permissions, helper
entitlements and hardened runtime. Only the unused restricted Keychain-group
declarations and profile-dependent application/team entitlement additions are
omitted from the generated application signature. Existing entitlement sources
and the default profile-authorized development mode are unchanged.

`zsh scripts/test-profileless-signing-policy.sh` checks the generated permission
shape and rejects changed groups, removed protections, restricted identifiers,
and missing or malformed identities without signing or launching an app.

This removes the short provisioning-profile deadline from that candidate, **not
the Apple certificate's expiry or revocation risk**. The builder prints the
certificate validity dates. It does not install or re-sign the installed app;
the normal verified replacement workflow is still required. The notarized
packaging script deliberately does not accept this local mode as a public release.

Before switching an existing installation, run the synthetic continuity test with
the same identity and a valid matching baseline profile:

```sh
TARVEN_SIGNING_IDENTITY=<matching-Apple-Development-SHA-1> \
zsh scripts/probe-profileless-macos-continuity.sh
```

It writes one fresh synthetic ordinary-Keychain credential, changes only a
temporary probe's signature from the profile-authorized shape to the profileless
shape, and verifies read/update/delete. Two signed probe roles then exchange and
remove a synthetic file in a separate test App Group. The matching production
bundle ID is used only to authorize the baseline signature; no existing
credential, production App Group data or application preference is accessed.
Temporary processes are bounded and generated probe bundles are removed; macOS
container shells are retained. Tests emit status metadata, not credentials.

That test does **not** certify the real AppKit helper launch, `SMAppService`
registration, an existing user's actual connection, or a clean-machine download.
Verify the complete candidate with `test-native-host.sh` and
`test-release-app-autostart.sh` on isolated synthetic data before installation.
These tests require the normal app and host to be stopped; they never stop an
existing installation themselves. Background-service permissions remain subject
to macOS approval and must not be changed merely to make a test pass.

## Keeping local builds running

Free development profiles expire after 7 days, and an app with an expired profile no
longer launches. Build and install it again before then; a paid Apple Developer Program
membership gives one-year profiles.

## Updating the Mac app

*Tarven › Check for Updates…* asks GitHub for the newest release of the repository the app
was built from (`build-macos-release.sh` writes it into `TarvenUpdateRepository` in the
app's Info.plist; builds made in Xcode have none and cannot update). The repository is public,
so updates check and download anonymously; the app has no GitHub token setting. The app
also looks at launch and periodically while running (including after wake) when at least 24 hours
have passed since its last successful check.
*Settings › Updates › Check for updates automatically* is on by default; turning it off stops
background checks. Automatic updates require Tarven to be installed at `/Applications/Tarven.app`
with write permission to `/Applications` (a translocated copy in Downloads or another folder cannot
replace itself). *Check for Updates…* in the Tarven menu opens *Settings › Updates* and
checks there; its answer shows on that page instead of in dialogs.

Once an update is chosen (*Install and Restart* in the offer of a background check, or
*Install … and Restart* in *Settings › Updates*), *Settings › Updates* shows the download with
its size, percentage and Cancel, and the Dock icon carries a small progress bar; there is no
extra window. Then Tarven closes and reopens by itself. In offline mode, where Settings can't
open, the check answers in dialogs as before.

To protect GitHub's anonymous rate limit (60 requests per hour per IP), checks send the HTTP
`If-None-Match` header with the cached release `ETag`. When no newer release is published,
GitHub answers with `304 Not Modified`, which consumes minimal quota and completes instantly.
If GitHub limits requests, try again later. With *Beta updates* on, the app reads the list of
recent releases instead of the latest one, so it also finds pre-releases.

Every Mac release has one disk image per processor, `Tarven-<version>-<build>-macOS-arm64.dmg`
(Apple silicon) and `…-macOS-x64.dmg` (Intel), each with only its own server runtime, VLCKit and
ffmpeg slice. The updater downloads the image named for the architecture it was built for.

The update dialog shows the new version and the disk image's published download size.
Release notes are available on GitHub. *Later*
dismisses the offer; *Skip This Version* remembers that version on this Mac and suppresses
its automatic offers, including another build of the same version. Future versions are
still offered. A manual check also offers skipped versions, so they can still be installed.

The app downloads the release's `SHA256SUMS` and `SHA256SUMS.minisig`, verifies the minisign
legacy signature against the owner's embedded public key with CryptoKit (see
[LINUX_UPDATE_SIGNING.md](LINUX_UPDATE_SIGNING.md)), and only then downloads the disk image and
checks it against its checksum in `SHA256SUMS`. Without a valid signature nothing is installed.
Disk images stream directly to a private download folder while SHA-256 is calculated;
they are not buffered in memory. Files are downloaded through their API asset address on
`api.github.com` or the public GitHub download URL. Release descriptions and checksum lists
are limited to 3 MiB and 1 MiB, and images to 2 GiB. Downloads have an overall time limit, reject
HTML and oversized or incomplete responses, and remove partial files after failures. Consumed images
and their empty managed UUID folders are also removed after installation failures, including the
diagnostic no-relaunch path. Cleanup preserves unexpected files and rejects linked download folders.
Rate limiting, private repositories, invalid releases, checksum mismatches, interrupted downloads
and insufficient disk space have specific error messages. Asset URLs must belong to the configured
GitHub repository; storage redirects use HTTPS and strip authorization headers and cookies.

It then quits and hands the image to the server host helper, which runs outside
the sandbox. The helper waits until the app and its server have stopped, then mounts the
image read-only. It checks that the image holds the same bundle identifier, the expected
newer build number, a valid signature and the installed app's signing team. The staged copy
is checked again before replacement. Updating also stops a background host for this quit;
its background and login settings are retained for the next launch. Only then does it
replace the app bundle and open the new version; the old bundle is moved aside first and put
back if the replacement fails. Library, server data, settings, sign-ins and media are not
touched, and no backup copy stays behind after success or a successful rollback. If both
replacement and rollback fail, the original app is retained in the private transaction folder
and the error gives its recovery path instead of deleting it.

`sh scripts/test-update-installer.sh` exercises the production filesystem transaction with
invented bundles and injected signature/process checks in a unique
`~/Library/Caches/Tarven/TestRuns/` directory. It neither launches applications nor modifies
the installed app. Mac unit tests cover release validation, bounded transfer and checksum
rules, download failures and cleanup using a synthetic transport, plus release notes,
optional download sizes, automatic-check timing and version-specific skip choices using
private preference suites. Real GitHub asset redirects
and macOS first launch after an update still require a suitable newer published release.

