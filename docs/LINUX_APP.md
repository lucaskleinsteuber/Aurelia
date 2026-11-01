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
| `Aurelia.Linux.Core` | App logic without any interface toolkit: API client, connection and profiles, keyring, discovery, Wake-on-LAN, screen order, settings |
| `Aurelia.Linux` | The app: design tokens and styles (`Design/`), window buttons and behavior (`Controls/`), screens (`Views/`) |
| `Aurelia.Linux.Tests` | Logic tests and headless interface tests that draw the real views without a screen |
| `Aurelia.Linux.IntegrationTests` | The connection logic against the real server, in process |

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
`ReduceTransparency` makes it the opaque canvas. Avalonia runs natively on Wayland and falls back to
X11; `AURELIA_DISPLAY_BACKEND=x11` forces X11.

## Window

Like the Mac app, the window has no title bar: the content reaches the top edge. On Wayland the app
extends into the window and Avalonia draws only the resize border; on X11 the window manager keeps a
thin border and drops its title bar (`WindowDecorations.BorderOnly`). Aurelia draws its own window
buttons (`Controls/WindowChrome.cs`): plain round close, minimize and maximize buttons, never imitations
of the Mac's colored ones, placed where the desktop puts them. KDE Plasma's `ButtonsOnLeft` and
`ButtonsOnRight` in kwinrc are read first, then GNOME's `button-layout` (also used by Cinnamon, Budgie
and MATE), otherwise they sit on the right. Pressing on empty space in the top 52 pixels moves the
window and a double click maximizes it (`Controls/AppWindowBehavior.cs`); F11 switches full screen,
F9 the sidebar, Ctrl+Q quits. The sidebar can be dragged between 210 and 300 pixels wide.

## Screens and settings

`Flow/AppFlow.cs` chooses the full-window screen in the Mac app's order: the start screen, the welcome
choice ("Set Up This PC" or "Connect to an Existing Server"), host setup or the connection screen, the
profile picker, the first storage locations and the library. The chosen mode is remembered.
Preferences are kept in `$XDG_CONFIG_HOME/aurelia-desktop/settings.json`, readable only by the user
and written through a temporary file; caches go to `$XDG_CACHE_HOME/aurelia-desktop`.

## Connecting

`Flow/AppSession.cs` keeps the connection the way the Mac app's AppModel does. At start it reads
the saved pairing from the desktop keyring (`Platform/SecretServiceCredentialStore.cs`, the
freedesktop Secret Service of GNOME Keyring and KDE Wallet; there is no plain-file fallback) and
reaches the server (`Connection/ServerWakeUp.cs`): a quick check, then Wake-on-LAN every 10 seconds
for up to two minutes when the server reported its hardware addresses, otherwise up to 20 seconds.
A server announced nearby with the same id and key at another address is accepted and remembered.

The connection screen lists servers announced on the network (`_aurelia._tcp` and the older
`_aurelia-home._tcp`, TLS only) or takes a typed address (HTTPS, port 43111 by default). On first
contact the client reads the server's P-256 key fingerprint from the TLS handshake and checks it
against the one the server reports; the person compares it with the fingerprint shown on the
server, enters the eight-digit pairing code (`POST /api/v1/auth/pair`) and every later connection
accepts only that key (`Api/ServerTransport.cs`). "Who's watching?" follows: profiles without a PIN
open at once, others take a four- to eight-digit PIN, and a server whose profiles were never set up
asks for its password and the owner's new PIN. A profile closes after its server-given expiry, at
most twelve hours, and the sidebar's profile button switches profiles.

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

restores, checks formatting, builds Release with warnings as errors and runs all tests:

- `Aurelia.Linux.Tests`: logic, and headless interface tests that draw the real views with Skia
  (frames are saved to `Local/Test Results/LinuxApp-<run>/snapshots`). They need no screen and do
  not take over one. Screens that talk to a server use a scripted fake server.
- `Aurelia.Linux.IntegrationTests`: the app's connection logic against the real Aurelia server in
  the same process, with a temporary data folder and synthetic accounts. It is a separate project
  because the server's SkiaSharp 4 and Avalonia's SkiaSharp 3 cannot load together.
- The real desktop keyring is tested only on a Linux desktop with `AURELIA_TEST_KEYRING=1`, using
  its own entry that the test removes again.

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
