# Aurelia in a web browser

Every Aurelia Server (in the Mac app or on Linux) also serves Aurelia for web browsers. It is
meant for devices without an Aurelia app: another computer, a phone or a tablet at home.
The Mac and Apple TV apps stay the full experience.

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
  connects again by itself once the server is back. A browser cannot wake a sleeping server
  with Wake-on-LAN. Open Aurelia on the Mac or the Apple TV to wake it.

## Signing in

1. The browser shows an 8-digit code, valid for five minutes.
2. In Aurelia on the Mac, the owner chooses *Enter Code from Apple TV or Browser…* and enters
   it. The Mac shows the browser's name, such as "Safari on iPhone", before approving.
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
stills above the playhead. In the last 20 seconds of an episode,
*Up Next* counts down to the next one. Scene notes are private to the profile, as on the Mac. Mark a Moment or a
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

## Browsing and settings

The top bar has the Mac app's sections: Home, Library, Recently Added, TV Shows and Movies.
The library sections have the same filters as on the Mac (kind, Favorites, watch state,
genre, release year and sort order); they are part of the address, so Back and bookmarks
keep them. Each section also searches within those filters. Release Year offers both From and
To; leaving a bound empty keeps that side open. Genre suggestions come from loaded titles;
Choose Genre also accepts a genre outside the current results without downloading the whole
library. Library and search load 100 titles at a time, with Load More for the rest. A changed
catalog restarts paging against a fresh revision rather than mixing old and new pages.

Collections has a complete, paged index, available from Library and See All on Home. Collection
links remember the index page; if a collection moves after a rename or is removed, All
Collections opens the index again. Collection editing remains management functionality in the
Mac app. A title's page shows its seasons as a row of episodes, its trailers and extras,
cast and crew, and its information, like the Mac's.

A title’s More Actions menu can remove it from Continue Watching or show it there again,
without changing its playback position. Continue Watching cards offer the same menu. Marking a
whole show or season watched or unwatched asks for confirmation with the number of episodes;
marking it unwatched resets the selected episodes’ positions, as in the Mac app.

The **Watchlist** shelf appears on the Home page whenever titles are marked for later viewing.
A title can be added or removed from the Watchlist from its detail page or context menu. Clicking
any Cast & Crew card opens a dedicated **Person** page showing the person's portrait, role and an
"Appears In" horizontal shelf with their titles in the library.

*Settings* in the profile menu has three pages:

- **General**: the version (the browser app is part of the server and always has its
  version), the server, the profile, Switch Profile and Sign Out of This Browser.
- **Playback**: the Mac's playback preferences, kept in this browser: automatic resume,
  playing the next episode, keeping the screen on, Night Mode, default speed and volume,
  how long controls stay and the seek interval.
- **Server** (owners and administrators): unlocked with the Server Password for ten minutes,
  as on the Mac; the browser doesn't keep the password or ask again while management is
  unlocked. Features a **Server Health** diagnostics panel displaying server uptime, data
  folder free space, scrub preview cache and live conversion status, last scan outcome,
  background job progress, automatic database backup status, and the 20 most recent
  redacted server warnings. Owners add storage locations using an absolute folder path on the server,
  remove locations after confirmation and manage profiles. Location removal waits for the
  server's operation to complete; media files are never changed. Full-library administrators
  can rescan locations and change monitoring; selected-title administrators manage only their
  allowed titles. Owner-only status, updates, profile editing, device revocation, power and
  backups keep the same server permissions.

Profile forms use the Mac's role, enabled state, PIN protection and content access controls.
PINs require matching 4–8 digit fields; leaving both empty preserves an existing PIN. Selected
Titles uses a searchable list of films and series, and existing storage grants stay unchanged
unless the owner changes the access mode. Saves use the profile's revision and one approval
for the complete change.

**Edit Metadata** is available from a title's More Actions menu and from Server › Movie Info.
General and Production & Release fields match the Mac: title, release year, FSK, movie runtime,
description, genres, studios and country. Manual changes survive scans and provider refreshes;
Reset to Automatic removes the selected override. Existing cast, artwork and file associations
are preserved. Provider matching can be searched, selected or cleared. The editor uses the
server's revision; a conflict keeps the draft open until the user chooses to reload. Artwork,
cast and source-file editing remain available in the Mac app.

