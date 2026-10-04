# Mac release checklist

Preparing a release does not authorize changing repository visibility, publishing
a GitHub release, or creating Apple account credentials. Keep private keys,
certificates, profiles, tokens, and result bundles outside Git. The intended
distribution is a free GitHub download, not the App Store. Paid Apple membership
is not a project requirement.

1. Verify the working tree, server format/build/tests, Mac tests, UI screenshots,
   native host, autostart, recovery, and both server architectures. Use synthetic
   data and cover fresh setup, existing-account upgrade, and unavailable storage.
2. Update app/server versions together and increment the build number once after
   pre-version checks pass. Never reuse a published build number.
3. Build a universal candidate using an authorized provisioning profile and
   certificate. `scripts/build-macos-release.sh` defaults to development signing.
   This candidate preserves the installed app's identity; it is not evidence that
   its profile and entitlements are portable. A free, non-notarized package must
   verify the helper, App Group, Keychain, and background-hosting requirements
   independently. Do not simply upload the development candidate.
   If Developer ID distribution is explicitly chosen, set
   `AURELIA_DISTRIBUTION=developer-id`,
   `AURELIA_SIGNING_IDENTITY` to the Developer ID certificate fingerprint, and
   `AURELIA_PROVISIONING_PROFILE` to its matching distribution profile. Existing
   team, bundle, and App Group identities must remain consistent.
4. Repeat runtime/UI checks on the final candidate. Signature checks alone do not
   demonstrate that the application works.
5. For the optional Developer ID route, store notarization credentials in a macOS
   Keychain profile with Apple's `notarytool`, outside Git. Set
   `AURELIA_NOTARY_PROFILE` to its name and run
   `scripts/package-macos-release.sh /path/to/Aurelia.app`. This explicitly
   submits the app to Apple. The script rejects development signatures, checks
   acceptance, staples the app, verifies Gatekeeper, and creates a versioned ZIP
   and SHA-256 checksum outside Git.
   This script supports only the notarized route; free packaging is not yet
   implemented. Do not imply that skipping notarization makes its output portable.
6. Check download/extraction and fresh setup with Gatekeeper enabled. A separate
   clean macOS user or VM can broaden isolation when no second Mac is available,
   but neither is equivalent to different physical hardware. Fresh CI runners
   currently verify the server, not GUI installation or downloaded-app trust.
   Verify first launch, permissions, host/client setup, supported synthetic-media
   playback, and upgrade without data loss. Record untested hardware/OS versions.
   For a verified non-notarized download, explain Apple's per-app **Open Anyway**
   flow for trusted apps; do not disable Gatekeeper globally or bypass malware,
   damaged-app, signature, or entitlement errors.
7. Complete license/third-party review, then publish release notes and the checked
   package/checksum only after explicit approval. Never publish the development
   candidate or rely on your own Mac's previous trust state.

Apple documentation: [Developer ID](https://developer.apple.com/developer-id/)
and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
Apple also documents [opening a trusted non-notarized app](https://support.apple.com/en-us/102445).

A local build is not a public-release check. Document which distribution path
and clean-environment behavior were actually tested, and leave unavailable
hardware coverage explicitly unverified.
