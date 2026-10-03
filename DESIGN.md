# Aurelia Interface System

This document is the visual and interaction contract for every Aurelia macOS
surface. New features must use it before introducing new colors, spacing,
materials, controls, layouts, or motion. The Aurelia Classic screenshots are
the composition reference, but Classic source and data remain read-only.

## Product character

Aurelia is a quiet private cinema that is also a capable native macOS
application. Artwork provides emotion and color. Navigation and controls are
calm, familiar, and secondary to the library itself.

The interface is deliberately dark because its primary tasks are browsing and
playing video. It must not resemble a generic technology dashboard or generic
dark glassmorphism. Every visible section, status, and action must be backed by
real content or real behavior.

The intended feeling is **calm, cinematic, private, and precise**.

## Non-negotiable principles

1. Real artwork is the only strong source of color.
2. The neutral content canvas is exactly `#202326` (`RGB 32, 35, 38`).
3. Content extends beneath the transparent titlebar and material sidebar.
4. Material communicates a floating functional layer; it is not a general card
   treatment.
5. Media pages are continuous compositions, not collections of dashboard
   panels.
6. Native macOS controls and behaviors take precedence over imitations.
7. Every visible control performs a real action.
8. Accessibility states are designed states, not fallbacks.

## Visual hierarchy

The visual order is:

1. Current artwork and title.
2. The primary action that continues the user's immediate task.
3. Browsing structure and useful metadata.
4. Secondary actions.
5. Administration and technical state.

Do not promote server details, scan internals, or decorative status into the
entertainment hierarchy. Technical state belongs in setup, Settings, and Manage
Media unless it directly prevents the current action.

## Color system

Use semantic roles in code. Do not place unrelated literal colors throughout
feature views.

| Role | Value or source | Purpose |
| --- | --- | --- |
| Primary canvas | `#202326` | Library pages and the area below heroes |
| Secondary canvas | a slightly darker neutral derived from the primary canvas | Subtle depth near a window edge, never a colored gradient |
| Solid surface | a slightly lighter neutral derived from the primary canvas | Forms, management sections, and editor bodies |
| Elevated surface | native unemphasized selection color or a neutral elevation | Selected rows and compact elevated controls |
| Primary text | macOS label color | Titles and primary information |
| Secondary text | macOS secondary label color | Metadata and descriptions |
| Tertiary text | macOS tertiary label color | Counts and low-priority context |
| Accent | macOS control accent color | Selection, links, focus, and meaningful progress only |
| Hairline | low-opacity label/separator color | Delicate boundaries where spacing is insufficient |
| Warning/error/success | native semantic colors | Real state only |
| Player ground | pure black | Video and letterboxing only |

Never introduce blue-purple, blue-cyan, neon, rainbow, or decorative radial
gradients. Gradients are permitted only as readability masks over artwork or as
a subtle transition from a hero into the primary canvas.

## Typography

- Use San Francisco through SwiftUI system fonts.
- Page title: 34 pt, bold.
- Hero title: 44 pt, bold, up to two lines.
- Section title: 20 pt, semibold.
- Card title: approximately 15 pt, semibold.
- Body copy uses normal system tracking and comfortable leading.
- Large display text may use slightly tighter tracking; small uppercase media
  labels may use modest positive tracking for legibility.
- Avoid monospace as decoration. Use it only for technical values that benefit
  from fixed-width characters.
- Long titles and accessibility text sizes must reflow without hiding primary
  actions.

## Spacing, geometry, and depth

Use the 8-point family as the basis, with these fixed anchors:

- Page inset: 32 pt.
- Section separation: 24–32 pt; 34–38 pt between major detail sections.
- Horizontal media gap: 20 pt.
- Sidebar ideal width: 236 pt; supported range 210–300 pt.
- Compact control radius: 12 pt.
- Media card radius: 18 pt.
- Hero and major sheet radius: 24 pt.
- Minimum interactive target: 44×44 pt; 42 pt is the absolute lower bound.
- Maximum media-card hover scale: `1.012`.

Most content is flat. Use shadow only for floating chrome, open menus, sheets,
or the media card currently under the pointer. Do not add glow. Do not make
every button, input, badge, and panel pill-shaped.

## Window and sidebar composition

Aurelia uses one full-window composition with a native sidebar `List` over
the content. The overlay preserves native selection and window behavior while
allowing a single horizontal rail to continue underneath the sidebar.

### Release blocker: no top strip

Aurelia must never show an empty gray, black, or differently colored horizontal
strip above the detail content. This includes the area beside the traffic-light
buttons, the automatic `NavigationSplitView` toolbar area, and the top safe area
of every root page. A visible strip is a release-blocking defect and must be
fixed at the shared window or split-view layer immediately; individual pages
must not hide it with local padding, overlays, or matching fake rectangles.

Every UI change must be checked in an actually launched app window, not only in
SwiftUI previews. The check is mandatory at the reference size, minimum size,
native fullscreen, and with an inactive window. The expected result is one
continuous surface: hero artwork continues to the window edge when present;
otherwise the entire area is the exact `#202326` canvas. If a screenshot shows
a top strip, visual acceptance fails regardless of passing unit tests.

