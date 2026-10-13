# Viewing profiles and scene notes

Every paired device can open the server's profile picker. Normal profiles may
open without a PIN, or use a numeric Profile PIN of 4–8 digits. Owners and
administrators always require a PIN. It protects viewing on a trusted device;
it does not encrypt data against the server operator or unlock administration.
Anyone on a paired device can read an unprotected profile's favorites, progress
and notes, while those records remain separate from other profiles. A device
credential alone cannot read personal content.

## First setup and recovery

An existing owner confirms the Server Password once and chooses a separate
Profile PIN. The confirmed password hash becomes the shared server management
credential. Existing users, media IDs, library grants, artwork, favorites,
progress, device credentials and server identity are retained. Profiles without
a PIN stay locked until an owner sets one or explicitly removes protection for
a normal profile in Users & Access. Migration never removes PIN protection.

Owners can reset another profile's PIN during an active management unlock.
A protected profile can change its own PIN or remove optional protection by
supplying the current PIN. Owners and administrators cannot disable protection.
With one active owner,
a lost owner PIN can be recovered only through the private host channel on the
server Mac, after verifying the Server Password. A remote password alone
does not provide that recovery authority.

At application startup the picker is shown again. Only device credentials belong
in protected persistent storage. Viewing tokens remain in memory for at most
twelve hours, and end on profile switch or application termination. The server's
viewing tokens are also volatile: after a server restart, unlock the profile
again. Do not reinterpret authentication failures as network outages or silently
use the device credential to continue playback.

Management requires an unlocked owner/admin profile plus the shared Server
Password. Its ten-minute unlock never changes roles or content rights and never
extends with activity. Allowed changes do not request the password again.
Exact-action, single-use approvals are issued automatically from the unlock,
expire within two minutes or at its deadline, and bind its generation, session,
action and body. Locking, re-unlocking, profile switching or revocation invalidate
old grants. Destructive changes retain explicit scope confirmations. During the
window the session may perform every action its role permits; Lock Management
ends that authority immediately.
Profile PINs and the shared password must use the verified HTTPS connection;
local host bootstrap/recovery uses its authenticated private loopback channel.

## Content permissions

Owners choose `Entire Library` or `Selected Titles` for a profile. A series grant
covers its current and future seasons, episodes, extras and trailers. Existing
restricted accounts retain their previous complete-storage grants until an owner
explicitly changes their mode; migration does not expand their access.

Authorization precedes catalog/search counts and paging and applies to images,
details, collections, progress, notes and streams. Selected-title administrators
may manage shared titles but cannot browse storage, reset an entire storage
location or start library-wide work. Profile revocation, expiry, device revocation
and access removal also stop affected playback.

## API lifecycle

`GET /api/v1/capabilities` reports the required client version and profile/note
features. Legacy bearer tokens are device credentials only, not viewing tokens.

- Device credential: `GET /api/v1/profiles`, `POST /api/v1/profiles/initialize`
  (`password`, `pin`), and `POST /api/v1/profiles/{id}/unlock` (`pin`).
- Unlock returns `user`, `sessionId`, `token`, and `expiresAt`. Use this token for
  personal requests, artwork, streaming and synchronization. Never persist it.
- `POST /api/v1/profile/end` ends viewing without unpairing. `DELETE /api/v1/device`
  with the device credential disconnects that device and its viewing sessions.
- `PUT /api/v1/profile/pin` takes `currentPin` and `newPin`.
  `/api/v1/profile/pin-protection` takes `pinProtectionEnabled`, optional
  `currentPin` and new `pin`. Removing protection requires the current PIN when
  protected, and is forbidden for owners/admins.
- `POST /api/v1/management/unlock` takes `password`; `/lock` ends the unlock.
  `/approval` takes `action` and the SHA-256 `payloadHash` and returns a one-use
  token for `X-Aurelia-Approval`; its deprecated password field is ignored.
  `403 approval_required` rejects before mutation: obtain a proof and retry once.
  `403 management_locked` ends administration, not viewing or authentication.
- `POST /api/v1/users` creates a profile without an account password.
  `GET/PUT /api/v1/users/{id}/profile` atomically reads/saves role, enabled status,
  PIN protection and optional access changes against one revision. Omitted
  access preserves storage grants; stale saves return `409 profile_conflict`.
  Promotion requires an existing or supplied PIN. Legacy mutations also update
  this revision. Missing PIN-protection response fields default to protected.
- Owner-only `/api/v1/users/{id}/pin`, `/enabled`, and `/titles` manage PINs,
  enabled status and title access. Title access uses `mode`, `titleIds` and
  `revision`; a stale revision returns `409 profile_access_conflict`.

All these authorities are enforced by the server, not by visible buttons.
PIN failures are limited by device/profile and IP; five failures lock that
device/profile combination for at least one minute. PINs, passwords and bearer
tokens are never included in diagnostic exports.

## Personal scene notes

The player's bookmark button opens a compact popover without pausing. A note can
identify a moment or an interval; times accept `m:ss` or `h:mm:ss`, with optional
millisecond fractions. The position captured when opening is stable until edited.
Closing the popover retains a draft during that playback; Cancel discards it.

Notes appear in start-time order, can be edited/removed and support jumping to
the scene. Reaching a marked scene normally shows a small six-second hint without
revealing player controls. Seeking forward does not replay skipped notes; seeking
back re-arms them. Resume inside a marked interval shows it once. Preparation,
pause, title changes and profile changes cannot emit stale cues.

`GET /api/v1/media/{id}/notes` returns only the active profile's notes, including
for temporarily offline media. `PUT .../notes/{noteId}` takes `startMilliseconds`,
optional `endMilliseconds`, `text` and `revision`. New notes use a client UUID and
revision zero; edits use the acknowledged revision. `DELETE .../{noteId}?revision=N`
also checks the revision. Conflicts return `409 scene_note_conflict`; preserve
the client's draft until the user resolves them. The text limit is 2,000 UTF-16
code units. No notes are stored in the video or embedded chapters.

Notes use stable user/media IDs and emit profile-scoped synchronization changes.
Even an owner does not read another profile's notes through personal endpoints.
Title removal cascades to its notes; a disconnected drive does not. Database and
encrypted full-server backups include PIN/management hashes, grants and notes.
They retain explicit PIN protection and profile revisions. Older backups default
profiles to protected, even when PIN setup is still pending.
Older backups follow the same initial profile setup; explicitly restoring still
revokes device sessions according to the existing recovery rules.