Every guarded change gets a one-time approval for exactly its method, address and serialized
body. If the management window expires while editing, the browser keeps the draft and offers
an inline unlock. Switching profiles or navigating away closes editors and cancels outstanding
reads; closing an editor with unsaved changes asks before discarding them.

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
the existing server contract does not provide a download percentage. Installation uses the
existing exact-action management approval after a confirmation, and never resets server data.

While checking, installing or reconnecting after a restart, only the update-status endpoint
is polled, once every two seconds; the rest of Settings is not reloaded. Polling resumes if
the section opens while an operation is already running, stops on navigation/profile change,
and has a bounded wait with an explicit status retry. Reaching idle alone does not prove a
new version was installed: the section reports the version actually returned by the server.
A management expiry offers the existing Server Password unlock page; a retired profile after
restart must be chosen again before progress can be checked. Passwords, tokens and cookies
are never read by the component or retained in its state.

Headless Node tests use an invented updater and manual timer queue to cover progress, restart
outages, failures, cancellation, approvals, unlock and duplicate clicks without a real server.

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

### Consistent title actions

Title cards, Continue Watching and episode cards use the same context-menu ordering: Play, Resume when progress exists, Go to Series for episodes, watched status, supported favorites, Continue Watching visibility and administrator metadata editing. Play starts at the beginning; Resume keeps progress. Missing titles retain navigation and management actions while playback stays disabled. Favorite actions retain the server's movie/series scope; watch-state changes keep the existing confirmation and exact state token. Route/profile changes retire open actions.

### Metadata editor layout

Edit Metadata is available in the title's More Actions menu. Its poster/title header and settings sections match the Mac editor: Title and Year, Overview, Genres, Production and Release, Cast and Crew, Artwork, Match with TMDB and Source. Cancel and Save remain visible while the form scrolls; invalid fields explain the correction beside the control. Existing cast, artwork/crops and source associations remain read-only in the browser and are preserved by text edits. Revision conflicts keep the draft until an explicit reload, and management expiry uses the existing unlock flow. Native Mac editing retains its existing image/crop, cast and server-file controls.

### Collections and Smart Lists

The browser app supports full collections browsing and management:
- View personal and shared collections in a dedicated Library tab and Home rails.
- Create manual collections or dynamic Smart Lists with custom filtering rules (genres, decade, rating, watch state, date added, text search).
- Add or remove titles via the card context menu ("Add to Collection...").
- Suggested TMDB Franchise rails appear automatically on movie detail pages when part of a recognized franchise, with a one-click button for administrators to convert them into managed collections.

### Sidecar Subtitles

The browser player automatically lists both embedded subtitle tracks and sidecar `.srt`/`.ass`/`.vtt` files discovered next to the video. Subtitle tracks are selectable from the player audio/subtitle menu, streamed as in-memory WebVTT, and rendered with custom styling matching native platform captioning.

### Watch History and Statistics

Profiles can view their personal viewing history and rich aggregate statistics:
- **History View:** Chronological log of watched titles with date, resume position, and clear/delete actions.
- **Statistics View:** Aggregate viewing metrics including total hours watched, weekly breakdowns, top genres, most-watched titles, viewing streaks, and Year in Review recaps.
All history and statistics are strictly private to the profile session.

### Library Health and Maintenance

Administrators can access the Library Health dashboard in Settings to inspect and resolve library issues:
- **Duplicate Titles:** Grouped side-by-side view with media details, enabling administrators to set a preferred version or merge duplicate entries without deleting files on disk.
- **Offline Items:** List of media entries whose physical files have been moved or are unavailable on disk, with options to clean database references.
- **Unmatched Metadata:** Titles missing TMDB matches, descriptions, or artwork, with direct shortcuts to the metadata editor.

### Remote Playback and AirPlay

The browser app integrates remote playback capabilities:
- **AirPlay Route Picker:** WebKit-native AirPlay button in the player control bar for casting playback directly to Apple TV and AirPlay-compatible receivers.
- **Play on Device (Remote Control):** Device picker menu allows sending current titles or playback commands (play, pause, seek, stop) to other active Aurelia players (Apple TV, Mac app, or other browser sessions) on the server.
- **Remote Player State:** When acting as a player, the browser app periodically reports its heartbeat and responds to remote control commands.
