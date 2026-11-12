# Organizing your media

Aurelia reads your folders as they are and never renames, moves or changes a file. It recognizes
most common layouts, and the import preview shows every decision before anything is added, so
nothing has to be perfect. The names below are the ones Aurelia understands best.

## Supported files

- **Video:** `.mkv`, `.mp4`, `.mov`, `.m4v`, `.avi`, `.webm`. The apps play the original file with
  every audio and subtitle track; a browser gets formats it cannot play (such as MKV) converted live,
  and nothing converted is ever stored.
- **Subtitles next to the video:** `.srt`, `.vtt`, `.ass`, `.ssa` (and `.sub`/`.idx`, which
  are listed but cannot be shown as text).

## Movies

One folder per movie, named with the year, is the most reliable:

```
Movies/
├── Arrival (2016)/
│   ├── Arrival (2016).mkv
│   ├── Arrival (2016).en.srt
│   ├── Arrival (2016).de.forced.srt
│   ├── Trailers/
│   │   └── Arrival Trailer.mp4
│   └── Extras/
│       └── Making Of.mkv
└── Blade Runner 2049 (2017).mkv
```

- A loose file such as `Blade Runner 2049 (2017).mkv` works too.
- Release noise after the title (`1080p`, `BluRay`, `x265`, `WEB-DL`, `REMUX` …) is ignored.
- The year in parentheses helps TMDB find the right film when several share a name.

## Series

One folder per series, one folder per season, and the season and episode number in each file name:

```
TV Shows/
└── Dark (2017)/
    ├── Season 1/
    │   ├── Dark S01E01 - Secrets.mkv
    │   └── Dark S01E02 - Lies.mkv
    ├── Season 2/
    │   └── Dark S02E01.mkv
    └── Extras/
        └── Behind the Scenes.mkv
```

Aurelia understands these episode names: `S01E02`, `S1 E2`, `1x02`, `Season 1 Episode 2`,
`Staffel 1 Folge 2`, and inside a season folder also `E02`, `Episode 2`, `Folge 2` or just `02`.
Season folders may be called `Season 1`, `Staffel 1` or `S1`.

## Intros and credits

For series, the server finds where the intro and the credits are, so players can offer
**Skip Intro** and the next episode when the credits begin. It works in the background after a
scan, one short read at a time, and waits while anyone is watching.

- If a file has chapters named like "Intro", "Opening", "OP", "Credits", "Ending" or "ED", those
  are used as they are.
- Otherwise the server compares the sound of each episode with up to four other episodes of the
  same season: the first 12 minutes (at most 40 % of the episode) for the intro and the last 10
  minutes (at most 25 %) for the credits. Music that at least two other episodes share at a
  believable length is the intro (10 to 150 seconds) or the credits (at least 15 seconds); a
  recap that only one other episode shares is not. Boundaries move to a quiet moment nearby.
- An episode that has no intro there is searched up to its middle, but then three other
  episodes must share the music. When someone speaks over an episode's intro, so its sound
  differs, the server compares the pictures of its first minutes with the other episodes'
  intros instead; two of them must show the same pictures.
- For credits it also looks at the pictures of each episode's last six minutes, two a second:
  names on a black screen, or a card the other episodes of the season show too (names over the
  same drawing). Such credits must last until shortly before the end. When sound and pictures
  both find credits, the earlier start counts as long as both describe the same credits. This
  is the slow part: on an older server a few minutes per episode, once. The owner can turn it
  off and keep detection from sound only.
- Movies (from Server 2.11.0) have no other episodes to compare with, so only their credits are
  looked for: from a chapter named like credits, or in the pictures of their last 20 minutes (at
  most 15 % of the movie). Names on black must last at least 45 seconds, a scene of up to five
  minutes may follow them, and credits that a mid-credits scene interrupts count from their
  first part. A movie's intro comes only from a chapter or from a correction by hand. Movies
  have their own rules' version, so changing them never examines episodes again.
- When it is not sure, it stores nothing and no button appears. A season needs at least two
  episodes; movies shorter than 20 minutes are not examined.
- Someone who may edit the library can correct the times of an episode in Edit Metadata. A
  correction is never replaced; "Reset to detected" removes it.

The media file is only read. Sound, pictures and the fingerprints made from them exist only in
the server's memory while a season is compared; only the timestamps are stored, in the server's
database. No sound, picture, fingerprint or other file is written anywhere. The server settings
show how far it is (episodes examined, the episode it is on, the time left) and each series'
results; there the owner turns detection or the pictures off and has a series examined again.
Times set by hand keep working when detection is off.

## Extras and trailers

Put them in a subfolder of the movie, the series or the season, and they appear on its page:

- **Trailers:** `Trailers`, `Trailer`, `Teasers`, `Official Trailer`.
- **Extras:** `Extras`, `Bonus`, `Special Features`, `Featurettes`, `Behind the Scenes`, `Making Of`,
  `Deleted Scenes`, `Interviews`, `Bloopers`, `Outtakes`, `Zusatzmaterial`.

A file whose name ends in `- Trailer`, `- Teaser`, `- Featurette`, `- Deleted Scene`,
`- Interview` or `- Behind the Scenes` is recognized as such also without a folder.

## Subtitle files

Name a subtitle file after its video and add the language and, if wanted, `forced` or `sdh`:
`Arrival (2016).en.srt`, `Arrival (2016).de.forced.srt`. Subtitles in a `Subs` or `Subtitles`
folder also count, and when a video is alone in its folder, every subtitle there belongs to it.

Subtitles found with OpenSubtitles are kept in the server's data folder, never next to your media.

## Details, artwork and cast from TMDB

With a free TMDB key (see [Getting started](GETTING_STARTED.md#3-get-posters-details-and-subtitles-optional-free)),
Aurelia fetches posters, backdrops, descriptions, ratings, age ratings and the complete cast and
crew. It compares the title, the year and, for series, the seasons and episodes you have, so most
titles match without asking. Unsure matches wait in **Review Matches**, where you choose the right
one. You can also edit any detail by hand; your edits are kept when the library is scanned again.

Selecting a person shows every movie and series in your library they are part of.

## Collections

- **Film series** such as *The Lord of the Rings* are gathered automatically from TMDB, with their
  TMDB description and artwork in release order.
- **Universes** such as the Marvel Cinematic Universe or Middle-earth gather the movies *and* series
  that TMDB marks as part of one world.
- **Your own collections** and **smart lists** that fill themselves by genre, year, rating,
  watched state or Watchlist are created under *Collections*. They can be private to your profile
  or shared with everyone.
- A collection works like a box set on a shelf: it can hold movies, whole series, single seasons
  (such as a show's Specials) and single episodes, in your own order or by release or title. Give
  it a description, a cover and a background picture, or let Aurelia make a cover from its titles.
  It shows how much of it you have watched, and **Play** continues where you left off.
- An automatic film series or universe can be saved as your own collection to change it. On
  Apple TV, collections can be browsed and played but not edited.

## Several folders, drives that are not always there

- Add as many folders as you like; each can be marked as movies, series or mixed.
- When a drive is unplugged, its titles stay with their details, favorites and progress and show as
  offline until the drive returns. Removing a title from the library never deletes its file.
- **Library Health** lists duplicates, missing files, unmatched titles and excluded files.
