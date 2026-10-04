# Mac release checklist

Preparing a release does not authorize changing repository visibility, publishing
a GitHub release, or creating Apple account credentials. Keep private keys,
certificates, profiles, tokens, and result bundles outside Git.

1. Verify the working tree, server format/build/tests, Mac tests, UI screenshots,
   native host, autostart, recovery, and both server architectures. Use synthetic
   data and cover fresh setup, existing-account upgrade, and unavailable storage.
2. Update app/server versions together and increment the build number once after
   pre-version checks pass. Never reuse a published build number.
3. Build a universal candidate using an authorized provisioning profile and
   certificate. `scripts/build-macos-release.sh` defaults to development signing.
   For distribution, set `AURELIA_DISTRIBUTION=developer-id`,
   `AURELIA_SIGNING_IDENTITY` to the Developer ID certificate fingerprint, and
   `AURELIA_PROVISIONING_PROFILE` to its matching distribution profile. Existing
   team, bundle, and App Group identities must remain consistent.
4. Repeat runtime/UI checks on the final candidate. Signature checks alone do not
   demonstrate that the application works.
5. Store notarization credentials in a macOS Keychain profile with Apple's
   `notarytool`, outside Git. Set `AURELIA_NOTARY_PROFILE` to its name and run
   `scripts/package-macos-release.sh /path/to/Aurelia.app`. This explicitly
   submits the app to Apple. The script rejects development signatures, checks
   acceptance, staples the app, verifies Gatekeeper, and creates a versioned ZIP
   and SHA-256 checksum outside Git.
6. Download/extract the package on a separate clean Mac with Gatekeeper enabled.
   Verify first launch, permissions, host/client setup, supported synthetic-media
   playback, and upgrade without data loss. Record untested hardware/OS versions.
   Do not ask users to disable Gatekeeper.
7. Complete license/third-party review, then publish release notes and the checked
   package/checksum only after explicit approval. Never publish the development
   candidate or rely on your own Mac's previous trust state.

Apple documentation: [Developer ID](https://developer.apple.com/developer-id/)
and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Developer ID signing/provisioning, notarization credentials, and independent
clean-Mac download testing are prerequisites to verify, not consequences of a
successful local build.
