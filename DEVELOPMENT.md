# Building and testing Aurelia

The repository contains a .NET server and a native SwiftUI macOS client. Install
the SDK pinned in `global.json`. The Mac client needs Xcode with the macOS 26 SDK
and its command-line tools selected with `xcode-select`. Scripts discover the
selected Xcode and `dotnet` on `PATH` rather than requiring a machine-specific path.

## Generated output

Builds and reports stay outside the checkout. The default workspace on macOS is
`~/Library/Caches/Aurelia/Artifacts`; other platforms use the user cache under
`Aurelia/Artifacts` (respecting `XDG_CACHE_HOME`). `AURELIA_OTHER_ROOT` selects a
different external workspace. `DOTNET_BIN` selects a specific SDK executable.
Never point generated output at the source tree or server data.

## Server

```sh
dotnet tool restore
dotnet restore Aurelia.slnx
dotnet format Aurelia.slnx --verify-no-changes --no-restore
dotnet build Aurelia.slnx --configuration Release --no-restore
dotnet test Aurelia.slnx --configuration Release --no-build
```

Tests use unique temporary data directories and synthetic media. No live library
or credentials are needed. `AURELIA_TEST_ROOT` can override the temporary parent.
CI runs server verification on macOS, including native image processing.

For CLI development, `dotnet run --project src/Aurelia.Server -- run` starts
loopback HTTP on port 43110. Use `--data-dir` to select disposable data. Never use
production data for mutation tests. Owner creation prompts for a password;
passwords and device tokens must not appear in arguments or logs. See
[server management](SERVER_MANAGEMENT.md) for network/recovery rules.

## Mac client

```sh
scripts/prepare-vlckit.sh
scripts/verify-build-number.sh
scripts/test-macos.sh
```

The official VLCKit archive is checksum-verified and stored in the external
cache. Only ignored dependency symlinks are created in the checkout. Open
`clients/macos/Aurelia.xcodeproj` and select the `Aurelia` scheme.

Signing needs a certificate/profile authorized for Aurelia's bundle ID and App
Group. Identifiers remain stable to preserve existing Keychain/container data.
A fork needs its own registered identifiers, matching entitlements, and migration
policy; changing the displayed name alone is insufficient. The checked-in team
identifier is a signing configuration, not a credential.

Mac tests stage executables in unique user-cache directories and retain reports
in the external workspace. UI tests require an unlocked GUI session and macOS
automation permission. A build-only check is not a UI pass.

After building a signed candidate, run:

```sh
scripts/test-native-host.sh /path/to/Aurelia.app
scripts/test-server-x64.sh /path/to/Aurelia.app
scripts/test-release-app-autostart.sh /path/to/Aurelia.app
scripts/test-recovery-disk-full.sh
```

The native-host smoke selects the current architecture. The Intel test uses
Rosetta on Apple Silicon without installing it. Report unavailable execution
separately from cross-compilation. Autostart requires free loopback ports; quit
the installed app cleanly first. Never stop unknown processes to make tests pass.

## Releases

See [the release checklist](docs/RELEASING.md). Development signatures are not
public GitHub downloads. Test before incrementing the build number, then verify
the final versioned bundle again. Updates replace only the app bundle and retain
accounts, connections, settings, library, and media.