- The native titlebar is transparent and uses real macOS traffic-light buttons.
- No empty toolbar, gray strip, black strip, or custom titlebar may appear above
  the content.
- The sidebar order is Home, Library, Recently Added, TV Shows, and Movies.
- Selection uses native active and inactive window behavior.
- The sidebar content background is hidden and native sidebar material provides the
  structural layer.
- Do not draw a custom selection pill or an extra separator at the split edge.

On Home and artwork detail pages, background extension applies only to the
authenticated image, never the page, title or controls. The hero contributes
diffuse light and color under the sidebar, not a recognizable second person.
Scrollable cards themselves continue under the material on their actual row;
there is no separately positioned duplicate rail. Both effects stay local to
the source content and leave the viewport with it. The sidebar does not use
a calculated dominant color or a permanently stretched backdrop.

With Reduce Transparency enabled, replace material with an opaque,
high-contrast neutral surface. With Increase Contrast enabled, strengthen
selection and boundaries without changing the hierarchy.

## Heroes

Home, movie, TV show, and collection pages share one hero language:

- Target height: approximately 500 pt; detail heroes may extend to 540 pt.
- Artwork uses a composition-preserving aspect fill. If only portrait artwork
  exists, use a restrained blurred edge extension and keep the poster legible.
- Apply a left readability gradient for text and a bottom gradient into
  `#202326`.
- Content order: media type and year, title, concise metadata or genres,
  description, primary action, then secondary actions.
- Descriptions are limited to three lines in a hero.
- Primary play, resume, or open actions use a bright neutral capsule with dark
  text. Secondary actions are visually quieter.
- Back is a circular material control at the upper left. Contextual actions use
  a native menu at the upper right.

Artwork changes use a short cross-fade and must not flash an empty placeholder
between two already available images.

## Horizontal media rails

Continue Watching, genres, favorites, collections, episodes, trailers, extras,
and Cast & Crew use the same rail behavior.

- At rest, the first and last items align to the 32 pt page inset.
- Use scroll content margins for the resting inset and compensate the outer
  layout so the inset is not a hard clipping boundary.
- While scrolling, cards travel to the split edge and disappear cleanly below
  the higher sidebar material.
- Content below the sidebar is not interactive and cannot show hover state.
- Card shadows and the 1.2% hover scale must not clip or flicker.
- Horizontal indicators are hidden unless a future accessibility requirement
  explicitly needs them.
- Hover and keyboard focus reveal compact vertical material chevrons at the
  visible column edges, immediately outside the sidebar. Show only directions
  with remaining content; non-overflowing rows have no arrows. Page by complete
  cards and keep trackpad, keyboard and VoiceOver navigation available.
- Vertical indicators use app-local native overlay scrollers, not reserved
  tracks or a change to macOS preferences.
- Refreshing metadata or synchronized catalog state must not reset a user's
  horizontal position or close the current detail page.

## Media cards

### Poster cards

- Nominal artwork size: approximately 154×231 pt, adapting to available width.
- Artwork, one-line title, and one quiet metadata line.
- Use a small availability warning only when it affects playback.

### Landscape and Continue Watching cards

- Default media ratio: 16:9; Continue Watching is approximately 320×180 pt.
- A bottom readability gradient may carry media type, title, and context.
- Progress is a 4 pt line at the bottom edge.

### Episode cards

- Show episode number, title, concise description, runtime or status, and
  progress when available.
- The still remains dominant; text belongs in the lower readability region.

### People

- Use one circular profile per provider-identified person: name and character
  for actors, or compact job names for crew. Do not repeat the generic Acting
  label. Keep every raw credit and editable role in the metadata editor; do not
  merge unidentified people by name.
- Missing profiles use a neutral person placeholder, never invented imagery.

Missing artwork uses a neutral media-specific placeholder with an SF Symbol and
real title. Never invent covers, names, activity, or metadata to fill space.

## Page compositions

### Home

One hero is followed by Continue Watching and only non-empty content rows.
Genre rows, Favorites, Collections, and Recently Added appear only when real
content exists. A completely empty library shows one calm explanation and the
real next action.

### Library and catalog pages

The header contains the page title, useful counts, compact search, native
filter and sort menus, and role-appropriate add actions. Collections come first,
followed by adaptive movie and TV show poster grids. Recently Added, TV Shows,
and Movies reuse the same grid and card system.

Search results are grouped by their actual kind. A failed refresh must not
remove content that was already visible.

### Media details

Hero, season selection, episodes, extras, trailers, Cast & Crew, About, and the
information grid form one continuous vertical scroll. They must not look like
separate dashboard panels. Empty sections disappear completely.

Trailer and extra categories remain distinct. Missing or offline media remains
visible with disabled playback rather than disappearing from the library.

### Collections

Collections use the same hero, artwork, rail, and card language as movies and
TV shows. They are not a separate visual product.

## Material and native menus

Material is reserved for:

