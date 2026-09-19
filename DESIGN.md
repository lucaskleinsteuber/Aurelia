# Aurelia Interface Direction

## Purpose

Aurelia should feel like a quiet private cinema that happens to be a capable
macOS application. Artwork is the emotional layer; controls are calm,
predictable, native, and secondary to the library itself.

The interface is dark because the primary task is browsing and playing video.
It is not a generic technology aesthetic. Neutral blue-black surfaces protect
artwork color, reduce glare, and keep changing posters and backdrops coherent.

## Hierarchy

1. Artwork and the currently relevant title.
2. The action that continues the user's immediate task.
3. Browsing structure and metadata.
4. Administration and technical status.

The sidebar and player controls may use translucent material because they float
above changing imagery. Cards, forms, settings, and management surfaces remain
mostly solid so that glass retains meaning.

## Foundations

- Canvas: neutral blue-black, never pure black except in the player.
- Color: comes from artwork. System blue is reserved for selection, links, and
  progress that needs emphasis.
- Typography: San Francisco system typography with tight display leading and
  ordinary body tracking.
- Spacing: 8-point family, with 32-point page insets and 24–32-point section
  separation.
- Radius: 12 points for controls, 18 for media cards, 24 for heroes and major
  sheets. Pills are reserved for compact playback controls and status.
- Depth: most content is flat. Shadow appears only for floating chrome or the
  media card currently under the pointer.
- Motion: immediate press feedback and short critically damped transitions.
  No looping motion and no decorative entrance choreography.

## Core compositions

- Home begins with one 500-point artwork hero, then Continue Watching and only
  non-empty editorial rows.
- Library is an efficient catalog: title and counts, search and real filters,
  collections, movies, and TV shows.
- Detail pages use a full-width backdrop with readable edge gradients and keep
  episodes, extras, people, synopsis, and facts in one continuous scroll.
- The player keeps video dominant. Controls occupy only the edges and one
  compact central transport capsule, then disappear after inactivity.
- Setup and management use a centered task or a clear solid work surface, not
  entertainment-page decoration.

## Interaction and accessibility

- Every visible control performs a real action.
- Interactive targets are at least 42 points.
- Pointer hover never exceeds 1.2% scale and must not clip inside scroll views.
- Reduced Motion uses short cross-fades without scale or spatial movement.
- Reduced Transparency replaces material with an opaque dark surface.
- Keyboard focus, VoiceOver labels, long titles, missing artwork, offline media,
  narrow windows, and large accessibility text are first-class states.
