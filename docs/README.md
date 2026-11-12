# Aurelia documentation

Start with [Getting started](GETTING_STARTED.md) if Aurelia is new to you. Every guide below is
written to be followed step by step; the technical pages at the end are for people who build
Aurelia from source or write their own client.

## Using Aurelia

| Guide | What it answers |
| --- | --- |
| [Getting started](GETTING_STARTED.md) | Which computer keeps the library, setting it up, adding media, connecting every device |
| [Organizing your media](MEDIA_LIBRARY.md) | How to name folders and files, extras and trailers, subtitles, TMDB and OpenSubtitles keys, collections |
| [Watching away from home](REMOTE_ACCESS.md) | Using Aurelia outside the home network with Tailscale or a WireGuard VPN (FRITZ!Box and others) |
| [Troubleshooting](TROUBLESHOOTING.md) | Common problems and questions, from "the app finds no server" to stuttering playback |
| [Privacy policy](PRIVACY.md) | What Aurelia stores, where, and what it never sends anywhere |

## The apps

| Guide | What it answers |
| --- | --- |
| [Aurelia for Mac](MAC_APP.md) | Which download (Apple silicon or Intel), installing, hosting on the Mac, downloads and the offline mode, updates |
| [Aurelia for Linux](LINUX_APP.md) | The desktop app: deb, rpm, Arch and Flatpak packages for x64 and arm64, hosting on a PC, updates |
| [Aurelia for Apple TV](APPLE_TV.md) | Building and installing the tvOS app with Xcode, pairing, using the remote |
| [Aurelia for iPhone and iPad](IOS_APP.md) | Building and installing the iOS app with Xcode, what it does |
| [Aurelia in a web browser](WEB_APP.md) | Signing in at the server's address, what plays in a browser and its limits |

## Running the server

| Guide | What it answers |
| --- | --- |
| [Aurelia Server on Linux](LINUX_SERVER.md) | One-line install on Ubuntu or Debian, the `aurelia` command, updates, power saving, media drives |
| [Aurelia Server with Docker](DOCKER.md) | Running the server on a NAS or any Docker host |
| [Backups and recovery](DATABASE_RECOVERY.md) | The daily database backup and how to restore it |
| [Security model](SECURITY_MODEL.md) | Profiles, roles, PINs, pairing and what administrators can and cannot see |
| [Screen time](SCREEN_TIME.md) | Bedtime, a daily limit and "one more episode" for children's profiles |
| [Audio processing](AUDIO_PROCESSING.md) | Dialogue Boost and Volume Leveling: what they do and their limits |

## Building and contributing

| Guide | What it answers |
| --- | --- |
| [Building and verification](TRANSPORT_TESTING.md) | Building from source and running the checks |
| [Distribution and updates](FREE_DISTRIBUTION.md) | Signing without the paid Apple program, Gatekeeper, how updates keep data |
| [Linux update signing](LINUX_UPDATE_SIGNING.md) | Why Linux updates carry the owner's minisign signature |
| [Client protocol](CLIENT_PROTOCOL.md) and [compatibility](CLIENT_COMPATIBILITY.md) | How the apps talk to the server, capabilities and versions |
| [Linux app parity](LINUX_APP_PARITY.md) | Which Mac features the Linux app has and how each is verified |
| [System callbacks](SYSTEM_CALLBACKS.md) | Threading rules for Apple framework callbacks in the Mac app |
| [Update test](UPDATE_TEST.md) | How the real update path of the Mac and Linux apps was tested |
| [Contributing](../CONTRIBUTING.md) | How to report bugs, suggest features and send changes |

A plain list of every page with a one-line summary, meant for AI assistants and search tools,
is in [`llms.txt`](../llms.txt).
