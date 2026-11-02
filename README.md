<div align="center">

<img src="docs/assets/aurelia-icon.svg" width="128" height="128" alt="Aurelia app icon">

# Aurelia

**Your own movie and TV library, at home.**

A self-hosted media server for Mac or Linux, with native apps for Mac, Linux, Apple TV, iPhone and iPad,
and a player in any web browser.

![macOS 26](https://img.shields.io/badge/macOS-26-1F2328?logo=apple&logoColor=white)
![tvOS 26](https://img.shields.io/badge/tvOS-26-1F2328?logo=apple&logoColor=white)
![iOS 26](https://img.shields.io/badge/iOS%20%7C%20iPadOS-26-1F2328?logo=apple&logoColor=white)
![Linux server](https://img.shields.io/badge/server-Linux%20x64%20%7C%20arm64-1F2328?logo=linux&logoColor=white)
![Linux app](https://img.shields.io/badge/desktop-Linux%20x64-1F2328?logo=linux&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-5B4FE0?logo=swift&logoColor=white)
![.NET 10](https://img.shields.io/badge/.NET-10-5B4FE0?logo=dotnet&logoColor=white)

</div>

<img src="docs/assets/screenshots/mac-home.jpg" alt="Aurelia for Mac: the Home page with a featured series and Continue Watching">

Aurelia turns the movies and series on your own drives into a library that looks and feels like
the Apple TV app: posters and backdrops, seasons and episodes, Continue Watching across devices
and a profile for everyone at home. Your files stay exactly where they are, and nothing leaves
your home network unless you want it to.

## Current versions

<!-- release-versions:start -->
| Product | Version | Build | Download / availability |
| --- | --- | --- | --- |
| **Mac & Server** | 1.26.6 | 123 | [Downloads](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.26.6-123) |
| **Linux Desktop** | 1.0.1 | 7 | [Downloads](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/linux-app-1.0.1-7) |
| **Apple TV** | 1.3.2 | 25 | Development installation; [build from source](https://github.com/lucaskleinsteuber/Aurelia/blob/main/clients/tvos/README.md) |
| **iPhone & iPad** | 1.0.3 | 4 | Development installation; [build from source](https://github.com/lucaskleinsteuber/Aurelia/blob/main/docs/IOS_APP.md) |
<!-- release-versions:end -->

Each app has its own Semantic Versioning counter. Mac and server share one version.
The Mac/server channel remains GitHub’s Latest release; Linux Desktop updates independently.

## At a glance

| | |
| --- | --- |
| **What it is** | A media server plus apps, like a private streaming service for your own files |
| **Server** | Inside the Mac app, or on its own on a Linux PC (x64 or arm64) |
| **Watch on** | Mac, Linux, Apple TV, iPhone, iPad and any browser on your home network |
| **Plays** | The original files, with all their audio and subtitle tracks; browsers get MKV and other formats converted live |
| **Profiles** | One per person, with their own progress, favorites, Watchlist and history; PIN protection |
| **Your data** | Stays on your hardware. No account, no cloud, no tracking. Online details are optional |
| **Cost** | Free. Releases are published here on GitHub |
| **Status** | In active development; the interface is in English |

## Screenshots

| Mac | Apple TV |
| --- | --- |
| <img src="docs/assets/screenshots/mac-detail.jpg" alt="A series in Aurelia for Mac with its seasons and episodes"> | <img src="docs/assets/screenshots/tv-home.jpg" alt="The Home page of Aurelia for Apple TV"> |
| <img src="docs/assets/screenshots/mac-movies.jpg" alt="The Movies page in Aurelia for Mac with filters and sorting"> | <img src="docs/assets/screenshots/tv-detail.jpg" alt="A movie in Aurelia for Apple TV"> |

| iPhone | | iPad |
| --- | --- | --- |
| <img src="docs/assets/screenshots/iphone-home.jpg" width="260" alt="Aurelia for iPhone: Home with a featured series and Continue Watching"> | <img src="docs/assets/screenshots/iphone-detail.jpg" width="260" alt="Aurelia for iPhone: a series with its episodes"> | <img src="docs/assets/screenshots/ipad-home.jpg" width="420" alt="Aurelia for iPad: Home with Continue Watching, Favorites and Collections"> |

| Browser | |
| --- | --- |
| <img src="docs/assets/screenshots/web-home.jpg" alt="Aurelia in a browser: Home and Continue Watching"> | <img src="docs/assets/screenshots/web-detail.jpg" alt="Aurelia in a browser: a series and its episodes"> |
| <img src="docs/assets/screenshots/web-player.jpg" alt="Aurelia browser player controls, shown paused over generated artwork"> | <img src="docs/assets/screenshots/web-settings.jpg" alt="Aurelia browser playback settings"> |

<sub>All titles, pictures and names are invented and drawn by `scripts/make-showcase.swift`;
`zsh scripts/capture-showcase.sh` makes the screenshots.</sub>

## Highlights

**A library that organizes itself.** Movies, series, seasons, episodes, extras and trailers
are recognized from your folders. An import preview shows what was found before anything is
added. Titles, descriptions, cast, covers and backgrounds can be edited, and your corrections
survive later scans. Details and artwork from TMDB are optional and use your own token.

**Made for watching.** Fullscreen playback of the original files with remembered audio and
subtitle choices per profile and series, subtitle files next to the video, timeline previews,
a sleep timer, Dialogue Boost, Volume Leveling and Up Next for series. *Play On* sends a title to
another screen at home.

**Everyone has their own profile.** Progress, favorites, Watchlist, collections, scene notes and
viewing history are separate per person. Profiles can be limited to chosen libraries or titles
and protected with a PIN; owner and administrator profiles always are.

**Collections and statistics.** Your own collections, smart lists that fill themselves by
genre, year, rating or watched state, film franchises together, and your watch time, streaks
and a year in review, private to your profile.

**A server that gets out of the way.** On Linux it can sleep when nobody watches and wakes by
Wake-on-LAN when you open Aurelia. Server Health and Library Health show free space, warnings,
duplicates and missing titles. The database is backed up and checked every day, and updates
install from the app.

## Apps

| | Runs on | What it does |
| --- | --- | --- |
| **Aurelia for Mac** | macOS 26 or later, Apple silicon (Intel Macs: up to 1.25.1) | Watch, manage the library, host the server or connect to one |
| **Aurelia for Linux** | Linux x64, Wayland or X11 | Watch, manage the library, host the server or connect to one; deb, rpm, Arch and Flatpak downloads |
| **Aurelia for Apple TV** | tvOS 26 or later | Watch on the big screen; pairs with your server by code |
| **Aurelia for iPhone & iPad** (preview) | iOS and iPadOS 26 or later | Touch-first app with activity, PIN and playback settings; installed from source, see [iPhone and iPad](docs/IOS_APP.md) |
| **Aurelia Server for Linux** | x64 and arm64 with systemd, e.g. Ubuntu | Runs the library on its own, sleeps when unused, updates from GitHub |
| **Aurelia in a browser** | Safari, Chrome, Edge or Firefox at home | Browse and watch without installing anything |

```mermaid
flowchart LR
    mac["Mac"] -- "home network, HTTPS" --> server
    linux["Linux app"] -- "home network, HTTPS" --> server
    tv["Apple TV"] -- "home network, HTTPS" --> server
    ios["iPhone / iPad"] -- "home network, HTTPS" --> server
    web["Browser"] -- "home network, HTTPS" --> server
    server["Aurelia Server<br/>on a Mac or a Linux PC"] -- "reads only" --> media[("Your media folders")]
    server -. "optional details" .-> tmdb["TMDB"]
```

## Getting started

1. **Set up the server.** Open Aurelia on a Mac or Linux PC and choose whether this computer hosts your library or
   connects to an existing server. On a new host, create the owner profile, add your media
   folders and confirm the import preview. For a Linux server without a desktop, follow
   [Aurelia Server on Linux](docs/LINUX_SERVER.md): unpack the download and run its installer.
2. **Connect your devices.** Apple TV, iPhone, iPad and browsers find the server on your network
   and show an 8-digit code. Approve it on the Mac with *Enter Code from Apple TV or Browser…*.
   Another Mac or Linux PC connects with a pairing code from the host's device settings.
3. **Choose your profile and watch.**

Mac/server [releases](../../releases) carry a disk image of the Mac app and the Linux server packages.
The Linux desktop app has its own releases, named **Aurelia for Linux**, with deb, rpm, Arch and
Flatpak packages; see [installing Aurelia for Linux](docs/LINUX_APP.md#installation).
The Mac app updates itself with *Aurelia › Check for Updates…* and keeps your library and
settings; see [Updating the Mac app](docs/FREE_DISTRIBUTION.md#updating-the-mac-app). It is
currently signed for development, so it runs on Macs registered for the developer account; a
download for everyone is planned through GitHub, not the App Store.

## Watching in a browser

While the server is on, open its address in a browser at home, for example
`https://192.168.1.50:43111`. The Mac app shows it with Copy and Open buttons under
*Settings › Server › Devices › Web Browser*. Continue past the certificate warning the first time
(the server signs its own certificate), approve the code on the Mac, choose your profile and
watch. Files the browser can't open itself, such as MKV, play converted live; nothing converted
is ever stored. More in [Aurelia in a web browser](docs/WEB_APP.md).

## Privacy and safety

- **Video files are only ever read.** Aurelia never modifies, moves or copies them and never
  stores converted video. Removing a title from the library never deletes its file.
- **Offline media keeps its place.** A missing drive keeps details, favorites and progress until
  you remove the title.
- **Encrypted at home too.** Apps talk to the server over HTTPS and remember its fingerprint, so
  another computer can't pose as your server. Devices join only with a code you approve.
- **Profiles stay private.** History, statistics and personal collections belong to one profile;
  administrators can't read them. See the [security model](docs/SECURITY_MODEL.md).
- **No cloud.** The server runs on your hardware and sends nothing out, except optional TMDB
  lookups and update checks on GitHub.

## Documentation

| Guide | Covers |
| --- | --- |
| [Aurelia Server on Linux](docs/LINUX_SERVER.md) | Installing, updating, power saving and media drives |
| [Aurelia for Linux](docs/LINUX_APP.md) | Installing the desktop app, hosting on a PC, updates and verification |
| [iPhone and iPad](docs/IOS_APP.md) | What the preview does and how to install it on your own device |
| [Aurelia in a web browser](docs/WEB_APP.md) | Signing in, what plays in a browser, and its limits |
| [Security model](docs/SECURITY_MODEL.md) | Profiles, roles, pairing and what administrators can do |
| [Backups and recovery](docs/DATABASE_RECOVERY.md) | Keeping the library database safe |
| [Audio processing](docs/AUDIO_PROCESSING.md) | Dialogue Boost, Volume Leveling and their limits |
| [Distribution and updates](docs/FREE_DISTRIBUTION.md) | Signing, Gatekeeper and keeping local builds running |
| [Client protocol](docs/CLIENT_PROTOCOL.md) and [compatibility](docs/CLIENT_COMPATIBILITY.md) | How the apps talk to the server |
| [Build and verification](docs/TRANSPORT_TESTING.md) | Building from source and running the checks |
| [Changelog](CHANGELOG.md) | Changes by product and version |
| [MIT license](LICENSE) | Copyright (c) 2026 Lucas Kleinsteuber |
| [Third-party notices](THIRD_PARTY_NOTICES.md) | Licenses of included components |
