# Aurelia for iPhone and iPad

`clients/ios` holds the iPhone and iPad client. It is a preview: it builds, its logic is
tested and it installs on a real iPhone, but its playback has not been checked on one yet.

## How it is built

The app shares its behavior with the Apple TV app, which plays on a real TV every day. Its
connection, playback and library code is a copy of the Apple TV app's, not a link to it, and
its screens are its own:
`clients/ios` has its own Xcode project with no references into `clients/tvos` or
`clients/macos`, as `AGENTS.md` requires.

- **Connecting** works exactly like on the Apple TV: the app finds servers with Bonjour or
  takes an address, shows the server's fingerprint to confirm, and shows a code that you enter
  on the Mac under *Enter Code from Apple TV or Browser…*. The server's certificate is pinned
  to that fingerprint.
- **Profiles** open with their PIN; Home, Movies, TV Shows, Search, title pages, the Watchlist
  and people pages work like on the Apple TV.
- **Playback** runs through MobileVLCKit and a small relay on `127.0.0.1` that adds the
  sign-in to each request and streams the bytes through; nothing is stored. Progress, sound
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

## Installing on your own iPhone

```bash
zsh scripts/build-ios.sh --device <identifier>
```

Builds the app signed for development and installs it on a paired iPhone or iPad, over the
cable or over Wi-Fi; `xcrun devicectl list devices` shows the identifier. The device needs
Developer Mode (Settings › Privacy & Security) and must have been paired with this Mac in Xcode
once. Reinstalling replaces only the app, so its server connection and settings stay. A free
development profile expires after seven days; the signing refresh job in
`scripts/refresh-signing.sh` currently renews only the Mac and Apple TV apps, so run the command
again to renew it.

The player works by touch: tap the picture to show or hide the controls, and drag along the
timeline (or tap a place on it) to jump there. The buttons at the top choose the speed, the
sound and subtitles (with Night Mode) and the sleep timer in a short sheet. A hardware keyboard
adds the arrow keys, Space and Escape.

## Known limits

- Installed on a real iPhone, but its playback and touch controls still need the owner's own
  check; automated tests never play a real title.
- Waking a sleeping server sends a broadcast, which iOS may block for apps without Apple's
  multicast permission; the server then has to be woken another way.
- No UI tests yet; the logic tests cover the shared core.
- The app is not published on GitHub.
