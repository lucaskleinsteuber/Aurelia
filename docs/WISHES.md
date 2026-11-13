# Family Wishes

Family Wishes lets household profiles ask for movies and TV series that are not in the library yet, see whether another person already wished for the same title ("Me Too"), and receive updates when an administrator marks a wish as added or declined.

## Capability and compatibility

Servers with this feature advertise capability `wishes-v1` in `GET /api/v1/capabilities`.

- Clients on older servers hide Wishes UI cleanly and never call `/api/v1/wishes` without `wishes-v1`.
- Older clients continue connecting and playing media against the updated server without changes.

## Access rules and age limits

Every wish is stored in the server database (`Wishes` and `WishSupports`) and enforces rules server-side:

- **Creating and viewing wishes:** Any authenticated profile can open `GET /api/v1/wishes`. Profiles with an `AgeLimit` (role `User`) see only their own wishes plus wishes whose known `minimumAge` is at or below their age limit. Creating or supporting a wish above the profile's age limit returns `403 wish_age_restricted`.
- **Duplicate merge & already in library:** `POST /api/v1/wishes` checks the library first. If the requested title already matches an existing catalog item, the server returns `409` with `code: "already_in_library"`, `mediaId`, `title`, and `kind`. If an open wish with the same kind and TMDB id already exists, the caller is added as a `"Me Too"` supporter and the response returns `mergedIntoExistingSupport: true`.
- **Resolving wishes:** Only Owner and Administrator profiles can mark a wish `fulfilled` (optionally linked to a matching catalog item and resolution note), `declined`, or reopen it (`PUT /api/v1/wishes/{id}/state`). Matching titles added during library scans appear as `suggestions` on open wishes for admins to pick from.
- **Clearing wisher badges:** When the requester or a `"Me Too"` supporter visits Wishes, `POST /api/v1/wishes/seen` marks newly fulfilled wishes seen and resets `newlyFulfilledCount` to `0`.

## API endpoints

| Request | Who | Purpose |
| --- | --- | --- |
| `GET /api/v1/wishes?state=&offset=&limit=` | Profile | List visible wishes (`open`, `fulfilled`, `declined`), `openCount`, `newlyFulfilledCount`, `providerEnabled` |
| `GET /api/v1/wishes/summary` | Profile | Lightweight counts (`openCount`, `newlyFulfilledCount`) for badges and notifications |
| `GET /api/v1/wishes/search?query=&kind=` | Profile | Server-proxied TMDB search annotated with `alreadyInLibrary` and `alreadyWished` |
| `POST /api/v1/wishes` | Profile | Create a TMDB-backed or manual wish, merge `"Me Too"`, or return `409 already_in_library` |
| `PUT /api/v1/wishes/{id}/support` | Profile | Toggle `"Me Too"` support (`{ supported }`) |
| `PUT /api/v1/wishes/{id}/state` | Owner / Admin | Update state (`open`, `fulfilled`, `declined`), optional `fulfilledMediaItemId` and `resolutionNote` |
| `DELETE /api/v1/wishes/{id}` | Requester / Admin | Remove a wish (requesters can remove open wishes; admins can remove any wish) |
| `POST /api/v1/wishes/seen` | Profile | Mark the profile's newly fulfilled wishes as seen |
| `GET /api/v1/wishes/poster?path=&width=` | Profile | Server-proxied wish poster image (`w342`, `w780`, `w1280`) |

## TMDB privacy and bounded poster caches

TMDB API tokens stay exclusively on the server. When TMDB is enabled, `/api/v1/wishes/search` queries TMDB on the server and records safe returned poster paths in `WishPosterCache` (bounded at `2048` recent paths, plus paths saved on existing wishes). `/api/v1/wishes/poster` refuses unknown or malformed paths, caps downloads at `5 MiB`, and stores cached poster files under `<dataDir>/WishPosters` with a `64 MiB` LRU eviction cap. When TMDB is disabled, manual title entry stays available.

Clients use matching bounded caches so scrolling many wishes stays fast and memory-safe:

- **Browser (`src/Aurelia.Server/WebApp/js/wishes.js`):** Bounded LRU object-URL cache whose blob URLs are revoked on eviction or when leaving a profile.
- **macOS (`clients/macos/Aurelia/Networking/WishPosterCache.swift`, `Views/WishesPage.swift`):** `24 MiB` / `150`-entry encoded byte cache, `64 MiB` disk cache under `Caches/Aurelia/WishPosters`, and a `48 MiB` / `120`-item decoded image `NSCache`.
- **Linux Desktop (`clients/linux/Aurelia.Linux.Core/Library/WishPosterCache.cs`, `Library/WishesPage.cs`):** `24 MiB` / `150`-entry LRU encoded byte cache, `64 MiB` disk cache, and bounded decoded bitmap cache.
- **iPhone & iPad (`clients/ios/AureliaIOS/Core/IOSWishPosterCache.swift`, `Views/IOSWishesView.swift`):** `24 MiB` / `150`-entry encoded byte cache, `64 MiB` disk cache, and `48 MiB` / `120`-item ImageIO-downsampled `UIImage` cache.
- **Apple TV (`clients/tvos/AureliaTV/Core/TVWishPosterCache.swift`, `Views/TVWishesView.swift`):** Read-only Wishes tab (`24 MiB` / `150`-entry encoded byte cache, `64 MiB` disk cache, `24 MiB` / `80`-item ImageIO-downsampled `UIImage` cache).

## Notifications and badges

Admins and Owners see a sidebar/menu badge with `openCount + newlyFulfilledCount`; regular profiles see `newlyFulfilledCount`. When background `/api/v1/sync/changes` reports changes (or summary increases), clients with notifications enabled surface a calm local notification (`"New wish: ..."` for admins; `"Your wish is here"` when a wished or supported title enters `fulfilled`). Notification toggles live in General/Settings and fail closed (no-op) under headless or UI-test environments.
