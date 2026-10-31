# Aurelia for Linux

Aurelia for Linux (`clients/linux`) is the native desktop app for Linux. It is meant to become the
full Mac app on Linux: the library, the player, the app settings, every server and administration
screen, and hosting the server on the same computer. It is a preview and is not published yet.

It is written in C# (.NET 10) with the Avalonia interface toolkit, the way the Mac app is written
in Swift with SwiftUI. Its interface code is its own; it shares only `src/Aurelia.Contracts` with
the server, so requests and responses always use the same field names and formats. It runs on
Linux x64. Platform specifics stay behind small adapters so the code stays portable.

## Projects

| Project | Contents |
| --- | --- |
| `Aurelia.Linux.Core` | App logic without any interface toolkit, such as the sidebar pages and their order |
| `Aurelia.Linux` | The app: design tokens and styles (`Design/`), the sidebar shell and pages (`Views/`) |
| `Aurelia.Linux.Tests` | Logic tests and headless interface tests that draw the real views without a screen |

The version and build number live in `clients/linux/Directory.Build.props`
(`Version`, `AureliaLinuxBuildNumber`), independent of the Mac/server and Apple TV versions.

## Design

The app follows the Mac app's dark Aurelia design, not GNOME or KDE styling. The tokens in
`Design/AureliaTokens.axaml` are the values from the Mac app's `AureliaDesign.swift`: the
measured canvas color, spacing, radii, sidebar width and type sizes. The typeface is Inter,
bundled with the app. The symbols in `Design/AureliaIcons.axaml` are drawn for Aurelia, so
nothing is loaded or licensed from elsewhere.

Pages run full height beneath the sidebar. The sidebar (`Controls/SidebarBackground.cs`) blurs
what passes beneath it and tints it with the canvas color at 66 %, like the Mac app;
`ReduceTransparency` makes it the opaque canvas. The window keeps the desktop's own title bar and
buttons. Avalonia runs natively on Wayland and falls back to X11; `AURELIA_DISPLAY_BACKEND=x11`
forces X11.

## Video

The player arrives in a later version. A test on KDE Plasma (Wayland) with the distribution's
libVLC 3.0 and synthetic test clips decided how it will draw video:

| Approach | Controls above the video | CPU, 1080p H.264 | CPU, 2160p HEVC |
| --- | --- | --- | --- |
| VLC draws into an embedded X11 window (XWayland) | no: the video covers them | about 4 % of one core | about 5 % |
| VLC hands decoded frames to Avalonia, which draws them (native Wayland) | yes | about 40 % of one core | about 55 % |

Embedding is efficient but hides anything drawn above the video, and it needs X11. Frames drawn
by Avalonia work on Wayland and X11 with the player's controls on top, so the player uses VLC's
frame callbacks (`libvlc_video_set_callbacks`). Notes for the player:

- Hardware decoding needs the media option `:avcodec-hw=vaapi_drm` (with a fallback to `any`);
  without a VLC window, VLC otherwise decodes in software.
- Frames are handed over at full size. Letting VLC scale 4K down to 1080p cost more and dropped
  frames; Avalonia scales on the graphics card while drawing.
- A later improvement is to take the frames as YUV and convert them to RGB on the graphics card,
  which saves VLC's color conversion on the processor.

## Building and testing

```bash
scripts/test-linux-app.sh
```

restores, checks formatting, builds Release with warnings as errors and runs all tests. The
headless interface tests draw the real views with Skia and save the frames to
`Local/Test Results/LinuxApp-<run>/snapshots`. They need no screen and do not take over one.

```bash
scripts/build-linux-app.sh
```

runs the tests, publishes the app self-contained for `linux-x64` and lays it out as installed:
`/usr/lib/aurelia-desktop`, the `aurelia-desktop` command (the server package owns `aurelia`),
the desktop entry and AppStream metadata `io.github.lucasfd3.Aurelia`, the icon and the
third-party notices. `scripts/package-linux-app.sh` then makes the packages on Linux:

| File | Distributions |
| --- | --- |
| `.deb` | Ubuntu, Linux Mint, Debian, Pop!_OS |
| `.rpm` | Fedora, openSUSE |
| `.pkg.tar.zst` | Arch Linux, CachyOS, Manjaro, EndeavourOS |
| `.flatpak` | any distribution with Flatpak (Freedesktop runtime 26.08 from Flathub) |

On the Mac, set `AURELIA_LINUX_PACKAGE_HOST` to an ssh host with `dpkg-deb`, `rpmbuild`,
`makepkg`, `flatpak-builder` and the Freedesktop 26.08 Platform and Sdk, and optionally
`AURELIA_LINUX_PACKAGE_SSH_CONFIG` to its ssh configuration. Everything lands in
`Local/Build/LinuxApp/<version>-<build>/`.

```bash
scripts/install-linux-app.sh <ssh host>
```

installs the newest build on a Linux computer with its own package manager. It replaces only the
package; settings in the home folder stay.
