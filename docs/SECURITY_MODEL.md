# Aurelia Security Model

Aurelia is a self-hosted media server designed for private LAN and remote streaming. This document defines the authorization model, role-based access control, and classification of operations across all clients and endpoints.

## Core Security Foundations

Aurelia protects user data and server operations through strict baseline controls:

1. **Device Authorization**: Every device or browser must be paired via an owner-authorized pairing code (`/api/v1/web/pairing` or `/api/v1/auth/pairings`). Paired devices receive a cryptographically random device session token.
2. **Profile Isolation and PIN Protection**: Within an authorized device, viewers select a profile. Owner and Administrator profiles always require a PIN. Regular viewer profiles may optionally be PIN-protected. Profile sessions expire after 12 hours or upon server restart.
3. **Cookie and CSRF Defenses**: The web client uses `HttpOnly`, `SameSite=Strict`, and `Secure` cookies. State mutations require an explicit `X-Aurelia-Web` header, preventing cross-site request forgery from malicious web pages on the same network.
4. **Transport Security**: Unencrypted HTTP is permitted only over the loopback interface (`127.0.0.1` / `::1`). Remote access requires verified TLS (HTTPS).
5. **Rate Limiting & Redaction**: Strict rate limits apply to authentication, pairing, and PIN/password attempts. Passwords, PINs, tokens, and personal file paths are redacted from server diagnostics.
6. **Read-Only Media Policy**: Aurelia only reads user media files; media is never modified, renamed, moved, or deleted on disk.

---

## Action Classification

Operations are categorized into three tiers:

### 1. Viewer Actions
*Authorization: Any active profile session (Viewer, Admin, or Owner).*
*No Server Password. No unlock required. No approval tokens.*

