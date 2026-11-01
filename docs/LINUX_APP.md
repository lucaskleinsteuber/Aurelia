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

## Library

When a profile opens, `Library/LibraryStore.cs` loads Home, every title, the collections and the
watchlist together and keeps them current with `Library/LibrarySync.cs`: a 30-second long poll of
`/api/v1/sync/changes` with the Mac app's refresh plan (Home plus changed titles, or everything);
its cursor is kept per server, profile and session. `Library/LibraryClient.cs` holds every library
endpoint; catalog lists load page by page (100, or 500 on servers that allow it) and start again
when the library changes while loading.

The pages follow the Mac app: Home (the recommendation as a full-bleed hero, Continue Watching,
three genre rows, Favorites, Collections, Recently Added), Library, Movies, TV Shows and Recently
Added (search after 220 ms, filter chips, sort, filters remembered per server, profile and page),
Collections (smart lists, collections, film series to save), Watchlist, History and Statistics,
and detail pages for titles (seasons, episodes, trailers, extras, cast and crew, information),
people and collections. Every title has the Mac app's context menu; season and series changes
are made on the series and ask first with the number of episodes. Artwork is requested in the
smallest width that stays sharp (320, 640, 1280, 1920) and kept in memory (96 MB) and on disk
(512 MB, only artwork with a revision). Ctrl+F opens the library search, Alt+Left goes back.

## Settings

Settings open with Ctrl+, or the gear next to the profile, in a window of their own like the Mac
app's, with a search field (`Settings/SettingsWindow.cs`):

- General: start screen, poster size, watched titles in rows, Reduce Motion, and "Let the Server
  Rest When Unused" with its minutes.
- Sidebar: the pages, their order and visibility (one always stays), and the startup screen.
- Activity: statistics and history.
- Playback: all twelve player settings with the Mac app's choices, "Forget Track Choices" and
  "Restore Playback Defaults".
- Profiles and Devices: the open profile, switching profiles, and changing, turning on or removing
  the own PIN (owners and administrators always keep one); a PIN change locks the profile.
- Updates: the installed version and automatic checks.
- Advanced: the server connection (name, address, fingerprint, profile) and "Disconnect This PC".

When nothing plays and nobody used Aurelia for the chosen minutes, Aurelia lets go of a server on
another computer so it can sleep: the sync stops, idle connections close and "Aurelia Is Resting"
shows. Any click or key wakes the server and continues with the open profile. Ctrl+/ lists the
keyboard shortcuts.

## Server management

Owners and administrators manage the server from Settings, as in the Mac app
(`Aurelia.Linux.Core/Management`, `Aurelia.Linux/Management`). Library appears for owners and for
administrators with the whole library, Metadata for both, and Server only for the owner, because
the server accepts its requests only from the owner; the Mac app shows them to administrators too
and they fail.

- Server: summary with state, facts and Restart Server; health; for a Linux package server its
  updates and power saving; new devices and automatic backups with Back Up Now; scrub previews; and
  under Advanced Settings the details, network (read-only: a Linux server is set up with
  `sudo aurelia setup`), sign-in and streaming limits, library maintenance and job queue, backups
  (retention, verify, encrypted export, restore with a passphrase) and diagnostics. Server settings
  are edited as JSON, so fields this app does not know are saved back unchanged.
- Profiles and Devices (owner): every profile with role, PIN and access, the profile editor (role,
  enabled, PIN, entire library or selected titles), deleting a profile (never the last owner),
  approving an Apple TV or browser code, the browser address, a pairing code for another computer
  with its countdown, and signing out devices.
- Library: storage locations chosen from the server's folders, each added waiting for an import
  preview; the preview lists every file with filters and search, assignments (movie, series, episode,
  extra, trailer, ignore) and confirmation. Rescan, monitoring, removing a location (files stay),
  scan activity, trailer reviews, Library Health (duplicates, offline titles, unmatched metadata,
  excluded items with reimport), Hide Offline Titles and Reset Library.
- Metadata: the owner's TMDB token, Enrich Library, the review queue, unused artwork and the
  running job. On every title, administrators find Edit Metadata (all fields, cast and crew,
  poster and backdrop with upload and crop, the source file) and Remove from Library, and on the
  detail page Find Metadata Match.

