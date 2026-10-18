# Aurelia for Windows (and later Linux)

A native desktop client written in C# with [Avalonia](https://avaloniaui.net), designed
like the Aurelia Mac app. The same code runs on Windows (x64 and ARM64), on Linux and on
macOS, so everyday development and testing happen on a Mac.

Version 0.0.3 connects to an Aurelia server and plays your library:

- **Connecting:** finds servers on the local network or takes a typed address, shows the
  server's fingerprint to compare with the Mac before trusting it, pairs with an 8-digit code
  approved on the Mac (Settings › General › Devices › Approve Device…), and asks for a
  profile's PIN where one is set. On Windows the credential is encrypted for the signed-in
  Windows user.
- **Library:** Home with a hero, Continue Watching and shelves; Movies and TV Shows; Search;
  detail pages with seasons, episodes and extras; favorites. Artwork is cached on this
  computer.
- **Player:** VLC playback that resumes where you stopped, with a loading ring, saved
  progress, audio and subtitle tracks remembered per series, playback speed, Night Mode, a
  sleep timer, the end time, timeline preview frames (kept in memory only), an Up Next
  countdown with automatic next episodes, full screen and keyboard shortcuts (Space, ←/→,
  ↑/↓, F, M, N, Esc).

The built-in server follows in a later version.

## On a Mac

From the repository root:

```sh
scripts/run-desktop.sh     # opens the app on this Mac
scripts/test-desktop.sh    # format check, warning-free build, headless UI tests
scripts/build-desktop.sh   # Windows x64 and ARM64 builds, plus a Mac build
```

`test-desktop.sh` renders the real windows off screen; no window appears. Set
`AURELIA_DESKTOP_RENDER_DIR=/path/to/folder` to save each rendered step as an image. It
also builds the server and runs the connection end to end against it: a temporary server
with synthetic accounts, reachable only on this computer, which stops after the test.

`build-desktop.sh` writes a folder for each Windows architecture, with `Aurelia.exe` and
its `libvlc` folder, plus a zip of it, to `Build/Desktop/<version>-<build>/` in the external
workspace. The app is self-contained and needs no .NET or VLC installation on Windows.

## On Windows

Copy the zip for the PC's architecture (`win-x64` for most PCs, `win-arm64` for
Snapdragon laptops and Windows on Apple Silicon), extract the whole folder and start
`Aurelia.exe` inside it.
Windows may show a SmartScreen warning because the app is not signed: choose
**More info › Run anyway**.

For regular Windows checks without the laptop, a Windows 11 ARM virtual machine on the
Mac (for example in UTM or VMware Fusion) runs the `win-arm64` build natively and the
`win-x64` build through Windows' own emulation.
