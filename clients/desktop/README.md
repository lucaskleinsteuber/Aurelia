# Aurelia for Windows (and later Linux)

A native desktop client written in C# with [Avalonia](https://avaloniaui.net), designed
like the Aurelia Mac app. The same code runs on Windows (x64 and ARM64), on Linux and on
macOS, so everyday development and testing happen on a Mac.

Version 0.1.0 installs with a setup program, runs its own Aurelia server or connects to one
elsewhere, and plays your library:

- **Set Up This PC:** the app brings the same server as the Mac app and starts it with
  itself. The first start asks for a Server Password, the owner's viewing PIN and the
  first storage locations (folders or drives; files are only read). Afterwards the profiles
  open directly. **Server Settings…** in the sidebar shows the server's state, addresses and
  fingerprint, renames it, turns network access for other devices on or off (tried for a
  minute, then confirmed or returned), restarts it, manages storage locations and scans,
  approves a new device's code and removes paired devices. A forgotten owner PIN is reset
  with the Server Password.
- **When the server runs:** closing the window keeps the server running behind an Aurelia
  icon in the notification area (**Open Aurelia**, **Quit Aurelia**), and Windows starts it
  when you sign in, so the Apple TV always finds it. Both, and keeping the PC awake while
  the server runs, are in Server Settings › General. Aurelia runs once per person; starting
  it again opens the running one.
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
(this computer only) and 43111 (HTTPS for other devices). The installer lets it through Windows
Firewall for devices on the same home network (networks marked Private) only; Server
Settings says when Windows treats the current network as public.

## On a Mac

From the repository root:

```sh
scripts/run-desktop.sh     # opens the app on this Mac
scripts/test-desktop.sh    # format check, warning-free build, headless UI tests
scripts/build-desktop.sh   # Windows x64 and ARM64 installers, plus a Mac build
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
`libvlc` folder, the bundled server in `server` and the third-party notices, and an installer
for each (`Aurelia-<version>-<build>-Setup-x64.exe` and `-arm64.exe`), to
`Build/Desktop/<version>-<build>/` in the external workspace. The installers are made with Inno
Setup 7.1.0 under CrossOver's Wine (`scripts/make-desktop-installer.sh` downloads it once,
checks its pinned checksum and keeps it in its own Wine prefix in the workspace). The app is
self-contained and needs no .NET or VLC installation on Windows. `make-desktop-icon.sh`
makes the Windows icon from the Aurelia app icon the Mac app also uses
(`clients/macos/Aurelia/AureliaAppIcon.icon`).

## On Windows

Run the installer for the PC's architecture (`x64` for most PCs, `arm64` for Snapdragon
laptops and Windows on Apple Silicon) and allow it to make changes; it installs Aurelia for
all users. Windows may show a SmartScreen warning because the installer is not signed:
choose **More info › Run anyway**. Installing a newer version over it keeps every setting.
Uninstalling (Settings › Apps) asks whether the server data should be removed too; it is
kept unless you choose **Yes**. Movie and TV show files are never touched.

For regular Windows checks without the laptop, a Windows 11 ARM virtual machine on the
Mac (for example in UTM or VMware Fusion) runs the `win-arm64` build natively and the
`win-x64` build through Windows' own emulation.