Requests go out as they are. Only when the server answers `approval_required` does the client ask
`POST /api/v1/management/approval` for a one-use approval of exactly that request (method, path with
query, SHA-256 of the exact body) and send it again with `X-Aurelia-Approval`. When management is
locked, the Server Password prompt opens above whatever sheet is open, `POST /api/v1/management/unlock`
unlocks it for ten minutes, and the request is retried. Sheets stack, so an editor stays open
beneath the prompt. Network changes of a server hosted in Aurelia on a Mac need a 60-second trial
with reconnection; they come with hosting on this PC.

## Player

`Playback/PlaybackController.cs` runs a playback the way the Mac app does. It asks the server for a
ticket (`POST /api/v1/media/{id}/playback`) and starts `Playback/LoopbackStreamRelay.cs`: VLC reads
plain HTTP from a random port on 127.0.0.1 with a secret path, and the relay forwards each byte range
over the pinned HTTPS connection with the profile's token, which never reaches the decoder. A body
shorter than announced counts as a broken stream. VLC opens directly at the resume position (the
Automatic Resume and start-over settings decide it). The remembered audio and subtitle choice
applies (the series' own first, then the last choice, then the default language), and the server's
sidecar subtitle files are added. Progress is saved every 15 seconds and at every pause, seek, end
and close, with the revision it builds on (`Playback/ProgressOutbox.cs`; saves that could not be
sent wait in `$XDG_STATE_HOME/aurelia-desktop/pending-progress.json`). A conflict offers to keep
this computer's position. Other behavior:

- Up Next appears for titles of at least five minutes in the last seconds of the countdown, and
  the next episode starts at the natural end unless the card was cancelled.
- The sleep timer runs for a number of minutes or until the end of the episode and tells the
  server when it ends.
- The ticket is renewed five minutes before it expires.
- A stall (no movement for 15 seconds, or no first frame within 30) or a broken stream is recovered
  at the last position after 1, 2, 4, 8, 15 and 30 seconds, for at most two minutes.
- Night Mode reopens the title with VLC's compressor at the same position.

`Playback/PlayerView.cs` is laid out like the Mac player:

- the title at the top;
- the timeline with server preview pictures and "Ends at";
- previous episode, back, play/pause, forward and next episode;
- menus for playback rate, audio (with Night Mode), subtitles and the sleep timer;
- scene notes, volume and full screen;
- keys: Space, ←/→, M, F, Esc, P, N and Ctrl+Shift+←/→.

The controls hide after the chosen delay. `Platform/LinuxPlaybackSystem.cs` publishes the player
through MPRIS (`org.mpris.MediaPlayer2.aurelia`, for media keys and the desktop's media controls)
and keeps the screen awake with `org.freedesktop.ScreenSaver` while playing.

Play On (`Playback/PlayOn.cs`): while a profile is open this computer announces itself every 15
seconds and follows play, pause, resume, seek, skip and stop commands from other devices (with the
position of "play" and the pause state). The title page sends titles to other players, and a remote
bar controls them.

### How video is drawn

A test on KDE Plasma (Wayland) with the distribution's libVLC 3.0 and synthetic test clips decided
how video is drawn:

| Approach | Controls above the video | CPU, 1080p H.264 | CPU, 2160p HEVC |
| --- | --- | --- | --- |
| VLC draws into an embedded X11 window (XWayland) | no: the video covers them | about 4 % of one core | about 5 % |
| VLC hands decoded frames to Avalonia, which draws them (native Wayland) | yes | about 40 % of one core | about 55 % |

The player uses VLC's frame callbacks (`Playback/VideoFrames.cs`, `Controls/VideoSurface.cs`):
they work on Wayland and X11 with the controls on top. Hardware decoding uses `:avcodec-hw=vaapi_drm`,
since without a VLC window VLC would otherwise decode in software; frames are handed over at full
size, because letting VLC scale 4K down cost more and dropped frames. A later improvement is to take
frames as YUV and convert them on the graphics card.

The automated tests drive the player with a simulated engine through the same controller and
views; real playback is checked by hand on a Linux desktop.

## Building and testing

```bash
scripts/test-linux-app.sh
```

restores, checks formatting, builds Release with warnings as errors and runs all tests:

- `Aurelia.Linux.Tests`: logic, and headless interface tests that draw the real views with Skia
  (frames are saved to `Local/Test Results/LinuxApp-<run>/snapshots`). They need no screen and do
  not take over one. Screens that talk to a server use a scripted fake server.
- `Aurelia.Linux.IntegrationTests`: the app's connection and library logic against the real
  Aurelia server in the same process, with a temporary data folder, synthetic accounts and a
  library made of one-byte files named like videos. It is a separate project
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
