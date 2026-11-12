# Aurelia in a web browser

Every Aurelia Server (in the Mac app or on Linux) also serves Aurelia for web browsers. It does
everything the Mac app does, from setting up a new server to editing the library, on any
computer, phone or tablet at home. The Mac app is development-signed and runs only on registered
Macs, so on every other Mac the browser is the way to use Aurelia.

## Opening it

The address is the server's own HTTPS address, for example `https://192.168.1.50:43111`.
The Mac app shows it with Copy and Open buttons under *Settings › Server › Devices ›
Web Browser*.

- **The first visit shows a warning** such as "This connection is not private" or, in
  Firefox, "Warning: Potential Security Risk Ahead". The connection is encrypted (HTTPS), but
  the server signs its own certificate, so browsers don't know it yet. Continue to the page
  once in each browser (in Firefox: *Advanced… › Accept the Risk and Continue*). The address
  bar may keep saying "Not Secure" for the same reason.
- **Without home network access**, a server running in the Mac app is reachable only from
  a browser on that Mac. Its loopback address is shown then.
- **When the server is off or asleep**, the browser cannot load the page at all, because
  the server serves it. If the server stops while the page is open, Aurelia says so and
  connects again by itself once the server is back. A browser cannot send Wake-on-LAN. On a
  Linux server with **Wake When a Device Connects** on (Settings › Power), opening the address
  or keeping the asleep page open wakes it, from a device that reached it shortly before;
  otherwise open Aurelia on the Mac to wake it. A server that Aurelia hosts on a Mac or Linux PC
  is never woken over the network: the page says "Start Aurelia on Your Mac" (or Linux PC) and
  connects once Aurelia runs there again.

## Setting up a new server

A Linux server without an owner can be set up entirely in a browser:

1. On the server computer, run `sudo aurelia setup` and choose the browser (or run
   `sudo aurelia setup --browser`). In Docker: `docker compose run --rm aurelia setup --browser`,
   start the server, then `docker compose exec aurelia aurelia setup-code`.
2. It shows the server's addresses and a one-time **setup code** such as `ABCDE-FGHJK`.
3. Open an address in a browser, type the code, the owner's name and the Server Password. This
   browser becomes the first device and asks for the owner's viewing PIN.
