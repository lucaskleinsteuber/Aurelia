# Aurelia for iPhone and iPad

`clients/ios` holds the iPhone and iPad client. It is a preview: it builds and its logic is
tested, but it has not been installed on a real device or played a real title yet.

## How it is built

The app shares its behavior with the Apple TV app, which plays on a real TV every day. Its
code is a copy of the Apple TV app's, adapted for touch and smaller screens, not a link to it:
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
- **Sizes**: the screens are the Apple TV's, scaled to half size on iPhone and three quarters
  on iPad (`IOSDesign.scale`). Touch controls the player; a hardware keyboard adds the
  arrow keys, Space and Escape.

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

The app is signed for development like the Apple TV app. To install it, open
`clients/ios/AureliaIOS.xcodeproj` in Xcode, choose your iPhone and press Run. A free
development profile expires after seven days; the signing refresh job in
`scripts/refresh-signing.sh` currently renews only the Mac and Apple TV apps.

## Known limits

- Not yet tried on a physical iPhone or iPad, and no real title has played in it.
- No UI tests yet; the logic tests cover the shared core.
- The app is not published on GitHub.
