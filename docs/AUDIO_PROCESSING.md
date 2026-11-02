# Dialogue Boost and Volume Leveling

All four native clients offer independent **Dialogue Boost** (Off, Standard, Strong)
and **Volume Leveling** (Off, Standard, Sleep) choices in Playback settings and the
player's Audio menu. The settings stay in each client's existing preference store;
no server API or database migration is needed.

Dialogue Boost emphasizes speech frequencies and reduces bass and extreme highs.
It is a local equalizer, not AI voice separation or restoration of masked speech.
VLC reports its actual band frequencies; the gain is interpolated in log frequency
between these points, rather than assuming a band index means a fixed frequency:

| Frequency (Hz) | 60 | 170 | 310 | 600 | 1,000 | 3,000 | 6,000 | 12,000 | 14,000 | 16,000 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Standard (dB) | −3 | −2 | −1 | 0 | 2 | 3 | 1 | 0 | −1 | −2 |
| Strong (dB) | −6 | −4 | −2 | 0 | 3 | 5 | 2 | 0 | −2 | −3 |

Standard uses −3 dB preamp; Strong uses −5 dB. This reserves headroom for the
equalizer boost. Frequencies outside the table keep the nearest endpoint's gain.

| Compressor setting | Standard | Sleep |
| --- | --- | --- |
| Detection: RMS to peak | 0.2 | 1 (peak) |
| Attack | 15 ms | 1.5 ms |
| Release | 300 ms | 650 ms |
| Threshold | −24 dB | −30 dB |
| Ratio | 4:1 | 12:1 |
| Knee | 6 dB | 6 dB |
| Makeup gain | 12 dB | 16 dB |

Standard retains the former Night Mode profile. Saved `nightMode = true` migrates
to Standard; false or an absent key remains Off. Dialogue Boost defaults to Off.
Explicit new choices take precedence over the legacy key, which remains in saved
Apple preferences for compatibility. Linux retains its old field and normalizes it
to the selected leveling mode. Other preferences and track choices remain intact.

## Filter configuration

Each client has one configuration that owns the full `compressor:equalizer` chain.
The public libVLC equalizer API sets band gains, but also replaces both the player's
and active output's audio-filter string. Merely setting an equalizer after enabling
compression would remove the compressor. Aurelia restores the complete chain and
recreates the audio output before opening the title.

With compression Off, Dialogue Boost can change through the public equalizer API
immediately. With compression active, or when changing compressor profiles, Aurelia
reopens with the complete configuration and restores position, paused/playing state,
rate and remembered audio/subtitle tracks. This avoids depending on private active
output structures or silently dropping a filter.

Before activation, the installed VLC's audio filter list must contain the selected
modules. Missing support produces a visible message. Native Linux packages use the
distribution's VLC 3; the Flatpak includes both modules and verifies their entry
points and dependencies. The Apple bridges inspect the bundled VLC library.
The Apple clients retain `.moviePlayback` for routes eligible for Apple's system
dialogue enhancement; Aurelia does not change the user's system setting.

Audio is processed locally. Original media remains read-only; no converted audio
or video copies are stored. These presets are starting points for the owner's
listening check, not a claim of measured dialogue intelligibility or loudness.

## Verification

Use `scripts/test-macos-audio-settings.sh`, `scripts/test-tvos-logic.sh`,
`scripts/test-ios-logic.sh` and `scripts/test-linux-app.sh`. These cover configuration,
migration, settings persistence and simulated controller state. Package checks inspect
module availability without opening media. No automated hearing, signal playback,
personal playback or takeover GUI tests are part of this change.
