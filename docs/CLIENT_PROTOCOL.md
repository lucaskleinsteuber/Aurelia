# Building another Aurelia client

The shared JSON contracts are in `src/Aurelia.Contracts`. The macOS client is the
current reference implementation, not a dependency of another client. This
stabilization does not add Windows/Linux clients or certify either OS runtime.

## Connection and authorization

Use `/api/v1/server/info` to identify a server, then redeem an owner-authorized pairing
code. Discovery is a hint, not a trust decision: verify the server identity with
the owner and persist its SPKI pin. Do not trust a fingerprint just because an
untrusted server reports it. Require HTTPS for remote connections; loopback HTTP
is for the local host only. Never follow a credential-bearing redirect.

Store only the device token in the platform's protected credential store. Use it
to load `/api/v1/profiles` and open the chosen profile. Verify its PIN when
`pinProtectionEnabled` is true; missing fields default to protected. Keep the resulting
viewing token in memory and send that token for personal and stream requests.
End it when switching profiles or quitting; never auto-enter the last profile.
Keep accounts/sessions isolated
when caching artwork, catalog, progress or synchronization state. A revoked or
expired session must stop authenticated work, not be treated as a network outage.

The server enforces roles and library grants on every supported route. Hiding a
button is not an access control. Owner-only host settings are optional client
features; a normal user must not need them just to browse or watch.

Normal profiles may have no PIN; owners and administrators always require one.
Viewing sessions expire after at most twelve hours and are invalidated by server
restart. A device credential never substitutes for an expired viewing token.
Check `/api/v1/capabilities` for minimum client version and feature support.

See [SECURITY_MODEL.md](SECURITY_MODEL.md) for the three-tier action classification
(Viewer, Admin, and Critical actions). Routine administrative configuration (TMDB key,
storage folders, scans, metadata editing, ordinary profiles, power, updates, scrub previews)
requires an active Owner or Administrator profile session and no Server Password.
Critical actions (library reset, backup restore, modifying/deleting owner or admin accounts,
changing the Server Password) require explicit confirmation with the Server Password.
When a critical action returns HTTP `403 approval_required` or when requesting approval,
the client obtains a single-use proof through `/api/v1/management/approval` (with the Server
Password) and retries with `X-Aurelia-Approval`. Proofs bind the action, exact request
bytes, session and unlock generation, expiring within two minutes. Locking or switching
profiles cancels pending administration work and discards old proofs.

Profile editors use `GET/PUT /api/v1/users/{id}/profile` and a revision; stale
saves return `409 profile_conflict` without partial changes. Omitted access
preserves existing storage grants. Whole-library and selected-title rights
apply before counts, paging, artwork and streaming; series grants include their
descendants. Selected-title administrators cannot run storage-wide operations.
Retain persistent identifiers across cosmetic product renames so stored
connections and data remain available; never migrate Aurelia Classic data.

Personal scene notes use `GET /api/v1/media/{id}/notes` and revisioned
`PUT/DELETE .../notes/{noteId}`. New notes use a client UUID and revision zero;
stale changes return `409 scene_note_conflict`. Preserve the draft on conflict.
Notes belong only to the active profile and retain stable media identity when
storage is offline. They are database records, never embedded video edits.

## Web browser sign-in

The browser app ([WEB_APP.md](WEB_APP.md)) is served by the server from `/` and `/web/`. It
uses the same owner-approved code as an Apple TV, but no script ever sees a credential:

- `POST /api/v1/web/pairing` with `{deviceName}` starts a device pairing. The answer has
  only the code, its expiry and the poll interval. The pairing's id and secret go into an
  HttpOnly cookie that is limited to `/api/v1/web/pairing`.
- `POST /api/v1/web/pairing/status` reports the state. On approval the server acknowledges
  the delivery itself and sets the `aurelia_device` cookie, which lasts as long as the
  device session.
- `POST /api/v1/web/pairing/cancel` gives up a pending code.
- `POST /api/v1/web/profiles/{id}/unlock` with `{pin}` opens a profile and sets the
  `aurelia_profile` session cookie. `POST /api/v1/web/profile/end` ends it.