4. A welcome page offers the next steps: media folders (picked from the server's folders), a
   TMDB token for posters and details, and power saving; then the first scan.

The code exists only while the server has no owner. It lives in the server's private data folder
(`/var/lib/aurelia/browser-setup-code`, readable by root and the server) and in its log, lasts a
day, and ten wrong tries replace it, so someone else at home cannot claim the server first. Until
the owner exists the network reaches only the browser app and the setup step.

## Signing in

1. On the main device, the owner creates an 8-digit code: *Settings › Profiles and Devices ›
   Create Code* in Aurelia on a Mac or Linux computer, or `aurelia pair` on a Linux server. A
   code works once and for five minutes.
2. The browser asks for the code (`POST /api/v1/web/pair`); the server keeps the browser's
   credential in an HttpOnly cookie. It appears on the main device under its name, such as
   "Safari on iPhone". Servers before `web-pairing-code-v1` still have the browser show a
   code that the owner enters with *Enter Code from Device…*.
3. The browser then shows the profiles. Profiles with a PIN ask for it in a PIN field: a
   computer types it on its keyboard, a phone or tablet shows its own number keyboard. The
   field shows only the digits typed, never how long the PIN is.

The browser then appears under *Signed-In Devices* on the Mac and can be signed out there.
*Sign Out of This Browser* in the profile menu does the same from the browser.

The browser never holds a token that scripts can read:

- The server keeps the device credential and the profile session in `HttpOnly`, `Secure`,
  `SameSite=Strict` cookies.
- The profile cookie ends when the browser closes. As in the apps, a profile session also
  ends after twelve hours and when the server restarts.
- Browsers keep cookies per address, not per port. Another web service on the same computer
  and address (for example `https://192.168.1.50:8443`) therefore receives these cookies with
  its own requests. Scripts there still cannot read them, but that service's server can. Run
  only services you trust next to Aurelia on the same address, or give the server its own
  host name.
- See [the client protocol](CLIENT_PROTOCOL.md#web-browser-sign-in) for the details.

## Watching

Browsers open MP4, M4V and MOV files with H.264 video (or HEVC in Safari, and in Chrome or
Edge where the system decodes it) and AAC or MP3 sound themselves. The player plays those
directly with byte ranges.

Everything else plays **live converted**: MKV and AVI files, and an MP4 whose picture or
sound the browser can't decode. The server repackages the file while it plays, which costs
little computing time. Only what the browser can't decode is converted:

- **Sound** such as DTS, TrueHD or Dolby Digital becomes stereo AAC when the browser can't
  play it.
- **Picture** is only re-encoded when the browser can't show it at all, for example HEVC in
  Firefox or an old AVI. It then becomes H.264 at up to 1080p, one title at a time.

With a server that reports adaptive streaming, a picture that has to be re-encoded comes over
HLS in the quality the connection carries (1080p down to 360p), switching between segments as
the measured speed changes. The **quality menu** in the player (next to the rate) offers
Original, Automatic and each quality. A chosen quality also converts files the browser could open
itself, which helps on a slow connection. Automatic first plays a picture that can be copied
without converting it, so a weak server does no work; only after real stalls (three in a minute,
or eight seconds of waiting) does it switch once to the qualities the connection carries. The
choice is remembered in the browser.

HDR pictures (PQ or HLG) that need re-encoding are mapped to SDR BT.709 so their brightness
and colors fit the browser's output. A picture the browser can already decode stays unchanged;
SDR pictures do not incur HDR conversion work. The server keeps the output within 1080p and
uses FFmpeg's native perceptual color mapper in the Mac app's LGPL build. Older Linux ffmpeg
builds can use `zscale` with `tonemap` instead; a build with neither reports that HDR conversion
is unavailable instead of returning a pale picture. Valid source color tags are retained as
input; missing HDR primaries/matrix tags default to BT.2020. The older-filter fallback uses a
100-nit SDR reference and conservative peak references of 10,000 nits for PQ and 1,000 nits for
HLG, preserving bright detail rather than assuming every PQ source peaks at 1,000 nits.
The server checks HDR filter support only when an HDR picture first needs re-encoding, then
reuses that result. Startup, native delivery, repackaging and SDR conversion skip this check.

Nothing converted is stored: the server's ffmpeg writes straight into the connection to the
browser, with no cache and no temporary files. The player keeps up to a minute ahead (less
for high bitrates, so the browser's own limit of about 100 MB is never reached) and removes
what played earlier. Seeking within what has arrived is instant; a seek further away starts a
new stream at that point, and a dropped connection continues where the arrived part ends.
The audio menu picks another sound track. A directly played file also exposes its native sound
tracks when the browser provides that control; otherwise Original sound is shown. This does not
start conversion or probing merely to populate a menu. Up to three titles convert at a time on
one server.

The subtitle menu also lists embedded text tracks (SubRip, ASS/SSA and MP4 text subtitles).
Selecting one reads the track as WebVTT into request memory, with no subtitle files or cache on
disk. Cues use the title's timeline and stay aligned when resuming, seeking or changing sound
tracks. Bitmap subtitles (PGS and VobSub) are listed as unsupported. ASS positioning and styling
are reduced to the text and formatting that WebVTT supports. A request is limited to 8 MiB and
30 seconds; a failed subtitle load leaves the video playing and can be retried from the menu.
Only the currently selected extracted subtitle track is retained.

Sound and subtitle choices, including an explicit Off, are remembered in this browser for the
current server and profile, with each series or film keeping its own choice. A different title
falls back to the last choice for that profile. Matching uses language and track names rather
than stream numbers, so reordered episode tracks do not select a different language. Missing,
ambiguous or unsupported choices leave the available defaults. At most 300 title choices and
32 server/profile defaults are kept; no credential enters this storage.

An MP4 starts directly first. If the browser shows no picture or plays no sound, the player
switches to live conversion at the same point by itself. Live conversion needs Media Source
Extensions, which current browsers have (on iPhone from iOS 17.1). When the server can't
convert (no ffmpeg), the player says the file can't play in a browser and suggests the Mac or
Apple TV app, as before.

Picture conversion of 4K titles can still be too slow on older servers. HDR conversion adds
work even after reducing the picture size; direct playback or repackaging avoids that cost.

The player looks and works like the Mac app's: back and the menus at the top (playback
speed, sound tracks with Night Mode, subtitles, sleep timer, scene notes), back/play/forward
in the middle, title, volume, Picture in Picture and full screen at the bottom, the timeline
with scene notes and "Ends at". Hovering or scrubbing along the timeline shows preview
stills above the playhead. While an episode's intro plays, **Skip Intro** jumps past it
(Return or S does too), and when its credits begin *Up Next* counts down to the next one with
**Watch Credits**; without known credits it appears in the last 20 seconds. Settings › Playback ›
Intros chooses Don’t Offer, Show Skip Intro or Skip Automatically, and Offer Next Episode When
Credits Begin can be turned off. Scene notes are private to the profile, as on the Mac. Mark a Moment or a
Time Range, edit Start and End as m:ss or h:mm:ss (optional milliseconds), or use the current
position. Reload updates the list while preserving an unsaved draft. Load, remove and revision
conflict failures remain visible; a conflict never replaces another device’s edit automatically.
The sleep timer stops playback and informs the server when it actually ends, so the server’s
existing sleep mode can take effect. Closing the player manually does not send that signal.

Play starts a title at 0:00. Resume and Continue Watching may use its saved position when
Automatic Resume is enabled. Previous Episode and Next Episode, including Up Next and
natural episode changes, always start at 0:00. The N and P keys invoke those episode actions;
text fields, open menus and dialogs keep their normal keys. Episode buttons are disabled at
the beginning or end of the available series. Specials are kept outside that normal queue.
Manual navigation saves the position being left; only an actual end marks it watched.

The player saves the position every ten seconds, when pausing and when closing. Each save
names the revision it builds on, so it never overwrites newer progress from another
device. If another device saved meanwhile, that position wins quietly and the browser
stops saving until the title is opened again.

Keys: Space or K plays and pauses, the arrow keys (or J and L) skip by the seek interval,
F switches full screen, M mutes and Escape closes a menu or the player.

## Browsing

The top bar has the Mac app's sections: Home, Library, Watchlist, Recently Added, TV Shows,
Movies and Collections. The library sections have the Mac's filters (kind, Favorites, watch
state, genre, release year and sort order); they are part of the address, so Back and
bookmarks keep them, and each section searches within them. Titles load 100 at a time with
Load More; a catalog that changes meanwhile restarts paging instead of mixing old and new
pages.

A title's page shows seasons as a row of episodes, trailers and extras, cast and crew (each
person opens a page with their titles in the library) and its information, like on the Mac.
Title cards, Continue Watching and episodes share one context menu: Play (from the
beginning), Resume, Go to Series, watched or unwatched (a whole season or show asks first and
names the number of episodes), Favorites, Watchlist, Add to Collection, Remove from Continue
Watching and, for administrators, Edit Metadata.

