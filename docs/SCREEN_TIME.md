# Screen time for children's profiles

Parents can give a children's profile a bedtime and a daily limit. When the time is up,
Aurelia does not start the next episode and ends with a calm good-night screen instead.

## Setting it up

Open the profile in **Settings › People › Edit** on the Mac, in the Linux app or in a browser.
Screen time is available for profiles without server access (role **User**). It works with or
without an age limit.

| Setting | What it does |
| --- | --- |
| **Screen Time** | Turns the rules on or off for this profile. |
| **When time is up, close** | **Playback only** keeps browsing open, and playing shows the good-night screen. **The whole profile** closes until the wake time: "Who's watching?" shows it with a moon and "Good night · back at 07:00", and it cannot be opened. |
| **A title that is playing** | **Let the title finish** lets an episode or film that started before the time play to its end. **Finish within** sets a limit (30 minutes by default), so a film started at 19:25 does not run until 21:30. **Stop right away** ends playback at the time. Progress is kept in both cases. |
| **School nights** | Sunday to Thursday evening: bedtime, wake time and daily limit. |
| **Weekend** | Friday and Saturday evening: bedtime, wake time and daily limit. |

A bedtime or a limit may be left empty. The wake time is the next morning. Five minutes before
the time, the player says "This is the last episode before bedtime" (or "the last title for
today") and stops offering Up Next and suggestions. From the time on, no new title starts.

### Exceptions for today

For an existing profile, the **Today** part shows the time watched today and when the profile
closes. Its buttons apply at once, without saving the editor:

- **+15 min, +30 min, +60 min** adds time to today's limit and moves today's bedtime later.
- **No Bedtime Tonight** lifts tonight's bedtime. A daily limit still applies.
- **One More Episode** allows exactly one more title after the profile has closed. That title
  ends the same way as any other.

Exceptions last until the next wake time.

## How it works

- The **server** decides, in its own time zone. The same rules therefore apply on every device
  and in the browser, and switching devices does not reset them.
- **Days** run from one wake time to the next. A day takes the rules of its evening: Friday and
  Saturday are the weekend, every other evening is a school night.
- **Watched time** is the time that actually played. It is counted from the players' progress
  reports, at most 90 seconds between two reports of the same title. Pauses, jumps forward and
  browsing do not count. Two devices playing at the same time both count.
- A refused title gets `403` with `screen_time_bedtime` or `screen_time_limit`. Unlocking a
  profile that is closed as a whole gets `403 profile_screen_time_closed`. Clients show the
  good-night screen for these, not an error.
- A playback ticket carries `screenTime`, the profile's status at that moment. Players read
  `GET /api/v1/profile/screen-time` every minute while a title plays, and again at its end.
- A background check every 15 seconds ends a title that runs past the time it was allowed
  (**Stop right away** at once, **Let the title finish** after the overtime). For a profile
  closed as a whole, it also ends the profile session once nothing is playing.

## API

| Request | Who | What |
| --- | --- | --- |
| `GET /api/v1/users/{id}/screen-time` | Owner | Rules, today's exceptions, status and revision |
| `PUT /api/v1/users/{id}/screen-time` | Owner | `{ rules, revision }`. A stale revision gets `409 screen_time_conflict`. |
| `POST /api/v1/users/{id}/screen-time/today` | Owner | `{ addMinutes, liftBedtime, oneMoreTitle }` |
| `GET /api/v1/profile/screen-time` | The open profile | `{ status }`, which is null without screen time |

`WatchingProfile.closedUntil` in `GET /api/v1/profiles` is set while a profile is closed as a
whole. Servers with this feature report the capability `screen-time-v1`. Clients without it
hide the settings.

## Limits

- The server's clock and time zone decide. If a device is in another time zone, it shows the
  server's times converted to its own clock.
- Only the database stores screen time: the rules, and each day's watched seconds and
  exceptions. Days older than 90 days are removed.
- Owner and administrator profiles never have screen time.
