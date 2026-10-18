# Aurelia for Windows (and later Linux)

A native desktop client written in C# with [Avalonia](https://avaloniaui.net), designed
like the Aurelia Mac app. The same code runs on Windows (x64 and ARM64), on Linux and on
macOS, so everyday development and testing happen on a Mac.

Version 0.0.2 connects to an Aurelia server:

- Finds servers on the local network, or takes a typed address
- Shows the server's fingerprint to compare with the Mac before trusting it, and from
  then on only talks to a server presenting exactly that key
- Pairs with an 8-digit code approved on the Mac (Settings › General › Devices ›
  Approve Device…)
- Shows the profiles, asks for a PIN where one is set, and remembers the connection;
  on Windows the credential is encrypted for the signed-in Windows user

The library, playback and the built-in server follow in later versions.

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

`build-desktop.sh` writes `Aurelia.exe` for each Windows architecture, plus a zip of it,
to `Build/Desktop/<version>-<build>/` in the external workspace. Each `Aurelia.exe` is
self-contained and needs no .NET installation on Windows.

## On Windows

Copy the zip for the PC's architecture (`win-x64` for most PCs, `win-arm64` for
Snapdragon laptops and Windows on Apple Silicon), extract it and start `Aurelia.exe`.
Windows may show a SmartScreen warning because the app is not signed: choose
**More info › Run anyway**.

For regular Windows checks without the laptop, a Windows 11 ARM virtual machine on the
Mac (for example in UTM or VMware Fusion) runs the `win-arm64` build natively and the
`win-x64` build through Windows' own emulation.
