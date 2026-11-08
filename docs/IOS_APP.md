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
  tracks, subtitles (including subtitle files next to the video), scrub previews, Up Next and
  the sleep timer behave as on the Apple TV.
- **Screens** are built for iPhone and iPad rather than taken from the TV: a tab bar with Home,
  Movies, TV Shows, Search and Settings, iOS text sizes and margins, the PIN entered on a keypad
  like the iPhone passcode, seasons as a menu with the episodes listed below, and settings as an
  iOS form. The player works by touch; a hardware keyboard adds the arrow keys, Space and Escape.
  The app icon is the Mac app's Liquid Glass icon.
- **Settings** hold everything that belongs to the profile on this device and nothing that
  manages the server: Watch History (swipe to remove an entry, or clear it), Statistics with
  watch time in minutes, hours and days, the last weeks as a chart, top titles and genres and a
  year in review, Playback, the profile's own PIN (set, change, or turn off for ordinary
  profiles), the size of the stored artwork with a button to clear it, and the server's name,
  address and version.

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
adds the arrow keys, Space and Escape.

## Known limits

- Automated tests never play a real title; playback is checked by hand on real devices.
- Waking a sleeping server sends a broadcast, which iOS may block for apps without Apple's
  multicast permission; the server then has to be woken another way.
- No UI tests yet; the logic tests cover the shared core.
- The app is not published as a download; build it from source as above. Away from home it works
  through a VPN, see [Watching away from home](REMOTE_ACCESS.md).
