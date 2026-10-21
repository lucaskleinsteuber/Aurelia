# Aurelia Server on Linux

Aurelia Server can run on its own on a Linux computer without a screen, for example an old PC
or a small home server. The Mac app and the Apple TV app then connect to it over the home
network. Media files are only read, never changed.

## Requirements

- A 64-bit Linux system with systemd, such as Ubuntu Server 24.04 or 26.04 LTS or Debian 12
  and newer. Download the `x64` package for Intel and AMD processors and the `arm64` package
  for ARM computers such as a Raspberry Pi 4 or 5 with a 64-bit system.
- ICU (`libicu`), which the installer adds through `apt` when it is missing.
- A network cable is recommended for the server.

## Installing and updating

Unpack the download on the server and run its installer:

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

## Setting up over SSH

```sh
sudo aurelia setup --name "Living Room Server"
```

This asks for the owner's name and the Server Password (twice) and turns on network access.
Then connect the devices and compare the verification fingerprint they show with the one from
`aurelia status`:

- **Apple TV:** choose the server; it shows a code. Approve it on the server with
  `aurelia approve 12345678`.
- **Mac:** run `aurelia pair` on the server and enter the code it shows in Aurelia on the Mac.

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

## Removing

```sh
sudo aurelia uninstall                # keeps the server data in /var/lib/aurelia
sudo aurelia uninstall --remove-data  # asks, then deletes accounts, library and progress
```

Media folders are never touched.

## Building and checking the packages

On a Mac, `scripts/build-linux-server.sh` builds both downloads into the external workspace's
`Build/Linux/<version>-<build>/`. `scripts/test-linux-server-install.sh <unpacked package>
[--exfat]` installs a package on a Linux computer without Aurelia data, checks it with synthetic
data only and removes everything again. The workflow `.github/workflows/linux-server.yml` runs the
server tests and this check on a Linux runner.