- `POST /api/v1/web/sign-out` revokes the device session and deletes both cookies.

All cookies are `HttpOnly`, `SameSite=Strict` and `Secure` on HTTPS. A cookie counts only
when the request names it in the `X-Aurelia-Web` header, either `device` or `profile`.
Another site cannot add that header without a CORS preflight, and the server never answers
one. Every `/api/v1/web/` call requires the header. The one exception is a plain `GET` or
`HEAD` of `/api/v1/streams/{ticket}` (including its `/live` stream) or `/api/v1/artwork/{id}`: it uses the profile cookie
without the header, because `<video>` and `<img>` elements cannot set headers. Changing
data with a cookie alone is refused.

A bearer `Authorization` header always takes precedence, so native clients are unaffected.

## Stable catalog loading

Catalog pages still have `items`, `offset`, `limit` and `total`. Current servers
add an opaque `revision`. Save the first page's revision and include it on later
requests using the `revision` query parameter. HTTP `409` with `catalog_changed`
means discard the incomplete result and start again, with a bounded restart
count. Do not publish partial lists or silently hide duplicate/missing items.

The revision is scoped to the account and database history. Do not interpret it
as a timestamp. Unknown additional JSON fields must remain compatible; older
responses without the optional revision are still readable. Check offsets,
totals, uniqueness and forward progress even against older servers.

## Changes and conditional responses

Long-poll `/api/v1/sync/changes` with `after` and `waitSeconds` (0–30). New servers
also return an optional `generation`; send it back on the next request. Persist
cursor/generation per server, user and device session, not just server address.
On `resetRequired`, reload the authorized snapshot before continuing from the
returned cursor. Restores rotate the generation; pruning retains a durable
high-water mark so an emptied history cannot masquerade as unchanged data.

Keep the ETag associated with its exact resource and account. Honor `304` only
when that cached body exists. A real `404` may identify an older missing sync
endpoint. Timeouts, `429`, `5xx` and malformed responses are not proof that sync
is unsupported: use bounded/backed-off retries and safe error messages. Preserve
HTTP status and bounded `Retry-After`; stop and ask for reauthentication on
`401`/`403`, and stop on a certificate identity mismatch.

Confirm a change cursor only after the corresponding local refresh succeeds.
For small `userState` or `metadata` batches, load Home and the authorized compact
`/api/v1/catalog/items/{id}/summary` responses instead of downloading the entire
catalog. A summary also supports episodes and supplements, does not load credits,
and applies the same library grants as other catalog routes. A `404` may mean a
removed or no longer shared item; do not retain it as an authorized card.

## Direct playback

Create a ticket through `/api/v1/media/{id}/playback`. Use its server-relative
stream path without exposing the token to a media engine or another origin.
Support GET/HEAD byte ranges and the returned length/type. Renew the ticket
before expiry; retry temporary failures only while the current authorization
remains valid. Stop on definitive access failure and cancel work when the player
closes. Save the user's progress and use the server's Continue Watching result.

Current progress responses include an integer `revision` (`0` when no state has
been saved) and optional `lastMutationId`. To replay progress safely, send a fresh
UUID `clientMutationId`, `enforceRevision: true` and the fetched `expectedRevision`
with each update. Retry a failed request with exactly the same mutation and values.
An exact replay of the latest committed mutation returns the original snapshot
without a new write, timestamp or change event. Reusing the UUID with different
values returns `409 playback_mutation_reused`; a stale baseline returns
`409 playback_progress_conflict`. Reload and retain the local draft for deliberate
resolution rather than silently overwriting another device's newer progress.
Backwards seeks are valid when based on the latest revision. Old unguarded clients
remain compatible, but invalidate the replay marker and advance the revision.
Responses without a revision cannot provide this replay guarantee; do not fall
back to unguarded background replay against those servers.

Playback authorization securely opens the current file rather than trusting a
previous scan's offline flag. An authorized missing/unreachable media source
returns `503` with `media_unavailable`; streaming also supplies `Retry-After`.
An unsafe path or refused file handle returns `409` with `media_file_unavailable`
and must not be treated as a reconnectable drive. Hidden or revoked tickets still
return `404`; access and certificate failures must never trigger trust bypasses.

