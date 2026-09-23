# Aurelia

Aurelia is a native, self-hosted media system. The server now maintains a
read-only movie and TV library, provides authenticated HTTP Range streaming,
and connects securely to a native macOS library and playback client. The Mac
starts as a host by default, preserves an explicitly selected
remote-client mode, and makes storage import available throughout the app.
People choose whole storage locations instead of separating movie and TV
folders themselves; Aurelia classifies clear structures locally and asks
only about ambiguous folders. Owners can optionally add their own TMDB token
for English metadata and bounded artwork storage; local names and manual edits
remain authoritative.
It has no browser interface and the native client is not a web wrapper.
An optional responsive web client may be added later for devices without a
native app.

## Non-negotiable data rules

- Aurelia Classic is a separate local-only app; its source, `Library.store`,
  and application data are untouched.
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
- Automatic storage locations with safe manual scans and persistent review decisions
- Per-library automatic filesystem monitoring with debounce, stability checks,
  startup/scheduled reconciliation, and offline-storage recovery
- Persistent lease-based scan and metadata queues with retries and cancellation
- Local filename parsing for movies, seasons, episodes, extras, and trailers
- Stable catalog IDs across unambiguous same-library moves, persistent
  missing-file state, and offline-drive protection
- Authenticated paged movie and series catalog APIs
- Short-lived, revocable playback URLs bound to one media file and device session
- Seekable HTTP Range streaming of original media without buffering whole files
- Per-user, cross-device watch progress with resume and completed-state handling
- Opt-in HTTPS access on the local network with a persistent server identity
- Bonjour discovery with a manual-address fallback
- Versioned JSON API under `/api/v1`
- Single-instance protection, serialized background scans, and graceful shutdown
- One-use, loopback-only bootstrap authorization for native owner setup
- Parent-process monitoring for an app-owned server process
- Optional TMDB metadata with cautious matching and an explicit review queue
- Authenticated artwork, cast and crew, collections, favorites, catalog search,
  and per-user Home recommendations with an hourly stable selection
- Compact presentation endpoints for paged movie/series cards and bundled
  details, with episode search context and no source paths in responses
- Server-side indexed search, combined catalog filters and sorting, revision
  ETags, and a bounded authenticated change cursor

## Current Mac client

- Native SwiftUI application for macOS 26 and newer
- Universal Apple Silicon and Intel executable
- A unified dark Apple TV/macOS 26 presentation across Home, Library, details,
  setup, settings, editors, and playback
- A transparent 236-point sidebar with content extending beneath it and no
  artificial title strip
- Hourly stable Home recommendations, Continue Watching, genre rows,
  favorites, collections, and Recently Added
- Artwork-rich movie, TV show, collection, season, episode, supplement,
  cast/crew, About, and information views with resilient placeholders
- Structured title, original-title, genre, person, series, season, and episode
  search; episode results open Direct Play immediately
- One consistent native sheet family for metadata, provider matching, review,
  and collection editing, restricted to owners and administrators
- Reliable host-first startup with an explicit, remembered remote-client mode
- Separately signed, windowless host helper with both self-contained server architectures
- App-Group-secured server bootstrap, bounded private logs, retry, and crash recovery
- Simple local setup with one password, storage selection, background scan status,
  pairing, and sessions
- A unified Add Media / Manage Media sheet for multiple folders and drives,
  library type selection, persistent scan history, rescans, safe removal, and
  classification review
- Per-library monitoring controls, health, automatic-change status, scan trigger,
  retry attempt, offline waiting, and cancellation in the media manager
- Foreground-only actor-isolated change polling with clean cancellation on
  backgrounding or server-profile changes and fallback for 1.0.12 servers
- Bonjour server discovery and manual server addresses
- Human-verified certificate pinning during one-time pairing
- Device token and server identity stored in the macOS Keychain
- Movie, TV show, season, episode, extra, and availability views
- Direct Play for movies, episodes, extras, and trailers through VLCKit 3.7.3
- A certificate-pinned, loopback-only streaming relay with no media cache
- Play/pause, five-second seeking, scrubbing, volume, mute, native fullscreen,
  and descriptive audio/subtitle track selection
- Automatic resume and regular server-side watch-progress updates
- No WebView and no local catalog or media cache
- Memory-bounded authenticated artwork loading through the certificate-pinned
  API session, with request coalescing, cancellation, and no persistent client cache

## Development

The repository uses the SDK pinned in `global.json`. Generated SDK and package
caches live outside the repository in `Aurelia Other/Package Cache`.

```sh
export PATH="../Aurelia Other/Package Cache/dotnet:$PATH"
dotnet tool restore
dotnet restore Aurelia.slnx
dotnet test Aurelia.slnx
dotnet run --project src/Aurelia.Server -- run
```

Build and test the Mac client with the checked-in Xcode project. The build-number
check keeps the server and app bundle on the same release number:

```sh
scripts/verify-build-number.sh
scripts/test-macos.sh
scripts/build-macos-release.sh
scripts/test-native-host.sh
scripts/test-release-app-autostart.sh
```

Generated builds, package caches, test results, and development logs are kept
outside the repository in the adjacent `Aurelia Other` directory. Test
source remains in the repository so every checkout can reproduce verification.
The Mac test script launches all runnable test products from the private
`~/Library/Caches/Aurelia/TestRuns` directory, so test execution cannot
accidentally ask for access to the protected Documents folder merely because the
repository lives there. It removes the temporary test host after copying the log
and result bundle to `Aurelia Other`.

