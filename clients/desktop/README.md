# Aurelia for Windows (and later Linux)

A native desktop client written in C# with [Avalonia](https://avaloniaui.net), designed
like the Aurelia Mac app. The same code runs on Windows (x64 and ARM64), on Linux and on
macOS, so everyday development and testing happen on a Mac.

Version 0.0.4 runs its own Aurelia server or connects to one elsewhere, and plays your
library:

- **Set Up This PC:** the app brings the same server as the Mac app and starts and stops it
  with itself. The first start asks for a Server Password, the owner's viewing PIN and the
  first storage locations (folders or drives; files are only read). Afterwards the profiles
  open directly. **Server Settings…** in the sidebar shows the server's state, addresses and
  fingerprint, renames it, turns network access for other devices on or off (tried for a
  minute, then confirmed or returned), restarts it, manages storage locations and scans,
  approves a new device's code and removes paired devices. A forgotten owner PIN is reset
  with the Server Password.
- **Connecting elsewhere:** finds servers on the local network or takes a typed address,
  shows the server's fingerprint to compare before trusting it, pairs with an 8-digit code
  approved on the server computer, and asks for a profile's PIN where one is set. On Windows
  the credential is encrypted for the signed-in Windows user.
- **Library:** Home with a hero, Continue Watching and shelves; Movies and TV Shows; Search;
  detail pages with seasons, episodes and extras; favorites. Artwork is cached on this
  computer.
- **Player:** VLC playback that resumes where you stopped, with a loading ring, saved
  progress, audio and subtitle tracks remembered per series, playback speed, Night Mode, a
  sleep timer, the end time, timeline preview frames (kept in memory only), an Up Next
  countdown with automatic next episodes, full screen and keyboard shortcuts (Space, ←/→,
  ↑/↓, F, M, N, Esc).

On Windows the server keeps its data in `%LOCALAPPDATA%\Aurelia Server` and uses ports 43110
(this computer only) and 43111 (HTTPS for other devices). The first time network access is on,
Windows asks whether Aurelia Server may use the network: choose **Allow** for private
networks. The server runs while the app is open.

## On a Mac

From the repository root:

```sh
scripts/run-desktop.sh     # opens the app on this Mac
scripts/test-desktop.sh    # format check, warning-free build, headless UI tests
scripts/build-desktop.sh   # Windows x64 and ARM64 builds, plus a Mac build
scripts/test-server-wine.sh  # the Windows server build under CrossOver's Wine
```

On a Mac, **Set Up This Computer** hosts a development server with its own data
(`~/Library/Application Support/Aurelia Desktop/Server`), its own ports (43120, 43121) and
network access off by default, so the installed Aurelia app and its server are not touched.

`test-server-wine.sh` needs CrossOver. It starts the Windows x64 server with synthetic data on
127.0.0.1 and checks the Windows file code (scan identities, handle-checked playback opens,
folder listings, refusal of links). Wine lacks ECDSA keys and PBKDF2, so HTTPS and accounts
are only checked on Windows itself.

`test-desktop.sh` renders the real windows off screen; no window appears. Set
`AURELIA_DESKTOP_RENDER_DIR=/path/to/folder` to save each rendered step as an image. It
also builds the server and runs the connection end to end against it: a temporary server
with synthetic accounts, reachable only on this computer, which stops after the test.

`build-desktop.sh` writes a folder for each Windows architecture, with `Aurelia.exe`, its
`libvlc` folder and the bundled server in `server`, plus a zip of it, to `Build/Desktop/<version>-<build>/` in the external
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
