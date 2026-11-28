# Moving to a new server

Tarven can move a whole server to another computer: a Linux server to a new Linux server, or
between a Linux server and the server in Tarven for Mac or Tarven for Linux. Titles, metadata,
artwork, progress, favorites, collections, profiles, settings, the server's identity and every
device's sign-in come along. Media files are never copied or changed; on the new computer each
storage location is pointed at the folder where the same files are now.

## For the owner

1. On the old server: **Settings › Server › Move to a New Server…** (Mac, Linux app or browser;
   asks for the Server Password). Choose:
   - **Over the network:** the old server shows a move code (`ABCD-EFGH-JKMN`, valid 15 minutes,
     one use).
   - **Moving file:** the old server writes an encrypted moving file protected by a passphrase,
     for a USB stick or a network share.
2. Set up the new server (browser or `sudo tarven setup` on Linux, **Set Up This Mac** on a Mac,
   hosting in the Linux app) and choose **Move from another Tarven server**. Pick the old server
   from the list (or type its address) and enter the move code, or choose the moving file and type
   its passphrase.
3. For each storage location Tarven suggests the folder on the new computer that holds the same
   files ("412 of 415 sample files found"). Confirm it, choose another folder, or choose **Later**:
   the location then stays offline with its titles until **Storage Location Moved…** points it at
   the new folder.
4. The new server starts with the old one's identity. The old server stops offering itself on the
   network and tells devices where the server went; devices stay signed in and switch on their own.
   **Undo Move** on the old server (or `sudo tarven move undo`) brings it back; turn the new one
   off first, two copies of the same server must never run at once.

Browsers reach the new server at its new address and sign in once there: their sign-in belongs to
the address.

On a Linux server without a screen the same works over SSH: `tarven move code` or
`tarven move export FILE` on the old server (as its owner), `sudo tarven setup --move` on the new
one (it asks for the address and code, or the file and its passphrase, and shows the suggested
folders to confirm), `tarven move status` and `sudo tarven move undo` on the old one again.

## Protocol

All bodies are JSON unless stated. Error bodies use the usual `{ "code", "message" }`.

### On the old server (Owner session, Server Password confirmation like other owner operations)

`POST` and `DELETE /api/v1/server/move` and `POST …/mark-moved` need an `X-Tarven-Approval` grant
(`POST /api/v1/management/approval` or `/api/v1/server/approval`), like a restore.

