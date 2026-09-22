# Active Tester Feedback

This file records unresolved observations from hands-on testing. It is an active
engineering backlog, not a release note. Resolve an item only after Lucas has
verified the installed app.

## P0 — Playback

- Verify that video no longer jitters. The suspected causes were repeated VLC
  drawable attachment during every SwiftUI update and repeated publication of
  unchanged engine state.
- Keep the player visually aligned with Aurelia Classic: compact controls,
  native menus, no artificial top bar, video as the dominant surface, and no
  oversized popovers.
- Verify windowed playback, native fullscreen, scrubbing, audio selection,
  subtitle selection, volume, sleep timer, and return to the detail page with
  real media.

## P1 — Library correctness

- Do not import a trailer stored beside a movie as a separate top-level film.
  The reported example is the trailer for *The Truman Show*.
- Improve ambiguous-series review for *Top Gear*, *The Grand Tour*, and
  *Planet Earth I* without guessing a wrong match.
- Improve manual recovery for badly named files such as *American Psycho*.
- Investigate why *Minions & Monsters* received no metadata despite an
  apparently unique title. A new release or provider coverage must not make the
  item unusable.
- Deduplicate people and supplemental rows by stable identity. Bryan Cranston
  appeared twice on *Breaking Bad*; similar duplicates were seen in episodes,
  cast, extras, and trailers.

## P1 — Navigation and media details

- Add a visible back action to collection details.
- Increase the leading breathing room for episodes, cast and crew, extras, and
  trailers. At rest these rails must begin at the standard content inset; while
  scrolling, cards may travel under the higher sidebar layer.
- Display only the release year in consumer-facing detail metadata.
- Do not show a series-wide runtime. Episode runtimes remain useful.
- Keep age certification and audience score as different concepts. Rename
  `Content Rating` to a clear age-rating label and present a separate 0–10
  audience/provider score where real source data exists; never fabricate one.

## Product readiness

Aurelia is a real self-hosted media system, not a repackaged Aurelia Classic.
The server, automatic scanning, metadata, collections, authenticated artwork,
and Direct Play are already useful. It remains pre-alpha until fatal playback
issues, importer false positives, ambiguous-match recovery, duplicate
presentation data, and the primary navigation/detail regressions above have
been verified. A beta should follow only after those paths survive repeated
fresh-install and existing-library testing.
