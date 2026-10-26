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

Nothing converted is stored: the server's ffmpeg writes straight into the connection to the
browser, with no cache and no temporary files. The player keeps up to a minute ahead (less
for high bitrates, so the browser's own limit of about 100 MB is never reached) and removes
what played earlier. Seeking within what has arrived is instant; a seek further away starts a
new stream at that point, and a dropped connection continues where the arrived part ends.
The audio menu picks another sound track. Up to three titles convert at a time on one server.

The subtitle menu also lists embedded text tracks (SubRip, ASS/SSA and MP4 text subtitles).
Selecting one reads the track as WebVTT into request memory, with no subtitle files or cache on
disk. Cues use the title's timeline and stay aligned when resuming, seeking or changing sound
tracks. Bitmap subtitles (PGS and VobSub) are listed as unsupported. ASS positioning and styling
are reduced to the text and formatting that WebVTT supports. A request is limited to 8 MiB and
30 seconds; a failed subtitle load leaves the video playing and can be retried from the menu.

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
with scene notes and "Ends at". In the last 20 seconds of an episode, *Up Next* counts down
to the next one. Scene notes are private to the profile, as on the Mac.

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
keep them. A title's page shows its seasons as a row of episodes, its trailers and extras,
cast and crew, and its information, like the Mac's.

*Settings* in the profile menu has three pages:

- **General**: the version (the browser app is part of the server and always has its
  version), the server, the profile, Switch Profile and Sign Out of This Browser.
- **Playback**: the Mac's playback preferences, kept in this browser: automatic resume,
  playing the next episode, keeping the screen on, Night Mode, default speed and volume,
  how long controls stay and the seek interval.
- **Server** (owners and administrators): unlocked with the Server Password for ten minutes,
  as on the Mac; the browser doesn't keep the password or ask again while management is
  unlocked. Owners add storage locations using an absolute folder path on the server,
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
