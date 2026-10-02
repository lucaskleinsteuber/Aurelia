# Aurelia 1.2.1: metadata editing and library maintenance

Changes are stored on the connected server. Owners can manage all libraries;
administrators can manage only their granted storage locations. Ordinary users
can manage their own favorites, but cannot edit or remove shared titles.
Video files are never deleted, uploaded, moved, or modified by these tools.

## Open the editor

Right-click a library card for **Add to Favorites / Remove from Favorites**,
**Edit Metadata…**, and **Remove from Library…**. Left-click still opens the
detail page. The gear in the top-right corner of movie and series detail pages
offers editing, provider matching/refresh, and removal. Favorites remain beside
Play. Right-click an episode to edit it without changing normal playback.

The resizable native editor has four sections:

- **General:** title, release year, description, genres, FSK (unspecified, 0, 6,
  12, 16, 18), and movie-only runtime in minutes. Foreign ratings are not silently
  converted into FSK. Episodes and series do not have a runtime field.
- **Production & Release:** individually editable studios and one country of
  origin.
- **Cast & Crew:** title-specific people with stable IDs, ordering, name,
  department, job, character, and their own profile image.
- **Artwork & File:** cover/background and their original images; a protected
  browser of the associated server storage location for movie/episode file
  reassignment. A series displays its folder; edit files on individual episodes.

Use **Use Automatic Value** to relinquish a manual override for that field.
Blank manual descriptions, years, ratings, lists, or images remain deliberately
blank through later scans and provider updates. Existing manual values are
carried forward by migration. Manual cast lists are not replaced by provider
refreshes; changes affect this title rather than every appearance of a person.

**Save** submits the entire draft with its server revision. A stale revision
returns a conflict rather than overwriting another device's changes. Validation
or connection failures keep the draft open. **Reload** discards local changes
only after confirmation. **Cancel** and closing a dirty editor ask before
discarding changes.

## Import and recrop images

The native client accepts JPEG, PNG, and HEIC. It converts imported images to
PNG before upload; the server fully decodes JPEG/PNG with SkiaSharp, restricts
uploads to 20 MiB / 24 megapixels, handles image orientation, and stores a
sanitized PNG without embedded metadata. Uploads belong to the authenticated
session and title and are not published until the draft is saved.

Crop using drag, zoom, and 90-degree rotation. Covers use 2:3, backgrounds 16:9,
and person photos 1:1 with a circular preview. A sanitized uncropped original is
retained for subsequent crops. New image revisions have new asset IDs. Removed
or superseded owned images and their originals are tracked for durable cleanup;
abandoned private uploads expire after 24 hours. No arbitrary image URL importer
or free-form server path is exposed.

Reassigning a video uses an existing supported file within the same storage
location, verified through no-follow file descriptors. Already assigned files
are rejected. The title ID, metadata, favorites, and progress survive; old
source files are excluded from future scans so they do not create duplicates.
Affected playback tickets and streams are revoked. The video itself is unchanged.

## Remove a title or reset selected libraries

Title removal asks for confirmation. A series also removes its episodes,
trailers, and extras; a movie removes its supplements. Aurelia deletes associated
catalog/metadata, owned images and crops, all users' favorites/progress, tickets,
and search/collection links. Shared assets remain while another title references
them. A minimal source exclusion prevents later scans from resurrecting the title.

Under **Settings → Library → Excluded Items**, explicitly **Reimport…** a source
to remove its exclusion and scan again. Reimport does not recover deleted personal
metadata/history. A series-folder reimport also clears its descendant exclusions.

**Settings → Library → Reset Library…** lets owners select all storage locations
and administrators select only their grants. Review the preview, confirm, then
enter the current password of the signed-in server account. Approval is one-use,
session/action/body-bound, and expires in two minutes. Changed previews must be
reviewed again. Reset coordinates job cancellation and stream revocation before
transactional catalog deletion. It also removes storage registrations, grants,
exclusions, and associated jobs, so storage must be explicitly added again.

Accounts, devices, server settings, TLS identity, and videos survive. Existing
backups remain and may contain older library data. File cleanup has a persistent
operation receipt and is retried after errors/restarts. A pending cleanup is
reported as pending, not completed; there is no success claim while files remain.

## Devices and backups

The device list shows only non-revoked, unexpired sessions. Acknowledged revocation
removes the row immediately; errors do not pretend it succeeded. While settings
are open, devices refresh every five seconds and when the app becomes active.
Security history can remain in Diagnostics without listing a revoked device as
active.

Encrypted full-server format 2 adds manually imported originals and rendered
crops to the database/configuration/identity backup. Provider artwork remains
recoverable cache, and video files are never included. Version 1 backups remain
readable. Restore validates images and their names/checksums in private staging
before replacing active state. See [SERVER_MANAGEMENT.md](SERVER_MANAGEMENT.md).

## New API surface

All routes below require administrator/owner authorization and library grants:

- `GET/PUT /api/v1/media/{id}/editor` — revisioned editor document/save.
- `POST/GET/DELETE /api/v1/media/{id}/editor/uploads[/{upload}]` — private drafts.
- `GET /api/v1/media/{id}/editor/artwork/{asset}` — authorized uncropped image.
- `GET /api/v1/media/{id}/editor/files?path=…` — same-location file browser.
- `DELETE /api/v1/media/{id}` — title-tree removal and cleanup receipt.
- `GET/DELETE /api/v1/libraries/{id}/exclusions[/{excluded}]` — exclusion/reimport.
- `POST /api/v1/libraries/reset/preview`, `/api/v1/libraries/reset/approval`, and
  `/api/v1/libraries/reset` — selected-library preview, password grant, and reset.
- `GET /api/v1/library-operations/{id}` — private operation/cleanup status.

Normal updates do not reset libraries or revoke sessions. Integration tests
exercise removal/reset only against disposable synthetic libraries, never
personal media. These checks are not an independent security audit.
