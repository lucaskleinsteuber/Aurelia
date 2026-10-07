# Building another Aurelia client

The shared JSON contracts are in `src/Aurelia.Contracts`. The macOS client is the
current reference implementation, not a dependency of another client. This
stabilization does not add Windows/Linux clients or certify either OS runtime.

## Connection and authorization

Use `/api/v1/server/info` to identify a server, then login or redeem a pairing
code. Discovery is a hint, not a trust decision: verify the server identity with
the owner and persist its SPKI pin. Do not trust a fingerprint just because an
untrusted server reports it. Require HTTPS for remote connections; loopback HTTP
is for the local host only. Never follow a credential-bearing redirect.

Store the device token in the platform's protected credential store. Send it as
a Bearer token, including for stream requests. Keep accounts/sessions isolated
when caching artwork, catalog, progress or synchronization state. A revoked or
expired session must stop authenticated work, not be treated as a network outage.

The server enforces roles and library grants on every supported route. Hiding a
button is not an access control. Owner-only host settings are optional client
features; a normal user must not need them just to browse or watch.

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

## Direct playback

Create a ticket through `/api/v1/media/{id}/playback`. Use its server-relative
stream path without exposing the token to a media engine or another origin.
Support GET/HEAD byte ranges and the returned length/type. Renew the ticket
before expiry; retry temporary failures only while the current authorization
remains valid. Stop on definitive access failure and cancel work when the player
closes. Save the user's progress and use the server's Continue Watching result.

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

There is no transcoding endpoint. A new client must choose and test its own
native decoding engine; byte-range transport tests do not certify codec support.

## Minimum new-client acceptance

Run isolated tests for trust rejection, pairing/login, two accounts with separate
libraries, revocation, coherent multi-page loading, interrupted/restarted sync,
range/HEAD playback, ticket renewal and progress. Use the real-socket checks in
[TRANSPORT_TESTING.md](TRANSPORT_TESTING.md) as a server-side baseline, then add
platform credential, decoding, UI and lifecycle tests. Server contract readiness
is not a guarantee of an untested client implementation.