- `POST /api/v1/server/move` `{ "method": "network" }` →
  `{ "state": "waiting", "method": "network", "code": "ABCD-EFGH-JKMN", "expiresAt" }`.
  `{ "method": "file", "passphrase" }` → `{ "state": "waiting", "method": "file", "transferId" }`;
  the moving file downloads like a backup transfer
  (`GET /api/v1/server/backups/transfers/{transferId}`). Starting again replaces an unused code.
  Errors: 400 `move_method_invalid`, 400 `passphrase_invalid` (12–1024 characters), 409
  `network_access_required` (a network move needs the server's network access and its key), 409
  `server_moved`.
- `GET /api/v1/server/move` → `{ "state": "none"|"waiting"|"transferring"|"moved", "method"?,
  "expiresAt"?, "movedTo"?: { "serverId", "name", "addresses": [url] }, "movedAt"? }`.
- `POST /api/v1/server/move/mark-moved` → `moved` without the new server reporting (for a moving
  file when the new server couldn't reach the old one).
- `DELETE /api/v1/server/move` → cancels a waiting move, or undoes `moved`.

`waiting` (network) turns `transferring` once a claim succeeded; it stays so until the new server
reports or the owner cancels and starts again. The code lives only in memory; five wrong proofs end
it. The code itself is never sent.

### Between the servers (no session; rate limited; HTTPS)

Plain HTTP answers 403 `https_required`. The new server accepts the old server's self-signed
certificate only to read its public key (`observedSpkiSha256`); the claim's connection must show
the same key as the hello's.

- `GET /api/v1/move/hello` → `{ "serverId", "name", "nonce" }` while a network move waits, else 404
  `move_not_waiting`.
- `POST /api/v1/move/claim` `{ "nonce", "clientNonce", "proof" }`, where
  `proof = base64(HMAC-SHA256(key: normalized code, message: nonce | clientNonce | observedSpkiSha256))`
  and `observedSpkiSha256` is the SHA-256 of the public key the new server saw in TLS. The old
  server checks the proof with its own key, so a machine in the middle fails. Answer: the move
  bundle as `application/octet-stream` with its `Content-Length`, encrypted with AES-256-GCM under
  `HKDF-SHA256(ikm: code, salt: nonce | clientNonce, info: "aurelia-move" | spkiSha256)`.
  Errors: 403 `move_proof_invalid`, 403 `move_ended` (the fifth wrong proof), 404
  `move_not_waiting`. All values are raw bytes, sent as base64 (32 bytes each).
- `POST /api/v1/move/arrived` `{ "moveToken", "serverId", "name", "addresses": [url] }` from the new
  server after it started with the moved data; `moveToken` is a random secret inside the bundle.
  The old server enters `moved`. Works for both methods while the old server runs, also after
  Mark as Moved (it then only adds the addresses); a wrong token answers 403 `move_token_invalid`.
  The new server reports right after its first start with the moved data and again after 5 s,
  20 s, 1 min and 3 min, to every address it knows (the typed one and `sourceAddresses`), and
  accepts only its own key, which is the old server's: the identity moved.

### The move bundle

A full server backup (`FullServerBackupService`) that keeps device sessions and pairings, plus
`move.json`: `{ "version": 1, "serverId", "name", "moveToken", "sourceAddresses": [url],
"locations": [{ "id", "name", "path", "samples": [{ "relativePath", "size" }] }] }` with up to 200
samples per storage location (a location's video files in id order, which spreads them over the
location and gives every preview the same ones). A moving file is that bundle in the usual
encrypted backup container (`EncryptedBackupContainer`) with the passphrase; a network bundle uses
the same container under the HKDF key (its manifest says `iterations: 0`, so neither opens as the
other). `move.json` is never restored as state.

### On the new server while it has no owner

Allowed only before setup finished (otherwise 409 `server_already_setup`), over HTTPS or on this
computer, with the setup code the browser setup uses (header `X-Tarven-Setup-Code`; a wrong one is
403 `setup_code_invalid` and counts like a wrong code in the browser setup). App hosts (Tarven for
Mac and for Linux hosting their own server) use the authority they already use for
`POST /api/v1/setup/owner`: the header `X-Tarven-Bootstrap-Token` with the token they pass to the
server in `TARVEN_BOOTSTRAP_TOKEN` at start, from loopback only (otherwise 403
`bootstrap_required`). Move calls never use the token up. `sudo tarven setup --move` reads the
setup code from the server's data folder as root.

- `POST /api/v1/setup/move/network` `{ "address", "code" }` asks the old server's hello first, then
  fetches in the background and answers the status below (`fetching`, with `source`). Errors: 400
  `move_code_invalid`, 400 `move_address_invalid` (an address without `https://` gets it, without a
  port 43111), 404 `move_not_waiting`, 502 `move_source_unreachable` or `move_source_failed`, 409
  `move_in_progress`. A wrong code shows up as `failed` with `error`, since the old server checks it.
- `PUT /api/v1/setup/move/file` (body: the moving file, with `Content-Length`) → `{ "uploadId" }`,
  then `POST /api/v1/setup/move/file/{uploadId}/open` `{ "passphrase" }` → the status (`fetching`
  while the suggestions are made, then `received`). A wrong passphrase is 400 `backup_invalid` and
  may be tried again; a plain backup is 400 `move_file_invalid`.
- `GET /api/v1/setup/move` → `{ "state": "idle"|"fetching"|"received"|"applying"|"done"|"failed",
  "progress"?: { "received", "expected" }, "error"?, "source"?: { "serverId", "name" },
  "locations": [{ "id", "name", "oldPath", "sampled", "suggestions": [{ "path", "matched" }] }] }`.
- `POST /api/v1/setup/move/locations/preview` `{ "id", "path" }` → `{ "sampled", "matched" }`.
- `POST /api/v1/setup/move/finish` `{ "mappings": [{ "id", "path": string|null }] }` → rewrites the
  paths in the staged data (`null`, or a location left out, keeps the old path, offline), applies it
  and restarts the server with the moved identity, then reports `arrived` to the old server. It
  answers the status with `done` once the restart is on its way. A path must be an existing,
  absolute folder (400 `folder_invalid`); two locations in one folder are 409 `locations_overlap`;
  without received data 409 `move_not_received`. The restart works like a restore: an app host gets
  `restore-prepared` on its control channel and restores and starts the server; the Linux package
  writes `restore-on-start` and lets systemd start it again; any other server (Docker, by hand) does
  the same and ends with status 75 for its supervisor. The first start with the moved data makes a
  certificate for the new computer with the moved key, so pinned devices keep trusting it.
- `DELETE /api/v1/setup/move` → discards the staged data and answers the status (`idle`).

### Storage Location Moved (any time, Owner)

- `GET /api/v1/libraries/{id}/relocate/suggestions` → `{ "sampled", "suggestions": [{ "path", "matched" }] }`.
- `POST /api/v1/libraries/{id}/relocate/preview` `{ "path" }` → `{ "sampled", "matched" }`.
- `POST /api/v1/libraries/{id}/relocate` `{ "path", "force"?: bool }` (with an `X-Tarven-Approval`
  grant) → rewrites the location's and its titles' paths (and manual file bindings), clears their
  file identities and starts a scan that finds them by path; answers
  `{ "sampled", "matched", "titles", "scanId" }`. Refuses `matched == 0` for a location with samples
  unless `force` (409 `relocate_no_matches`), and while its scan runs (409 `library_scan_active`).
  Media is only read.

Suggestions search readable folders under `/mnt`, `/media`, `/srv`, `/home` and mount points on
Linux and `/Volumes` and the home folder on a Mac, four levels deep (plus the old path itself),
and rank them by matched samples (same relative path and size, read from the directory entry; no
media file is opened).

### A server that moved

The public `GET /api/v1/server/info` keeps answering and adds `"moved": { "serverId", "name",
"addresses": [url] }` (absent while not moved), so a reconnecting client can jump to the new
address. Every other API call except `GET /api/v1/server/move` and `DELETE /api/v1/server/move`
answers `409 { "code": "server_moved", "message", "movedTo": { "serverId", "name",
"addresses" } }`, with two exceptions: `POST /api/v1/move/arrived`, and the steps an owner needs to
reach Undo Move (`POST /api/v1/auth/login` from the server computer, `GET /api/v1/profiles`,
`POST /api/v1/profiles/{id}/unlock` and `/api/v1/web/profiles/{id}/unlock`,
`POST /api/v1/management/unlock`, `POST /api/v1/management/approval` and `/api/v1/server/approval`,
`POST /api/v1/profile/end` and `/api/v1/web/profile/end`, `DELETE /api/v1/device`). Pages of the
browser app still load. Bonjour advertising stops, and starts again after Undo Move. Clients that
see `server_moved` (or can't reach the saved address) switch to an address of the same `serverId`
with the same pinned key, from `movedTo` or from Bonjour, and keep their sign-in.
