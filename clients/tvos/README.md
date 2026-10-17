# Aurelia for Apple TV

A native tvOS 26 client for an Aurelia server on your local network, designed
like the Aurelia Mac app. Version 0.2.0 includes:

- Home with a hero, Continue Watching that resumes directly, genre shelves,
  Favorites, Collections and Recently Added
- Movies, TV Shows and Search with filters and sorting
- Details with a season bar, episodes, trailers, extras, cast and crew and full
  information, plus favorite, watched and Start Over actions
- Fullscreen playback with saved progress, audio and subtitle selection,
  playback speed, a sleep timer, automatic next episodes and left/right skipping
  while the controls are hidden
- Centered profiles with a digits-only PIN keypad
- Artwork kept on the Apple TV for each profile, so posters appear at once
  after the app restarts

Open `AureliaTV.xcodeproj` and select the **AureliaTV** scheme. The TV client has
its own project, bundle identifier and version; it does not share an application
library with the Mac client. Server and user administration remain on the Mac.

From the repository root:

```sh
scripts/prepare-tvvlckit.sh
scripts/build-tvos.sh --unsigned
scripts/test-tvos-logic.sh
scripts/test-tvos-ui.sh
```

For a device-signed build, omit `--unsigned`. If Xcode needs to fetch a matching
development profile, add `--allow-provisioning-updates`; an existing configured
Apple development account and the device's pairing are required. To select an
already paired Apple TV, add `--device <identifier>`. Together with provisioning
updates, this allows Xcode to register that selected device for development.
The build script builds for **Apple TV devices**, never a simulator, and does not install
or launch the application. `AURELIA_TV_BUILD_ROOT` can select an external output
directory. Generated files otherwise use `scripts/workspace-paths.sh` defaults.

The TV Home Screen icon and top shelf use the existing Aurelia brand mark in
a native TV asset catalog. No Mac source files are linked into the app.

TVVLCKit 3.7.3 comes from the [official VideoLAN production archive](https://download.videolan.org/cocoapods/prod/TVVLCKit-3.7.3-319ed2c0-79128878.tar.xz)
and is verified against the SHA-256 pinned in the preparation script. The cache
stays external; ignored `Dependencies` symlinks make the project portable.
`TVVLCKIT_ROOT` can override that dependency directory. The vendor license is
included in the app's resources.

The **AureliaTVLogicTests** scheme runs platform-neutral TV logic directly
on the Mac without an app host or TVVLCKit. The **AureliaTVUITests** scheme uses
`XCUIRemote` in a dedicated tvOS 26.0 Apple TV simulator for real focus and
navigation checks, geometry assertions and attached screenshots. Install that
runtime in Xcode Components before running `scripts/test-tvos-ui.sh`; the script
creates and removes only its own simulator and leaves results outside Git.

UI tests use the same app views and playback controller, with Debug-only
synthetic profiles, catalog responses and a simulated engine/relay. They never
read personal credentials, contact a real server, or start the video engine.
The fixture entry point is absent from Release builds. Actual remote navigation
and video playback still receive separate user acceptance on a physical Apple
TV; no automated codec, stream or playback gate runs.

The separate **AureliaTVDeviceCheck** scheme and `scripts/test-tvos-device.sh`
exist only for the explicitly approved, five-minute check of one episode on a
paired Apple TV. It requires opt-in environment variables, never runs with the
simulator tests and removes its test runner afterwards.