Distinguish a completed media input from a truncated HTTP transfer or a stalled
decoder. On recoverable interruption, preserve the actual local position, cancel
old reads, obtain fresh authorization and use bounded backoff. Do not mark early
EOF as completed or remove the next episode from its queue before playback starts.
Explicit pause, player close and recovery cancellation must stop automatic work.
The Mac client retries at most six times without actual forward playback progress;
a successful reload alone does not reset that budget.

A new client must choose and test its own native decoding engine; byte-range
transport tests do not certify codec support.

## Live conversion

Servers that report `live-conversion-v1` (in `/api/v1/server/info` and
`/api/v1/capabilities`) convert a title while it plays, for players that cannot open the
original file, such as a web browser with an MKV. The server reports the feature only when it
found a working ffmpeg: its own in the Mac app, the system's on Linux, or the one named by the
`Aurelia:Ffmpeg` setting (`off` turns it off). Converted video is never stored: ffmpeg reads
the checked file and writes fragmented MP4 straight into the response. There is no cache, no
segment and no temporary file.

1. `POST /api/v1/media/{id}/conversion` with `{videoCodecs, audioCodecs}`, the codec
   families the player decodes from MP4 (`h264`, `hevc`, `av1`, `vp9`; `aac`, `mp3`, `ac3`,
   `eac3`, `opus`, `flac`). The answer is the plan:
   - `video`: `copy` repackages the picture unchanged; `h264` re-encodes it (at most
     1920 × 1080, 8-bit 4:2:0) because the player cannot decode it. `videoCodec` is its
     RFC 6381 codec string, `width` and `height` its size.
   - `durationSeconds`: the whole title, for the player's timeline.
   - `audioTracks`: every sound track with its stream `index`, `format`, `channels`,
     `language`, `title` and `isDefault`. `mode` is `copy` when the player decodes it, else
     `aac` (stereo AAC); `codec` is the codec string the player then receives.
     `audioTrack` names the track to start with.
   - `subtitleTracks` (optional on older servers): embedded subtitle streams with `index`,
     `format`, `language`, `title`, `isDefault`, `isForced` and `supported`. Text tracks can
     become WebVTT; bitmap tracks remain listed with `supported: false`.

   A server without ffmpeg answers `409 conversion_unavailable`; a picture it can neither
   repackage nor convert, `422 conversion_not_possible`. The file is read through the same
   access rules and secure handle as a playback ticket.
2. Create a playback ticket as for direct playback, then read
   `GET {streamPath}/live?start=<seconds>&audio=<index>&audioMode=copy|aac&video=copy|h264`.
   The answer is `video/mp4` as fragmented MP4 (an `ftyp` and `moov`, then `moof`/`mdat`
   pairs), without a length and without byte ranges. It keeps the title's own timestamps: a
   stream started at 600 seconds reports positions from about 600 on (repackaging starts at
   the key frame at or before that point). To seek outside what has arrived, close the stream
   and open a new one at the target. A stream counts against the device's stream limit like a
   direct one and ends with its ticket, session or profile. The server runs at most three
   conversions at once, at most one of them re-encoding the picture, and answers
   `429 conversion_busy` with `Retry-After` beyond that.
3. An embedded or sidecar text track is read with `GET {streamPath}/subtitles/{index}` under the same
   ticket, session and profile rules. Track indices `0..999` refer to embedded subtitle tracks; indices
   `1000+` refer to sidecar subtitle tracks discovered next to the video or in `Subs/` or `Subtitles/`
   directories. The response is `text/vtt; charset=utf-8`, private and uncached. SubRip (`.srt`),
   ASS/SSA (`.ass`, `.ssa`), `mov_text`, WebVTT (`.vtt`) and plain text are supported and converted
   in-memory; bitmap tracks (`.sub`/`.idx`) return `422 subtitle_not_supported`. All converted text
   subtitles are capped at 5 MB in memory with an LRU cache; no converted files are ever written to disk.