**Collections** lists shared collections, your own, smart lists and the automatic film series and
universes. A collection can hold movies, shows, single seasons (*Add Season to Collection*) and
episodes, with a description, a cropped cover and background, and a sort order (Custom Order,
Release Year or Title). Its page shows the watched progress and plays the whole collection in
order. Smart lists fill themselves by rules (genre, decade, rating, watch state, date added, text);
*Save as Collection* copies a film series or universe into an editable collection, and
administrators manage shared collections.
**Watch History** and **Statistics** in the profile menu show only your own profile's viewing.

## Settings

Edit Metadata › **Intro and Credits** shows an episode's times with where they came from, lets
them be typed, reset or the season re-analyzed, and opens **Edit Intro…** and **Edit Credits…**: the
episode's picture (played in the browser when it can play the file, otherwise the server's
stills), a film strip and yellow handles; Play Selection loops the yellow part, Mute silences the
preview, the arrow buttons nudge by a tenth of a second, No Intro/No Credits saves that there is
none. Every button says what it does when pointed at. Settings › Server › **Intros and Credits**
shows the detection's progress, the episode it is on, the time left and each series with
Re-analyze, and turns detection and the pictures on or off.

With a server that has whisper.cpp and a speech model (Settings › Server › **Speech
Recognition**, where the owner downloads one), Edit Metadata › Subtitles offers **Create
Subtitles from Speech** in the spoken language and **Sync to Speech** for one of the title's
subtitle tracks. The server does the listening in the background; the page shows how far it is
and can stop it.

