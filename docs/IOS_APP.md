# Aurelia for iPhone and iPad

`clients/ios` holds the iPhone and iPad client. It plays your library on iPhone and iPad with
touch controls, and is installed from source with Xcode like the Apple TV app; it is not in the
App Store. Version 2.1.0 adds downloads for watching without the server.

## How it is built

The app shares its behavior with the Apple TV app, which plays on a real TV every day. Its
connection, playback and library code is a copy of the Apple TV app's, not a link to it, and
its screens are its own:
`clients/ios` has its own Xcode project with no references into `clients/tvos` or
`clients/macos`, as `AGENTS.md` requires.

- **Connecting** works exactly like on the Apple TV: the app finds servers with Bonjour or
  takes an address, shows the server's fingerprint to confirm, and asks for the 8-digit code
  that the main device shows (*Settings › Profiles and Devices › Create Code* on a Mac or
  Linux computer, or `aurelia pair` on a Linux server). The server's certificate is pinned
  to that fingerprint.
- **Profiles** open with their PIN; Home, Movies, TV Shows, Search, title pages, the Watchlist
  and people pages work like on the Apple TV.
- **Playback** runs through MobileVLCKit and a small relay on `127.0.0.1` that adds the
  sign-in to each request and streams the bytes through; nothing is stored unless you download
  the title (see below). Progress, sound
  tracks, subtitles (including subtitle files next to the video), scrub previews, Skip Intro,
  Up Next (also when the credits begin, with Watch Credits), Cinema Mode before a film and the
  sleep timer behave as on the Apple TV. A file's **chapters** appear as a menu and as marks on
  the timeline, and **scene notes** are listed, added at the current moment or as a range,
  edited, deleted with a swipe and shown at their moment, private to the profile.
- **Movie Night** shows *Tonight's program*: the host picks kind, genre, era and length right in
  the lobby card and deals; everyone else sees the choice.
- **Collections**: Add to Collection… in a title's menu chooses your own collections or starts a
  new one; a collection's page renames or deletes it and removes titles. Smart lists stay on the
  Mac and in the browser.
- **Name and Picture** crops a chosen photo to a circle (drag and pinch) before it is uploaded.
- **Screens** are built for iPhone and iPad rather than taken from the TV: a tab bar with Home,
  Movies, TV Shows, Search and Settings, iOS text sizes and margins, the PIN entered on a keypad
  like the iPhone passcode, seasons as a menu with the episodes listed below, and settings as an
  iOS form. The player works by touch; a hardware keyboard adds the arrow keys, Space and Escape.
  The app icon is the Mac app's Liquid Glass icon.
