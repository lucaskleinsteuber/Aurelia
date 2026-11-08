# Aurelia for Mac

The Mac app watches, manages the library and, if you like, hosts the server on the Mac itself.
It needs macOS 26 or later.

## Which download?

Each release has one disk image per processor. Open the Apple menu › **About This Mac**:

| It says | Download |
| --- | --- |
| *Chip: Apple M1, M2, M3, M4 …* | `Aurelia-<version>-macOS-arm64.dmg` (Apple silicon) |
| *Processor: … Intel …* | `Aurelia-<version>-macOS-x64.dmg` (Intel) |

Each image carries only the server for its processor, so it is about half the size of one image
for both. The release also lists `…-macOS-universal.dmg`; that is the Apple silicon image under the
name that version 1.34 of the app asks for when it updates itself, not a separate build.

> [!IMPORTANT]
> Aurelia is free and does not use Apple's paid developer program. The published Mac download is
> development-signed and starts only on Macs registered to the developer's account. On any other
> Mac, build it from source as described below. [Distribution and updates](FREE_DISTRIBUTION.md)
> explains the background.

## Installing

1. Open the disk image and drag **Aurelia** onto **Applications**.
2. Open Aurelia from Applications.
3. Choose **Set Up This Mac** to keep the library on this Mac, or **Connect to an Existing Server**
   to watch from a server elsewhere at home. [Getting started](GETTING_STARTED.md) walks through
   both.

## Building it yourself

You need a Mac with Xcode 26 and a free Apple ID signed in under Xcode › Settings › Accounts.

```sh
git clone https://github.com/lucaskleinsteuber/Aurelia.git
cd Aurelia
AURELIA_MAC_ARCH=arm64 zsh scripts/build-macos-release.sh   # or x64 for an Intel Mac
```

The script restores the pinned .NET SDK and dependencies, builds the server for the chosen
processor, the app and its LGPL ffmpeg, signs everything with your development identity and puts
`Aurelia.app` in `Local/Build/Build <number>/` (`Build <number> x64/` for Intel). Copy it to
Applications. [Building and verification](TRANSPORT_TESTING.md) lists every check.

## Hosting on the Mac

With **Set Up This Mac** the server runs in a separate helper, *Aurelia Server Host*, so the
Apple TV and other devices can keep watching while the Aurelia window is closed. *Quit When the
Window Closes* (Settings › General) decides only whether the app itself quits. *Let the Server Rest
When Unused* stops the server after a while without anyone watching; opening any Aurelia app starts
it again.

*Settings › Server* holds network access (*Allow HTTPS access from LAN / private VPN*), Bonjour,
devices and backups, scrub previews, Server Health and the server's own updates.

## Settings at a glance

| Section | What it holds |
| --- | --- |
| General | Start screen, poster size, watched titles in rows, Reduce Motion, window and rest behavior |
| Sidebar | Which pages appear in the sidebar and in which order |
| Activity | Your watch history and statistics |
| Playback | Audio and subtitles, Automatic Resume, Dialogue Boost, Volume Leveling |
| Library | Storage folders, scans, Library Health, import previews |
| Metadata | TMDB token, Review Matches, OpenSubtitles key (subtitles from speech are in Edit Metadata) |
| Profiles and Devices | Profiles, PINs, age limits, devices, **Create Code** for a new device, the browser address |
| Server | Network, power, backups, scrub previews, Server Health (only on the host) |
| Updates | App and server updates, Beta updates |
| About | Version, what changed, source code, license texts, privacy policy |

## Downloads and the offline mode

On a movie or episode, choose **Download** to keep a copy on this Mac. It is the original file,
streamed through the usual secure connection and kept in the app's own data folder; its size is
shown and **Remove Download** deletes it. Downloads belong to the profile that made them.

When the server is out of reach, for example on a train, Aurelia offers **Watch Downloads Offline**.
It shows your downloads with Continue Watching, movies and series. Your profile opens with its PIN,
and the progress you make is sent to the server the next time it answers.

## Subtitles from speech

For a title without fitting subtitles, the Mac can write them itself from what is said.

1. Open the movie or episode, choose **Edit Metadata** and scroll to **Subtitles**.
2. Choose **Create Subtitles from Speech…**, pick the sound track and the language spoken in it
   (Aurelia suggests both), then **Create Subtitles**.
3. The Mac listens to the track and shows how far it got. A two-hour film usually takes a few
   minutes, mostly for reading the sound from the server. You can close the editor meanwhile.
4. The finished subtitles are saved on the server as "German · From Speech" (or the language you
   chose) and appear in the subtitle menu on every device. Doing it again replaces them;
   **Remove** deletes them.

The recognition is macOS's own speech recognition and runs on this Mac only: the sound goes from
your server to your Mac and nowhere else, and is never stored. The first time for a language,
macOS loads its speech model from Apple once. It needs macOS 26 on a Mac that supports it, a
server 2.1.0 or newer, and an administrator profile. Clear dialogue works best; songs, heavy
accents and people talking over each other come out less well.

## Updates

The app checks the GitHub releases once a day (*Settings › Updates*). It downloads the disk image
for its own processor, checks it against the release's checksums and Apple's code signature,
replaces only the app and starts it again; the library, profiles and settings stay. Turn on
**Beta updates** to receive test versions before they become stable.

## Removing Aurelia

Quit Aurelia and move it from Applications to the Trash. Your media is never touched. The library
database and settings stay in the app's container in your Library folder, so a reinstall picks up
where you left off.