Edit Profile has **Screen Time** for children's profiles, as on the Mac: a bedtime and a daily
limit, today's exceptions, and a good-night screen in the player when time is up (see
[Screen time](SCREEN_TIME.md)).

Name and Picture crops a chosen photo in the browser: drag the circle and zoom, then Use Photo
draws a square JPEG that is uploaded on Save.

*Settings* in the profile menu has the Mac's categories; viewers see only their own.

- **General** and **Playback** are kept in this browser: start page, poster size, which sections
  the top bar shows and in which order, whether watched or offline titles appear, reduced motion, automatic resume,
  starting over when a title was barely started, the next episode and its Up Next countdown,
  default audio and subtitle languages (used until you choose tracks for a series), subtitle
  size and background, Dialogue Boost and Volume Leveling (the apps' presets, through Web Audio),
  Cinema Mode, speed, volume, how long controls stay and the skip interval.
- **Library**, **Metadata**, **Profiles and Devices**, **Server** and **Updates** are for owners
  and administrators, who are signed in with their PIN; they work without the server password.
  They cover storage locations (picked in a browser of the server's folders), files a scan leaves
  out, Library Health (duplicates, missing titles and titles without details), the TMDB token,
  Review Matches, OpenSubtitles, codes for new devices (*Create Code*, *Enter Code from Device*),
  profiles with their access, devices and passwords, Power (on a Linux package server: keep
  running, stop Aurelia, sleep or shut down after unused minutes or a sleep timer, awake hours and
  waking when a device connects; on a server inside Aurelia on a Mac or Linux PC: keep running or
  stop after unused minutes), Video Conversion, backups
  (checking them, encrypted backups to download, and restoring on a server hosted by the Mac app
  or installed from the Linux package, which restores at its restart), an Import Preview for a
  new storage location (*Review Before Importing*: what each folder and file becomes, corrected
  before anything is imported),
  restart, a diagnostics report, Server Health and server updates.
- Not in a browser: subtitles written from speech (macOS speech recognition), offline downloads
  and sending Wake-on-LAN (see Wake When a Device Connects above).
- A few changes that cannot be undone ask for the server password once more, exactly as on the
  Mac: resetting the library, removing a title, restoring a backup, changing the server
  password and changing or removing the owner or an administrator. See
  [Security model](SECURITY_MODEL.md).

**Edit Metadata** (a title's More Actions menu) edits title, year, rating, runtime,
description, genres, studios and country, Cast and Crew (add, remove, reorder, roles), the poster
and background (upload a picture and crop it to shape, or crop the current one), matches the title
with TMDB, chooses another video file for a film or episode, downloads subtitles from OpenSubtitles
and removes a title. Every field can go back to the automatic value. Manual changes survive later
scans. A conflict with a change made elsewhere keeps your draft until you reload.

## Add Aurelia to the home screen

Open the server's HTTPS address on the phone or tablet and accept its certificate when prompted.
In Safari, choose **Share › Add to Home Screen**; in Chrome on Android, choose **Add to Home
Screen** or **Install App** from the browser menu. Open the resulting Aurelia icon to use the
app in its own window without the browser toolbar. Pair that window with the server if it
asks to sign in; a home-screen app can keep a separate browser session.

The manifest and 192/512-pixel icons support standalone installation; Safari uses its
180-pixel touch icon, title and status-bar settings. The icons are derived from Aurelia's
existing vector icon with `swift scripts/make-web-icons.swift
src/Aurelia.Server/WebApp/icon.svg src/Aurelia.Server/WebApp/icons`. They contain no library
artwork. The public manifest, icons and app shell reveal no account, library or management
data. Those still require authentication through the same API. Aurelia uses no service worker
and no offline cache: the server must be reachable.

## Speed and motion

- The page loads its scripts and styles from `/web/v/<version>/…`, a name that changes with their
  content, so a browser keeps them for good and fetches them side by side (announced with
  `modulepreload`); they come compressed (Brotli or gzip). Pictures carry their revision, so a
  browser keeps them too until a new picture replaces them.
- Pages seen before show at once from what the server said last time and refresh quietly; Back
  returns to the same place. Pointing at a poster loads its page ahead. Slower pages show their
  shape while they load.
- Pages blend into each other, a clicked poster grows into the title's picture, menus and sheets
  open from where they were asked for, and rails rise in as they come into view. Reduce Motion (the
  system's or Settings › General) keeps everything still.

## How it is built

- The files are in `src/Aurelia.Server/WebApp`: plain HTML, CSS and JavaScript modules, with
  no framework, no build step and nothing loaded from the internet. They are built into the
  server, so every server version carries its matching browser app.
- The page has its own strict content security policy: only its own scripts, styles,
  images and media (plus `blob:` media for its own MediaSource).
- `js/live.js` is the live player (Media Source Extensions, no library); the server side is
  described under [live conversion](CLIENT_PROTOCOL.md#live-conversion).
- `js/player.js` is the player, `js/settings.js` the settings pages, and `js/settings-editors.js`
  the storage, profile and metadata forms.
- `js/logic.js`, `js/live-logic.js` and `js/api.js` hold the rules that need no page. They
  are tested with:

```bash
node --test "tests/WebApp/*.test.mjs"
```

- The server side (cookies, the sign-in steps, the page's policy) is tested in
  `tests/Aurelia.Server.Tests/WebAppTests.cs`.

### Server updates in the browser

Owners of a Linux server installed from the Aurelia package can check and install releases
under Settings › Server › Updates. The section shows the installed/newest versions and the
server updater's checking, installing, failed or completed state. Progress is indeterminate:
the existing server contract does not provide a download percentage. Installation asks for
confirmation first and never resets server data.

While checking, installing or reconnecting after a restart, only the update-status endpoint
is polled, once every two seconds; the rest of Settings is not reloaded. Polling resumes if
the section opens while an operation is already running, stops on navigation/profile change,
and has a bounded wait with an explicit status retry. Reaching idle alone does not prove a
new version was installed: the section reports the version actually returned by the server.
A profile that ended with the server's restart must be chosen again before progress can be
checked. Passwords, tokens and cookies are never read by the component or kept in its state.

Headless Node tests use an invented updater and manual timer queue to cover progress, restart
outages, failures, cancellation and duplicate clicks without a real server.

## Reproducing the browser screenshots

Run `zsh scripts/capture-showcase.sh --web-only` on a Mac with Swift, Node and an existing Playwright
installation. Set `AURELIA_PLAYWRIGHT_NODE_MODULES` (or `NODE_PATH`) to its `node_modules`
folder if it is not on Node's module path. `AURELIA_CHROMIUM_EXECUTABLE` can select an existing
Chromium/Chrome executable; `AURELIA_NODE` can select Node. Nothing is downloaded or added to
the browser app's dependencies. `--help` prints usage, and
`node scripts/capture-web-showcase.mjs --check` only checks capture dependencies.

The script regenerates the same 13-title library and artwork with `scripts/make-showcase.swift`
in a unique cache folder, serves it with the unchanged production browser modules on an
unused loopback port, and uses a fresh headless browser context. The fixture API is a separate
developer script, never compiled into Aurelia; it does not connect to a real server or read
credentials. Only its own origin is allowed, and every real media request is rejected.

Home, the title page, paused player controls and Playback settings are written as `web-*.jpg`
under `docs/assets/screenshots`. The player receives capture-only simulated video metadata and
a generated episode backdrop. Native media `src`, `load` and `play` are intercepted before the
app loads, so no video or audio engine plays anything. These images demonstrate the production
controls' layout; they are not playback verification or an authenticated-server test. The
private report under `Local/Logs` records image hashes, fixture provenance and rejected
requests; temporary fixture data and the headless browser context are removed afterward.

The approved `capture-showcase.sh --web-only` entrypoint dispatches before the native path.
It never invokes Mac/tvOS apps, native builds or UI/XCUITest suites; the default entrypoint
without `--web-only` retains its existing native capture behavior.

Developer fixture and wrapper guards run with `node --test "tests/WebShowcase/*.test.mjs"`.
They use synthetic files and simulated media objects, with no browser launch or native tests.

## Play on another device

A title's page has **Play on…**, which lists the profile's other open Aurelia players (Mac,
Apple TV, iPhone or another browser) and starts the title there. While the browser plays, it
reports itself as a player too, so the others can start, pause, seek or stop it. Safari shows an AirPlay button where the video can be
sent to an Apple TV or AirPlay receiver; other browsers do not offer it.

## Watch Together

The player's **Watch Together** menu starts a party for the title; a title's page shows **Join …**
for parties others started for it or one of its episodes. Play, pause, jumps and the next title
then apply to everyone, a short notice says who did what, and closing the player leaves the
party. The rules live in `js/watch-together.js` and are tested in
`tests/WebApp/watch-together.test.mjs`; see [Watch Together](CLIENT_PROTOCOL.md#watch-together).

## Movie Night and Wrapped

**Movie Night** (`/movie-night`, from Home or the profile menu) lets anyone at home swipe on a
phone, Android included: right for yes, left for nope, or the buttons and arrow keys. The lobby's
*Tonight's program* card lets the host choose movies or also shows, a genre, an era (2020s,
2010s, 2000s, older) and a length (up to 1 h 40 m or 2 h 10 m) right there. The match
shows as a ticket with **Play**. The page covers the whole window; ✕ returns to Home and keeps
the browser in the night. A browser can also start a night as the lobby screen without
swiping. The rules live in `js/movie-night.js`, the page in `js/movie-night-view.js`, tested in
`tests/WebApp/movie-night.test.mjs`; see [Movie Night](CLIENT_PROTOCOL.md#movie-night).

**Wrapped** starts from **Statistics › Year in Review**: the year as full-screen slides; on a
wide screen the poster stands beside the words. From the 2nd of a month, **Your October Wrapped
is here** in Statistics (and on Home in that first week) plays last month the same way. Tapping
the right or left side moves on or back, holding pauses, Escape closes, and with Reduce Motion
the slides wait for a tap. `js/wrapped.js`, tested in `tests/WebApp/wrapped.test.mjs`.

## Cinema mode

Settings › Playback › **Cinema Mode** works as on the Mac: before a film that starts from the
beginning comes one of Aurelia's made-up ads (ice cream, popcorn or phones; nothing is for sale),
up to three trailers of films in the library nobody has watched, and the curtain, which opens once
the film's picture moves (at most after ten seconds). **Skip** moves on, **Start Film** (Return)
goes straight to the film, Esc ends everything. The rules live in `js/cinema.js`.
