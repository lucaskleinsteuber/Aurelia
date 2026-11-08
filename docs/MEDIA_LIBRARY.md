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

- **Film series** such as *The Lord of the Rings* are gathered automatically from TMDB, in the
  order they came out.
- **Universes** such as the Marvel Cinematic Universe or Middle-earth gather the movies *and* series
  that TMDB marks as part of one world.
- **Your own collections** and **smart lists** that fill themselves by genre, year, rating,
  watched state or Watchlist are created under *Collections*. They can be private to your profile
  or shared with everyone.

## Several folders, drives that are not always there

- Add as many folders as you like; each can be marked as movies, series or mixed.
- When a drive is unplugged, its titles stay with their details, favorites and progress and show as
  offline until the drive returns. Removing a title from the library never deletes its file.
- **Library Health** lists duplicates, missing files, unmatched titles and excluded files.
