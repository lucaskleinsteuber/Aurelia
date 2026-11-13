# Security model

Aurelia runs on a computer at home and is reachable only from the home network. This page
describes who may do what and which protections stay in place, so that a change to an
endpoint or a client can be checked against it.

## The basics that always apply

- **Only the home network.** The server answers only private and link-local addresses (plus
  the computer itself); an owner can narrow that further to chosen networks.
- **Encrypted connections.** Clients connect over HTTPS with the server's own certificate and
  pin its fingerprint, which the owner confirms when pairing. Plain HTTP works only on the
  server computer's loopback address, for requests addressed to `localhost`, `127.0.0.1` or
  `[::1]`. The server treats every caller on that port as someone at the server computer, so
  never put a reverse proxy, a tunnel or a port forwarding in front of it.
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
  per address. Waiting pairing codes also end after 100 wrong guesses in total, from any
  address.
- **Media is only read.** No request changes, moves or deletes a file in a media folder.
  Removing a title from the library removes its catalog entry; the file stays.
- **Converted video stays in memory.** Live conversion and adaptive streaming (HLS) run ffmpeg
  without a shell on the file the server checked and opened; it writes only to its standard
  output. HLS segments live in the server's memory, capped per session, for as long as someone
  plays them. Every playlist and segment request checks its playback ticket, session and
  profile, and a session ends with its user, profile session or title. A video chip is opened
  only through `/dev/dri` render nodes (or Nvidia's driver) after a test encode of an invented
  picture.
- **Intro detection keeps only timestamps.** To find intros and credits the server decodes
  short stretches of an episode's sound, and small grey pictures of its last minutes, the same way (ffmpeg without a shell, the checked and
  opened file, standard output only). Sound, pictures and fingerprints stay in memory while a season is
  compared; only the times are stored, in the database.
- **Diagnostics are redacted.** Tokens, passwords, PINs and full paths do not appear in
  logs, Server Health or exported diagnostics.
- **Performance measurements keep no contents.** Server Health › Performance stores, for seven
  days in `server-performance.json` in the data folder, how long each endpoint took (by its route
  template, such as `GET /api/v1/catalog/items/{mediaId:guid}`, never the address with its
  values), how many database queries it ran, and the 200 most recent queries over 100 ms as SQL
  with every value replaced by `?`. Owners and administrators read it; only the owner resets it.

## Who may do what

### Everyone signed in to a profile

Watching and everything that belongs to the profile itself: browsing, playback and progress,
favorites, the Watchlist, watched and unwatched, scene notes, remembered sound and subtitle
choices, the profile's own collections and smart lists, its watch history and statistics,
"Play on…" between the profile's own players, Watch Together and Movie Night with the
household, and changing its own PIN. In a shared Movie Night deck every member's title limits
apply, and nobody sees how another member voted.

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
profiles and their access, and the scrub-preview and intro detection settings.

### Changes that also need the server password

A few changes cannot be undone, so the server asks for its password once more, even from the
owner, and lets the confirmed request run exactly once:

- resetting the library (`POST /api/v1/libraries/reset`) and removing a title
  (`DELETE /api/v1/media/{id}`), which administrators may also do;
- restoring a backup;
- changing the server password or another profile's password;
- changing a profile's role, and removing an owner or administrator profile.

Removing a storage location (`DELETE /api/v1/libraries/{id}`) and removing a title whose file
is missing from Library Health (`DELETE /api/v1/library/health/entries/{id}`) also take titles
out of the catalog, but do not ask for the password yet: the apps send no approval for them, so
asking would break them. Until they do, an administrator can remove these without it.

The client asks for the password in a sheet that says what will happen, then gets a one-time
approval with `POST /api/v1/management/approval` (or the older `/api/v1/server/approval`)
bound to the profile, the exact method and address, and the request body's hash. The approval
lasts two minutes and is used up by that one request, sent with the `X-Aurelia-Approval`
header.

Older clients that send an approval with other requests still work; the server ignores it
where none is needed. A newer client that meets an older server answering `management_locked`
or `approval_required` falls back to asking for the password first.

## Security log, new devices and the block list

Servers with `security-v1` keep a security log for the owner (Settings › Profiles and Devices ›
Security on the Mac, Linux, in the browser and on iPhone & iPad):

- sign-ins with the Server Password, a device code or a code the device shows, opened
  profiles and management unlocks (with the password, Face ID or Touch ID, or confirmed on
  another device);
- failed attempts: a wrong Server Password, profile PIN or device code, pauses after too many
  attempts, a blocked device that tried again, and a refused password while Face ID is required;
- changes: storage locations added or removed, profiles created, changed or deleted, PINs and
  passwords replaced, roles, screen time, server settings, network, power, backups, updates,
  devices signed out, allowed, blocked or unblocked, and Face ID keys.

Each entry has the time, the profile, the device's name, platform and IP address, and a short
detail such as a profile's name or a storage location's folder name. It never holds a password,
PIN, token, full path or title. The log is kept for 90 days (30 to 365, set by the owner).

Every app sends `X-Aurelia-Installation` (a random identifier it creates once) and
`X-Aurelia-Client` (`ios/2.11.0`, `macos/…`, `linux/…`, `tvos/…`); the browser keeps its
identifier in an HttpOnly cookie. A device that signs in for the first time is **new** until the
owner answers "That Was Me". The owner's apps show it at once while they are open (the Mac also
as a notification); there are no push notifications, so a closed app sees it the next time.
**Block** signs the device out at once and puts its identifier on the block list: signing in,
pairing and device approval then answer `403 device_blocked`. The owner's current device can't
block itself. Honest limit: blocking applies to the device as it identifies itself; someone who
knows the Server Password or gets a new device code can still come in with a new identifier.
Device codes and the Server Password remain the real protection.

## Face ID and Touch ID instead of the Server Password

On iPhone, iPad and the Mac, an owner or administrator can set up Face ID or Touch ID for
management. The app creates a P-256 key in the device's Secure Enclave that only works after
Face ID, Touch ID or the device passcode, and that never leaves the device or syncs. Only its
public key is registered (`POST /api/v1/management/passkeys`, which needs the Server Password
once). To unlock management, the app asks for a one-time challenge
(`POST /api/v1/management/passkey-challenge`, valid for a minute, used once, bound to the
profile session), signs `aurelia-passkey-v1|unlock|<challenge>` and sends it to
`POST /api/v1/management/passkey-unlock`. The profile PIN is unchanged.

The owner can require Face ID or Touch ID for administrators once their own profile has a key.
Then `POST /api/v1/management/unlock` answers `403 passkey_required` for the password, except on
the server computer itself (loopback), which stays the way back if every key is lost. Apps
without a key (Linux, the browser) use **Confirm on Another Device**: they start a request
(`POST /api/v1/management/remote-unlock`) and show its four-digit code; an iPhone, iPad or Mac
of the same profile or the owner's shows the request and confirms it with Face ID or Touch ID
(signing `remote:<request id>`), and the asking device is then unlocked for ten minutes.
Requests last two minutes and are used once.

## Checking a change

When adding an endpoint, decide which group above it belongs to and enforce it on the server,
not only in a client. Add a test that a profile outside the group is refused, as
`SecurityModelEnforcementTests` does for the existing groups.