Reading paces the conversion: when the player stops reading, ffmpeg waits. Closing the
connection ends ffmpeg. PQ/HLG pictures re-encoded to H.264 are tone- and gamut-mapped to SDR
BT.709 with limited range; copied pictures and SDR sources keep their existing behavior.
The server detects a usable mapper when discovering ffmpeg: native perceptual `scale` mapping
in FFmpeg 9, or the older `zscale` plus `tonemap` filters. If neither is present, a request that
needs HDR picture re-encoding returns `422 hdr_conversion_unavailable`; original picture
copying remains available. Picture conversion beyond 1080p is not part of `live-conversion-v1`.

## Collections v2 and Smart Lists

The server reports capability `collections-v2`. Clients can interact with collections via:
- `GET /api/v1/collections`: returns shared collections (`UserId == null`) and own collections (`UserId == caller`).
- `POST /api/v1/collections`: creates a new manual collection or smart list. Viewers create personal collections; administrators can create personal or shared collections (`isShared: true`).
- `PUT /api/v1/collections/{id}`: updates collection name, rules, or item list. Viewers can only modify own collections; administrators can modify own and shared collections.
- `DELETE /api/v1/collections/{id}`: deletes collection. Viewers can only delete own collections; administrators can delete own and shared collections.
- `POST /api/v1/collections/{id}/items/{mediaId}`: adds an item to a collection.
- `DELETE /api/v1/collections/{id}/items/{mediaId}`: removes an item from a collection.
- `GET /api/v1/franchises`: returns all discovered TMDB franchise collections (`belongs_to_collection`).
- `POST /api/v1/collections/from-franchise/{id}`: creates a personal/shared collection pre-populated with all available franchise items.
- Smart lists include `isSmart: true` and a `rulesJson` string containing `SmartCollectionRules` (`kind`, `genres`, `yearMin`, `yearMax`, `decade`, `ratingMin`, `ratingMax`, `watchedState`, `addedWithinDays`, `favoritesOnly`, `textContains`, `combination`). Evaluations are cached in memory for 60 seconds with lazy paging.

## Watch History and Statistics

Each playback progress update automatically appends or updates a `WatchEvent` record.
- `GET /api/v1/history?offset=0&limit=20`: returns paged watch history for the authenticated profile.
- `DELETE /api/v1/history/{id}`: deletes a single history item for the authenticated profile.
- `DELETE /api/v1/history`: clears all watch history for the authenticated profile.
- `GET /api/v1/statistics`: returns personal viewing statistics (total hours watched, weekly and monthly hours, top genres, top titles, viewing streaks, busiest day and time of day, completion rate).
- `GET /api/v1/statistics/year/{year}`: returns Year in Review statistics for a specific year.
All history and statistics are strictly private to the profile session. Admins and other profiles cannot access them. Records are pruned automatically after 3 years.

## Library Maintenance and Health

Administrators can inspect and maintain the media library without touching any files on disk:
- `GET /api/v1/library/health/duplicates`: returns groups of duplicate titles detected by TMDB ID or normalized title and year.
- `GET /api/v1/library/health/offline?days=7`: returns media items that are offline or have not been seen in the specified number of days.
- `GET /api/v1/library/health/unmatched`: returns media items needing metadata matching or missing artwork/overview.
- `POST /api/v1/library/health/merge`: merges progress, favorites, watch events, and collection memberships from a source entry to a target entry, then removes the source entry from the database.
- `POST /api/v1/library/health/preferred-version`: marks a duplicate item as the preferred version.
- `DELETE /api/v1/library/health/entries/{id}`: deletes an obsolete entry from the server database. Media files on disk are never deleted or modified.

## Minimum new-client acceptance

Run isolated tests for trust rejection, pairing/login, two accounts with separate
libraries, revocation, coherent multi-page loading, interrupted/restarted sync,
range/HEAD playback, ticket renewal and progress. Use the real-socket checks in
[TRANSPORT_TESTING.md](TRANSPORT_TESTING.md) as a server-side baseline, then add
platform credential, decoding, UI and lifecycle tests. Server contract readiness
is not a guarantee of an untested client implementation.
