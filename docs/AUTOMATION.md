# Smart Home: Home Assistant, webhooks and Siri

Aurelia Server 2.16.0 tells other programs what happens, the moment it happens: a movie starts on
the living room TV, someone pauses, an episode ends, a new title arrives. Home Assistant can dim the
lights, start a scene or send a notification. In the other direction, Home Assistant can read what
plays, wake the server and turn it off.

Everything is set up by the server's owner in **Settings › Smart Home** (Mac, iPhone and iPad,
browser) or **Settings › Server › Smart Home** (Linux app). The capability is `automation-v1`.

## Webhooks

A webhook is an address that receives a signed JSON `POST` for each event it is subscribed to.

| Event | When |
|---|---|
| `playback.started` | A title really plays, after any buffering. |
| `playback.paused` | Someone pauses. |
| `playback.resumed` | A paused title plays again. |
| `playback.stopped` | The player closes before the end. |
| `playback.finished` | The title was watched to its end or its credits. |
| `library.title_added` | A new movie or show arrives (once TMDB found it, or after ten minutes with the file's name). A scan that adds more than 20 at once sends one event with only `count`. |
| `server.started` | Aurelia Server started, for example after waking. |
| `server.stopping` | Aurelia Server is stopping, sleeping or turning off. |
| `test` | Send Test in the settings. |

Each webhook can be limited to some devices (only the Apple TV in the living room) and some
profiles, can leave out children's profiles, and can leave out titles and profile names: then only
which device played is sent.

### What arrives

```json
{
  "event": "playback.started",
  "eventId": "6b0f2c8e-…",
  "occurredAt": "2026-11-14T20:15:03.120Z",
  "server": { "name": "Living Room Server", "version": "2.16.0" },
  "device": { "id": "1d2c…", "name": "Living Room", "platform": "Apple TV" },
  "profile": { "name": "Alex", "isChild": false },
  "media": {
    "id": "8f1e…", "kind": "episode", "title": "Pilot", "seriesTitle": "An Invented Show",
    "season": 1, "episode": 1, "year": 2024, "durationSeconds": 2880, "positionSeconds": 0
  }
}
```

Headers: `X-Aurelia-Event` (the event), `X-Aurelia-Delivery` (the event's ID, the same on every
retry) and `X-Aurelia-Signature`.

### Checking the signature

`X-Aurelia-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, t + "." + body)>`. The secret
is shown once when the webhook is created (and again after **New Secret**). A receiver computes the
HMAC over the raw body and rejects old timestamps:

```python
import hashlib, hmac, time
def valid(secret, header, body):
    parts = dict(item.split("=", 1) for item in header.split(","))
    expected = hmac.new(secret.encode(), (parts["t"] + "." + body).encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, parts["v1"]) and abs(time.time() - int(parts["t"])) < 300
```

Home Assistant's Webhook trigger doesn't check signatures; its webhook ID is the secret there, so
keep **local_only** on.

### Speed and retries

Players report their state the moment it changes (`POST /api/v1/playback/{ticket}/state`); the
server answers at once and sends the event without touching the database first. A delay usually
comes from the player, for example while it buffers: "started" is sent when the picture is there.
An older app that doesn't report gets "started" five seconds after opening and "stopped" when it
closes. A renewed ticket during a long title doesn't send a second "started".

- Each webhook has its own queue, so a slow receiver delays only its own events, always in order.
- Requests time out after 5 seconds; redirects are not followed; only the status counts (2xx).
- **Playback events** go stale fast: they are tried again after 1, 3 and 10 seconds, then dropped.
- **New titles and server events** are kept in the database and tried after 30 seconds, 2 and 10
  minutes and an hour. 408, 429 and 5xx are tried again (honouring `Retry-After`); other answers
  are final.
- After 20 failed deliveries in a row a webhook pauses; saving it again resumes it.
- The delivery log keeps the last 100 outcomes per webhook for seven days, never the bodies.

### Where a webhook may point

HTTPS goes anywhere. Plain HTTP only to this computer or the home network (private addresses and
names such as `homeassistant.local`), because elsewhere it would send what is playing
unencrypted. Link-local addresses (cloud metadata services among them) and multicast are refused,
and the address is checked again for every connection. A self-signed certificate is accepted only
at home.

## Home Assistant

1. In Home Assistant: **Settings › Automations › Create Automation**, add the trigger **Webhook**
   and note its ID (for example `aurelia_movie_lights`). Keep **Only accessible from the local
   network** on.
2. In Aurelia: **Smart Home › Add Webhook…**, choose **Home Assistant**, enter Home Assistant's
   address (`homeassistant.local:8123`) and the webhook ID, and choose the events.
3. Aurelia shows an example automation to paste in YAML: lights to 10 % when a title starts or
   continues, back to 70 % when it pauses, stops or ends. Conditions such as
   `{{ trigger.json.device.name == 'Living Room' }}` limit it to one TV.

### Keys: Home Assistant reads and controls Aurelia

**Smart Home › Create Key…** makes a key that is shown once and stored only as a SHA-256
fingerprint. It is no profile and opens nothing else; each key does only what it was allowed:

| Scope | Calls |
|---|---|
| Read What Plays (`status`) | `GET /api/v1/integration/status` |
| Turn the Server Off (`power`) | `POST /api/v1/integration/power` with `{"action":"sleep"}` (or `shutdown`, `stop`) |
| Control Players (`playback`) | `GET /api/v1/integration/players`, `POST /api/v1/integration/players/{deviceId}/commands` (the owner's own devices that have Aurelia open) |

Send it as `Authorization: Bearer aur_it_…`. Creating or removing a key is recorded in the security
log, and so is every power request. Examples for `configuration.yaml`:

```yaml
rest_command:
  aurelia_sleep:
    url: https://aurelia.local:43111/api/v1/integration/power
    method: POST
    headers: { Authorization: !secret aurelia_key }
    content_type: application/json
    payload: '{"action": "sleep"}'
    verify_ssl: false

sensor:
  - platform: rest
    name: Aurelia playing
    resource: https://aurelia.local:43111/api/v1/integration/status
    headers: { Authorization: !secret aurelia_key }
    value_template: "{{ value_json.playing | count }}"
    verify_ssl: false
```

`verify_ssl: false` is needed because the server uses its own certificate; keep these requests in
the home network.

### Turning the server on

Home Assistant's **Wake on LAN** integration starts the server with
`wake_on_lan.send_magic_packet` and the MAC address shown under **Smart Home › Turning the Server On
and Off**. Every Aurelia app wakes it the same way.

## Siri and Shortcuts

On iPhone, iPad (2.14.0) and Mac (2.17.0) the owner taps **Smart Home › Set Up Siri**. That
creates a key for this device (status, power and playback), kept in its Keychain, so Siri works
even when Aurelia is closed. Then, in English:

| Say | What happens |
|---|---|
| “Hey Siri, turn on my Aurelia server” | Sends Wake-on-LAN for up to a minute and says when the server answers. Needs no key. |
| “Hey Siri, turn off my Aurelia server” | Turns it off (or puts it to sleep, as the shortcut is set); asks first while someone watches. |
| “Hey Siri, play in Aurelia” | Siri asks what to play: “Breaking Bad season 3 episode 4”, “… S3E4”, a movie, or just a show to continue it. It plays on the Apple TV, or on the device you name, that has Aurelia open with the owner's profile. |
| “Hey Siri, what's playing in Aurelia” | Says what plays on which device. |

The same actions are in the Shortcuts app for automations and the Home Screen. Limits: Siri needs
the app's language phrases above (English until Aurelia is localized); the Apple TV receives the
title only while Aurelia is open on it, because tvOS doesn't wake apps in the background; Siri on
the Apple TV's remote doesn't offer these actions. Removing Siri on the device also removes its key.

## Turning the server off now

`POST /api/v1/server/power/now` (owner) or `/api/v1/integration/power` (key) with `sleep`,
`shutdown` or `stop`. While someone watches it answers `409 playback_active` unless `force` is set.

- **Linux package:** the server leaves `power-now` in its data folder; `aurelia-power-request.path`
  hands it to `aurelia-autosleep --now` at once, which sleeps or turns the computer off as
  `aurelia sleep` would (even with power saving off). Only the three words are accepted; a running
  update finishes first.
- **Server in the Mac or Linux app:** only `stop`; it starts again when Aurelia is opened there.
- **Docker and other services:** not available; something else starts and stops them.

## Privacy

Nothing leaves the server unless the owner adds a webhook, and only to the addresses the owner
enters. Titles and profile names can be left out per webhook, and children's profiles excluded.
Webhook secrets are kept encrypted with the server's data-protection keys; a restore on another
computer asks for a new secret. Pending bodies of new-title and server events are kept at most an
hour, until delivered or given up. See [PRIVACY.md](PRIVACY.md).
