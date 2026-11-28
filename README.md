<div align="center">

<img src="docs/assets/tarven-icon.svg" width="128" height="128" alt="Tarven app icon">

# Tarven

**Your own movies and TV shows, in a library that feels like a streaming service, on your own hardware.**

A free, self-hosted media server for Mac, Linux or a NAS, with native apps for
Mac, Linux, Apple TV, iPhone and iPad, and a player in any web browser.

[![Latest release](https://img.shields.io/github/v/release/lucaskleinsteuber/Tarven?label=release&color=5B4FE0)](../../releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-1F2328)](LICENSE)
![macOS 26](https://img.shields.io/badge/macOS%2026-Apple%20silicon%20%7C%20Intel-1F2328?logo=apple&logoColor=white)
![tvOS 26](https://img.shields.io/badge/tvOS-26-1F2328?logo=apple&logoColor=white)
![iOS 26](https://img.shields.io/badge/iOS%20%7C%20iPadOS-26-1F2328?logo=apple&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-x64%20%7C%20arm64-1F2328?logo=linux&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-amd64%20%7C%20arm64-1F2328?logo=docker&logoColor=white)

[What it is](#what-tarven-is) · [Features](#what-it-can-do) · [Downloads](#downloads) ·
[Get started](#get-started) · [Away from home](docs/REMOTE_ACCESS.md) ·
[Guides](docs/README.md) · [Screenshots](#screenshots)

</div>

> **Tarven used to be Aurelia.** Same app, new name: see [what changes on your devices](docs/RENAMED.md).

## What Tarven is

You have movies and series on a drive. Tarven turns them into a library with posters,
descriptions, seasons, cast and trailers, remembers where everyone stopped, and plays them on
your TV, computer, tablet and phone, like a private streaming service for files you already own.

It has two parts:

- **The server** keeps the library. It runs inside the Mac or Linux app, on its own on a Linux
  PC (also an old laptop or a Raspberry Pi class computer), or in Docker on a NAS. It only ever
  *reads* your media folders.
- **The apps** browse and play: on Mac, Linux, Apple TV, iPhone, iPad and in any browser at home.

There is no account, no cloud and no subscription. Everything stays on your hardware and in your
home network; details and artwork from [TMDB](https://www.themoviedb.org) are optional.

## What it can do

**A library that organizes itself**
- Recognizes movies, series, seasons, episodes, extras and trailers from your folders, and shows
  what it found in an import preview before anything is added.
- Fetches details, artwork and the complete cast and crew from TMDB with your own free key, and
  matches by title, year and, for series, the episodes you have. Everything can be edited, and
  your corrections survive later scans.
- Collections: whole film series in release order, shared universes (for example Marvel or
  Middle-earth, movies and series together), your own collections and smart lists that fill
  themselves by genre, year, rating or watched state.

**Made for watching**
- Plays the original files with every audio and subtitle track, subtitle files next to the
  video, subtitles from OpenSubtitles (with your own free key), and subtitles the Mac writes
  from a title's speech when none fit, or moves to fit the speech when they are off.
- Timeline previews, Up Next for series, a sleep timer, Dialogue Boost, Volume Leveling and the
  time a title ends.
- Cinema Mode on the Mac: a made-up ad and trailers of films you haven't watched yet before the
  film starts.
- *Play On* sends a title to another screen at home and controls it from there.
- Downloads on Mac, Linux, iPhone and iPad for watching without the server, with an offline
  mode when the server is out of reach.

**For everyone at home**
- A profile per person with their own progress, favorites, Watchlist, collections, scene notes,
  history and statistics (watch time, streaks, a year in review). Administrators cannot read them.
- PIN protection, age limits (FSK) and profiles limited to chosen libraries or titles.

**A server that gets out of the way**
- Sleeps when nobody watches and wakes by Wake-on-LAN when you open an app.
- Server Health and Library Health show free space, warnings, duplicates and missing titles.
- A file watch reads every file in the background and finds damaged, cut-off and silently
  changed files (bit rot) early, and shows how the drives are doing.
- Daily database backups and checks; updates from the app or with one command.

**Private by design**
- Your files are never moved, renamed, converted or deleted, and no converted video is ever stored.
- Apps talk to the server over HTTPS and pin its certificate; new devices join only with a code
  you create. See the [security model](docs/SECURITY_MODEL.md) and the [privacy policy](docs/PRIVACY.md).

## Downloads

Every app has its own release on the [releases page](../../releases). Choose the download for
your system **and processor**:

| App | System | Download |
| --- | --- | --- |
| **Tarven for Mac** | macOS 26, **Apple silicon** (M1 and newer) | `Tarven-<version>-<build>-macOS-arm64.dmg` |
| | macOS 26, **Intel** | `Tarven-<version>-<build>-macOS-x64.dmg` |
| **Tarven for Linux** (desktop app) | Ubuntu, Debian, Mint · **x64** / **arm64** | `…-amd64.deb` / `…-arm64.deb` |
| | Fedora, openSUSE · **x64** / **arm64** | `…-x86_64.rpm` / `…-aarch64.rpm` |
| | Arch, CachyOS, Manjaro · **x64** / **arm64** | `…-x86_64.pkg.tar.zst` / `…-aarch64.pkg.tar.zst` |
| | Any distribution with Flatpak · **x64** | `…-x86_64.flatpak` |
| **Tarven Server for Linux** | systemd Linux · **x64** / **arm64** | One-line install, or `…-linux-x64.tar.gz` / `…-linux-arm64.tar.gz` |
| **Tarven Server with Docker** | NAS or any Docker host · amd64 / arm64 | Built on your machine, see [Docker](docs/DOCKER.md) |
| **Tarven for Apple TV** | tvOS 26 | Built from source with Xcode, see [Apple TV](docs/APPLE_TV.md) |
| **Tarven for iPhone & iPad** | iOS and iPadOS 26 | Built from source with Xcode, see [iPhone and iPad](docs/IOS_APP.md) |
| **Tarven in a browser** | Safari, Chrome, Edge, Firefox | Nothing to install: open the server's address |

Not sure which processor you have? On a Mac: Apple menu › About This Mac (it says *Chip: Apple M…*
or *Processor: Intel*). On Linux: run `uname -m` (`x86_64` means x64, `aarch64` means arm64).

> [!NOTE]
> Tarven is free and does not use Apple's paid developer program. The Mac download is
> development-signed, runs only on Macs registered to the developer's account and is published
> as a test version. **On any other Mac, use Tarven in your browser** (Safari, Chrome, Firefox):
> it does everything the Mac app does, from setting up the server to editing your library. Or build
> the Mac app yourself with a free Apple ID: [step by step](docs/BUILD_MAC_APP.md), no programming
> needed. The Apple TV, iPhone and iPad
> apps are not in the App Store and are installed from source the same way.
> [Distribution and updates](docs/FREE_DISTRIBUTION.md) explains why.

## Get started

1. **Pick the computer that keeps the library.** A Mac or Linux PC that is on when you watch,
   with your media drives attached. For a computer without a screen, install the Linux server
   with one line:
   ```sh
   curl -fsSL https://raw.githubusercontent.com/lucaskleinsteuber/Tarven/main/packaging/linux/get-tarven.sh | sudo bash
   ```
2. **Set it up.** On Linux, the installer offers to finish in a web browser: open the address it
   shows, type its one-time code, and create the owner, your media folders and your free TMDB key
   there. In the Mac or Linux app, choose *Set Up This Mac* (or *Set Up This PC*) instead.
3. **Connect your other devices.** On the server computer choose *Settings › Profiles and Devices ›
   Create Code* (or run `tarven pair` on a Linux server) and type the 8-digit code in the app on
   the new device, or in the browser at the server's address.
4. **Choose your profile and watch.**

The [getting started guide](docs/GETTING_STARTED.md) walks through every step, including how to
name your folders so everything is recognized.

## Watching away from home

Tarven answers only devices in your home network and VPNs; it is never opened to the internet.
To watch on the road, connect your phone, tablet or laptop to home through a VPN such as
Tailscale or your router's WireGuard, and Tarven works as if you were at home.
[Watching away from home](docs/REMOTE_ACCESS.md) explains both ways step by step.

## Guides

| | |
| --- | --- |
| [Getting started](docs/GETTING_STARTED.md) | From an empty drive to the first movie on every device |
| [Organizing your media](docs/MEDIA_LIBRARY.md) | Folder and file names, extras, trailers, TMDB and subtitles |
| [Watching away from home](docs/REMOTE_ACCESS.md) | Tailscale, FRITZ!Box and other WireGuard VPNs |
| [Tarven for Mac](docs/MAC_APP.md) | Installing, hosting, downloads and the offline mode, updates |
| [Tarven for Linux](docs/LINUX_APP.md) | The desktop app: packages, hosting on a PC, updates |
| [Tarven Server on Linux](docs/LINUX_SERVER.md) | Headless server: install, update, power saving, drives |
| [Tarven Server with Docker](docs/DOCKER.md) | Running the server on a NAS |
| [Apple TV](docs/APPLE_TV.md) and [iPhone & iPad](docs/IOS_APP.md) | Building and installing with Xcode |
| [Tarven in a web browser](docs/WEB_APP.md) | Signing in and what plays in a browser |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Common questions and what to do |
| [All documentation](docs/README.md) | Security, backups, audio, the client protocol, building from source |

Asking an AI assistant about Tarven? Point it at [`llms.txt`](llms.txt): it lists every guide
with a one-line summary, so the assistant can open the right page for exact instructions.

## Screenshots

<img src="docs/assets/screenshots/mac-home.jpg" alt="Tarven for Mac: Home with a featured series and Continue Watching">

<img src="docs/assets/screenshots/mac-detail.jpg" alt="A series in Tarven for Mac with its seasons and episodes">

The screenshots use an invented showcase library made by `scripts/make-showcase.swift`.

## How it fits together

```mermaid
flowchart LR
    mac["Mac app"] -- "HTTPS, home network or VPN" --> server
    linux["Linux app"] -- "HTTPS" --> server
    tv["Apple TV"] -- "HTTPS" --> server
    ios["iPhone / iPad"] -- "HTTPS" --> server
    web["Browser"] -- "HTTPS" --> server
    server["Tarven Server<br/>Mac, Linux PC or Docker"] -- "reads only" --> media[("Your media folders")]
    server -. "optional details" .-> tmdb["TMDB / OpenSubtitles"]
```

## Versions

All apps reached **2.0.0** together. From here each app counts its own versions again, because
a change in one app does not need a new version of the others; every
[release page](../../releases) ends with links to the current version of every product (for Mac,
the newest beta; for Apple TV and iPhone & iPad, the build-from-source guide).
For the Server and Linux desktop app, stable releases are the default and test versions appear as
**betas** (*Pre-release* on GitHub) only when *Beta updates* is turned on in Settings › Updates
(or `sudo tarven update --beta on`). The Mac app ships as development-signed betas only, with
*Beta updates* enabled by default. Changes are listed in the [changelog](CHANGELOG.md).

## Contributing and support

Questions, ideas and bug reports are welcome as [issues](../../issues). Before you open a pull
request, read [CONTRIBUTING.md](CONTRIBUTING.md); please report security problems privately as
described in [SECURITY.md](SECURITY.md). Everyone is expected to follow the
[code of conduct](CODE_OF_CONDUCT.md).

The interface is in English. Tarven is developed by one person in their free time; it is not
affiliated with Apple, TMDB, OpenSubtitles, VideoLAN or AVM.

## License

Tarven is [MIT licensed](LICENSE), © 2026 Lucas Kleinsteuber. It includes open-source components
under their own licenses, such as VLCKit and FFmpeg (LGPL); see the
[third-party notices](THIRD_PARTY_NOTICES.md). This product uses the TMDB API but is not endorsed
or certified by TMDB.