The development server listens on `http://127.0.0.1:43110` by default. Override
the location of its small data directory with `AURELIA_DATA_DIR` or
`--data-dir`. Create the first owner without exposing the password in the
process list:

```sh
dotnet run --project src/Aurelia.Server -- setup-owner \
  --username lucas --device-name "Server Mac"
```

The command prompts for the password without echoing it and prints the initial
device token once. The default server remains restricted to loopback. After the
owner exists, opt in to encrypted local-network access explicitly:

```sh
dotnet run --project src/Aurelia.Server -- run --lan
```

This keeps the local CLI on `http://127.0.0.1:43110` and adds HTTPS on LAN port
`43111`. The server creates its long-lived TLS identity inside its private data
directory and prints a short verification fingerprint. Password login and owner
setup are rejected over the network; other devices use pairing.

While the server is running, create a one-time code for the Mac app:

```sh
dotnet run --project src/Aurelia.Server -- pairing create --username lucas
dotnet run --project src/Aurelia.Server -- server identity
```

Compare the fingerprint shown by the app with the local CLI output before
entering the pairing code. If the server identity changes later, the app blocks
the connection until the server is deliberately forgotten and paired again.

While the server is running, an owner or administrator can manage libraries
through the local CLI. The password is prompted without echo and the temporary
CLI session is revoked afterward:

```sh
dotnet run --project src/Aurelia.Server -- library add \
  --kind automatic --path "/Volumes/Media" --username lucas

dotnet run --project src/Aurelia.Server -- library list --username lucas
dotnet run --project src/Aurelia.Server -- library scan --all --username lucas
```

Advanced users may still use `--kind movies` or `--kind tv` for a fixed library.
Removing a library requires its ID and the explicit `--yes` flag; it removes
database records only and never touches media files.

Scans recognize MKV, MP4, MOV, M4V, AVI, and WebM. They read directory entries,
file sizes, and modification times only. Hidden files, AppleDouble files,
packages, and symbolic links are ignored.

An authenticated client requests a twelve-hour, single-file playback URL with
`POST /api/v1/media/{mediaId}/playback`. The returned relative URL accepts `GET`
and `HEAD`, including byte ranges for seeking. It contains a dedicated playback
ticket rather than the long-lived device token. Transcoding and automatic file
watchers are not part of the current build.
Automatic classification stays local and uses only the same filesystem facts
as the scanner.

Online metadata is optional and disabled until an owner supplies a TMDB API
Read Access Token under Advanced settings or through the CLI. The token is kept
in a private server file and never returned by the API or written to logs.
Metadata matching is deliberately conservative; uncertain titles remain local
and appear in a review queue instead of being guessed. Artwork is authenticated,
stored under opaque names, and limited to 1 GiB by default. This product uses
the TMDB API but is not endorsed or certified by TMDB.

```sh
dotnet run --project src/Aurelia.Server -- metadata configure --username lucas
dotnet run --project src/Aurelia.Server -- metadata refresh --username lucas
dotnet run --project src/Aurelia.Server -- metadata reviews --username lucas
```

Both the password and TMDB token are prompted without echo. Neither is accepted
as a command-line argument.

The Mac app gives VLCKit a random loopback URL. Its internal relay validates
that URL, forwards only GET/HEAD and byte-range requests over the already pinned
HTTPS connection, and streams responses incrementally. Neither the device token
nor the server playback ticket is exposed to VLCKit or written to logs. The
VLCKit download is pinned and verified by `scripts/prepare-vlckit.sh`; license
information is recorded in `THIRD_PARTY_NOTICES.md` and bundled with the app.

The Mac client stores its paired-server profile in a new app-owned macOS
Keychain namespace. Build 6 also uses a stable Apple Development signature so
future local builds retain the same Keychain identity. It deliberately leaves
incompatible legacy ACL entries untouched; upgrading from Build 5 therefore
requires pairing once again. UI tests use an in-memory profile store and never
read or write the production Keychain service.

For normal Aurelia use, launch Aurelia. A new installation first asks whether
this Mac should host the server or connect to an independently managed server.
Choosing **Set Up This Mac** opens the native assistant for server name, owner,
password, LAN HTTPS, and storage locations. Aurelia remembers that choice,
starts the local server on later launches, and opens the library directly.
Choosing an existing server keeps its startup under the server owner's control.
Technical server and port settings remain under Advanced. Clear movie and TV structures are classified automatically;
uncertain folders can be marked Movie, TV Show, or Ignore and reviewed again
later. Closing the last
window leaves the app and its server running; clicking the Dock icon restores
the window. Choosing **Aurelia > Quit Aurelia** stops both cleanly.
Existing remote profiles remain in client mode after upgrading. A deliberate
host or remote-client choice is versioned and remembered.

The sandboxed app starts its separately signed host helper through Launch
Services and exchanges only transient bootstrap files in their shared macOS App
Group. A versioned launch description is bound to the exact running app PID
and executable path, while the random 256-bit control secret crosses only a
permission-restricted FIFO and is removed immediately after use. The secret is
never placed in process arguments, environment variables, configuration files,
or logs. The helper has no Keychain access and stops its server if the owning app
disappears.

The product language is English for the first release. Additional localizations
will be introduced deliberately in a later milestone.
