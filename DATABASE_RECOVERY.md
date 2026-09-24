# Aurelia Server database recovery

Aurelia stores its server database as `aurelia.db` in the configured server data
directory. The server uses SQLite's online backup API for snapshots, so committed
changes still in the write-ahead log are included. Do not copy the live `.db`
file directly as a backup.

## Automatic and migration backups

While the server is running, its maintenance worker creates a verified daily
snapshot and a separate weekly snapshot. It retains the newest seven daily and
four weekly snapshots. It also makes a verified snapshot immediately before an
upgrade migration. Backup files live in the private `Backups` subdirectory of
the server data directory; their file and directory permissions are restricted
to the account running Aurelia.

Before any pending migration, Aurelia runs SQLite `quick_check` and
`foreign_key_check`, checks the recorded migration identifiers, and creates the
pre-migration snapshot. If verification or the snapshot fails, startup stops
before the migration. A failed migration also stops startup. Aurelia never
automatically restores a backup after corruption or a failed migration.

Backups contain only the SQLite database. They do not contain media files,
artwork, TLS identity, application settings, or the rest of the server data
directory. Because automatic backups are stored on the same volume as the
database, they do not protect against that volume failing; copy selected verified
backups to separate storage as part of the server's regular backup routine.

## Local database commands

Run commands on the server Mac/account. Use `--data-dir` if the server uses a
non-default data directory.

```sh
dotnet run --project src/Aurelia.Server -- database backup
dotnet run --project src/Aurelia.Server -- database verify
dotnet run --project src/Aurelia.Server -- database verify \
  --from "/path/to/aurelia-database-weekly-<timestamp>.db"
```

To restore, stop Aurelia Server first. Verify the chosen backup, then run the
explicitly confirmed restore command:

```sh
dotnet run --project src/Aurelia.Server -- database verify \
  --from "/path/to/aurelia-database-weekly-<timestamp>.db"
dotnet run --project src/Aurelia.Server -- database restore \
  --from "/path/to/aurelia-database-weekly-<timestamp>.db" --confirm
```

Restore acquires the exclusive server lock, verifies the source, stages and
verifies a SQLite backup copy, and preserves the current database before
replacing it. A pending explicit restore is resumed safely if the process exits
during replacement. An invalid source leaves the active database untouched. On
the next start, Aurelia applies any required forward migrations after creating
their own pre-migration snapshot. Restore is local-only; no HTTP restore route
exists.