1. The structural sidebar.
2. Native menus and popovers.
3. Temporary player controls.
4. Small controls floating directly over artwork.

Cards, settings, setup forms, editor bodies, and management sections remain
solid. Do not stack translucent surfaces.

Use native `Menu`, `contextMenu`, popover, confirmation, and sheet behavior so
macOS owns Liquid Glass, blur, shadow, focus, keyboard navigation, active-window
appearance, destructive roles, and submenus. Do not recreate menu chrome in
SwiftUI rectangles.

## Settings, setup, editors, and management

Settings is a separate native macOS window with a top tab bar for General,
Playback, Library, Metadata, and Advanced. Each tab uses grouped native forms,
switches, pickers, steppers, and sliders on solid surfaces.

Setup and connection screens center one task, a concise explanation, and at
most one bounded solid work surface. Common choices appear first; addresses,
ports, fingerprints, and similar technical fields remain under Advanced.

Metadata, match, review, collection, and media-management sheets share:

- an approximately 720×640 pt working size where practical;
- a fixed header;
- a scrollable body;
- a fixed Cancel/Save or Done footer;
- grouped fields and real artwork previews;
- solid surfaces based on the Aurelia canvas.

Administration never leaks local paths into ordinary consumer views. Removing
a library remains visibly different from deleting media files; Aurelia never
deletes the media itself.

## Player

The player is the strongest exception to the normal canvas: video and
letterboxing use pure black.

- Back control: upper left.
- Real rate, audio, subtitle, and sleep controls: compact native-material group
  at the upper right.
- Transport: centered material capsule containing seek back, play/pause, and
  seek forward.
- Media context: lower left.
- Timeline: along the lower edge with current and total time.
- Real chapter, mute, volume, Picture in Picture, and native fullscreen
  controls: lower right when supported.

Controls disappear after the configured inactivity delay, but remain visible
during scrubbing, menu interaction, preparation, and errors. Unsupported
capabilities are hidden or disabled honestly. Never draw fake fullscreen
window controls.

Aurelia does not decode, analyze, hash, copy, transcode, remux, or cache video
to generate timeline thumbnails. Direct scrubbing and chapter interaction must
work without frame previews.

## Motion

Motion explains state and preserves spatial relationships; it is not
decoration.

- Press feedback begins immediately.
- Default transitions are critically damped and approximately 140–280 ms.
- Reversible transitions enter and leave along the same path.
- A running transition must not block the next input.
- No looping pulse, bounce, floating background, or decorative entrance
  choreography.
- Reduce Motion replaces scale and spatial movement with a short cross-fade or
  an immediate state change.

## Loading, empty, error, and offline states

- Loading names what is loading and remains local to the affected section.
- Empty states explain why content is absent and offer the one real next action.
- Filtered-to-zero, first-run, permission-denied, and offline states are
  different states with different copy.
- Errors state what failed and what the user can do next.
- Existing content remains visible during a failed refresh whenever it is still
  useful.
- Full-window spinners are reserved for startup states where no usable surface
  can exist yet.

## Accessibility and input

- Support keyboard-only use, visible focus, VoiceOver labels, pointer input,
  menu commands, and native fullscreen behavior.
- Interactive targets are at least 42–44 pt.
- Do not encode availability or progress through color alone.
- Support long titles, missing descriptions, large libraries, narrow windows,
  and large accessibility text without hiding primary actions.
- Reduce Motion, Reduce Transparency, and Increase Contrast must each work
  independently.

## Anti-slop prohibitions

Do not add:

- generic blue-purple or neon gradients;
- decorative glow, orbs, grids, noise, or glass cards;
- bento dashboards, statistic cards, activity feeds, or charts without a real
  user question;
- decorative emoji, fake terminal chrome, fake traffic lights, or generic AI
  iconography;
- repeated pills and badges with no semantic meaning;
- invented content, placeholder people, fake metrics, or dead controls;
- sections that exist only to fill visual space;
- endless animation.

## Delivery gate for every new surface

Before a UI change is complete, verify all of the following:

- [ ] The neutral canvas is `#202326`.
- [ ] Artwork, not decoration, supplies the strong color.
- [ ] The titlebar has no visible empty strip.
- [ ] Sidebar and floating chrome use material; forms and content cards do not.
- [ ] Content under a hero and sidebar is layered rather than hard-clipped.
- [ ] Horizontal rails reach the split edge without clipping hover or shadow.
- [ ] Every visible control has real behavior and the correct role permission.
- [ ] Empty, loading, error, missing, and offline states are honest and useful.
- [ ] The surface works at 760×560, 1470×956, a wide window, and fullscreen.
- [ ] Long titles and accessibility settings do not hide primary actions.
- [ ] Keyboard, VoiceOver, Reduce Motion, Reduce Transparency, and Increase
      Contrast have been checked.
- [ ] The player remains uninterrupted by catalog or detail refreshes.
- [ ] No media file, artwork, secret, or personal path is copied into the
      repository or a client cache.

If a new feature conflicts with this document, update the design decision here
first and explain why. Do not create a parallel visual language inside one
feature.
