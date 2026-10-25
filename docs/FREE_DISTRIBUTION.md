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
entitlements do require authorization. Aurelia's existing Keychain query does not
explicitly select an access group or force the Data Protection Keychain.

`AURELIA_SIGNING_IDENTITY=<matching-development-identity> zsh scripts/probe-profileless-macos-signing.sh`
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
AURELIA_DISTRIBUTION=profileless-development \
AURELIA_SIGNING_IDENTITY=<matching-Apple-Development-SHA-1> \
zsh scripts/build-macos-release.sh
```

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
AURELIA_SIGNING_IDENTITY=<matching-Apple-Development-SHA-1> \
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
longer launches. `zsh scripts/refresh-signing.sh --install` sets up a per-user
LaunchAgent that runs at login and twice a day. When a profile has less than three
days left, it asks Apple for a fresh profile (Xcode's signing step on a small checkout,
stopped once the profile arrives), embeds it, and re-signs only the outer bundle of the
installed Mac app and the adopted Apple TV build with the same certificate. Nested
code, identifier, entitlements and hardened runtime are preserved, and the version
does not change. The Mac app is skipped while it is open. A notification reports each
refresh or failure; the log is `~/Library/Logs/Aurelia Signing Refresh.log`.

Background jobs may not read `~/Documents`, so the job keeps its own copy of the
script, the checkout and the Apple TV app in
`~/Library/Application Support/Aurelia Signing Refresh`. Run
`--adopt-tv` after installing an Apple TV build, `--force` to refresh now, and
`--uninstall` to remove the job. A paid Apple Developer Program membership makes this
unnecessary with one-year profiles.

## Updating the Mac app

*Aurelia › Check for Updates…* asks GitHub for the newest release of the repository the app
was built from (`build-macos-release.sh` writes it into `AureliaUpdateRepository` in the
app's Info.plist; builds made in Xcode have none and cannot update). With a token saved, the
app also looks once a day at launch and speaks up only when a newer build exists.

A private repository needs a read-only token, made like the one for
[the Linux server](LINUX_SERVER.md): a fine-grained token for only this repository with
Contents: Read-only. Paste it under *Settings › App › Updates*. It stays in this Mac's
Keychain and is sent only to GitHub's API.

The app downloads the release's disk image and `SHA256SUMS` and checks the image against its
checksum. It then quits and hands the image to the server host helper, which runs outside
the sandbox. The helper waits until the app and its server have stopped, then mounts the
image read-only. It checks that the image holds the same bundle identifier, the expected
build number, a valid signature and the installed app's signing team. Only then does it
replace the app bundle and open the new version; the old bundle is moved aside first and put
back if the replacement fails. Library, server data, settings, sign-ins and media are not
touched, and no backup copy stays behind.

