# Import previews and source assignments

New storage locations added by the native client require a confirmed import
preview. Registering a location does not import media or start its watcher.
`Manage Media` and the initial library setup expose unfinished previews after a
restart. Existing locations can be reviewed from `Settings > Storage > Manage
Media` without resetting the library.

## Resolution and review

The scanner indexes filenames and filesystem metadata once, then resolves the
directory tree with inherited title, season, and supplement context. It never
opens, hashes, modifies, or copies video content. Manual file assignments win
over inherited folder rules; excluded sources and editor-selected source
bindings remain protected.

Bonus folders include Extras, Featurettes, Bonus, Special Features, Behind the
Scenes, Making Of, Deleted Scenes, Interviews, Bloopers, Outtakes, and German
equivalents. Numbered categories such as Featurettes 5.1 and 5.2 inherit their
ancestor's season. Series-wide supplements retain a null season. Numbered S00
specials remain episodes. Container folders can contain separate movies or a
series' packaging folders without creating a second main title.

Bounded trailer/teaser names and supplement suffixes are recognized without
misclassifying titles such as Trailer Park Boys. Uncertain owners or unnumbered
videos remain review items, not invented movies or episodes. Explicit TV Show
Force Import assigns unnumbered episodes in natural filename order; inspect the
resulting preview before confirming.

The conventions are informed by the [Jellyfin extras documentation](https://jellyfin.org/docs/general/server/media/movies/#extras).
Disc extraction, transcoding, theme videos, and video-content inspection are
not part of this importer.

## Native workflow

1. Choose a storage folder, then `Analyze and Preview`.
2. Expand titles and folders; filter review, ignored, error, or manual items.
3. Select files or folders and choose `Edit Assignment…`. Assign a movie, TV
   show, episode, extra, trailer, or Ignore. For supplements select a proposed
   movie/series, Entire Series or an existing season, category, and display name.
4. `Save Assignment` changes the draft only. `Use Automatic Detection` removes
   an explicit assignment; reanalysis or closing asks before discarding edits.
5. `Import Recognized Items` publishes confirmed assignments and queues the
   transactional catalog scan. Remaining uncertain files stay in review.

Video files are unchanged. Later background scans import clear new sources and
retain uncertain ones for review. Partial read errors preserve existing catalog
data under unreadable paths. A first-import preview with unreadable sources
cannot be confirmed. An unavailable storage location is not an empty library.

Series-wide extras/trailers and season-specific supplements use separate detail
sections. The existing sidebar and rail rendering is unchanged.

## API and conflicts

All routes are administrator-authorized and library-scoped under
`/api/v1/libraries/{libraryId}`:

| Route | Purpose |
| --- | --- |
| `POST /import-preview` | Analyze without catalog writes |
| `GET /import-preview/{previewId}/items` | Paginated items, counts and targets |
| `PUT /import-preview/{previewId}/assignments` | Revision-checked draft corrections |
| `POST /import-preview/{previewId}/confirm` | Confirm current source/stat manifest |
| `GET /import-assignments` | Current saved assignments, including legacy decisions |

Drafts expire after one day; at most five are retained per location. Stale,
expired, already confirmed, concurrently edited, or changed-source previews
return a conflict. The queued scan verifies the manifest again before catalog
commit. Paths are relative and confined to the location. Resolved legacy folder
and trailer decisions become general rules on confirmation. The legacy create
API remains opt-in (`requireImportPreview`), while the native client always
requires preview for new locations. Combining overlapping locations is not
performed through a first-import preview.

The native scan status exposes file discovery, context resolution, catalog
commit, and terminal state with recognized, pending, ignored, and failed counts.
Provider metadata work remains a separate existing job; supplements are never
searched as standalone films or series.

## Reproducible checks

`ImportStructureAcceptanceTests` builds empty synthetic sources from the 843
relative-path fixture and tests known title totals, nested categories, wrapper
folders, S00, Unicode, bounded rules, repeated discovery and a larger 10,000-file
catalog. `ImportPlanningApiTests` verifies preview gating, manual precedence,
revision/source conflicts, grants, exclusions, cancellation, and unreadable
sources against isolated databases. Mac tests render the preview and editors;
UI tests use isolated synthetic fixtures rather than personal catalog data.

The explicitly opt-in `AURELIA_IMPORT_ACCEPTANCE_ROOT` test performs metadata-only
discovery in place and verifies unchanged path/size/modification-time snapshots.
It does not start a server, import catalog entries, or reset the library. Scanner
measurements do not include provider downloads or imply complete import times.

Normal updates preserve existing data and do not automatically repair or clear
old catalog entries. A deliberate reset and reimport remains a separate,
explicitly confirmed user action during a management unlock. No reset is required to use saved assignments.
