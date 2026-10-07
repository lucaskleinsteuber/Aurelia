# Aurelia Server management and recovery

Open **Aurelia → Settings → Server** while connected as an owner. Playback
preferences and metadata tools remain separate. Server settings are read from
the connected server, not copied over it by the Mac helper. Existing data,
accounts, session expiries, preferences, and TLS identity survive normal updates.
Aurelia Classic is the separate local-only reference application and is not
migrated. Historic identifiers of this server-backed product are retained only
for compatibility; they do not identify another current application.

## Settings

- **Overview:** current server status/version, uptime, active stream requests,
  database size, storage warnings, reachable addresses, and certificate expiry.
- **Network:** name, private LAN/VPN HTTPS access, HTTPS port, optional CIDR
  allowlist, Bonjour, and certificate identity. Stored and active settings are
  shown separately. Changes require password confirmation and a reachable
  native Mac host. Connect to the new address and confirm within 60 seconds;
  otherwise the host restores the previous configuration. Turning off remote
  access requires explicit additional confirmation.
- **Hosting:** app-owned hosting or explicitly enabled background hosting,
  start at login, restart, and optional idle-sleep prevention. Remote requests
  remain **Awaiting Mac approval** until applied on the server Mac. macOS may
  additionally require permission in Login Items; pending permission is not
  reported as active hosting.
- **Users & Access:** create/manage accounts, roles, enable/disable accounts,
  reset passwords, grant libraries, and inspect/revoke devices per user. The
  last enabled owner cannot be removed, demoted, or disabled.
- **Devices & Security:** new pairing, new-session lifetime, and concurrent
  request limits. Defaults are 90-day sessions, five-minute one-use pairing
  codes, 32 simultaneous stream requests globally, and four per user. Changing
  session policy does not silently expire existing devices.
- **Library & Jobs:** existing storage manager, monitoring/reconciliation,
  maintenance window in the host's local time, bounded queues, cancel, and retry.
  Automatic background work respects the maintenance window; manual jobs remain
  available. The job cap applies independently to the scan and metadata queues.
- **Backups:** daily/weekly retention, interval, verified database snapshots,
  encrypted full-server export, and guided restore. Defaults: daily snapshots,
  seven daily and four weekly snapshots.
- **Diagnostics:** bounded structured events and a sanitized export. Defaults:
  30 days, at most 10,000 events. Export excludes passwords, device/playback
  tokens, host-control secrets, provider credentials, and private keys.

Server-wide settings and security changes are owner-only. Administrators may
edit metadata and run library jobs only within their grants. Regular users can
play granted media and manage their own favorites and progress. New restricted
accounts have no grants. Migration grants existing non-owner accounts access
to the libraries that existed before this feature; later libraries are not
automatically shared. The common request-scoped access boundary also protects
legacy endpoints, artwork, counts, collections, and change notifications before
ordering and pagination.

Settings writes use a revision: concurrent stale edits return `409`, requiring
a reload. Sensitive changes require current-password confirmation for a
single-use grant bound to the session, action, and exact request bytes, valid
for at most two minutes. Revocation/account blocking/grant removal also cancel
active affected streams. Last-used timestamps are written at most once a minute.
That bookkeeping is best-effort during recoverable storage failures; session
and access checks still have to succeed before a request is authorized.

## Network and Mac service boundaries

Use the home network or a private VPN. Public source addresses are rejected;
there is no public-internet mode, TLS-off switch, proxy-header trust, or remote
shell. Native clients verify and pin the public key. Certificate renewal retains
the key; a genuinely different identity requires deliberate trust verification.
Keep routers/firewalls configured without public port forwarding.

Library and metadata CLI commands obtain the same one-use approvals for owner
changes. They allow HTTP only on localhost, verify HTTPS normally for remote
addresses, and do not follow redirects with credentials. Self-signed remote
servers need a certificate trusted by the CLI environment; do not bypass TLS
verification. Creating pairing codes through the CLI remains localhost-only.

The user-level `SMAppService` LaunchAgent is not a root service. Background
hosting is off unless expressly enabled, and legacy app-owned behavior remains
the default. Background hosting can run after login while the Mac is awake; it
does not keep a powered-off Mac or closed sleeping MacBook serving media.
macOS permission and service-registration status remain authoritative.

