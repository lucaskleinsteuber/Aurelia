# Aurelia Home

Aurelia Home is a native, self-hosted media system. The server now maintains a
read-only movie and TV library; the native desktop client and player come later.
There is intentionally no browser interface or web app.

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
- Versioned JSON API under `/api/v1`
- Single-instance protection, serialized background scans, and graceful shutdown

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
device token once. LAN discovery and HTTPS are intentionally deferred until a
native client can verify the server identity during pairing.

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
packages, and symbolic links are ignored. Online metadata, artwork, streaming,
transcoding, and automatic file watchers are not part of the current build.

The product language is English for the first release. Additional localizations
will be introduced deliberately in a later milestone.
