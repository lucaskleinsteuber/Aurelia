# Troubleshooting

Short answers to the questions that come up most. If none fits, open an
[issue](https://github.com/lucaskleinsteuber/Aurelia/issues) with the app, its version
(*Settings › About*) and what you did; leave out passwords, codes and personal paths.

## Connecting

**The app finds no server.**
- The server computer must be on, Aurelia must run there, and both devices must be in the same
  home network (not a guest Wi-Fi, which keeps devices apart).
- On the server, *Settings › Server › Allow HTTPS access from LAN / private VPN* must be on.
- Bonjour may be blocked by the router; type the server's address instead, for example
  `192.168.1.50`. The Mac and Linux apps show it under *Settings › Profiles and Devices*; on a
  Linux server, `aurelia status` prints it.
- On a Linux server with a firewall other than `ufw`, allow TCP port **43111** and UDP port
  **5353** (Bonjour). The installer opens them only in an active `ufw`.

**"Server identity has changed".** The app pins the server's certificate. This appears when
the server was reinstalled with new data, or when another computer answers at that address. If you
reinstalled the server yourself, remove the server in the app and connect again; otherwise do not
continue and check which computer has that address.

**The pairing code is not accepted.** A code works once and for five minutes. Create a new one on
the server computer (*Create Code*, or `aurelia pair`) and type it on the device right away.

**The browser warns about the certificate.** The server signs its own certificate, so browsers do
not know it. Compare the fingerprint the browser shows with the one in the app, then continue.
[Aurelia in a web browser](WEB_APP.md) explains it per browser.

## The server

**It went to sleep and does not wake up.** Wake-on-LAN must be allowed in the computer's firmware
(BIOS/UEFI) and works only over a network cable on most computers. The Mac and Linux apps wake
it when they open; iOS and tvOS may block the broadcast that wakes it, so open Aurelia on a Mac or
Linux PC first. Away from home, wake it
through your router (for example the MyFRITZ!App) or keep it awake during set hours with
`sudo aurelia sleep server --awake 17:00-23:30`. See
[power saving](LINUX_SERVER.md#saving-power).

**A drive is missing.** Titles on a disconnected drive stay with their details and progress and
show as offline until it is back. On Linux, mount media drives permanently (for example through
`/etc/fstab`) so they are there after a restart; [Aurelia Server on Linux](LINUX_SERVER.md)
shows how.

**Titles are not recognized or matched wrongly.** Check the names against
[Organizing your media](MEDIA_LIBRARY.md), then scan again. Wrong matches can be fixed under
*Review Matches* or with *Find Metadata Match…* on the title; your choice is kept.

**Posters and details are missing.** TMDB must be turned on with your own token under
*Settings › Metadata*. The artwork store has a limit of 1 GB; Server Health shows how much is used.

**Updating the server.** On Linux run `sudo aurelia update`, or use *Settings › Updates › Server
Updates* in the Mac or Linux app. Accounts, library and settings stay.

## Playback

**It stutters or keeps loading.** The apps play the original file, so the network must carry its
full bit rate. Large 4K files need a fast connection: prefer a network cable for the server and,
on Wi-Fi, a 5 GHz network. Away from home the upload speed of your internet line is the limit; see
[Watching away from home](REMOTE_ACCESS.md#good-to-know).

**No sound, or the wrong language.** Choose the track in the player's audio menu. Aurelia
remembers it for the series and the profile. Default languages are set under *Settings › Playback*.

**Subtitles are missing.** Name subtitle files after the video (`Movie.en.srt`), see
[Organizing your media](MEDIA_LIBRARY.md#subtitle-files), or search them on OpenSubtitles from the
player once a key is set under *Settings › Metadata*.

**A browser does not play a file.** Browsers play only some formats themselves; the server
converts the rest live, which needs `ffmpeg` on a Linux server (`sudo apt install ffmpeg`). The
Mac app brings its own.

## Apple devices

**The Apple TV, iPhone or iPad app stopped opening after a week.** Apps installed with a free
Apple ID are signed for seven days. Install them again, or let the Mac re-sign them every day with
`scripts/refresh-signing.sh`, see [Apple TV](APPLE_TV.md#keeping-it-running).

**The Mac app does not open on another Mac.** The published Mac download only runs on Macs
registered to the developer's account. Build it yourself with a free Apple ID, see
[Aurelia for Mac](MAC_APP.md#building-it-yourself).

## Profiles

**I forgot my PIN.** An owner or administrator can set a new PIN for an ordinary profile under
*Settings › Profiles and Devices*. The owner chooses **Forgot PIN?** in the profile picker on the
server's Mac and sets a new PIN with the Server Password.

**Someone can see too much.** Give them an ordinary profile with an age limit or chosen libraries.
Administrators manage the server but cannot read another profile's history, statistics or private
collections; see the [security model](SECURITY_MODEL.md).
