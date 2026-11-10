# Aurelia Server with Docker

For a NAS or a computer that already runs Docker. On a plain Ubuntu or Debian PC, the
[one-line install](LINUX_SERVER.md#installing-and-updating) is simpler and adds power saving and
updates from the app.

The image is built on your own computer from the newest stable server release on GitHub; the
download is checked against the release's `SHA256SUMS` and its minisign signature. ffmpeg, which lets browsers play MKV and
other files, comes from Debian. Intel/AMD (amd64) and ARM (arm64) are supported.

## Start

Save [`compose.yaml`](../packaging/docker/compose.yaml) in a new folder and change the media
folder in it (the left side of `/srv/media:/media:ro`) to where your movies and shows are. Then:

```sh
docker compose run --rm aurelia setup   # owner name and Server Password, once
docker compose up -d
```

`setup` asks for the owner's name and the Server Password (twice) and turns on network access.
`AURELIA_SERVER_NAME` in the environment names the server.

## Connect devices and add media

Each command asks for the owner's name and Server Password; the first one also sets the owner's
viewing PIN.

```sh
docker compose exec aurelia aurelia pair                 # a code to type on a new device (any app or browser)
docker compose exec aurelia aurelia library add --kind automatic --path /media
docker compose exec aurelia aurelia library scan --all
```

Inside the container your media folder is `/media`, mounted read-only: Aurelia only reads it.

## Updating

```sh
docker compose build --pull --no-cache && docker compose up -d
```

builds the image again from the newest stable release. Accounts, library, progress and settings
stay in the `aurelia-data` volume. `--build-arg AURELIA_BUILD=135` builds a particular release.

## Good to know

- **Network.** `network_mode: host` lets Macs, Apple TVs and phones find the server by themselves.
  Without it, publish port `43111` and enter the server's address in the apps.
- **No power saving or app updates.** The container keeps running; the server's sleep and update
  settings in the Mac app are for the Linux package. Stop the container to save power.
- **Not as root.** The container starts as root only to hand the data folder to the user
  `aurelia`; the server itself always runs as `aurelia`.
- **Video chip.** Converting for browsers and for apps set to a streaming quality is much faster on
  a video chip. For Intel or AMD graphics, uncomment `devices` and `group_add` in `compose.yaml`
  and put in the number `getent group render | cut -d: -f3` prints; the image already has the
  VA-API drivers. For an Nvidia card, install the NVIDIA Container Toolkit and add
  `gpus: all` to the service. **Settings → Server → Video Conversion** in the browser app shows
  which encoder the server uses and, if a chip isn't usable, what is missing.
- **Away from home**, see [Watching away from home](REMOTE_ACCESS.md).