The helper accepts only fixed commands over a random-secret-authenticated
loopback channel. Request bodies use bounded `Content-Length` framing, not
chunked encoding. App-owned hosting stops when the app quits; background mode
hands ownership to its separately registered user service. An unconfirmed
network trial is journaled so its previous configuration can be recovered.

Configuration/key/backup directories are private to the host account. Media is
opened read-only with no-follow traversal and checked through the opened file
descriptor. The app does not defend against compromise of the server's OS/user
account. These controls and targeted tests are not an independent security
audit or a guarantee that no vulnerabilities remain.

## Full backup format and restore

Save a `.aureliabackup` export to separate trusted storage using a strong,
unique passphrase (12–1,024 characters). The container includes a verified
SQLite database, authoritative server settings, TLS identity, metadata-provider
configuration/credential when present, and data-protection keys. It does not
include videos, provider-downloaded artwork, macOS Keychain profiles, or Login
Items permission. Format 2 additionally includes manually imported image
originals and rendered crops. Media remains at the recorded original paths;
provider artwork can be fetched again. See [MEDIA_EDITING.md](MEDIA_EDITING.md).

Format version 2 uses .NET AES-256-GCM in 1 MiB blocks, a fresh salt/nonce prefix,
and PBKDF2-HMAC-SHA256 with 600,000 iterations. Authentication covers the
manifest, block indices/lengths/order, and final completion record; truncated,
reordered, extended, or modified containers fail validation. The implementation
uses built-in cryptographic primitives, not a new encryption algorithm.
Version 1 backups remain readable. Transfers and total payloads are bounded at
4 GiB; individual configuration/key entries at 1 MiB and owned image entries at
20 MiB. Version 2 accepts at most 50,000 allowlisted entries; version 1 retains
its 256-entry limit. At most four saved
transfers are retained, with 24-hour expiry on transfer housekeeping.

Restore decrypts into a private staging directory and checks integrity, paths,
SQLite/schema compatibility, enabled owner, settings, server identity, and TLS
key/certificate pairing. A confirmed restore first prepares a verified rollback
copy, stops the server, and activates state using same-volume renames with a
recovery journal. Interrupted activation recovers the previous state at startup.
The complete recovery journal is validated before any active file is moved,
including originals from the currently running state, not only incoming files.
Failed validation, cancellation before activation, or inability to prepare the
rollback copy leaves active state unchanged. Free enough storage before retrying.

Restoration intentionally invalidates every old device session, pairing code,
and playback ticket, preventing an old backup from reviving previously revoked
access. Reconnect and pair/sign in again afterward. Normal updates do not revoke
sessions. A restored database also receives a new synchronization generation,
so clients cannot reuse cursors from the previously active history. Applying
full restoration requires the native Mac helper; a standalone
server can export/validate backups but does not expose arbitrary remote process
or file-system control.

## Verification and performance

SQLite uses WAL with private pooled connection caches. Revisioned reads use
deferred snapshot transactions, allowing concurrent readers and the writer
without reserving the writer merely to serve a catalog page. Keep shared-cache
mode disabled; combining it with WAL introduces table locking that defeats
this concurrency. See [Microsoft's connection-string guidance](https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/connection-strings).

Tests use synthetic libraries/credentials and disposable directories only:

```sh
dotnet restore Aurelia.slnx
dotnet test Aurelia.slnx -warnaserror
scripts/test-macos.sh
scripts/test-native-host.sh /path/to/signed/Aurelia.app
scripts/test-release-app-autostart.sh /path/to/signed/Aurelia.app
scripts/test-recovery-disk-full.sh
sh scripts/test-server-transport.sh 30 2
scripts/test-server-settings-render.sh /path/to/signed/Debug/Aurelia.app
dotnet run --project tools/Aurelia.Server.Benchmark -- \
  /path/to/baseline/Aurelia.Server /path/to/candidate/Aurelia.Server \
  /path/to/external/benchmark.json
```

The 10,000-entry benchmark uses identical synthetic database snapshots, eight
credits per item, three warmups, and two concurrent clients (20 requests per
endpoint). It records p50/p95 latency, process CPU, sampled RSS, and EF command
counts; raw FTS command counts are not included. Compare results from the same
machine/configuration. This short local comparison is not a production
throughput guarantee. Compact cards avoid loading full credits; detail requests
still return them. FTS is maintained incrementally after successful writes;
change synchronization uses post-commit signals with a slow fallback. Direct
Play still has no transcoding, media copies, or video cache.
