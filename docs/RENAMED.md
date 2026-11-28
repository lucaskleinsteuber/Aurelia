# Tarven used to be Aurelia

Tarven was called Aurelia until Server 3.0.0, Mac 2.30.0, Linux 2.16.0, Apple TV 2.13.0 and
iPhone & iPad 2.23.0. The name changed because many other products are called Aurelia; Tarven
now has its own website at [tarven.org](https://tarven.org). Your library, profiles, progress and
favorites stay as they are. This page says what happens on each device.

## Server on Linux

`sudo aurelia update` (or Settings › Server Updates in an app) installs Tarven Server like any
update. The installer takes the Aurelia installation over in place:

- the service user `aurelia` becomes `tarven` and keeps its number, so file permissions stay right;
- `/var/lib/aurelia` becomes `/var/lib/tarven`, `/etc/aurelia` becomes `/etc/tarven` and the
  database `aurelia.db` becomes `tarven.db`; nothing is copied;
- the services are now `tarven.service`, `tarven-autosleep.timer` and so on, with the same power
  saving, update channel and settings;
- the command is `tarven`; `aurelia` keeps working as another name for it.

The one-line installer also still works under its old address and does the same.

## Server in Docker

The image is now `tarven-server:local` and the command inside it `tarven` (`aurelia` keeps
working). **Keep the volume name of your compose file**: if it says `aurelia-data`, leave it, or
the server starts empty. A new `compose.yaml` from this repository names the volume `tarven-data`;
when you replace your file with it, change that name back to `aurelia-data` in both places.
Settings named `AURELIA_OWNER`, `AURELIA_SERVER_NAME` and `AURELIA_DEVICE_NAME` still apply.

## Mac

Tarven is a new app to macOS, so Aurelia's updater can't install it in Aurelia's place. Aurelia
2.30.0 says so in Check for Updates once Tarven is out.

1. Download Tarven from the [releases](https://github.com/lucaskleinsteuber/Tarven/releases)
   (`Tarven-<version>-<build>-macOS-arm64.dmg` for Apple silicon, `-x64` for Intel).
2. Quit Aurelia, drag Tarven to Applications and open it.
3. Tarven takes over the server connection and offline profiles, your settings and, if this Mac
   hosts the server, its folder (`Aurelia Server` becomes `Tarven Server`).
4. Move Aurelia to the Trash. Face ID or Touch ID for server changes is set up again once.

## Linux app

Updates offer Tarven like any update (from Aurelia 2.16.0 on). The `tarven-desktop` package
replaces `aurelia-desktop`; settings, the server connection and a server hosted on this PC come
along. The Flatpak `org.tarven.Tarven` copies the Aurelia Flatpak's settings and then removes it.

## iPhone, iPad and Apple TV

Install Tarven, connect it once to your server with a code, as with a new device, and delete
Aurelia. Offline downloads on an iPhone or iPad are downloaded again.

## Browser

Nothing to do: the browser keeps its sign-in and settings.

## For older apps

A Tarven server still answers apps called Aurelia: it reads their requests, cookies and
settings under the old names and is also found under the old network name. Backups and moving
files from Aurelia (`.aureliabackup`, `.aureliamove`) can be restored.
