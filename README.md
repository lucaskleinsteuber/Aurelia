# Aurelia Home

Aurelia Home is a native, self-hosted media system. The current milestone is
the independent server foundation; the desktop library and player come later.
There is intentionally no browser interface or web app.

## Non-negotiable data rules

- Existing Aurelia source code and `Library.store` are separate and untouched.
- Media files stay at their original locations.
- The server never copies, converts, remuxes, transcodes, or caches video files.
- Server data contains only configuration, accounts, sessions, metadata, and
  bounded logs/assets introduced by later milestones.

## Current foundation

- .NET 10 and ASP.NET Core
- SQLite with versioned Entity Framework Core migrations
- One-time local owner setup
- Owner, administrator, and user roles
- Password login, revocable device sessions, and one-time pairing codes
- Versioned JSON API under `/api/v1`
- Single-instance protection and graceful shutdown

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

The product language is English for the first release. Additional localizations
will be introduced deliberately in a later milestone.
