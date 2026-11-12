# Aurelia for Apple TV

The Apple TV app is made for the big screen and the Siri Remote: Home with Continue Watching,
Movies, TV Shows, Search, title pages with seasons, cast, trailers and extras, and fullscreen
playback of the original files with every audio and subtitle track. It needs tvOS 26 and an
Aurelia server at home.

The app is not in the App Store. You build it once on a Mac with Xcode and install it on your
Apple TV; this guide shows how. Developers find the project details in
[`clients/tvos/README.md`](../clients/tvos/README.md).

## What you need

- An Apple TV with tvOS 26 on the same network as the Mac.
- A Mac with Xcode 26 and an Apple ID signed in under Xcode › Settings › Accounts. A free Apple ID
  works; its apps must be signed again every seven days (see [Keeping it running](#keeping-it-running)).
- This repository: `git clone https://github.com/lucaskleinsteuber/Aurelia.git`.

## 1. Pair the Apple TV with Xcode (once)

1. On the Apple TV open **Settings › Remotes and Devices › Remote App and Devices**.
2. On the Mac open Xcode › **Window › Devices and Simulators**. The Apple TV appears; choose
   **Pair** and type the code the TV shows.
3. In Terminal, `xcrun devicectl list devices` now lists the Apple TV with its identifier.

## 2. Build and install

From the repository folder:

```sh
zsh scripts/prepare-tvvlckit.sh
zsh scripts/build-tvos.sh --allow-provisioning-updates --device <identifier>
xcrun devicectl device install app --device <identifier> \
  "Local/Build/tvOS/<version>-<build>/DerivedData/Build/Products/Release-appletvos/Aurelia.app"
```

The first command downloads the VideoLAN player framework and checks it against a pinned SHA-256.
The second builds and signs the app for your Apple TV (Xcode may ask to register the device). The
third installs it. Reinstalling later replaces only the app; its server connection and settings stay.

## 3. Connect to your server

1. Open **Aurelia** on the Apple TV. It lists the servers it finds at home; choose yours, or type
   its address.
2. Check that the **fingerprint** matches the one on the server computer.
3. On the server's Mac or Linux app choose **Settings › Profiles and Devices › Create Code**
   (on a Linux server: `aurelia pair`) and type the 8-digit code on the Apple TV.
4. Choose your profile and enter its PIN.

Settings › Playback › **Streaming Quality** (shown when the server offers adaptive streaming)
plays the server's live conversion in the quality the connection carries instead of the original
file, for a slow network. Original stays the default.

## Using the remote

| Press | Does |
| --- | --- |
| Select (click) | Open a title, play, show the player controls |
| Play/Pause | Play or pause, also while the controls are hidden |
| Left / right while playing | Jump back or forward by the skip interval; the picture stays clear |
| Swipe or hold on the timeline | Move through the title with preview pictures; Select jumps there |
| Up / down in the player | Move between the track controls, the play controls and the timeline |
| Back (‹ or Menu) | Close a menu, leave the player, go back a page |
| Press and hold on a title | Favorite, Watchlist, mark watched, Start Over |

The player remembers audio and subtitle choices for each series and offers Up Next, a sleep
timer, Dialogue Boost and Volume Leveling. While an episode's intro plays, **Skip Intro** takes
the focus: Select skips, Back lets the intro play. When the credits begin, Up Next counts down
with **Watch Credits**. Settings › Playback › Intros and Offer Next Episode When Credits Begin
choose how.

The profile page opens **Watch History** (grouped by day; press and hold a title to remove it, or
clear it all) and **Statistics and Wrapped**: watch time, streaks, the last weeks as a chart, top
titles and genres, a year in review and Wrapped as full-screen slides (right and left move,
Play/Pause holds, Back leaves).

**Cinema Mode** (Settings › Playback) plays one of Aurelia's made-up ads, trailers of films
nobody has watched yet and the curtain before a film that starts from its beginning, as on the
Mac. Skip and Start Film take the focus; Back leaves the player.

**Movie Night** on Home turns the Apple TV into the screen everyone looks at: it shows who
joined from their phones, how far each has swiped, and the match as a ticket with Play already
selected, so one click starts it. The remote can swipe too (**Swipe with the Remote**). Back
leaves the night.

## When the server is off

The Apple TV shows *The Server Is Off* and sends a Wake-on-LAN packet to the server's last
address. tvOS does not allow the broadcast that wakes every sleeping computer, so if the server
stays asleep, open Aurelia on a Mac, Linux PC or iPhone, which wakes it. As soon as the server
answers, the Apple TV connects by itself.

## Keeping it running

A free Apple ID signs apps for seven days; after that the app no longer opens until it is signed
again. Either build and install again every week, or let the Mac do it: run
`zsh scripts/refresh-signing.sh --install` once and, after each install,
`zsh scripts/refresh-signing.sh --adopt-tv`. A small daily job then re-signs and reinstalls the
same version before it expires, as long as the Mac and the Apple TV are on the same network.
With a paid Apple Developer account the signature lasts a year.
