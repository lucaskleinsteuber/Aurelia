# Aurelia Server on Linux

Aurelia Server can run on its own on a Linux computer without a screen, for example an old PC
or a small home server. The Mac app and the Apple TV app then connect to it over the home
network. Media files are only read, never changed.

## Requirements

- A 64-bit Linux system with systemd, such as Ubuntu Server 24.04 or 26.04 LTS or Debian 12
  and newer. Download the `x64` package for Intel and AMD processors and the `arm64` package
  for ARM computers such as a Raspberry Pi 4 or 5 with a 64-bit system.
- ICU (`libicu`), which the installer adds through `apt` when it is missing.
- ffmpeg, which the installer also adds through `apt` when it is missing. Web browsers use it
  to play MKV, AVI and other files the server converts live (see
  [Aurelia in a web browser](WEB_APP.md#watching)). Without it the server works as before and
  browsers play only files they open themselves.
- Optional: a video chip. Converting for browsers and for apps set to a streaming quality is much
  faster on Nvidia (NVENC), Intel (Quick Sync or VA-API) or AMD (VA-API) graphics. The installer
  adds the server's user to the `render` and `video` groups and, with `apt`, the VA-API driver
  for Intel or AMD graphics (`intel-media-va-driver`, `i965-va-driver` for Intel before 2015,
  `mesa-va-drivers`); Nvidia needs its own driver. The server finds the chip by itself;
  **Settings › Server › Video Conversion** shows which one it uses or what is missing.
  `Aurelia:HardwareEncoding=off` in the server's settings turns it off.
- A network cable is recommended for the server.

## Installing and updating

On Ubuntu or Debian, one line installs Aurelia Server and then asks the setup questions,
including whether the computer stays on all the time or saves power:

```sh
curl -fsSL https://raw.githubusercontent.com/lucaskleinsteuber/Aurelia/main/packaging/linux/get-aurelia.sh | sudo bash
```

It picks the newest stable server release for this computer (x64 or arm64), checks the
download against the release's `SHA256SUMS` and its signature (see
[LINUX_UPDATE_SIGNING.md](LINUX_UPDATE_SIGNING.md)) and runs the package's installer described below.
Run again, it updates an existing installation and asks nothing.

To do the same by hand, unpack the download on the server and run its installer:

```sh
tar -xzf Aurelia-Server-<version>-<build>-linux-x64.tar.gz
cd Aurelia-Server-<version>-linux-x64
sudo ./install.sh
```

The installer creates a system user `aurelia`, puts the program in `/opt/aurelia`, keeps the
server's data in `/var/lib/aurelia` and starts the `aurelia` service, which also starts with
the computer and restarts after a failure. If `ufw` is active, it allows the server's port 43111
and Bonjour discovery. Installing a newer package the same way updates only the program; accounts,
library, progress and settings stay.

Server releases use independent `server-<version>-<build>` tags. The Mac app uses
its own version and can ship UI updates without a new server package. Older
combined releases remain available under their original tags.

Installed updaters first look at GitHub's Latest release. While Latest is still the
last combined Mac/server release, they can stop there because it contains a
compatible server package. If a standalone server release ships before the first
Mac-only release, download and verify the new server archive and run its
`install.sh` over the existing installation once. After a Mac-only release becomes
Latest, the updater falls back to the release list to find server packages.

### Updating from GitHub

From version 1.8.5 the server updates itself from the GitHub Releases of the repository it was
built from:

```sh
sudo aurelia update --check   # show the installed and the newest version
sudo aurelia update           # asks, then downloads and installs the newest version
sudo aurelia update --yes     # without asking
sudo aurelia update --beta on # also install test versions (pre-releases); --beta off stops that
```

From version 1.8.7 Aurelia on a Mac shows the installed and the newest version under
Settings › Updates › Server Updates and installs an update with one click. The server looks for a new
version once a day by itself (`aurelia-update-check.timer`); installing always waits for the
owner. A click leaves a request in `/var/lib/aurelia`, where `aurelia-update-request.path` notices
it and runs `aurelia update` as root, which reports back in `/var/lib/aurelia/update-status`.
Restart Server in the app works too: the service ends and systemd starts it again.

It picks the published release with the highest build that has a package for this computer,
checks the download against the release's `SHA256SUMS`, which must carry the owner's minisign
signature (checked with openssl, see [LINUX_UPDATE_SIGNING.md](LINUX_UPDATE_SIGNING.md)), and runs
the package's installer, so accounts, library, progress and settings stay. It never installs an
older version. When power saving has stopped Aurelia, the update starts it again; power saving
then continues as set.

For public repositories, updates download directly without requiring any API token.
If a private fork or mirror is used, a read-only token can be configured. On GitHub, open
Settings › Developer settings › Personal access tokens › Fine-grained tokens, generate a token
for only this repository with the permission Contents: Read-only, and save it on the server:

```sh
sudo aurelia update --set-token   # paste the token; it is not shown
```

The token is kept in `/etc/aurelia/github-token`, which only root can read. When it expires,
`aurelia update` says so; save a new one the same way. An empty entry removes the saved token.

## Setting up over SSH

```sh
sudo aurelia setup --name "Living Room Server"
```

This asks for the owner's name and the Server Password (twice), turns on network access and asks
one question about power use: always on, save power (the computer sleeps after 15 unused minutes
and Wake-on-LAN wakes it), or stop only Aurelia (for a computer that also does other work). Give
the answer up front with `--power always`, `--power save` or `--power stop-only`; change it later
with `sudo aurelia sleep` or in Aurelia on a Mac.
Then connect the devices and compare the verification fingerprint they show with the one from
`aurelia status`:

- **Every device** (Mac, Linux PC, Apple TV, iPhone, iPad, browser): run `aurelia pair` on the
  server and type the code it shows on the device. A code works once and for five minutes.
- **Older Apple TV, iPhone, iPad or browser versions** show a code themselves; approve it with
  `aurelia approve 12345678`.

The first of these asks for the owner's new viewing PIN. Add media folders with:

```sh
aurelia library add --kind automatic --path /mnt/media/Movies
aurelia library scan --all
```

`aurelia help` lists all commands, `aurelia logs` follows the server log.

## Media drives

The `aurelia` service may read everything except other users' private folders and writes only
to its own data folder. A drive with media can be mounted at a fixed place through
`/etc/fstab`, for example an exFAT drive found by its UUID (`sudo blkid`):

```
UUID=1234-ABCD  /mnt/media  exfat  ro,nofail,uid=0,gid=0,fmask=0022,dmask=0022  0  0
```

`nofail` lets the computer start without the drive. While a drive listed in `/etc/fstab` is
unplugged, Aurelia shows its storage location as unavailable and keeps its titles, progress and
favorites; they come back when the drive does. On exFAT, FAT and FUSE drives Linux assigns new
file numbers at every mount, so Aurelia recognizes files there by their path only: a file that is
renamed or moved on such a drive is added again rather than followed.

## Saving power

When nobody uses Aurelia, the server can save power. Choose it in Aurelia on a Mac under
Settings › Server › Power, or over SSH:

```sh
sudo aurelia sleep server --idle 15   # stop only Aurelia Server; the computer stays on
sudo aurelia sleep on --idle 15       # put the whole computer to sleep
sudo aurelia sleep off                # keep running (the default)
sudo aurelia sleep status
```

- **Stop Aurelia Server** suits a computer that also does other work, such as a NAS. Aurelia
  Server stops and systemd listens on its port instead (`aurelia-start.socket`). When a Mac or
  Apple TV connects, Aurelia starts again within seconds; the app's first attempt is dropped and
  it tries again by itself.
- **Put the computer to sleep** suspends it to RAM, using a few watts. Aurelia on a Mac wakes it
  when you open it (Wake-on-LAN). An Apple TV
  cannot send Wake-on-LAN packets: open Aurelia on a Mac first. Someone signed in over SSH keeps
  the computer awake.
- Either happens after `--idle` minutes (15 by default) in which nobody used Aurelia (browsing,
  playing, saving progress or changing settings on any device; an app that is merely open does
  not count), and five
  minutes after a player's sleep timer ends on a Mac or Apple TV if nothing played since on any
  device, at any time of day and even if the app is still open.
- Optional awake hours, for example `--awake 17:00-23:30`, keep it running during those hours; a
  sleeping computer then also wakes itself at their start. `--awake off` removes them.
- The settings are in `/var/lib/aurelia/sleep-settings`; `aurelia-autosleep.timer` checks them
  every five minutes.

Wake-on-LAN is allowed by the installer for the network card that leads to the home network.
Some computers also need it allowed in the BIOS (often "Power On By PCI-E" on, "ErP" off), and a
computer whose BIOS battery is empty forgets that after a power cut.

## Removing

```sh
sudo aurelia uninstall                # keeps the server data in /var/lib/aurelia
sudo aurelia uninstall --remove-data  # asks, then deletes accounts, library and progress
```

Media folders are never touched. Uninstalling also removes the saved GitHub token.

## Building and checking the packages

On a Mac, `scripts/build-linux-server.sh` builds both downloads into the git-ignored
`Local/Build/Linux/<version>-<build>/`; each package records the GitHub repository of `origin` for
`aurelia update`. For every Mac/server version, `scripts/publish-release.sh` publishes these
downloads, the Apple silicon Mac app from `scripts/build-macos-release.sh` as a disk image and
`SHA256SUMS` as the GitHub Release `<version>-<build>` at the pushed `HEAD`; GitHub adds the
source code. `scripts/test-linux-server-install.sh <unpacked package> [--exfat]` installs a package on
a Linux computer without Aurelia data, checks it with synthetic data only, including an update
from a local stand-in for GitHub Releases, and removes everything again. The workflow `.github/workflows/linux-server.yml` runs the
server tests and this check on a Linux runner.
