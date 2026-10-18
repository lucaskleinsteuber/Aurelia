# Native client compatibility

Aurelia currently ships a native macOS client. These additive API contracts also
prepare the server for another native client. They do not imply a released tvOS app.

## Discovery and identity

Resolve the `_aurelia._tcp` Bonjour service to its actual target and port. Display
names and TXT records are discovery hints, not proof of identity. Before sending
saved credentials to a relocated address, require the stored server ID and the
stored public-key fingerprint to match. A changed identity needs explicit review.

Device credentials persist separately from temporary profile and management
unlocks. A profile timeout returns to profile selection; device rejection requires
pairing again. Transport errors do not erase saved connections.

## Feature negotiation

`GET /api/v1/server/info` and `GET /api/v1/capabilities` advertise capability names.
Clients must tolerate absent optional fields and unknown additive fields. Features
introduced in 1.5.5 are `server-readiness-v1`, `device-authorization-v1`, and
`artwork-variants-v1`. They do not change the existing minimum client version.

Since 1.6.0, `catalog-pages-500-v1` means catalog lists (`/api/v1/catalog/items`,
`/movies`, `/series` and `/search`) accept a `limit` of up to 500; older servers
accept up to 200. Catalog, Home and collection GET responses are compressed with
Brotli or gzip when the request sends `Accept-Encoding`; other responses are not.

Since 1.7.0, `media-segments-v1` means `GET /api/v1/media/{id}/segments` returns a title's
intro and credits times (`analyzed`, `introStartMilliseconds`, `introEndMilliseconds`,
`creditsStartMilliseconds`, `source`, `analysisVersion`). Administrators set them with `PUT`
and clear them with `DELETE`; `GET /api/v1/media/segment-analysis` lists seasons and movies
still to be analyzed and, since 1.7.4, `totalTitles` and `analyzedTitles` for progress. Only timestamps are stored. Times set by hand (`source: manual`) are
never replaced by automatic results. Since 1.7.7, administrators save automatic results with
`PUT /api/v1/media/{id}/segments/detected`, which needs no management unlock and rejects
`source: manual`; setting or clearing times by hand still requires it.

`GET /api/v1/health/live` (also HEAD) indicates HTTP liveness without a database
read. `GET /api/v1/health/ready` reports a coarse cached state. Component details
and bounded recovery history require the Owner management endpoint
`GET /api/v1/server/status`. Readiness degradation alone must not trigger restart.

## Device authorization

Start with `POST /api/v1/auth/device-pairings` and a `deviceName`. Display the
returned eight-digit `code`; keep the returned `secret` private. The request expires
after five minutes. Use POST `/{id}/status`, `/{id}/ack`, and `/{id}/cancel` with
`{ "secret": "…" }`; never put secrets in a URL. Wait at least five seconds between
status requests and honor Retry-After.

An unlocked Owner enters the code through POST
`/api/v1/server/device-pairings/lookup`, reviews the server and device, then chooses
POST `/{id}/approve` or `/{id}/deny` in that management namespace. Decisions use
the existing exact-action approval bound to the active management unlock.

Only the secret holder can retrieve approved device credentials. Repeated delivery
uses the same credentials. Persist them securely before acknowledgement. Ack clears
the encrypted delivery copy; unacknowledged credentials expire with the request.
Pairing never unlocks a watching profile. Existing pairing-code APIs remain valid.

## Artwork

`GET /api/v1/artwork/{id}?width=320` supports widths 320, 640, 1280, and 1920.
Omit width for the stored source. Variants preserve orientation, crop, aspect ratio,
and transparency and never upscale. HTTP ETags and the optional artwork `revision`
change with the source. Cache by server, watching profile, artwork revision, and
width; bytes cached for a revision stay valid until the revision changes. An
`If-None-Match` request for unchanged artwork returns `304` without a body.
On older servers, request the existing artwork path without a width parameter.

The shared synthetic JSON fixtures in the Mac test target are also embedded in
the server test assembly. Both decoders validate the same compatibility examples.
