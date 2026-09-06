# Aurelia Home

Aurelia Home is a native, self-hosted media system. The server now maintains a
read-only movie and TV library, provides authenticated HTTP Range streaming,
and connects securely to the first native macOS library client.
Build 4 has no browser interface and the native client is not a web wrapper.
An optional responsive web client may be added later for devices without a
native app.

## Non-negotiable data rules

- Existing Aurelia source code and `Library.store` are separate and untouched.
- Media files stay at their original locations.
- The server never copies, converts, remuxes, transcodes, or caches video files.
- Server data contains only configuration, accounts, sessions, metadata, and
  bounded logs/assets introduced by later milestones.

## Current server

- .NET 10 and ASP.NET Core
- SQLite with versioned Entity Framework Core migrations
- One-time local owner setup
- Owner, administrator, and user roles
- Password login, revocable device sessions, and one-time pairing codes
- Explicit movie and TV library roots with safe manual scans
- Local filename parsing for movies, seasons, episodes, extras, and trailers
- Stable catalog IDs, missing-file state, and offline-drive protection
- Authenticated paged movie and series catalog APIs
- Short-lived, revocable playback URLs bound to one media file and device session
- Seekable HTTP Range streaming of original media without buffering whole files
- Opt-in HTTPS access on the local network with a persistent server identity
- Bonjour discovery with a manual-address fallback
- Versioned JSON API under `/api/v1`
- Single-instance protection, serialized background scans, and graceful shutdown

## Current Mac client

- Native SwiftUI application for macOS 26 and newer
- Universal Apple Silicon and Intel executable
- Bonjour server discovery and manual server addresses
- Human-verified certificate pinning during one-time pairing
- Device token and server identity stored in the macOS Keychain
- Movie, TV show, season, episode, extra, and availability views
- No WebView and no local catalog or media cache

Playback controls are intentionally deferred to the next milestone even though
the server streaming API already exists.

## Development

The repository uses the SDK pinned in `global.json`. On this development Mac it
is installed in `~/.dotnet`; add that directory to `PATH` in a new shell if the
`dotnet` command is not found.

```sh
export PATH="$HOME/.dotnet:$PATH"
dotnet tool restore
dotnet restore AureliaHome.slnx
dotnet test AureliaHome.slnx
dotnet run --project src/Aurelia.Home.Server -- run
```

Build and test the Mac client with the checked-in Xcode project. The build-number
check keeps the server and app bundle versions synchronized:

```sh
scripts/verify-build-number.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project clients/macos/AureliaHome.xcodeproj \
  -scheme AureliaHome -destination 'platform=macOS' test
```

Generated builds, package caches, test results, and development logs are kept
outside the repository in the adjacent `Aurelia Home Other` directory. Test
source remains in the repository so every checkout can reproduce verification.

The development server listens on `http://127.0.0.1:43110` by default. Override
the location of its small data directory with `AURELIA_HOME_DATA_DIR` or
`--data-dir`. Create the first owner without exposing the password in the
process list:

```sh
dotnet run --project src/Aurelia.Home.Server -- setup-owner \
  --username lucas --device-name "Server Mac"
```

The command prompts for the password without echoing it and prints the initial
device token once. The default server remains restricted to loopback. After the
owner exists, opt in to encrypted local-network access explicitly:

```sh
dotnet run --project src/Aurelia.Home.Server -- run --lan
```

This keeps the local CLI on `http://127.0.0.1:43110` and adds HTTPS on LAN port
`43111`. The server creates its long-lived TLS identity inside its private data
directory and prints a short verification fingerprint. Password login and owner
setup are rejected over the network; other devices use pairing.

While the server is running, create a one-time code for the Mac app:

```sh
dotnet run --project src/Aurelia.Home.Server -- pairing create --username lucas
dotnet run --project src/Aurelia.Home.Server -- server identity
```

Compare the fingerprint shown by the app with the local CLI output before
entering the pairing code. If the server identity changes later, the app blocks
the connection until the server is deliberately forgotten and paired again.

While the server is running, an owner or administrator can manage libraries
through the local CLI. The password is prompted without echo and the temporary
CLI session is revoked afterward:

```sh
dotnet run --project src/Aurelia.Home.Server -- library add \
  --kind tv --path "/Media/TV Shows" --name "TV Shows" --username lucas

dotnet run --project src/Aurelia.Home.Server -- library list --username lucas
dotnet run --project src/Aurelia.Home.Server -- library scan --all --username lucas
```

Use `--kind movies` for a movie library. Removing a library requires its ID and
the explicit `--yes` flag; it removes database records only and never touches
media files.

Scans recognize MKV, MP4, MOV, M4V, AVI, and WebM. They read directory entries,
file sizes, and modification times only. Hidden files, AppleDouble files,
packages, and symbolic links are ignored.

An authenticated client requests a twelve-hour, single-file playback URL with
`POST /api/v1/media/{mediaId}/playback`. The returned relative URL accepts `GET`
and `HEAD`, including byte ranges for seeking. It contains a dedicated playback
ticket rather than the long-lived device token. Online metadata, artwork,
transcoding, and automatic file watchers are not part of the current build.

The product language is English for the first release. Additional localizations
will be introduced deliberately in a later milestone.
