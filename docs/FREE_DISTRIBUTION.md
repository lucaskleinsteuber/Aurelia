# Free Mac distribution: feasibility boundary

The intended download channel is GitHub, without requiring paid Apple membership
or an App Store release. A per-app Gatekeeper exception is appropriate only for
a trusted, intact non-notarized download; it cannot repair missing entitlements.

The present development bundle uses a team-scoped App Group for the private
app/helper channel and restricted Keychain access groups for connection profiles
and migration. Its existing profile, container and credentials must remain
unchanged during ordinary updates. Removing those protections or writing tokens
to plaintext is not a packaging fix.

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
[provisioning profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

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
