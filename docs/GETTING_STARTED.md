# Getting started

This guide takes you from a drive full of movies and series to watching them on every device at
home. It takes about fifteen minutes, plus the time the first scan needs.

## 1. Choose the computer that keeps the library

Aurelia has one **server** that keeps the library, and **apps** that watch. The server must be on
whenever someone watches, and your media drives must be connected to it.

| You have | Run the server | Guide |
| --- | --- | --- |
| A Mac that is usually on | Inside the Mac app | [Aurelia for Mac](MAC_APP.md) |
| A Linux desktop or laptop | Inside the Linux app | [Aurelia for Linux](LINUX_APP.md) |
| A spare PC, mini PC or a 64-bit ARM board without a screen | The standalone Linux server | [Aurelia Server on Linux](LINUX_SERVER.md) |
| A NAS with Docker (Synology, QNAP, Unraid, TrueNAS…) | The Docker server | [Aurelia Server with Docker](DOCKER.md) |

A computer that is always on is the most convenient. The Linux server can also sleep when nobody
watches and wake when you open an app (Wake-on-LAN), so an older PC uses little power.

You need **one** server. Every other device only connects to it.

## 2. Set up the server

### On a Mac or Linux PC with a screen

1. Download and install the app for your system and processor from the
   [releases page](https://github.com/lucaskleinsteuber/Aurelia/releases) (see the
   [download table](../README.md#downloads)).
2. Open Aurelia and choose **Set Up This Mac** (on Linux: **Set Up This PC**).
3. Create the **owner profile**: a name, a password for managing the server and a viewing PIN.
4. Add your **media folders**. You can add several, for example one for movies and one for series.
   Aurelia only reads them; it never renames, moves or changes a file.
5. Check the **import preview**: it lists what Aurelia recognized (movies, series, seasons,
   episodes, extras and trailers) before anything is added. Fix an assignment if needed, then
   confirm. [Organizing your media](MEDIA_LIBRARY.md) shows the names Aurelia understands best.

### On a Linux computer without a screen

Run this on Ubuntu or Debian (x64 or arm64) and answer its questions:

```sh
curl -fsSL https://raw.githubusercontent.com/lucaskleinsteuber/Aurelia/main/packaging/linux/get-aurelia.sh | sudo bash
```

It installs the server as a service, creates the owner profile and asks how much power it may
save. Add your media with `aurelia library add --path /media/movies`, or later from any Mac or Linux
app. All commands are in [Aurelia Server on Linux](LINUX_SERVER.md).

## 3. Get posters, details and subtitles (optional, free)

Aurelia works without them, but they make the library look like a streaming service.

- **TMDB** (posters, descriptions, cast, collections): create a free account at
  [themoviedb.org](https://www.themoviedb.org/signup), open *Settings › API* on the website, request
  an API key for personal use and copy the **API Read Access Token** (the long one). In Aurelia open
  *Settings › Metadata*, paste it into *TMDB API Read Access Token* and choose **Enable TMDB**.
  Only titles, years and episode numbers are sent, never file paths.
- **OpenSubtitles** (subtitles by search or automatically): create a free account at
  [opensubtitles.com](https://www.opensubtitles.com), add an *API consumer* in your profile there,
  and paste its key under *Settings › Metadata › OpenSubtitles*.

## 4. Connect your other devices

Every device joins the same way, with an 8-digit code that the server computer creates:

1. On the server's Mac or Linux app: **Settings › Profiles and Devices › Create Code**.
   On a Linux server without a screen: run `aurelia pair`.
2. On the new device, open Aurelia (or the server's address in a browser) and pick your server.
   Aurelia finds it by itself on the home network; otherwise type its address.
3. Check that the **fingerprint** shown matches the one on the server computer, then type the code.

| Device | Get the app |
| --- | --- |
| Another Mac or Linux PC | Install the app and choose **Connect to an Existing Server** |
| Apple TV | Build it with Xcode, see [Apple TV](APPLE_TV.md) |
| iPhone or iPad | Build it with Xcode, see [iPhone and iPad](IOS_APP.md) |
| Any browser | Open `https://<server address>:43111`, see [web browser](WEB_APP.md) |

The code works once and only for a short time. A device stays connected until you remove it under
*Settings › Profiles and Devices*.

## 5. Add the people at home

In *Settings › Profiles and Devices*, add a profile for everyone. Each has its own progress,
favorites, Watchlist, collections and history, and can have a PIN, an age limit (FSK) and access
to chosen libraries only. The [security model](SECURITY_MODEL.md) explains the roles.

## 6. Watch

Choose your profile and press play. Continue Watching follows you from the TV to the phone, and
the Mac and Linux apps can download a title to watch on the go. To watch while you are away from
home, set up a VPN as described in [Watching away from home](REMOTE_ACCESS.md).

Something not working? See [Troubleshooting](TROUBLESHOOTING.md).
