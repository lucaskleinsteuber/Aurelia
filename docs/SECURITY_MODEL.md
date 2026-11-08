# Security model

Aurelia runs on a computer at home and is reachable only from the home network. This page
describes who may do what and which protections stay in place, so that a change to an
endpoint or a client can be checked against it.

## The basics that always apply

- **Only the home network.** The server answers only private and link-local addresses (plus
  the computer itself); an owner can narrow that further to chosen networks.
- **Encrypted connections.** Clients connect over HTTPS with the server's own certificate and
  pin its fingerprint, which the owner confirms when pairing. Plain HTTP works only on the
  server computer's loopback address.
- **Paired devices.** A Mac, Linux PC, Apple TV, iPhone, iPad or browser gets access only with
  a one-time 8-digit code that the owner creates on the main device (*Create Code*, or
  `aurelia pair` on a Linux server); a code works once and for five minutes. Each device has its
  own token, which the owner can revoke under *Settings › Profiles and Devices*.
- **Profiles.** On a paired device, each person chooses their profile. Owner and administrator
  profiles always need their PIN; other profiles can have one.
- **Browsers** keep their credentials in `HttpOnly`, `SameSite=Strict` cookies that scripts
  cannot read, and every change must carry the `X-Aurelia-Web` header, which another web page
  cannot add. The page's content policy loads nothing from the internet.
- **Rate limits** slow down guessing of passwords, PINs and pairing codes and cap requests
  per address.
- **Media is only read.** No request changes, moves or deletes a file in a media folder.
  Removing a title from the library removes its catalog entry; the file stays.
- **Diagnostics are redacted.** Tokens, passwords, PINs and full paths do not appear in
  logs, Server Health or exported diagnostics.

## Who may do what

### Everyone signed in to a profile

Watching and everything that belongs to the profile itself: browsing, playback and progress,
favorites, the Watchlist, watched and unwatched, scene notes, remembered sound and subtitle
choices, the profile's own collections and smart lists, its watch history and statistics,
"Play on…" between the profile's own players, and changing its own PIN.

A profile limited to selected titles sees and plays only those in lists, search and
collections.

History, statistics and private collections belong to the profile alone: no other profile,
administrators included, can read or change them.

### Administrators and the owner

Managing the library, after signing in to their profile with its PIN and without the server
password: storage locations and scans, editing and matching title details, the TMDB key,
Library Health, shared collections and Server Health. An administrator limited to selected
titles manages only those and cannot browse or scan storage locations.

### The owner

Everything about the server and its people, also without the server password: server
settings, network access, power saving, updates, backups, paired devices and pairing codes,
profiles and their access, and the scrub-preview settings.

### Changes that also need the server password

A few changes cannot be undone, so the server asks for its password once more, even from the
owner, and lets the confirmed request run exactly once:

- resetting the library (`POST /api/v1/libraries/reset`) and removing a title
  (`DELETE /api/v1/media/{id}`), which administrators may also do;
- restoring a backup;
- changing the server password or another profile's password;
- changing a profile's role, and removing an owner or administrator profile.

The client asks for the password in a sheet that says what will happen, then gets a one-time
approval with `POST /api/v1/management/approval` (or the older `/api/v1/server/approval`)
bound to the profile, the exact method and address, and the request body's hash. The approval
lasts two minutes and is used up by that one request, sent with the `X-Aurelia-Approval`
header.

Older clients that send an approval with other requests still work; the server ignores it
where none is needed. A newer client that meets an older server answering `management_locked`
or `approval_required` falls back to asking for the password first.

## Checking a change

When adding an endpoint, decide which group above it belongs to and enforce it on the server,
not only in a client. Add a test that a profile outside the group is refused, as
`SecurityModelEnforcementTests` does for the existing groups.