- **Settings** (rebuilt in 2.12.0) is one list of pages, each with a line that says what it is
  for; on an iPad the list is a sidebar like the Mac's, and the chosen page opens beside it with
  its own back navigation. For the owner and administrators *Server* comes first, then *You*
  (Name and Picture, Playback, Profile PIN, Watch History, Statistics with Wrapped, Family Wishes,
  Downloads), *This iPhone* (notifications and stored artwork, About) and *Connection* (the
  server's name and version, Wake-on-LAN and Disconnect). Every page starts with what it does,
  every option explains itself, and actions report progress, "Done" or the problem in their own
  row.
- **Server Administration** (from 2.9.0, rebuilt in 2.12.0) gives the owner and administrators
  what the Mac, the Linux app and the browser manage. *Library*: storage locations with Scan,
  Watch for Changes, Review Import and Remove on each row (swipe or touch and hold); adding one or
  more folders through a browser of the server's drives and folders (up, typed paths, "Use This
  Folder"), with Review Before Importing on by default, after which the review opens or the first
  scan starts; scans with what they found and their problems; Import Preview with selecting
  several items, Analyze Again and corrections; folders to sort; files to check, assigned to a
  movie or left out; left-out items; watching storage for changes and the scan schedule; Library
  Health (duplicates, titles whose drive is away for 7, 30 or 90 days, and titles without
  information matched on TMDB); and Reset Library, followed until it finishes. *Metadata*: TMDB,
  finding or refreshing information, Review Matches, OpenSubtitles, unused artwork and search.
  *Profiles and Devices*: profiles with name, picture, role, PIN, children's age limit, screen
  time and content access, Allow New Devices, codes for new devices or the code a device shows,
  and one page of signed-in devices with That Was Me, Sign Out and Block. *Security* (from
  2.11.0): Face ID or Touch ID instead of the Server Password, with the key in the Secure Enclave,
  and for the owner the security log, the block list and whether Face ID is required for
  administrators; requests from Linux or a browser to confirm an unlock appear at the top of the
  screen. *Server*: status, health in one line with details, restart, Performance, what the server
  does by itself (scrub previews, intros and credits, speech recognition, video conversion),
  maintenance (backups with check, encrypted backup through the share sheet and restore from a
  file; background jobs; diagnostics) and network and limits. *Smart Home* (from 2.13.0, owner): webhooks for Home
  Assistant with Send Test, deliveries and new secrets, keys for Home Assistant and shortcuts, the
  network card to wake the server, and Sleep, Turn Off or Stop Now; the player tells the server at
  once when it plays, pauses, buffers or ends ([AUTOMATION.md](AUTOMATION.md)). *Siri* (from 2.14.0):
  Set Up Siri in Smart Home lets Siri turn the server on and off, play a title on the Apple TV
  and say what plays, also with Aurelia closed ([AUTOMATION.md](AUTOMATION.md)). *Power* and
  *Server Updates* say why when this server can't use them. The network is shown but changed on the server computer,
  because a change can cut the iPhone off. Visibility follows the server: the owner sees
  everything, administrators the library and metadata, and storage needs the whole library.
  Changes that the server protects ask once for the Server Password (or Face ID), which unlocks
  management for ten minutes and is never stored; the app then asks the server for a one-time
  approval of exactly that change. Changing titles one by one (the metadata editor, artwork)
  stays on the Mac and in the browser.
- **Wake Server**: when the saved server doesn't answer, *Wake Server* sends a Wake-on-LAN packet
  now and every ten seconds for two minutes and connects as soon as it answers. Settings › Server
  shows whether waking can work (how many network cards the server reported) and sends one packet
  on request. A server found with Bonjour is looked up to its IPv4 address so waking reaches it.
- **Movie Night** starts from Home, or joins a night someone else started there: everyone swipes
  the same posters (right for yes, left for nope, or the buttons), and the first title all
  voters like shows as a ticket with Play. Closing it leaves the night.

## Streaming quality

**Settings › Playback › Streaming Quality** (shown when the server offers adaptive streaming)
plays the server's live conversion instead of the original file: Automatic picks the best
quality the connection carries, "Up to 720p" and the like cap it. That helps on mobile data over
a VPN. The original stays the default; the stream goes through the same local relay.

## Downloads and watching offline

For a train ride or a holiday, keep titles on the iPhone or iPad and watch them without the
server and without a VPN.

1. At home, open a movie and choose **⋯ › Download**, or press and hold an episode and choose
   **Download**. On a series, **⋯ › Download Season N** loads every episode of that season.
2. The download keeps going while Aurelia is in the background or the screen is locked. Titles
   load one after another, so a season never takes all of a profile's streams and the TV keeps
   playing meanwhile. **Settings › Downloads** shows the progress, the space used and the space
   left; a stopped download continues with **Try Again**.
3. Away from home, open Aurelia. When the server doesn't answer, **Watch Downloads** opens the
   downloads in a small library: Continue Watching, movies, and series with their episodes.
   Each profile sees only its own downloads and opens with its PIN, which the device checks
   against a salted value it saved when the profile last opened at home.
4. Back at home, the progress watched offline goes to the server by itself when the profile
   opens. If the title was watched on another device meanwhile, the later position wins.

Good to know:

- A download is the original file, with the subtitle files next to it, its poster and its
  description. It plays with the normal player: sound tracks, subtitles, speed, Dialogue Boost,
  scrub previews, the sleep timer and Up Next for the next downloaded episode. Watch Together
  needs the server and is off for downloads.
- Downloads live in Aurelia's own storage on the device, are left out of iCloud backups and
  are never written next to your media or on the server. Swipe a download in Settings ›
  Downloads to remove it; deleting the app removes all of them.
- One copy per title and device: a title another profile downloaded on the same device shows
  as already downloaded.
- Aurelia keeps 1 GB free and refuses a download that would leave less.
- Disconnecting the device from its server removes that server's downloads too.

## Building and testing

```bash
zsh scripts/test-ios-logic.sh
```

Runs the logic tests on the Mac without a simulator.

```bash
zsh scripts/build-ios.sh
```

Builds the app for the iOS Simulator in Release, with warnings as errors.

To look at the app without a server, build the Debug configuration and launch it with the
argument `--aurelia-ui-testing` and the environment variable
`AURELIA_IOS_UI_SCENARIO=library`: it shows an invented library and a simulated player.

```bash
zsh scripts/capture-showcase.sh --ios-only
```

Makes the README screenshots of iPhone and iPad from the invented showcase library in
simulators; `AURELIA_IOS_SHOWCASE_PAGE` (`movies`, `shows` or `detail`) chooses the page.

## Installing on your own iPhone

```bash
zsh scripts/build-ios.sh --device <identifier>
```

Builds the app signed for development and installs it on a paired iPhone or iPad, over the
cable or over Wi-Fi; `xcrun devicectl list devices` shows the identifier. The device needs
Developer Mode (Settings › Privacy & Security) and must have been paired with this Mac in Xcode
once. Reinstalling replaces only the app, so its server connection and settings stay. A free
development profile expires after seven days. After installing, run
`zsh scripts/refresh-signing.sh --adopt-iphone` so the signing refresh job re-signs and
reinstalls that build before it expires (the iPhone has to be on the same network then); the
build folder is removed because the job keeps its own copy. An iPad gets its own build folder
(`AURELIA_IOS_BUILD_ROOT=Local/Build/iPad/<version>-<build>`) and `--adopt-ipad`.

The player works by touch: tap the picture to show or hide the controls, and drag along the
timeline (or tap a place on it) to jump there. The buttons at the top choose the speed, the
sound and subtitles (with Dialogue Boost and Volume Leveling) and the sleep timer in a short sheet. A hardware keyboard
adds the arrow keys, Space and Escape. Ending a timed or end-of-episode sleep timer closes the player (instead of only pausing), releases `isIdleTimerDisabled`, and optionally shows the 5-minute Good-Night screen when **Settings › Playback › Show Good Night When the Sleep Timer Ends** is enabled.

## Family Wishes

When the server supports `wishes-v1`, iPhone and iPad offer **Family Wishes** from Home and Settings (with a badge showing open wishes for administrators or newly fulfilled wishes for members), including server-proxied TMDB search, manual fallback, `"Me Too"` voting, `"Your wish is here"` / `"New wish"` local notifications (opt-in in Settings), and bounded poster caching. See [Family Wishes](WISHES.md).

## Known limits

- Automated tests never play a real title; playback is checked by hand on real devices.
- Waking a sleeping server sends the packet straight to the server's last IPv4 addresses and to
  their /24 broadcast address; iOS may block the broadcast for apps without Apple's multicast
  permission, which needs a paid developer account. The direct packet reaches the server while the
  router still knows its address; otherwise wake it another way, such as from a Mac or the router.
- New-device notes and unlock requests appear only while the app is open; there are no push
  notifications. Face ID itself is checked on a real device; tests sign with a software key.
- Server administration is checked by logic tests, against an isolated test server and with
  simulator screenshots of invented data (the debug "admin" scenario); there are no iOS UI tests.
- The app is not published as a download; build it from source as above. Away from home it works
  through a VPN, see [Watching away from home](REMOTE_ACCESS.md).
