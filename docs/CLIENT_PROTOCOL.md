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

## Where the server runs

From 2.10.0, `GET /api/v1/server/info` reports `hosting`: `macApp` or `linuxApp` when Aurelia for
Mac or Aurelia for Linux hosts the server on a desktop or laptop, `linuxServer` for the Linux
package and `server` otherwise. An app-hosted server reports no `wakeOnLanAddresses`; a client
remembers `hosting` per server, forgets wake addresses it stored for it and, when the server does
not answer, asks to start Aurelia on that Mac or Linux PC instead of sending Wake-on-LAN.
`GET /api/v1/server/power` (owner) reports the same `hosting`; such a server offers only the modes
`off` and `stop`, and with `stop` it ends itself after the unused minutes (or five minutes after a
player's sleep timer, `afterSleepTimer`) with exit status 76, which its app treats as "stopped
until Aurelia is opened here", not as a crash.

## Web browser sign-in

A server without an owner can be set up from a browser instead (2.7.0): `GET /api/v1/web/setup`
answers `{open}`; `POST /api/v1/web/setup` with `{code, ownerName, password, deviceName}` checks
the one-time setup code from the server computer (`browser-setup-code` in the data folder, ten
wrong codes replace it, a day at most), creates the owner and sets the device cookie like `/pair`.
Both need the `X-Aurelia-Web` header and HTTPS; afterwards the request answers `409
server_already_setup`. `setup-browser` (the server command behind `aurelia setup --browser`)
turns on network access before an owner exists; until then the network reaches only anonymous
endpoints.

The browser app ([WEB_APP.md](WEB_APP.md)) is served by the server from `/` and `/web/`. It
signs in with the main device's pairing code like every other client, but no script ever sees
a credential:

- `POST /api/v1/web/pair` with `{code, deviceName}` redeems the code and sets the HttpOnly
  device cookie; the answer is empty (204). Servers before `web-pairing-code-v1` only offer the
  owner-approved flow below, which stays for older browser app versions.

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
   conversions at once, at most one of them re-encoding the picture on the processor (three
   on a video chip, see [Video chips](#video-chips)), and answers `429 conversion_busy` with
   `Retry-After` beyond that.
3. An embedded or sidecar text track is read with `GET {streamPath}/subtitles/{index}` under the same
   ticket, session and profile rules. Track indices `0..999` refer to embedded subtitle tracks; indices
   `1000+` refer to sidecar subtitle tracks discovered next to the video or in `Subs/` or `Subtitles/`
   directories; indices `2000+` refer to subtitles an administrator downloaded from OpenSubtitles,
   which the server keeps in its data folder (`Subtitles/`), never beside the media. All of them are
   listed by `GET {streamPath}/subtitles` with `isSidecar: true`. The response is `text/vtt; charset=utf-8`, private and uncached. SubRip (`.srt`),
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

### Video chips

On Linux the server looks for a video chip when it finds ffmpeg, in this order: Nvidia
(`h264_nvenc`), Intel Quick Sync (`h264_qsv`) and VA-API (`h264_vaapi`, Intel and AMD) on the
render nodes `/dev/dri/renderD128` onwards. A chip counts only when ffmpeg lists its encoder and
a one-second encode of an invented test picture to ffmpeg's null output succeeds; it then also
decodes when ffmpeg offers its decoder (`cuda` or `vaapi`) and falls back to the processor per
title by itself. When a chip fails before the first byte of a conversion, that title is
converted with `libx264` instead and the chip rests for ten minutes. `Aurelia:HardwareEncoding`
is `auto` (default), `off`, `nvenc`, `qsv` or `vaapi`; `Aurelia:MaximumVideoConversions`
overrides the limit of one picture encode at a time on the processor and three on a chip. The
Mac app's server uses Apple's VideoToolbox as before.

`GET /api/v1/server/transcoding` (owner) reports `available`, `encoder` (`nvenc`, `qsv`,
`vaapi`, `videotoolbox` or `libx264`), `encoderName`, `device`, `hardwareDecoding`,
`hardwareResting`, `runningConversions`, `videoLimit`, the running HLS `sessions` (`title`,
`quality`, `encoder`, `speed` against real time, `converting`) and a `hint`: one plain next
step when the computer has a chip the server cannot use (a missing VA-API driver, the `render`
group, `/dev/dri` not passed into a container, Nvidia's driver).

## Adaptive streaming (HLS)

Servers that report `adaptive-streaming-v1` (only when their ffmpeg can encode pictures) also
stream a title over HLS in several qualities, converted live. Every request carries a playback
ticket like a direct stream and is checked against its session and profile; the segments are
kept in memory only, for as long as someone plays them, and are never written anywhere.

- `GET {streamPath}/hls/master.m3u8?audio=<index>` lists the qualities, best first, each with
  `BANDWIDTH` (peak), `AVERAGE-BANDWIDTH`, `RESOLUTION` and `CODECS`. They are 1080p (8 Mbit/s),
  720p (4), 480p (1.8) and 360p (0.9), never larger than the original, the best one at most
  about the original's bitrate; a smaller original is offered once at its own size. Sound is
  stereo AAC of the chosen track (default: the file's default track). Addresses are relative.
- `GET {streamPath}/hls/<quality>/index.m3u8` is a video-on-demand playlist of 4-second segments
  over the whole title (`#EXT-X-PLAYLIST-TYPE:VOD`, `#EXT-X-MAP` to `init.mp4`).
- `GET {streamPath}/hls/<quality>/init.mp4` and `…/<n>.m4s` are the fragmented MP4 init segment
  and media segments. Segment `n` starts with a key frame at `4n` seconds of title time and
  keeps the title's own timestamps, so qualities can be switched between any two segments.

A session per profile session, title, quality and sound track runs one ffmpeg that converts
ahead of the player (up to 15 segments or 96 MB) and pauses there. A segment it has not reached
starts it again at that segment (a seek). Another quality of the same title makes the first one
stop converting. A session ends a minute after its last request, or at once with its user,
profile session or title; at most six run at a time (`429 conversion_busy` beyond that). A
title without a known length answers `422 stream_length_unknown`, a quality the title does not
have `404 stream_quality_not_found`.

## Subtitle downloads

The owner sets up OpenSubtitles.com with their own free API key and, optionally, an
OpenSubtitles account for more downloads a day (`GET`/`PUT /api/v1/metadata/subtitles`,
`DELETE …/key`, `DELETE …/account`). The key and password are written to private files in the
server's `Secrets/` folder and never returned; the status says only whether they exist. Up to
five languages (two-letter codes) are chosen in order of preference.

Administrators list, search, download and remove the subtitles of one movie or episode:
`GET /api/v1/media/{id}/subtitles`, `GET …/subtitles/search?language=de`,
`POST …/subtitles` with `{fileId, language, release, hearingImpaired, foreignPartsOnly}` and
`DELETE …/subtitles/{subtitleId}`. A search sends OpenSubtitles the TMDB id, season and episode,
the language and the OpenSubtitles hash (file size plus the first and last 64 KiB); file names
and paths are never sent. A used-up daily quota answers `429 subtitle_quota_reached`.

With **automatic downloads** on, the server looks every six hours for matched, online movies
and episodes without a subtitle in a chosen language (in the file, beside it or downloaded) and
downloads the best human-made match, at most 25 per pass, each title and language at most once
a week. Downloaded subtitles are not part of encrypted server backups; they can be downloaded
again.

## Subtitles from speech

When the server found a working ffmpeg it reports `speech-subtitles-v1`. A device with a speech
recognizer (the Mac app) then writes subtitles from what is said in a sound track; the server
does no recognition itself.

- `GET {streamPath}/speech-audio/tracks` lists the title's sound tracks
  (`{durationSeconds, tracks: [{index, codec, channels, language, title, isDefault}]}`) through a
  normal playback ticket.
- `GET {streamPath}/speech-audio?audio={index}` streams that track (the default one without
  `audio`) as raw 16-bit little-endian PCM, 16 kHz, one channel
  (`audio/L16;rate=16000;channels=1`, `X-Aurelia-Duration` in seconds). Surround tracks lean on
  their center channel, where dialogue sits. ffmpeg decodes it live with low priority and writes
  only to the response; nothing is stored, and it counts as one of the server's conversions.
- `POST /api/v1/media/{id}/subtitles/speech?language=de` (administrators, like subtitle
  downloads) takes the finished SubRip text as `text/plain`, at most 2 MB. It replaces earlier
  speech subtitles in that language and is listed with the downloaded subtitles as
  "German · From Speech"; players find it in the stream's subtitle list. No OpenSubtitles setup
  is needed.
- With `subtitle-sync-v1` (server 2.2.0), `POST /api/v1/media/{id}/subtitles/synced?language=de`
  takes a copy of one of the title's subtitles that the device moved to fit the speech. It is
  listed as "German · Synced", replaces an earlier synced copy in that language, and leaves the
  original (embedded, beside the video or downloaded) as it is. The device reads the original
  as WebVTT through `GET {streamPath}/subtitles/{index}`.

### Speech recognition on the server

A server from 2.11.0 reports `server-speech-v1`: it writes subtitles from speech and syncs
subtitles to speech itself, with whisper.cpp beside it (the Mac app's own build, or the
distribution's `whisper.cpp` package on Linux and in Docker). Sound is decoded by ffmpeg and
handed to whisper.cpp through its standard input in stretches of about ten minutes cut at a quiet
moment; sound and words stay in memory, and only the finished subtitles are stored, as
"From Speech" or "Synced" like those above. One title is examined at a time, at low priority,
pausing while anyone watches.

- `GET /api/v1/media/{id}/speech` (administrators) answers `{available, modelReady, job}`.
  `available` says whether whisper.cpp is installed, `modelReady` whether the owner downloaded a
  model. `job` is `{mediaId, title, kind: create|sync, language, subtitleIndex, state, progress,
  pausedForPlayback, message, subtitleId}` with `state` one of `waiting`, `listening`, `saving`,
  `done`, `alreadyInSync`, `failed` and `cancelled`.
- `POST /api/v1/media/{id}/speech` starts a job: `{kind: "create", language, audioIndex?}` writes
  subtitles in the spoken `language`; `{kind: "sync", language, subtitleIndex, audioIndex?}`
  moves the subtitle track `subtitleIndex` (numbered as in `{streamPath}/subtitles`) onto the
  speech, with offsets up to ten minutes, 23.976/24/25 frames per second and parts of another
  cut, and saves it as a synced copy in `language`. Subtitles that already fit are left alone
  (`alreadyInSync`); subtitles that fit nowhere are refused (`failed`, nothing saved). Without
  whisper.cpp or a model the answer is `409`.
- `DELETE /api/v1/media/{id}/speech` stops a running job, or clears a finished one.
- The owner reads `GET /api/v1/server/speech` (`{available, model, modelBytes, downloading,
  downloadError, models, jobs}`), downloads a model with `POST /api/v1/server/speech/model`
  (`{name: "base" | "small" | "medium"}`; one model is kept, in the data folder's
  `SpeechModels`) and removes it with `DELETE /api/v1/server/speech/model`.

## Intro and credits

A server from 2.8.0 reports `media-segments-v2`. It finds the intro and the credits of episodes
itself, in the background, and every client gets the same times. The playback ticket
(`POST /api/v1/media/{id}/playback`) carries them in an optional `segments` object:
`{introStartMilliseconds, introEndMilliseconds, creditsStartMilliseconds}`, each from the start
of the title and each possibly `null`. A missing `segments` means there is nothing to skip.
Clients never analyze media themselves and show no button without a time; the server prefers no
time to a wrong one.

- A client shows **Skip Intro** from one second before `introStartMilliseconds` until two
  seconds before `introEndMilliseconds` and jumps to `introEndMilliseconds`. Skipping
  automatically is the person's own setting on that device, off by default.
- From `creditsStartMilliseconds` a client offers the next episode with its countdown and a
  **Watch Credits** choice that keeps playing to the end of the file.
- `GET /api/v1/media/{id}/segments` returns the times with their origin
  (`introSource`/`creditsSource`: `none`, `chapters`, `detected` or `manual`), a confidence from
  0 to 1, `analyzed` and `canAnalyze` (episodes of a series; from 2.11.0 also movies, whose
  credits come from a chapter or their last pictures and whose intro only from a chapter).
- Administrators with management unlocked correct them: `PUT` with the three times makes each
  changed part `manual`, which no later analysis replaces; `DELETE` removes the corrections and
  has the episode examined again; `POST .../segments/reanalyze` examines the episode's season
  (or, for a series id, all its seasons, and from 2.11.0 for a movie id that movie) again.
- The owner reads the state with `GET /api/v1/server/media-segments` (`available`, `enabled`,
  `pendingCount`, `analyzedCount`, `noResultCount`, `running`, `pausedForPlayback`; from 2.10.0
  also `usePictures`, `totalCount`, `currentTitle`, `currentStep` and
  `estimatedSecondsRemaining`; from 2.11.0 `movieCount`, `moviesWithCredits` and
  `moviesPendingCount`, while the other counts stay episodes), turns detection or the pictures on or off with
  `PUT {enabled, usePictures?}`, lists each series with `GET /api/v1/server/media-segments/series`
  (`seriesId`, `title`, `episodeCount`, `withIntro`, `withCredits`, `pendingCount`) and starts over with
  `POST /api/v1/server/media-segments/reanalyze` (`{seriesId?, seasonNumber?, movies?}`; without a
  series `movies: true` examines only movies, `false` only episodes, and no value both). While it is off,
  tickets carry only times set by hand.

How the server finds the times and what it stores is described in
[Organizing your media](MEDIA_LIBRARY.md#intros-and-credits).

## Suggestions

A server from 2.11.0 reports `suggestions-v1`. `GET /api/v1/media/{id}/suggestions?limit=10`
(1 to 30) returns `{mediaId, suggestions: [{item, kind, reason}]}`, best first: movies and series
the profile may open (its age limit included) and has not finished. For an episode the
suggestions are for its series. `kind` is `nextPart` (the next film of a series of films, far
ahead of everything), `franchise`, `keywords` (shared TMDB keywords, rare ones weigh more),
`people`, `genres`, `studio` or `title`; `reason` says it in words, such as "Next in the Toy Story
Collection" or "Also directed by …", and clients show it instead of a percentage. Very different
age ratings weigh strongly against a title.

`GET /api/v1/home` adds `becauseYouWatched`: up to three rails `{sourceId, sourceTitle,
suggestions}` for the latest titles the profile finished or watched a while, each with titles no
earlier rail shows. With a watch history, `recommendation` (the hour's title) is one of the
profile's personal top ten. Older servers send no rails; clients show none.

In the player a client offers a suggestion when a movie reaches its credits or the last episode
of a series does: a card with **Watch Now**, **Watch Credits** and **Done**, without a countdown;
only the person's own setting *Play Suggestions Automatically* (off by default) starts it on its
own. At the end of the file an end screen shows the suggestion and two alternatives.

## Cinema mode

With `cinema-trailers-v1` (server 2.3.0), a player can show trailers before a film, as at the
cinema. `GET /api/v1/media/{id}/cinema-trailers?count=2` (0 to 3, 2 without `count`) answers
`{trailers: [{trailer, title}]}`: catalog items for one trailer each of up to `count` other films
in the profile's library that it has not started or finished, in random order, and the film each
trailer belongs to. Only trailers whose file is there are listed, and the profile's access and age
limits apply. A title that is not a film the profile can see answers 404, so a player also learns
from `count=0` whether a title gets a pre-show at all. Each trailer plays through its own normal
playback ticket; the player saves no progress for it.

## Watch Together

Several devices at home play one title in step. The server keeps each party in memory: the
title, whether it plays, the position at `updatedAt`, and its members (one profile on one
device each). While `isPlaying` is true and `isWaiting` is false, the shared position now is
`positionMilliseconds` plus the time since `updatedAt`; `serverTime` lets a client measure the
offset between its clock and the server's.

- `GET /api/v1/watch-together[?mediaId=]` lists parties for titles the profile may open.
- `POST /api/v1/watch-together` with `{mediaId, positionMilliseconds, isPlaying, deviceName}`
  starts one; `POST …/{id}/join` with `{deviceName}` joins. A profile session is in at most one
  party.
- `GET …/{id}?after={revision}&waitMs=20000` answers as soon as the revision is newer (long
  poll, at most 25 s). Asking at least every 40 s keeps a member in the party; these polls do
  not keep a power-saving server awake.
- `POST …/{id}/commands` with `{action, positionMilliseconds?, mediaId?}`: `play`, `pause`,
  `seek`, `buffering`, `ready` and `change` (to another title, such as the next episode).
  A joining member, everyone after `change`, and a member that reports `buffering` hold the
  party at the same picture until they report `ready`, for at most 30 seconds.
- `DELETE …/{id}/members/me` leaves; the last member ends the party.

The Mac, Linux, Apple TV, iPhone, iPad and browser players follow the party: they jump to the shared moment when they are more
than 1.5 seconds apart (0.5 seconds while paused), and send their own play, pause, seek and
title changes as commands. Answers that arrive out of order never undo a newer revision.

## Movie Night

Everyone at home swipes through the same deck of films (and, if the host wants, shows); the
first title every voter liked is the match. The server keeps each night in memory. A member
is one profile on one device and either votes or, with `isVoting: false`, is a screen that
only shows the lobby, everyone's progress and the result (the Apple TV starts as one).

Each member brings the films and shows its profile may open; a deck only holds titles every
member may open, so a children's profile in the night limits it for everyone. Nobody learns
how another member voted, only how many cards each has swiped. A night with a children's
profile (one with an age limit) gets the friendly lines.

- `GET /api/v1/movie-night` lists open nights: `{id, hostName, hostDevice, memberCount, phase}`.
- `POST /api/v1/movie-night` with `{deviceName, isVoting}` starts one; `POST …/{id}/join` with
  the same body joins. A profile session is in at most one night.
- `GET …/{id}?after={revision}&deckVersion={n}&waitMs=20000` is the long poll (at most 25 s;
  ask at least every 40 s to stay in). `deck` is null when `deckVersion` is the current one.
  These polls do not keep a power-saving server awake.
- `POST …/{id}/settings` with `{kinds: "movies"|"all", genre}`: the host only; `genre` is one of
  `genreOptions` or null.
  Servers from 2.7.0 also take `era` (`any`, `2020s`, `2010s`, `2000s`, `older`) and `length`
  (`any`, `short` = films up to 100 minutes, `standard` = up to 130) and report both in the state;
  a request without them means `any`, so older apps leave every era and length in.
- `POST …/{id}/deal` deals up to 40 titles in one order for everyone (films the dealer has
  finished are left out, and nothing dealt before comes again). It starts the night and deals
  again later; everyone's votes start over. `409 movie_night_empty` when nothing is left.
- `POST …/{id}/votes` with `{mediaId, like}`; `POST …/{id}/keep-swiping` sets a match aside;
  `POST …/{id}/role` with `{isVoting}` switches between voting and watching.
- `DELETE …/{id}/members/me` leaves; the last member ends the night.

`phase` is `lobby`, `voting`, `match` or `no-match`. With every card swiped and no match,
`result` holds the title most voters liked (`card` is null when nobody liked anything). The
result also carries a `headline`, a cheeky `line` and `awards` such as "Hardest to please".

## Offline downloads

A person may download a movie or episode to their own Mac or Linux computer. The app streams
the original file once through a normal playback ticket and the loopback relay (so the pinned
certificate and sign-in apply) and keeps it, with the stream's subtitle files as WebVTT, in its
own data folder: the sandboxed Application Support on the Mac, `$XDG_DATA_HOME/aurelia-desktop`
on Linux. Nothing is written on the server or next to the media. A download plays through the
normal player without the server; progress watched offline is saved on the computer and sent
with the expected revision once the server answers and the profile is open, unless the server
already has a newer position.

## Collections and smart lists

The server reports capability `collections-v3` (extending `collections-v2`).

- `GET /api/v1/collections` and `GET /api/v1/catalog/collections` list shared collections and the
  caller's own. A collection with `isShared: true` belongs to the administrators; any other belongs
  to one profile, which is the only one that can see or change it (administrators included). Each
  summary includes `id`, `name`, `overview`, `poster`, `backdrop`, `provider` (`tmdb`, `universe`,
  `local` for a folder, or `null` for own collections and smart lists), `canEdit`, `isSmart`, `isShared`, `userId`,
  `rulesJson`, `sortMode` (`custom`, `release`, `title`), `itemCount`, `watchedCount`, `yearRange`,
  `totalCount` and preview `items`.
- `GET /api/v1/collections/{id}` returns a `CollectionDetail` with the above fields plus
  `totalRuntimeSeconds`, `genres`, ordered `members` (`id`, `mediaId`, `kind`, `title`,
  `seasonNumber` where `0` represents Specials, resolved `item`, season `episodes`, `watchedCount`,
  `itemCount`, `totalRuntimeSeconds`) and `nextItem`.
- `POST /api/v1/collections` creates a collection from
  `{ name, mediaIds, isSmart, isShared, rulesJson, overview, sortMode, members }` where `members`
  holds `{ mediaId, seasonNumber }` entries so movies, shows, individual seasons and episodes can be
  mixed. Only administrators may set `isShared`. `PUT /api/v1/collections/{id}` replaces metadata,
  members or rules; `PUT /api/v1/collections/{id}/order` updates member order and `sortMode`;
  `DELETE /api/v1/collections/{id}` removes the collection, never a title.
- `POST` and `DELETE /api/v1/collections/{id}/items/{mediaId}` (with optional `?seasonNumber=`)
  add or remove a movie, series, season or episode. A smart list answers `409 smart_collection`
  (its rules choose its titles); an automatic collection (`canEdit: false`) answers
  `404 collection_not_found` to every change.
- `GET /api/v1/collections/{id}/next` (matching `detail.nextItem`) returns the continuous playback
  target `{ item, resume, positionMilliseconds, itemIndex, totalItems }` across the collection's
  ordered playable items (`404 no_playable_items` when empty).
- Custom collection artwork uses draft uploads `POST` / `GET` /
  `DELETE /api/v1/collections/{id}/editor/uploads[/{uploadId}]` (`EditorUploadSummary`) and
  commits or clears a `poster` (2:3) or `backdrop` (16:9) with `POST` /
  `DELETE /api/v1/collections/{id}/artwork/{kind}` (`{ uploadId, crop }`). Artwork URLs are
  served at `/api/v1/artwork/collection/{id}` (`?kind=poster|backdrop&width=...`) and
  `/api/v1/artwork/collection/{id}/{kind}`, falling back to TMDB collection artwork, then a cover made from
  up to four member posters and the first member's backdrop, when no image of its own is set.
- A smart list's `rulesJson` is a `SmartCollectionRules` object: `kind` (`movie`, `series` or
  `episode`), `genres`, `yearMin`, `yearMax`, `decade`, `ratingMin`, `ratingMax`,
  `watchedState` (`unwatched`, `inProgress`, `watched`), `addedWithinDays`, `favoritesOnly`,
  `watchlistOnly`, `textContains` and `combination`. With `and` a title must meet every rule
  (and every genre); with `or` one rule is enough. Text and genres match literally. The server
  stores the rules in exactly these names and answers `400 invalid_smart_rules` when
  `rulesJson` is not a JSON object; for lists saved by earlier apps it also reads `watched`,
  `watchState`, `search`, `match` (`any`/`all`), `matchAny` and the kind `movies`. Results are
  evaluated per profile and kept for 60 seconds, except watchlist-only lists.
- `GET /api/v1/catalog/franchises` lists automatic TMDB film-series and `universe` collections;
  `POST /api/v1/collections/from-franchise/{id}` turns one into an editable personal collection.
  Any other id answers `404 franchise_not_found`.

## Watch history and statistics

Saving playback progress records the viewing in a history entry (one per title and sitting;
time counts only while the position advances, so a pause adds nothing).

- `GET /api/v1/history?offset=0&limit=20` returns `{ items, offset, limit, total }`; each item
  has `id`, `mediaId`, `title`, `eyebrow` (series and episode, or the year), `year`, `kind`,
  `poster`, `watchedAt`, `positionMilliseconds`, `durationMilliseconds`, `secondsWatched` and
  `isCompleted`.
- `DELETE /api/v1/history/{id}` removes one entry; `DELETE /api/v1/history` clears them all.
- `GET /api/v1/statistics` and `GET /api/v1/statistics/year/{year}` summarize the profile's
  viewing. Days, weekdays and hours are counted in the server's time zone. Watch times are
  hours to the second (`totalHoursWatched`, `hoursPast7Days`, `hoursByWeek` with ISO weeks such
  as `2026-W43`, and `hours` beside each top genre and title), so clients can show minutes.
- `GET /api/v1/statistics/year/{year}/wrapped` (capability `year-wrapped-v1`) is the year as
  slides, like a story: `{ year, profileName, slides }`. Each slide has `kind`, `eyebrow`,
  `headline`, an already formatted `bigNumber` with its `unit`, `detail`, a cheeky `quip`, an
  `accent` color name (`night`, `ember`, `violet`, `gold`, `rose`, `mint`, `ocean`, `lime`) and
  optionally `mediaId`, `poster`, `posters` and `facts` (the summary slide). The server picks
  which slides to show and their lines, the same each time for a profile and year; a children's
  profile gets friendly lines. Clients show unknown kinds like any other slide.
- `GET /api/v1/statistics/year/{year}/month/{month}/wrapped` (capability `monthly-wrapped-v1`)
  is the same for one month, with `month` set in the answer. A month is ready from the 2nd of
  the following month in the server's time zone; before that the server answers 404
  `wrapped_not_ready`. Clients offer the newest ready month: the previous month from the 2nd on,
  otherwise the month before it.

History and statistics belong to the profile alone; no other profile, administrators
included, can read them. Entries older than three years are pruned.

## Library Health

For administrators. Nothing here changes a file on disk.

- `GET /api/v1/library/health/duplicates` returns groups `{ key, title, kind, year, items }`:
  movies with the same provider match (or, without one, the same title and year), and
  episodes with several files for the same season and episode. Each item has `id`, `title`,
  `kind`, `year`, `fileName`, `fileSize` and `availability`.
- `GET /api/v1/library/health/offline?days=30` returns titles whose file has been missing for
  at least that many days: `id`, `title`, `kind`, `year`, `libraryName`, `fileName`,
  `lastSeenAt`, `daysOffline`.
- `GET /api/v1/library/health/unmatched` returns movies and series without usable details:
  `id`, `title`, `kind`, `year`, `fileName`, `issueReason`.
- `POST /api/v1/library/health/merge` with `{ sourceMediaId, targetMediaId }` moves every
  profile's favorites, progress, history and collection membership from a copy whose file is
  missing to another copy of the same movie or episode, then removes the missing copy.
- `DELETE /api/v1/library/health/entries/{id}` removes a title whose file is missing.

Both changes refuse a title whose file is still available (`409 source_available`): the next
scan would bring it back. Removing such a title is `DELETE /api/v1/media/{id}`, which needs the
server password and keeps the file out of later scans. Paths are never returned, only file names.

## Family Wishes

Servers with capability `wishes-v1` let household profiles request movies and TV series not yet in the library (`GET/POST /api/v1/wishes`, `GET /api/v1/wishes/summary`, `GET /api/v1/wishes/search`, `PUT /api/v1/wishes/{id}/support`, `PUT /api/v1/wishes/{id}/state`, `DELETE /api/v1/wishes/{id}`, `POST /api/v1/wishes/seen`, `GET /api/v1/wishes/poster`). See [Family Wishes](WISHES.md) for age-limit visibility, duplicate `"Me Too"` merging, `409 already_in_library` conflicts, and server-proxied TMDB poster caching.

## Sleep timer end signal

When a player's sleep timer expires, `POST /api/v1/playback/sleep-timer-ended` notifies the server and returns `{ powerMode, afterSleepTimer, minutes }`. Clients with **Show Good Night When the Sleep Timer Ends** enabled (off by default) reuse the Good-Night screen without profile locking or wake-time text and auto-close after five minutes; see [Screen time](SCREEN_TIME.md#good-night-after-the-sleep-timer).

## Play on another device

A player that can take commands announces itself while it is open:

- `POST /api/v1/devices/player/heartbeat` with `deviceId` (at most 128 characters, chosen by
  the client and kept per installation), `deviceName`, `clientType` (`mac`, `tvos`, `ios`,
  `web`), `isPlaying`, `isPaused`, `mediaId`, `title`, `positionSeconds`, `durationSeconds`.
  The first paired device that claims a `deviceId` owns it: another device sending the same id
  while it is active gets `409 device_id_in_use`. Players not heard from for 45 seconds are no
  longer offered; after ten minutes they are forgotten.
- `GET /api/v1/devices/players?currentDeviceId={id}` lists the profile's other active players,
  and `GET /api/v1/devices/players/{deviceId}/status` one of them.
- `POST /api/v1/devices/players/{deviceId}/commands` queues `play` (with `mediaId` and optional
  `positionSeconds`), `pause`, `resume`, `stop`, `seek` (`positionSeconds`) or `skip`
  (`skipSeconds`). Only the profile signed in on that player can command it; commands expire
  after 60 seconds, and switching the player's profile drops any still queued.
- `GET /api/v1/devices/player/commands?deviceId={id}&waitMs={ms}` waits up to 15 seconds for
  the player's commands. Only the device that registered the player may read them.

## Minimum new-client acceptance

Run isolated tests for trust rejection, pairing/login, two accounts with separate
libraries, revocation, coherent multi-page loading, interrupted/restarted sync,
range/HEAD playback, ticket renewal and progress. Use the real-socket checks in
[TRANSPORT_TESTING.md](TRANSPORT_TESTING.md) as a server-side baseline, then add
platform credential, decoding, UI and lifecycle tests. Server contract readiness
is not a guarantee of an untested client implementation.