Normal viewing activities do not require administrative elevation:
- **Watchlist**: Adding, viewing, and removing titles from personal watchlists (`GET /api/v1/watchlist`, `PUT/DELETE /api/v1/media/{id}/watchlist`, `/api/v1/watchlist/batch`).
- **Watch Progress & History**: Updating resume points, playback state, and marking titles as watched or unwatched (`/api/v1/media/{id}/progress`, `/api/v1/media/{id}/watch-state`, `/api/v1/media/{id}/continue-watching`).
- **Favorites**: Toggling favorite titles (`/api/v1/media/{id}/favorite`).
- **Personal Scene Notes**: Creating, viewing, editing, and deleting personal timestamps and notes (`/api/v1/media/{id}/notes`).
- **Playback & Conversion Choices**: Selecting preferred audio streams, subtitle languages, and live conversion qualities (`/api/v1/media/{id}/playback`, `/api/v1/media/{id}/conversion`).
- **Scrub Previews**: Retrieving timeline preview frames for scrubbing (`/api/v1/media/{id}/scrub-previews`).
- **Streaming & Media Delivery**: Requesting stream tickets, video playback, embedded/sidecar subtitles, and artwork (`/api/v1/streams`, `/api/v1/streams/{ticket}/subtitles`, `/api/v1/artwork`).
- **Catalog & Collections**: Searching and browsing movies, series, episodes, franchises, and people (`/api/v1/catalog`, `/api/v1/franchises`). Creating, renaming, reordering, updating, and deleting own personal collections and smart lists; adding/removing collection items; creating personal collections from franchises (`/api/v1/collections`, `POST/DELETE /api/v1/collections/{id}/items/{mediaId}`, `POST /api/v1/collections/from-franchise/{id}`).
- **Watch History & Statistics**: Viewing personal watch history, deleting single history items, clearing own history (`GET/DELETE /api/v1/history`, `DELETE /api/v1/history/{id}`); viewing personal statistics and Year in Review (`GET /api/v1/statistics`, `GET /api/v1/statistics/year/{year}`). Strictly private to the authenticated profile (administrators cannot view other profiles' viewing history).
- **Remote Playback & Device Control**: Registering player heartbeat, querying online players on the user/account, reading player status, sending remote playback control commands (play, pause, stop, seek, skip), receiving commands via long-poll (`POST /api/v1/devices/player/heartbeat`, `GET /api/v1/devices/players`, `GET /api/v1/devices/players/{id}/status`, `POST /api/v1/devices/players/{id}/commands`, `GET /api/v1/devices/player/commands`).
- **Own Profile Settings**: Changing own profile PIN or PIN protection toggle (`/api/v1/profile/pin`, `/api/v1/profile/pin-protection`).

### 2. Admin Actions
*Authorization: Owner or Administrator profile session only. Non-admin profiles are refused with HTTP 403 `administration_required`.*
*No Server Password. No unlock required. No approval tokens.*

Server configuration and library management are directly accessible to administrators once signed into their PIN-protected profile:
- **Shared Collections Management**: Creating, editing, or deleting shared collections visible to all users (`POST /api/v1/collections` with `IsShared: true`, `PUT/DELETE /api/v1/collections/{id}`).
- **Library Health & Maintenance**: Inspecting duplicate media side-by-side, offline titles, and unmatched titles (`GET /api/v1/library/health/duplicates`, `/offline`, `/unmatched`); merging entries without touching disk files (`POST /api/v1/library/health/merge`); setting preferred duplicate versions (`POST /api/v1/library/health/preferred-version`); removing library database entries (`DELETE /api/v1/library/health/entries/{id}`).
- **Metadata Configuration**: TMDB API key management (`PUT/DELETE /api/v1/metadata/provider`, `/api/v1/metadata/provider/token`).
- **Storage Locations**: Adding storage folders, toggling directory monitoring, and scanning libraries (`/api/v1/libraries`, `POST /api/v1/libraries`, `PUT /api/v1/libraries/{id}/monitoring`, `/api/v1/libraries/{id}/scans`, `/api/v1/scans`).
- **Metadata Editing & Matching**: Editing title metadata, poster artwork, episode information, and triggering catalog search rebuilds (`/api/v1/media/{id}/editor`, `/api/v1/metadata/jobs`, `/api/v1/catalog/search/rebuild`).
- **Ordinary Profile Management**: Creating new profiles, editing name/avatar/access mode, changing roles for regular users, and resetting viewer PINs (`/api/v1/users`).
- **Scrub Preview Settings**: Configuring preview generation modes (off, on open/play, after import) and cache storage caps (`/api/v1/server/settings/scrub-previews`).
- **Database Backup Creation**: Triggering immediate database backups and verifying backup snapshots (`POST /api/v1/server/backups/database`, `POST /api/v1/server/backups/{name}/verify`, `POST /api/v1/server/backups/export`).
- **Server Health & Diagnostics**: Viewing system health metrics, storage consumption, background job statuses, and operational logs (`/api/v1/server/health`, `/api/v1/server/status`, `/api/v1/server/diagnostics/export`).
- **Power & Sleep Policy**: Configuring server idle sleep times and Wake-on-LAN policies (`PUT /api/v1/server/power`).
- **Software Updates**: Checking for server updates and triggering installation (`POST /api/v1/server/updates/check`, `POST /api/v1/server/updates/install`).
- **Device Management**: Creating client pairing codes and revoking non-current device sessions (`POST /api/v1/auth/pairings`, `DELETE /api/v1/auth/sessions/{id}`, `DELETE /api/v1/server/sessions/{id}`).

### 3. Critical Actions
*Authorization: Owner profile session (or Administrator for library reset/media deletion) + Server Password verification.*
*Requires explicit password verification and single-use `X-Aurelia-Approval` token.*

Only irreversible or highly destructive actions demand explicit confirmation with the Server Password:
- **Library Database Reset**: Clearing the entire server library database (`POST /api/v1/libraries/reset`).
- **Permanent Title Deletion from Library**: Deleting a media title completely from the library database (`DELETE /api/v1/media/{id}`). *(Note: Media files on disk are never touched).*
- **Database Backup Restore**: Restoring a database snapshot, which overwrites active server state (`POST /api/v1/server/backups/restore/prepare`, `POST /api/v1/server/backups/restore/{id}/apply`).
- **Server Password Modification**: Changing or resetting the Server Password (`PUT /api/v1/server/password`, `PUT /api/v1/users/{id}/password` for Owner/Admin).
- **Owner/Admin Profile Mutation or Deletion**: Deleting an Owner or Administrator account, or promoting/demoting an Owner role (`DELETE /api/v1/users/{userId}` for Owner/Admin, `PUT /api/v1/users/{userId}/role` involving Owner/Admin).
- **Server Factory Reset**: Wiping server state (`POST /api/v1/server/reset` or factory reset operations).

---

## Client Approval Handshake for Critical Actions

When a client initiates a Critical action:
1. The client presents a focused confirmation sheet stating exactly what will happen and requesting the Server Password.
2. The client requests a single-use approval token via `POST /api/v1/management/approval` (supplying the Server Password or utilizing an active password unlock).
3. The server validates the Server Password and returns an approval token bound to the HTTP method, exact path, payload hash, and profile session.
4. The client executes the critical request with the `X-Aurelia-Approval: <token>` header.
5. The server consumes the token atomically upon execution.

### Backwards Compatibility
- Older clients sending `X-Aurelia-Approval` headers for actions that are now categorized as normal Admin actions will succeed; the server accepts or ignores the header on non-critical endpoints.
- Newer clients communicating with older servers that return HTTP 403 `approval_required` or `management_locked` fall back to presenting the Server Password unlock prompt.
