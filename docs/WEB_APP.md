# Aurelia in a web browser

Every Aurelia Server (in the Mac app or on Linux) also serves Aurelia for web browsers. It is
meant for devices without an Aurelia app: another computer, a phone or a tablet at home.
The Mac and Apple TV apps stay the full experience.

## Opening it

The address is the server's own HTTPS address, for example `https://192.168.1.50:43111`.
The Mac app shows it with Copy and Open buttons under *Settings › Server › Devices ›
Web Browser*.

- **The first visit shows a warning** such as "This connection is not private". The server
  signs its own certificate, so browsers don't know it yet. Continue to the page once in
  each browser.
- **Without home network access**, a server running in the Mac app is reachable only from
  a browser on that Mac. Its loopback address is shown then.
- **When the server is off or asleep**, the browser cannot load the page at all, because
  the server serves it. If the server stops while the page is open, Aurelia says so and
  connects again by itself once the server is back. A browser cannot wake a sleeping server
  with Wake-on-LAN. Open Aurelia on the Mac or the Apple TV to wake it.

## Signing in

1. The browser shows an 8-digit code, valid for five minutes.
2. In Aurelia on the Mac, the owner chooses *Enter Code from Apple TV or Browser…* and enters
   it. The Mac shows the browser's name, such as "Safari on iPhone", before approving.
3. The browser then shows the profiles. Profiles with a PIN ask for it in a PIN field: a
   computer types it on its keyboard, a phone or tablet shows its own number keyboard. The
   field shows only the digits typed, never how long the PIN is.

The browser then appears under *Signed-In Devices* on the Mac and can be signed out there.
*Sign Out of This Browser* in the profile menu does the same from the browser.

The browser never holds a token that scripts can read:

- The server keeps the device credential and the profile session in `HttpOnly`, `Secure`,
  `SameSite=Strict` cookies.
- The profile cookie ends when the browser closes. As in the apps, a profile session also
  ends after twelve hours and when the server restarts.
- See [the client protocol](CLIENT_PROTOCOL.md#web-browser-sign-in) for the details.

## Watching

The browser plays the original file directly with byte ranges. Nothing is converted or
stored on the server. Browsers can decode:

| Plays | Doesn't play yet |
| --- | --- |
| MP4, M4V and MOV with H.264 video (all browsers) or HEVC video (Safari, and Chrome or Edge where the system decodes it) and AAC or MP3 audio | MKV and AVI files in most browsers, and DTS, TrueHD or other surround formats the browser can't decode |

When a file can't play, the player says so and suggests the Mac or Apple TV app. When only
the sound is missing (Chrome and Edge report this), a short notice explains it. Live
conversion for these files is planned for a later version. It will convert in memory
only and never store converted video.

The player saves the position every ten seconds, when pausing and when closing. Each save
names the revision it builds on, so it never overwrites newer progress from another
device. If another device saved meanwhile, that position wins quietly and the browser
stops saving until the title is opened again. At the end of an episode, the player offers
the next one.

Keys: Space or K plays and pauses, the arrow keys (or J and L) skip ten seconds, F switches
full screen, M mutes and Escape closes the player.

## How it is built

- The files are in `src/Aurelia.Server/WebApp`: plain HTML, CSS and JavaScript modules, with
  no framework, no build step and nothing loaded from the internet. They are built into the
  server, so every server version carries its matching browser app.
- The page has its own strict content security policy: only its own scripts, styles,
  images and media.
- `js/logic.js` and `js/api.js` hold the rules that need no page. They are tested with:

```bash
node --test "tests/WebApp/*.test.mjs"
```

- The server side (cookies, the sign-in steps, the page's policy) is tested in
  `tests/Aurelia.Server.Tests/WebAppTests.cs`.
