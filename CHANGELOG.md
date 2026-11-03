# Changelog

All notable changes to Aurelia are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and new versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Mac/server, Linux, Apple TV and iOS have independent versions. Historical development
builds and the archived desktop client are included; an entry does not imply public
availability. Dates use DD.MM.YYYY. Early Builds 1–11 retain their original 0.1.0
version and individual build numbers. Builds 25, 26, 29 and 30 have no separate
versioned commit, so their skipped numbers are preserved.

## [Unreleased]

## [Mac/server 1.27.9 (133)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.27.9-133) - 03.11.2026

### Changed

- Remove the App Updates button from the main window. Check for Updates remains available in the Aurelia menu before signing in.
- Use a smaller update confirmation with shorter text and a compact area for release notes.

## [Mac/server 1.27.8 (132)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.27.8-132) - 03.11.2026

### Changed

- Provide a separate release to verify installation and automatic relaunch from the repaired Mac updater in 1.27.7.

## [Mac/server 1.27.7 (131)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.27.7-131) - 03.11.2026

### Fixed

- Keep the Mac installer visible with a native progress window and menu-bar item instead of submitting an invisible background update job that macOS can terminate after the app quits.
- Offer App Updates on startup, connection, resting and profile-selection screens without requiring a server connection or profile PIN.
- Keep client update settings independent of server administration requests and errors; limit the optional server sign-out request to two seconds during a client update.

## [Mac/server 1.27.6 (130)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.27.6-130) - 03.11.2026

### Fixed

- Package the independent installer and automatic relaunch for the normal update from the repaired 1.27.5 preparation, using the owner's temporarily public main repository without reading a saved token.

## [Mac/server 1.27.5 (129)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.27.5-129) - 03.11.2026

### Fixed

- Run Mac installation in an independent, one-shot worker. macOS was terminating the hidden subordinate helper when Aurelia exited, interrupting replacement and relaunch after a successful download.
- Remove the transient worker job after completion without installing a login item or changing background-host preferences.
- Point the explicitly enabled anonymous Mac update test at the main Aurelia repository, as requested, while preserving saved tokens without reading or sending them. Normal authenticated updates still work after the repository becomes private again.

## [Mac/server 1.27.4 (128)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.27.4-128) - 03.11.2026

### Fixed

- Package the verified asynchronous quit repair for the normal update from the repaired 1.27.3 preparation, retaining signature checks, automatic relaunch and existing app data.

## [Mac/server 1.27.3 (127)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.27.3-127) - 03.11.2026

### Fixed

- Finish asynchronous playback, connection and local-host cleanup before the final AppKit quit request. The previous update could enter a nested termination loop and leave Aurelia open until the installer timed out.
- Coalesce repeated quit requests while cleanup is running, then accept termination only after cleanup completes.

## [Mac/server 1.27.2 (126)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.27.2-126) - 03.11.2026

### Fixed

- Package the sandbox-safe installer handoff and exact request acknowledgement for the normal update from the repaired 1.27.1 preparation build.
- Retain Dialogue Boost, Volume Leveling and existing settings, with installation outcomes recorded separately from download success.

## [Mac/server 1.27.1 (125)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.27.1-125) - 03.11.2026

### Fixed

- Hand updates from the sandboxed app to its same-team helper through a bounded, single-use request in their existing App Group. macOS discards NSWorkspace launch arguments from sandboxed callers.
- Wait for acknowledgement of the exact request and build before quitting; show a clear failure and keep the app open when the helper does not acknowledge.
- Start installation after Launch Services completes helper launch, then record success or failure for the next app start.
- Validate request age, filename, UUID directory, file type and size; reject symlinks and replayed requests.

## [Mac/server 1.27.0 (124)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.27.0-124) - 02.11.2026

### Added

- Independent Dialogue Boost choices (Off, Standard, Strong) and Volume Leveling choices (Off, Standard, Sleep) in Playback settings and the player’s Audio menu.
- Speech equalizer curves with headroom, mapped to VLC’s actual frequency bands; stronger Sleep compression for quiet/loud transitions.
- Visible errors when the installed VLC lacks the required audio filters; processing stays local and leaves media files unchanged.

### Changed

- Migrate saved Night Mode to Volume Leveling Standard while retaining other settings and track preferences.
- Preserve the complete compressor/equalizer chain and reopen at the same position with pause, speed and track choices when a combined-filter change requires it.

## [Linux app 1.1.0 (9)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/linux-app-1.1.0-9) - 02.11.2026

### Added

- Independent Dialogue Boost choices (Off, Standard, Strong) and Volume Leveling choices (Off, Standard, Sleep) in Playback settings and the player’s Audio menu.
- Speech equalizer curves with headroom, mapped to VLC’s actual frequency bands; stronger Sleep compression for quiet/loud transitions.
- Visible errors when the installed VLC lacks the required audio filters; processing stays local and leaves media files unchanged.

### Changed

- Migrate saved Night Mode to Volume Leveling Standard while retaining other settings and track preferences.
- Preserve the complete compressor/equalizer chain and reopen at the same position with pause, speed and track choices when a combined-filter change requires it.

## Apple TV 1.4.0 (26) - 02.11.2026

### Added

- Independent Dialogue Boost choices (Off, Standard, Strong) and Volume Leveling choices (Off, Standard, Sleep) in Playback settings and the player’s Audio menu.
- Speech equalizer curves with headroom, mapped to VLC’s actual frequency bands; stronger Sleep compression for quiet/loud transitions.
- Visible errors when the installed VLC lacks the required audio filters; processing stays local and leaves media files unchanged.

### Changed

- Migrate saved Night Mode to Volume Leveling Standard while retaining other settings and track preferences.
- Preserve the complete compressor/equalizer chain and reopen at the same position with pause, speed and track choices when a combined-filter change requires it.

## iOS 1.1.0 (5) - 02.11.2026

### Added

- Independent Dialogue Boost choices (Off, Standard, Strong) and Volume Leveling choices (Off, Standard, Sleep) in Playback settings and the player’s Audio menu.
- Speech equalizer curves with headroom, mapped to VLC’s actual frequency bands; stronger Sleep compression for quiet/loud transitions.
- Visible errors when the installed VLC lacks the required audio filters; processing stays local and leaves media files unchanged.

### Changed

- Migrate saved Night Mode to Volume Leveling Standard while retaining other settings and track preferences.
- Preserve the complete compressor/equalizer chain and reopen at the same position with pause, speed and track choices when a combined-filter change requires it.

## [Mac/server 1.26.6 (123)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.26.6-123) - 02.11.2026

### Fixed

- Keep offering a validated newer release after GitHub answers with HTTP 304; save the release and ETag together, separately for each update source.
- Check both the semantic version and increasing build number before offering a Mac update.

### Added

- Explicit Public Update Test setting for anonymous downloads from the separate test repository, preserving saved tokens without reading them.
- Shared product version table in the README and regular release descriptions.

## [Linux app 1.0.2 (8)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/linux-app-1.0.2-8) - 02.11.2026

### Fixed

- Search GitHub release pages beyond the first 100 entries; report an incomplete check when the bounded search cannot finish.
- Keep downloaded packages and checksum addresses tied to the selected update source.

### Added

- Public Update Test setting with anonymous metadata, checksum and package requests; saved GitHub credentials remain untouched.
- Bounded request diagnostics that record only the host and presence of Authorization, without tokens or signed URLs.

## [Mac/server 1.26.5 (122)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.26.5-122) - 02.11.2026

### Added

- MIT license with Copyright (c) 2026 Lucas Kleinsteuber, included in new app and server packages.

### Changed

- Replace separate build reports with one changelog covering the committed history from Build 1.
- Use day-month-year dates and expand notable changes from historical build reports and release descriptions.

### Fixed

- Episode results in search and watch history use the selected series poster when the episode has no poster of its own.
- Honor manually selected series covers and retain the original episode title, identity and season/episode details.
- Keep artwork access restricted to the profile's permitted library.

## [Mac/server 1.26.4 (121)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.26.4-121) - 02.11.2026

### Fixed

- Embed the renamed GitHub repository in the Mac app and Linux server packages.
- Check release metadata and download assets against the canonical address.
- Keep strict repository and authentication checks during updates.

## [Linux app 1.0.1 (7)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/linux-app-1.0.1-7) - 02.11.2026

### Fixed

- Request release metadata from the renamed GitHub repository.
- Validate package and checksum assets against the canonical repository while retaining strict redirect and token handling.
- Update the private-token instructions and package homepage links.

## [Apple TV 1.3.2 (25)](https://github.com/lucaskleinsteuber/Aurelia/commit/b2604b903e2a09d5c355d0b2e3d926e694827956) - 02.11.2026

### Added

- Include the MIT license and copyright notice in the app.

### Fixed

- Stop showing a blocking Playback Progress dialog when a restored local update conflicts with newer server progress at startup.
- Retain the newer server position, refresh the library and keep active-player conflict protection.
- Continue reporting actual storage failures rather than hiding them with routine synchronization.

## [iOS 1.0.3 (4)](https://github.com/lucaskleinsteuber/Aurelia/commit/d5dfdc11bb3d76204ee9daf8429e5c801602242f) - 02.11.2026

### Added

- Include the MIT license and copyright notice in the app.

### Fixed

- Center the profile avatars, including a single profile and the final partially filled row.
- Remove the fixed dark strip above Home so hero artwork continues beneath the status bar.
- Identify episode search results with the series name and season/episode number.
- Reconcile newer server progress silently in the background while keeping real save failures visible.

## [Linux app 1.0.0 (5, 6)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/linux-app-1.0.0-6) - 01.11.2026

### Added

- Browse Home, movies, TV shows, collections, Watchlist, history and statistics; manage metadata, profiles, devices, storage, imports, backups and server settings.
- Use the player with chapters, audio and subtitle choices, scene notes, Up Next, Play On, progress recovery and timeline previews. Server preview failures fall back to a separate silent local still decoder. Playback diagnostics can be exported without title names, addresses, file paths or credentials.
- Set up the bundled server, recover an owner PIN with the Server Password, keep hosting in the background and open the same running app from the launcher or a terminal, even when their temporary directories differ. Network changes use a 60-second trial that reverts unless the new trusted connection is confirmed.
- Check Linux app releases from Settings, verify the downloaded package against its SHA-256 checksum, and confirm installation through the distribution's package manager. Private-repository tokens stay in a separate desktop-keyring entry.

## [Linux app 0.3.0 (4)](https://github.com/lucaskleinsteuber/Aurelia/commit/816f6ebf0953171b007a1c80d2efab6be71ab7ab) - 01.11.2026

### Added

- Supervised local hosting, first-run setup, PIN recovery and reversible network changes.
- Set up the owner profile, choose initial storage locations and recover a forgotten owner PIN with the Server Password.
- Supervise the bundled server, handle occupied ports and keep hosting in the background.
- Revert unconfirmed network changes after a 60-second trial.

## [Mac/server 1.26.3 (120)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.26.3-120) - 31.10.2026

### Changed

- History and Statistics now live in Settings › Activity. They no longer appear in the sidebar unless you turn them on in the sidebar settings.

### Fixed

- History and Statistics in the sidebar no longer leave an empty strip the width of the sidebar. The Watchlist and Collections headings line up with their content again.
- The statistics chart always shows the last twelve weeks, so a short history shows narrow bars instead of one wide block.

## [Mac/server 1.26.2 (119)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.26.2-119) - 31.10.2026

### Fixed

- Smart lists choose titles by their rules again. Before, every smart list showed the whole library. Lists you already saved work without changes. "Match any rule" now applies to all rules.
- Merging a missing copy into another one (Library Health) keeps every profile's favorites, progress and history, not only those of the administrator who merges.
- Watch history counts only titles a profile may see, so paging works for profiles with selected titles. Clearing history still removes everything.
- "Play On" works on the Mac: it lists other players again and follows commands.
- Subtitle files next to the video: SRT files with times like 0:00:01,000 now show in the browser, and the server keeps less of them in memory.
- Only text subtitle files are requested, not bitmap files the server cannot convert.

### Security

- The server now runs on .NET 10.0.14. Since 10.0.11, the version used before, Microsoft has published three security updates. Image decoding (SkiaSharp), the database (SQLite via EF Core 10.0.14) and network discovery are also on their latest patches.
- On Linux, the status and power-saving files in the server's data folder are now written by the server's own user. Before, a compromised server process could have used them to take over other files on the computer.

## [Mac/server 1.26.1 (118)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.26.1-118) - 31.10.2026

### Fixed

- A server that saves power now sleeps while you work in other apps on your Mac. Aurelia used to count any keyboard or mouse use on the Mac as using Aurelia, so it never let go of the server. Now only using Aurelia itself counts. When another app is in front, Aurelia lets go of the server after the time set in Settings › Interface (15 minutes unless you changed it). A click in Aurelia connects again and wakes the server.

## [Mac/server 1.26.0 (117)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.26.0-117) - 31.10.2026

### Added

- Settings › Activity: your statistics and your watch history in one place, switchable at the top. The History and Statistics pages in the sidebar show the same.
- Watch time reads the way you'd say it: "45 min", "2 h 5 min", "3 days 4 h", not tenths of an hour.
- Statistics: total watch time with the past 7 and 30 days, streaks, how much you finish, when you watch most, the last 12 weeks as a chart (point at a week for its time), your most watched titles and favorite genres by time, and a year in review.
- History: grouped by day ("Today", "Yesterday", then the date), with how long each sitting lasted and how far you got.

### Fixed

- The browser app's statistics showed missing values; they now use what the server sends and read in minutes, hours and days too.
- The server reports watch time to the second instead of in six-minute steps.
- The Mac app is smaller: it no longer carries Intel code.

## [Mac/server 1.25.1 (116)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.25.1-116) - 31.10.2026

### Fixed

- Settings that did nothing now take effect, in the Mac app and the browser: languages for sound and subtitles, Up Next timing, where playback resumes, poster size, hidden watched titles, reduced motion and the start screen. Options that could not work were removed.
- The Mac app opens where you left it again by default.
- Settings › Server shows hosting, pairing, background jobs and diagnostics again, and Profiles and Devices shows the full profile list with its safety checks again.
- Library Health finds real duplicates and offline titles. Moving watch data between two copies of a title and removing an offline title are safe and keep favorites.
- Watch history shows when you actually watched, in your time zone, and groups episodes under their series.
- Statistics count only time you really watched, not paused or skipped time.

## [Linux app 0.2.0 (3)](https://github.com/lucaskleinsteuber/Aurelia/commit/dcb6eb89bccdebe53e8c1acb9000553ad45d4fc9) - 31.10.2026

### Changed

- Content beneath native window chrome, desktop window controls and a clearer welcome screen.
- Use the desktop window-button order and native resize behavior.
- Offer a welcome flow for connecting to another server or setting up this computer.

## [Linux app 0.1.0 (2)](https://github.com/lucaskleinsteuber/Aurelia/commit/612fdf372584d35c12f42fb69b6970b149e87ba0) - 31.10.2026

### Added

- Independent native Linux app foundation, design system and platform adapters.
- Native sidebar and application shell with a dedicated Linux version counter.
- Small platform adapters for desktop integration and reproducible build and test scripts.

## [Apple TV 1.3.1 (24)](https://github.com/lucaskleinsteuber/Aurelia/commit/a2ee41a3ca3cb047d2afba287559c06aff856d46) - 31.10.2026

### Changed

- Decode remote command timestamps in the server format.
- Handle unnamed subtitle tracks and load only actual sidecar files as external subtitles.

### Fixed

- Remote Play On commands and subtitle lists with unnamed tracks.

## [iOS 1.0.2 (3)](https://github.com/lucaskleinsteuber/Aurelia/commit/647d65b5fe31151621adb26b8a5e3e23060d0796) - 31.10.2026

### Fixed

- Profile progress synchronization and subtitle-track decoding.
- Apply synchronized profile progress without losing newer local samples.
- Decode subtitle tracks whose optional title is missing.

## [iOS 1.0.1 (2)](https://github.com/lucaskleinsteuber/Aurelia/commit/a2ee41a3ca3cb047d2afba287559c06aff856d46) - 31.10.2026

### Fixed

- Remote Play On commands and subtitle lists with unnamed tracks.
- Decode remote command timestamps in the server format.
- Keep external subtitle loading limited to actual sidecar files.

## [iOS 1.0.0 (1)](https://github.com/lucaskleinsteuber/Aurelia/commit/35b0055785cf716bc0f5d165d3d3489d7db641b2) - 31.10.2026

### Changed

- Compact touch player, full-bleed title pages, activity settings and the Aurelia app icon.
- Size transport controls and track menus for touch, with settings in a compact native sheet.
- Let title artwork fill the top edge and fade into the canvas.
- Add watch history, statistics, profile PIN controls and artwork-cache settings.

## [Mac/server 1.25.0 (115)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.25.0-115) - 30.10.2026

### Added

- Modular Sidebar Customization: Configure your sidebar navigation layout to suit your habits. Freely reorder all items (Home, Library, Movies, TV Shows, Collections, Watchlist, Recently Added, History, Statistics) using up and down controls, toggle visibility of any individual section (including hiding Home if you prefer a direct library flow), and choose your preferred default startup landing screen.
- Activity & Statistics in Settings: New dedicated Activity section in Settings sidebar allowing quick inspection of total watch time, 7-day and 30-day activity, current and longest streaks, title completion rate, favorite genres, viewing habits, and Year in Review directly within application preferences.
- Visual Polish & Focus Fixes: Eliminated the thick system focus/selection outline in the macOS Settings sidebar, replaced with smooth native accent pills and clean dark aesthetics.
- Settings Navigation & Scroll Position: Switching between Settings categories now reliably anchors at the top of each view, resolving previous scroll-offset retention when switching to Playback preferences.
- Resilient Statistics Loading: Hardened UserStatistics decoding with complete optional fallbacks and clear error states with retry controls, alongside informative empty states when no activity has been logged yet.

## [Mac/server 1.24.0 (114)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.24.0-114) - 30.10.2026

### Added

- Dedicated iPhone and iPad Native Client: Brand-new native SwiftUI client for iOS and iPadOS with Bonjour discovery, TLS SPKI fingerprint pinning, multi-profile switcher, direct playback via MobileVLCKit 3.7.3, zero-disk loopback stream relay, and full offline caching.
- Collections v2 & Smart Lists: Create manual collections or dynamic smart lists based on genres, release decade, content ratings, watch status, addition dates, and custom keywords. Browse TMDB movie franchises automatically with one-click collection creation.
- Sidecar Subtitle Support: Automatically discovers external subtitle files (.srt, .ass, .ssa, .vtt) in media folders and Subs/ subfolders. Features in-memory conversion to WebVTT with LRU caching and strict zero-converted-storage guarantees.
- Watch History & Personal Statistics: Private, profile-scoped viewing logs and comprehensive statistics (total watch time, weekly trends, favorite genres, top titles, streaks, and Year in Review).
- Library Health & Maintenance: Administrator tools to inspect duplicate entries, offline titles, and unmatched metadata, with in-place entry merging and preferred-version selection.
- Remote Playback & AirPlay: Integrated Apple TV AirPlay streaming and "Play on Device" remote controls to command active Aurelia players across the home network.

## [Mac/server 1.23.0 (113)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.23.0-113) - 30.10.2026

### Changed

- **Mac:** Aurelia-1.23.0-113-macOS-universal.dmg, for Apple silicon and Intel. Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with `sudo aurelia update` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below.

## [Mac/server 1.22.0 (112)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.22.0-112) - 29.10.2026

### Changed

- **Mac:** Aurelia-1.22.0-112-macOS-universal.dmg, for Apple silicon and Intel. Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with `sudo aurelia update` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below.

## [Mac/server 1.21.0 (111)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.21.0-111) - 29.10.2026

### Added

- Anonymous update checks: Aurelia for Mac checks GitHub releases anonymously without requiring any personal access token.
- Public asset downloads: Update downloads use public release asset URLs (`browser_download_url`) directly on GitHub.
- Conditional update requests: Uses HTTP `If-None-Match` with cached release `ETag` to eliminate rate-limit pressure (GitHub answers `304 Not Modified`).
- Rate-limit friendly handling: Clear, helpful notification if GitHub's anonymous IP rate limit is reached.
- Optional GitHub Token: Stored securely in macOS Keychain under Settings › Updates › Advanced ("Only needed while the repository is private").
- Automatic private repository detection: Checks returning 404 guide the user to configure a token if the repository is private.

## [Mac/server 1.20.0 (110)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.20.0-110) - 29.10.2026

### Changed

- **Mac:** Aurelia-1.20.0-110-macOS-universal.dmg, for Apple silicon and Intel. Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with `sudo aurelia update` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below.

## [Mac/server 1.19.0 (109)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.19.0-109) - 29.10.2026

### Added

- Simplified security model: removed the server-management password wall for routine administrative actions. Owner and Administrator profiles open Server and Library settings directly without entering the Server Password.
- Three-tier action classification (Viewer, Admin, Critical):
- Viewer actions (Watchlist, favorites, progress, mark watched, scene notes, track preferences) require only a profile session.
- Admin actions (storage locations, metadata editing, TMDB key, scrub-preview settings, live conversion limits, power/sleep settings, ordinary profile editing, server updates, device pairings) require an Owner or Admin profile session without password prompt.
- Critical actions (resetting library, restoring backups, factory reset, modifying server password, changing user roles or deleting Owner/Admin profiles) remain strictly guarded by Server Password confirmation.
- Direct management UI: removed "Unlock Server Management" banners and gates from macOS Settings and the WebApp; critical actions display dedicated password confirmation sheets.

## [Apple TV 1.3.0 (23)](https://github.com/lucaskleinsteuber/Aurelia/commit/e07fa0c86e336dc0923bab529d461c656e23ceeb) - 29.10.2026

### Added

- Franchise collections appear on title pages with related movies.
- Load and select sidecar subtitle tracks through the authenticated local relay.

### Changed

- Decode expanded collection and library response fields from newer servers.

## [Apple TV 1.2.0 (22)](https://github.com/lucaskleinsteuber/Aurelia/commit/e9216da80e6faf8254a27d8f3e31048fd3b259f9) - 29.10.2026

### Added

- Watchlists, person pages and server-backed scrub previews.

### Changed

- Show the profile Watchlist on Home and add context-menu actions.
- Open cast and crew person pages with their filmography.
- Prefer server-provided scrub frames and retain a local fallback.

## [Mac/server 1.18.0 (108)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.18.0-108) - 28.10.2026

### Added

- Shared Watchlist and navigable cast and crew pages across macOS and the browser app.
- Player keyboard accessibility improvements: focus rings, VoiceOver and ARIA announcements, Reduce Motion support, and a dedicated Keyboard Shortcuts cheat sheet (? in browser, Help menu on macOS).
- Bulk season and series watched status management from context menus with confirmation dialogs reporting the affected episode count.
- Screen and navigation memory: macOS reopens on the last visited library screen and the browser restores scroll positions on back navigation.
- Friendly error and offline states: guidance when the server is asleep with Wake Server offer, locked, unreachable, or when a file is offline.
- Hardened media container verification in probe parsing rejecting unsafe script or playlist demuxers.

## [Mac/server 1.17.0 (107)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.17.0-107) - 28.10.2026

### Added

- Optional server timeline scrub-preview strips: choose Off (on-demand in memory, default), When a title is opened or played, or After import in Settings › Server on macOS and in the browser.
- Configurable frame interval (5–120 seconds, default 15 seconds) and storage limit (50 MB–10 GB, default 500 MB) with automatic oldest-strip eviction and a Delete All Previews action.
- Background strip extraction runs one frame at a time at low CPU priority and pauses automatically whenever playback or live conversion is active.
- Mac and browser players use the shared cacheable scrub-preview endpoint (`ETag`, `Cache-Control`, `304 Not Modified`) so scrubbing shows timeline frames right away.
- Bundled macOS LGPL FFmpeg now includes `mjpeg` and `image2` support for fast single-frame still extraction to standard output without storing converted video.

## [Mac/server 1.16.2 (106)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.16.2-106) - 28.10.2026

### Changed

- Previous and Next episode now always start at 0:00. Only Resume and Continue Watching pick up where you left off.
- The F7 and F9 keys play the previous and next episode. In the player you can also press P and N, or Command-Shift-Left and Right (listed in the Playback menu). The browser player supports P and N too.
- Skipping to another episode no longer marks the one you left as watched, so Resume points at the right episode again.
- Closing the player when the library was in full screen no longer leaves the window in a broken state without its red, yellow and green controls.
- The scrub preview appears above the player controls instead of covering them, shows frames you have already seen at once and loads nearby frames ahead.
- Right-click menus are the same everywhere, with Play, Resume, Go to Series, watched status, favorites, Remove from Continue Watching and Edit Metadata.

## [Mac/server 1.16.1 (105)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.16.1-105) - 28.10.2026

### Changed

- Starting playback with Now Playing artwork no longer crashes when macOS requests the artwork image on a background queue.
- Media-command and sleep/wake callbacks use explicit thread-safe boundaries.

## [Mac/server 1.16.0 (104)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.16.0-104) - 28.10.2026

### Changed

- The Mac update dialog shows release notes directly, displays the download size, lets you skip a version and adds an automatic daily check toggle in Settings.
- Now Playing in macOS Control Center and media keys now include artwork, 10-second skip controls and next episode.
- Library pages, title details and rescans are significantly faster on large libraries by avoiding redundant search-index rebuilds and repeated folder checks.

## [Mac/server 1.15.0 (103)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.15.0-103) - 28.10.2026

### Changed

- Add Aurelia to a phone or tablet home screen for a full-screen layout with Aurelia icons.
- Check and install Linux server updates directly from the browser under Settings › Server › Updates.
- Browse the full library in pages of 100 titles with year filters, collection pages, scene-note editing and saved audio/subtitle preferences.
- Hide entries from Continue Watching or change watched status for a whole series or season with confirmation.

## [Mac/server 1.14.1 (102)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.14.1-102) - 28.10.2026

### Changed

- The Mac updater removes its downloaded disk image and temporary download folder after both successful and failed updates.

## [Mac/server 1.14.0 (101)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.14.0-101) - 28.10.2026

### Changed

- Embedded text subtitles (SubRip, ASS/SSA, mov_text) now work during live conversion in the browser.
- HDR video (PQ and HLG) is tone-mapped to natural SDR colors when transcoded for the browser.
- Browser Settings can now add or remove storage folders, edit profiles and edit title metadata.
- The Mac updater validates release assets and signatures more strictly and cleans up safely if an update fails.

## [Mac/server 1.13.0 (100)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.13.0-100) - 25.10.2026

### Changed

- **Mac:** Aurelia-1.13.0-100-macOS-universal.dmg, for Apple silicon and Intel. Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with `sudo aurelia update` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below.

## [Mac/server 1.12.1 (99)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.12.1-99) - 25.10.2026

### Changed

- **Mac:** Aurelia-1.12.1-99-macOS-universal.dmg, for Apple silicon and Intel. Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with `sudo aurelia update` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below.

## [Mac/server 1.12.0 (98)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.12.0-98) - 25.10.2026

### Changed

- **Mac:** Aurelia-1.12.0-98-macOS-universal.dmg, for Apple silicon and Intel. Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with `sudo aurelia update` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below.

## [Mac/server 1.11.0 (97)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.11.0-97) - 25.10.2026

### Changed

- **Mac:** Aurelia-1.11.0-97-macOS-universal.dmg, for Apple silicon and Intel. Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with `sudo aurelia update` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below.

## [Mac/server 1.10.0 (96)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.10.0-96) - 24.10.2026

### Changed

- **Mac:** Aurelia-1.10.0-96-macOS-universal.dmg, for Apple silicon and Intel. Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with `sudo aurelia update` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below.

## [Mac/server 1.9.1 (95)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.9.1-95) - 24.10.2026

### Changed

- **Mac:** Aurelia-1.9.1-95-macOS-universal.dmg, for Apple silicon and Intel. Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with `sudo aurelia update` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below.

## [Apple TV 1.1.1 (21)](https://github.com/lucaskleinsteuber/Aurelia/commit/d59980e27a95f453f43440fc956bd310f6ffa12c) - 24.10.2026

### Changed

- Retain known revisions when the app leaves and returns to the foreground.
- Keep the newer server position on conflict and remove rejected pending entries.

### Fixed

- Progress saving after backgrounding and conflicts; rejected entries no longer remain stuck.

## [Apple TV 1.1.0 (20)](https://github.com/lucaskleinsteuber/Aurelia/commit/3be2f58ab2aeb650050064078d5ba639b30c5dff) - 24.10.2026

### Added

- Bounded Wake-on-LAN attempts from the saved-server screen.

### Changed

- Remember the server hardware addresses and recent numeric LAN addresses.
- Keep waking and reconnecting bounded and tied to the trusted saved server.

## [Apple TV 1.0.0 (19)](https://github.com/lucaskleinsteuber/Aurelia/commit/0bbe314998879cf4ae7f7b3e71ce0dc3f87e3a02) - 24.10.2026

### Changed

- First full release with clear saved-server connecting and offline screens.
- Show the remembered server while connecting instead of dropping into the manual setup form.
- Explain when the server does not answer and connect automatically when it returns.

## [Mac/server 1.9.0 (94)](https://github.com/lucaskleinsteuber/Aurelia/commit/16e23ea0b1874ab5b15e028d758a87e9b630ee36) - 23.10.2026

### Changed

- Separate device-pairing guidance for Apple TV, another Mac and browsers.
- Explain which device displays a code and where the owner enters it.
- Keep approval controls limited to the appropriate owner context.

## [Mac/server 1.8.9 (93)](https://github.com/lucaskleinsteuber/Aurelia/commit/47864aac101346c0bb9c0306b346130a020bc576) - 23.10.2026

### Changed

- Refined editable app icon and installed icon registration.
- Preserve editable Icon Composer layers for the Aurelia A and light echo.
- Register the updated installed icon without retaining duplicate app bundles.

## [Mac/server 1.8.8 (92)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.8.8-92) - 23.10.2026

### Changed

- **Mac:** Aurelia-1.8.8-92-macOS-universal.dmg, for Apple silicon and Intel. Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with `sudo aurelia update` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below.

## [Apple TV 0.3.7 (18)](https://github.com/lucaskleinsteuber/Aurelia/commit/fa9f599cc9e373d206723e1ed4ddc2e73e84e27f) - 23.10.2026

### Changed

- Centered colored profile avatars and PIN entry without length hints.
- Use the same profile colors and initials as the Mac client.
- Respect Reduce Motion and avoid showing an expected PIN length.

## [Apple TV 0.3.6 (17)](https://github.com/lucaskleinsteuber/Aurelia/commit/d570b5cec04588498364e99cb8dd8e972baf9eff) - 23.10.2026

### Added

- Layered parallax app icon and Top Shelf artwork.

### Changed

- Use separate background, light-echo and foreground layers for native icon depth.
- Provide matching Top Shelf artwork.

## [Mac/server 1.8.7 (91)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.8.7-91) - 22.10.2026

### Changed

- **Mac:** Aurelia-1.8.7-91-macOS-universal.dmg, for Apple silicon and Intel. Open it and drag Aurelia to Applications. It is signed for development and not notarized, so it runs on the Macs registered for this developer account.
- **Linux server:** the package for x64 or arm64; see docs/LINUX_SERVER.md. Installed servers update with `sudo aurelia update` or in Aurelia on a Mac under Settings › Server › Updates.
- **Source code:** attached by GitHub below.

## [Mac/server 1.8.6 (90)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.8.6-90) - 22.10.2026

### Fixed

- Linux updates reliably query the latest release.

## [Mac/server 1.8.5 (89)](https://github.com/lucaskleinsteuber/Aurelia/releases/tag/1.8.5-89) - 22.10.2026

### Added

- Verified Linux server updates from GitHub releases.

## [Mac/server 1.8.4 (88)](https://github.com/lucaskleinsteuber/Aurelia/commit/449e08c0ec741ea9da553be9172004d1069d3025) - 22.10.2026

### Changed

- Probe the saved address before showing a wake screen.
- Send bounded wake attempts and retry the trusted server while it starts.

### Fixed

- Quick saved-server probes and bounded Wake-on-LAN reconnect attempts.

## [Mac/server 1.8.3 (87)](https://github.com/lucaskleinsteuber/Aurelia/commit/7d7bc7388ce62c45b25989ce588c3903e716d975) - 22.10.2026

### Changed

- Optional awake hours and predictable idle sleep on Linux servers.
- Default to idle sleep without a fixed awake-hours window.
- Clear obsolete RTC alarms when awake hours are turned off.

## [Mac/server 1.8.2 (86)](https://github.com/lucaskleinsteuber/Aurelia/commit/5fa4fd064d89c377f4d1cc9a8017ebad2d1e84b2) - 22.10.2026

### Added

- Server Wake-on-LAN information, quieter logging and sleep after a client sleep timer ends.

### Changed

- Report LAN hardware addresses to paired clients for wake attempts.
- Let the server sleep after a client sleep timer ends when no playback remains active.

## [Mac/server 1.8.1 (85)](https://github.com/lucaskleinsteuber/Aurelia/commit/02d8ee7f6b1d0fd5157cec73aac6554d5b335435) - 22.10.2026

### Changed

- Clear fingerprint verification and pairing steps.
- Make fingerprint verification visible before entering a pairing code.
- Show where to obtain the code on a Mac or Linux server.

## [Mac/server 1.8.0 (84)](https://github.com/lucaskleinsteuber/Aurelia/commit/46503c402c889f4e35d8fae9f9bfbee9dcbcbcaa) - 22.10.2026

### Added

- Self-contained Linux server packages for x64 and arm64 with systemd installation.

### Changed

- Install an unprivileged systemd service with separate program and private data locations.
- Keep media at its original path and provide third-party notices with both architectures.

## [Apple TV 0.3.5 (16)](https://github.com/lucaskleinsteuber/Aurelia/commit/e27fec2092dd905334ba6afe82ab4334466a6afd) - 22.10.2026

### Changed

- Explain when a saved server is not answering and reconnect automatically.
- Show a clear saved-server explanation after bounded connection retries.
- Retry in the background so the library opens when the server becomes available.

## [Apple TV 0.3.4 (15)](https://github.com/lucaskleinsteuber/Aurelia/commit/5fa4fd064d89c377f4d1cc9a8017ebad2d1e84b2) - 22.10.2026

### Changed

- Send the sleep-ended notification for both minute timers and At End of Episode.
- Remain compatible with servers that do not provide this endpoint.

### Fixed

- Notify the server when the sleep timer ends so idle sleep can follow.

## Archived desktop client 0.2.0 (6) - 21.10.2026

### Added

- Library filters, profiles, media administration, scene notes and server settings.
- Add watch-state actions, filtering, sorting and media management.
- Keep content beneath native window chrome and expose dedicated playback settings.
- Provide profiles and server administration in the desktop client.

## [Mac/server 1.7.18 (83)](https://github.com/lucaskleinsteuber/Aurelia/commit/ff2834fcf66dc064d3934818c2935808306a1cc4) - 20.10.2026

### Changed

- Resume a waiting scan even when the storage probe detects the drive before library monitoring does.
- Retain existing identities and viewing state across disconnection.

### Fixed

- Scans resume after a disconnected media drive returns.

## [Mac/server 1.7.17 (82)](https://github.com/lucaskleinsteuber/Aurelia/commit/1698f5633d78104d3038cb0aa2505ecff4b92970) - 20.10.2026

### Changed

- Editable Liquid Glass app icon.

## [Mac/server 1.7.16 (81)](https://github.com/lucaskleinsteuber/Aurelia/commit/b4d98755942fbb473f8a2324d02b16a488ee232e) - 19.10.2026

### Added

- Up Next countdown and faster preparation of subsequent playback.

### Changed

- Show the next queued episode near the end of eligible playback.
- Respect autoplay cancellation and the end-of-episode sleep timer.

## [Apple TV 0.3.3 (14)](https://github.com/lucaskleinsteuber/Aurelia/commit/a24cdaf55d102c51d68c21649976ca1cfa750e8e) - 19.10.2026

### Added

- Timeline previews and Up Next; improved resume and loading presentation.

### Changed

- Open at the saved position, with a fallback seek for containers that ignore it.
- Keep scrub previews in memory and show a restrained loading ring.
- Show an Up Next countdown while respecting autoplay and sleep-timer choices.

## Archived desktop client 0.1.0 (5) - 19.10.2026

### Added

- Windows installer, background hosting, login startup and firewall integration.
- Keep the hosted server running from the notification area after closing its window.
- Support start with Windows and an all-users installer with a firewall rule.
- Ask before removing application data during uninstall.

## Archived desktop client 0.0.4 (4) - 19.10.2026

### Added

- Bundled server hosting and Windows filesystem support.
- Set up and supervise a local server from the desktop app.
- Validate Windows file access without following unsafe links.

## Archived desktop client 0.0.3 (3) - 19.10.2026

### Added

- Library browsing and native playback for the former desktop client.
- Browse title details, seasons and episodes.
- Stream through an authenticated local relay and save profile progress.

## Archived desktop client 0.0.2 (2) - 19.10.2026

### Added

- Server discovery, manual addresses, fingerprint verification and secure pairing.
- Discover local servers through Bonjour or enter a secure server address manually.
- Verify the fingerprint, pair the device and keep credentials separate from ordinary preferences.

## Archived desktop client 0.0.1 (1) - 19.10.2026

### Added

- Initial independent desktop-client shell and Windows build foundation.
- Separate native desktop project with its own version counter and no Mac source linkage.
- Initial platform adapters, design system and build tooling.

## [Mac/server 1.7.15 (79, 80)](https://github.com/lucaskleinsteuber/Aurelia/commit/879ab5a1d4b4f5ada7fb47701febf5501c458a9e) - 18.10.2026

### Changed

- Open the decoder at the saved position and seek again only when needed.
- Fade out the plain loading ring once the picture starts moving.

### Fixed

- Faster opening at the saved position and a restrained loading ring.

## [Mac/server 1.7.14 (78)](https://github.com/lucaskleinsteuber/Aurelia/commit/9ac0a1608c4dfc2b0a9b790d36fe50b72d86c279) - 18.10.2026

### Changed

- Parallel, bounded timeline-preview preparation.
- Respect the server preview-stream capability and bounded concurrent work.
- Keep the pointer-requested preview responsive while background frames are prepared.

## [Mac/server 1.7.13 (77)](https://github.com/lucaskleinsteuber/Aurelia/commit/56610c704aeca9f8bb1e07b8fba3bb735079c91e) - 18.10.2026

### Changed

- Stop preview activity together with the title.
- Do not let preview transport failures trigger a playback reconnect.

### Fixed

- Preview generation uses its own relay and cannot interrupt playback.

## [Mac/server 1.7.12 (76)](https://github.com/lucaskleinsteuber/Aurelia/commit/22004f997d35fd506ac457c5b07fc8c23c660f91) - 18.10.2026

### Added

- Bounded background preparation of in-memory timeline preview images.

### Changed

- Keep generated frames in memory and cap the number of timeline steps for long titles.
- Prepare previews after the main playback source is ready.

## [Mac/server 1.7.11 (75)](https://github.com/lucaskleinsteuber/Aurelia/commit/ae151aceae1101c7ff1b4bfba1c7ff60f26be80a) - 18.10.2026

### Fixed

- Watch-state requests accept the documented title, season and series scopes.

## [Mac/server 1.7.10 (74)](https://github.com/lucaskleinsteuber/Aurelia/commit/5e6a15e3c24c8a725232155f289caf5b8ef3072e) - 18.10.2026

### Added

- Playback end time, remembered per-series tracks and Night Mode.

### Changed

- Account for playback speed when displaying the expected finish time.
- Remember confirmed audio and subtitle choices per series, including subtitles Off.

## [Mac/server 1.7.9 (73)](https://github.com/lucaskleinsteuber/Aurelia/commit/c864b105dd2d5f31f54881e6e7beef8eacc266da) - 18.10.2026

### Changed

- Stop advertising the segment capability and remove its stored timestamps.
- Keep ordinary seeking, subtitles, progress and next-episode behavior.

### Removed

- Intro and credits detection, segment endpoints and skip controls.

## [Mac/server 1.7.8 (72)](https://github.com/lucaskleinsteuber/Aurelia/commit/688ab87e8690b1f7296d5726b71cec2320ab5a77) - 18.10.2026

### Changed

- Stream sample analysis through the pinned local relay.

## [Mac/server 1.7.7 (71)](https://github.com/lucaskleinsteuber/Aurelia/commit/1318bdd94fa24216ba1881f6a1c289730a16008e) - 18.10.2026

### Fixed

- Automatic segment results saving without a separate management unlock.

## [Mac/server 1.7.6 (70)](https://github.com/lucaskleinsteuber/Aurelia/commit/ca417ca01a0d0f9de3d1279b5ea9ee23deb01d1a) - 18.10.2026

### Changed

- Bounded sample-reader waits and background read-ahead.

## [Mac/server 1.7.5 (69)](https://github.com/lucaskleinsteuber/Aurelia/commit/e4ee43711fc6f35b05dfc2b70d63283955e1c9ba) - 18.10.2026

### Changed

- Read analysis audio through a bounded ranged stream instead of the earlier sample-reader path.
- Keep cancellation and read-ahead bounded while detecting intros and credits.

## [Mac/server 1.7.4 (68)](https://github.com/lucaskleinsteuber/Aurelia/commit/b97b5b5ce62f3ff6adb456778d98aecaf53744f0) - 18.10.2026

### Changed

- Visible progress and title counts for segment analysis.
- Show the active title and analyzed/total counts in playback settings.
- Keep manual segment times separate from automatic analysis results.

## [Mac/server 1.7.3 (67)](https://github.com/lucaskleinsteuber/Aurelia/commit/feae7fa0ae737dd70a61a03e16345892504d3dbf) - 18.10.2026

### Fixed

- Audio sample layout and intro-analysis throughput.

## [Mac/server 1.7.2 (66)](https://github.com/lucaskleinsteuber/Aurelia/commit/8ee849f3cf6628b97dcc42dc5334c1e83d5d8130) - 18.10.2026

### Fixed

- Automatic intro detection not starting.

## [Mac/server 1.7.1 (65)](https://github.com/lucaskleinsteuber/Aurelia/commit/a4793e8a41626dacdc7078f35141e4df0630d9d9) - 18.10.2026

### Changed

- Avoid freezing when opening the metadata editor.
- Correct Continue Watching removal requests and restart detection work after failures.

### Fixed

- Metadata editor hangs, Continue Watching removal and detection startup.

## [Mac/server 1.7.0 (64)](https://github.com/lucaskleinsteuber/Aurelia/commit/d33deb1484c2c372348c0fdf103d7564b2b0630c) - 18.10.2026

### Added

- Intro and credits segment detection and skip controls; later removed in 1.7.9.

### Changed

- Read chapter-based, detected or manually entered segment times.
- Keep detected timestamps separate from original media files.

## [Mac/server 1.6.7 (63)](https://github.com/lucaskleinsteuber/Aurelia/commit/4a72fa950c2d6015a9cf3744fb854728ed299613) - 18.10.2026

### Changed

- Show a dedicated metadata-edit pencil for authorized profiles.
- Make the entire circular More Actions control clickable.

### Fixed

- Visible metadata editing and a fully clickable More Actions control.

## [Mac/server 1.6.6 (62)](https://github.com/lucaskleinsteuber/Aurelia/commit/4b0beec0f48ca06b824c8ce0f62a7c1058781e26) - 18.10.2026

### Changed

- Visible library filter chips with compact genre and year controls.
- Combine media type, favorites and watched-state chips.
- Choose genres and year ranges in compact popovers.

## [Apple TV 0.3.2 (13)](https://github.com/lucaskleinsteuber/Aurelia/commit/d618460079202f63b0a0de30914df80f0c60e122) - 18.10.2026

### Added

- Playback end time, remembered per-series tracks and Night Mode.

### Changed

- Calculate Ends at using the active playback speed.
- Remember confirmed audio and subtitle choices per series, including Off.

## [Apple TV 0.3.1 (12)](https://github.com/lucaskleinsteuber/Aurelia/commit/07e58f12ef71065a7c111c6e2e9a65e72ac07237) - 18.10.2026

### Changed

- Return to ordinary seeking and next-episode behavior without requesting segment times.

### Removed

- Intro and credits skip controls and segment requests.

## [Apple TV 0.3.0 (11)](https://github.com/lucaskleinsteuber/Aurelia/commit/92a5cca637628f23c58f1e866376355c2dcf593e) - 18.10.2026

### Added

- Intro and credits skip controls; later removed in 0.3.1.

### Changed

- Show Skip Intro or Skip Credits only within the corresponding server-provided interval.
- Remain compatible with older servers that provide no segment information.

## [Mac/server 1.6.5 (61)](https://github.com/lucaskleinsteuber/Aurelia/commit/722fa3170562071ce77e62836d5d091613d24974) - 17.10.2026

### Security

- Hardened server validation and resource bounds after an authentication and storage review.

## [Mac/server 1.6.4 (60)](https://github.com/lucaskleinsteuber/Aurelia/commit/8bbeee1ef9caa619638839ecc6bf62e9956f0c6f) - 17.10.2026

### Changed

- Reuse pinned server connections for faster browsing and artwork loading.
- Reuse connections only within the same host, port and pinned server identity.
- Keep certificate verification active on every new connection.

## [Mac/server 1.6.3 (59)](https://github.com/lucaskleinsteuber/Aurelia/commit/94b8924677644d2e19c1e80b0dcac76702c33a14) - 17.10.2026

### Changed

- Consistent pressed and hover feedback on media cards.
- Use one pressed-card response for posters, collections, episodes and Continue Watching.
- Add restrained pointer lift, shadows and borders.

## [Mac/server 1.6.2 (58)](https://github.com/lucaskleinsteuber/Aurelia/commit/d70b59365a604911fe5253c137aa5ede0aaa269e) - 17.10.2026

### Changed

- Show title details immediately from already loaded information.
- Draw the first detail frame from already loaded or prepared title information.
- Fill in the full details without clearing the initial artwork and title.

## [Mac/server 1.6.1 (57)](https://github.com/lucaskleinsteuber/Aurelia/commit/0afe17a755a220bdc186ddaddf4250db88776247) - 17.10.2026

### Changed

- Prepare title details and artwork on hover for faster opening.
- Prepare the hovered title after a short delay and warm the Home hero immediately.
- Expire prepared details when their profile session or short validity window changes.

## [Mac/server 1.6.0 (56)](https://github.com/lucaskleinsteuber/Aurelia/commit/699246da118357355799a2f4808b4d74e740da13) - 17.10.2026

### Changed

- Persistent profile-scoped artwork caching and larger, more efficient catalog pages.
- Scope persistent artwork to the server, profile, revision and requested size.
- Return unchanged artwork without reopening its original file.
- Reduce catalog requests with larger revisioned pages.

## [Mac/server 1.5.10 (55)](https://github.com/lucaskleinsteuber/Aurelia/commit/f1fb9037a6ce279beb0d5dc740e5d8028670ff6b) - 17.10.2026

### Changed

- Server settings arranged into everyday controls and advanced administration.
- Present server status, network access, devices and storage first.
- Keep less frequent maintenance and diagnostic controls in an advanced section.

## [Mac/server 1.5.9 (54)](https://github.com/lucaskleinsteuber/Aurelia/commit/06e8b1c4d0d94377d73680856de79c7c31100522) - 17.10.2026

### Changed

- Finish a complete library snapshot before applying a queued Home-only refresh.
- Avoid replacing the catalog with a partial response after saving progress.

### Fixed

- Home refreshes racing with complete library snapshots.

## [Mac/server 1.5.8 (53)](https://github.com/lucaskleinsteuber/Aurelia/commit/2791a1b0a8890548229c8fdbf490ea3ae7027cad) - 17.10.2026

### Changed

- Faster, bounded artwork variant generation and scaled image decoding.
- Generate different artwork sizes concurrently within a small bounded worker pool.
- Serve cached variants immediately and decode JPEGs near their target size.

## [Mac/server 1.5.7 (52)](https://github.com/lucaskleinsteuber/Aurelia/commit/b40ba007da2393afe6b38709b6332741e9ea4305) - 17.10.2026

### Changed

- Explain that profile PINs contain four to eight digits.
- Show invalid PIN input clearly instead of leaving an unexplained disabled Save button.

### Fixed

- Clear numeric PIN requirements and validation.

## [Apple TV 0.2.0 (10)](https://github.com/lucaskleinsteuber/Aurelia/commit/81edd3de50dd4b62e369053136781450a7bcbdbc) - 17.10.2026

### Added

- Persistent, bounded artwork caching and efficient catalog pagination.

### Changed

- Load unchanged posters from a profile-scoped disk cache after restarting.
- Bound artwork storage and invalidate changed revisions automatically.
- Keep revisioned library pagination efficient.

## [Apple TV 0.1.8 (9)](https://github.com/lucaskleinsteuber/Aurelia/commit/e22ae840fc19a08dfd1b5c129659e164d24ffb80) - 17.10.2026

### Changed

- Reuse pinned stream-relay connections for faster seeking.
- Pool a small number of upstream sessions for successive range requests.
- Keep every reused session tied to its pinned server identity.

## [Apple TV 0.1.7 (8)](https://github.com/lucaskleinsteuber/Aurelia/commit/e3e130c0bb6534c08a7496afe74898693ef1e249) - 17.10.2026

### Changed

- Enter catalog grids, cast, trailers and extras at their first card.
- Let left and right skip immediately when player controls are hidden.

### Fixed

- Grids and shelves focus their first card; hidden-player directional skipping works immediately.

## [Apple TV 0.1.6 (7)](https://github.com/lucaskleinsteuber/Aurelia/commit/087db3d697cb559446fa6e29dd3269a5cbc84f88) - 17.10.2026

### Added

- Trailers, extras and grouped cast information; improved playback settings.

### Changed

- Show series and season extras alongside trailers.
- Group repeated cast and crew credits into one person card.

## [Apple TV 0.1.5 (6)](https://github.com/lucaskleinsteuber/Aurelia/commit/063954b0b1f6c356a6a14a5b444aa3315b2ae0b9) - 17.10.2026

### Changed

- Reuse one pinned session per server instead of establishing a connection for every request.
- Keep unavailable titles reachable and explain disconnected storage.

### Fixed

- Faster browsing through connection reuse, predictable focus and offline title access.

## [Apple TV 0.1.4 (5)](https://github.com/lucaskleinsteuber/Aurelia/commit/3cb30fb66f1d139584e02047f9d1ea5ff8c0c800) - 17.10.2026

### Changed

- Request supported artwork sizes so episode stills load again.
- Play the Continue Watching target directly and improve movie and series loading.

### Fixed

- Episode artwork, direct Continue Watching playback, catalog loading and clipped player menus.

## [Apple TV 0.1.3 (4)](https://github.com/lucaskleinsteuber/Aurelia/commit/df3a1460f4e07156cc72b01af8e41e43580c2975) - 17.10.2026

### Changed

- Mac-style Home, centered profiles, numeric PIN entry and calmer remote controls.
- Use a full-bleed hero and landscape Continue Watching cards.
- Keep profile rows centered and enter numeric PINs without the system keyboard.
- Keep focus visible over bright artwork and simplify playback settings.

## [Apple TV 0.1.2 (3)](https://github.com/lucaskleinsteuber/Aurelia/commit/0b149f61a13afa863cbf46e2cb4d240f3a4f003d) - 17.10.2026

### Changed

- Derive playing, paused, stalled and ended states from actual decoder observations.
- Do not count a resume jump or manual seek as watched time.
- Add favorites, watch-state actions, filters and shared library browsing.

### Fixed

- Playback state, saved progress, scrub seeking and everyday library actions.

## [Mac/server 1.5.6 (51)](https://github.com/lucaskleinsteuber/Aurelia/commit/3740fbe327ee3e3185da5a00572ce72c1a0364ee) - 16.10.2026

### Added

- Confirmed profile deletion from Users & Access, preserving protected owner profiles.

### Changed

- Require an unlocked owner and confirmation of the named profile.
- Protect the current profile and the final enabled owner.

## [Mac/server 1.5.5 (50)](https://github.com/lucaskleinsteuber/Aurelia/commit/657b8b766cec75fe3b86b03e1564e69a95d05cde) - 16.10.2026

### Changed

- Resolve the actual Bonjour service host and port, including IPv4 and IPv6 addresses.
- Recover the bundled server with bounded retries after an unexpected exit.

### Fixed

- Bonjour resolution, saved-server reconnects and supervised server hosting.

## [Apple TV 0.1.1 (2)](https://github.com/lucaskleinsteuber/Aurelia/commit/3db4cb1a392601963bfc224dd2cff6df72984586) - 16.10.2026

### Changed

- Reveal hidden controls without triggering the newly focused button.
- Keep all transport controls reachable and resume the correct series episode.

### Fixed

- Remote focus, hidden player controls and series resume.

## [Apple TV 0.1 (1)](https://github.com/lucaskleinsteuber/Aurelia/commit/45fc224de763548761c63b867029fc30b06d2bc5) - 16.10.2026

### Added

- Independent native Apple TV client with secure discovery, pairing, profiles, browsing and playback.

### Changed

- Discover a server or enter its address, verify its fingerprint and approve the device from an existing client.
- Keep device credentials in Keychain and unlock viewing profiles separately.
- Browse movies, series and title details with the remote.

## [Mac/server 1.5.4 (49)](https://github.com/lucaskleinsteuber/Aurelia/commit/1d8a1de9e802c93d8b61227a3a59fde264e7410f) - 15.10.2026

### Changed

- Apply access restrictions and filters before result counts and pagination.
- Propagate renamed series titles into episode search without inventing a different default sort.

### Fixed

- Consistent filtered search, correct relevance ordering and renamed-series episode results.

## [Mac/server 1.5.3 (48)](https://github.com/lucaskleinsteuber/Aurelia/commit/d75265cb87a20909326f6bd154e3395261bfb08a) - 15.10.2026

### Added

- Consistent series resume plans, watch-state actions, shared browsing and disconnected-drive status.

### Changed

- Share one series playback plan between title details, search and Continue Watching.
- Support title, season and series watch-state actions while retaining disconnected media.

## [Mac/server 1.5.2 (47)](https://github.com/lucaskleinsteuber/Aurelia/commit/0602016988b521fe7bbba60194497047e054be63) - 14.10.2026

### Changed

- Center wrapped avatar rows and reserve a consistent name area.
- Keep the sidebar opaque and support the native fullscreen shortcut.

### Fixed

- Centered profile avatars, PIN entry, opaque sidebar and fullscreen shortcuts.

## [Mac/server 1.5.1 (46)](https://github.com/lucaskleinsteuber/Aurelia/commit/b4b52764fcf3f042f970dd47824cb54609b04b07) - 14.10.2026

### Changed

- Optional PINs for ordinary profiles and consistent protected server administration.
- Allow ordinary profiles without a PIN while owners and administrators retain a numeric PIN.
- Use consistent management-password checks for protected server operations.

## [Mac/server 1.5.0 (45)](https://github.com/lucaskleinsteuber/Aurelia/commit/6e9f850b46ff0de8fe05a2d0a2c79c79157e7bc0) - 13.10.2026

### Added

- PIN-protected viewing profiles, personal scene notes and compact player controls.

### Changed

- Keep profile progress and scene notes separate between viewers.
- Release the player cursor and interaction state cleanly on errors, exit and focus loss.

## [Mac/server 1.4.2 (44)](https://github.com/lucaskleinsteuber/Aurelia/commit/9da5c390e5acf542f8dc422e8cff9689bee4a2b6) - 13.10.2026

### Changed

- Split large network callbacks into bounded chunks.
- Apply cancellation-aware backpressure without buffering an entire media file.

### Fixed

- Bounded streaming through the authenticated Direct Play relay.

## [Mac/server 1.4.1 (43)](https://github.com/lucaskleinsteuber/Aurelia/commit/9bdbbaaa867f433f8af5fefc0278a352af305b84) - 10.10.2026

### Changed

- Preserve the exact progress mutation when a request may have succeeded before its response was lost.
- Keep newer local samples while an older write is being acknowledged.

### Fixed

- Durable, idempotent progress saving across interruptions and safer device pairing.

## [Mac/server 1.4.0 (42)](https://github.com/lucaskleinsteuber/Aurelia/commit/793715aa6fd979551eecf2db913fbb0f830d75d1) - 07.10.2026

### Changed

- Authorize playback against the opened source file rather than stale scanner availability.
- Keep replay and next-episode transitions consistent after interruptions.

### Fixed

- Playback interruption, replay, episode advancement and server/client recovery.

## [Mac/server 1.3.2 (41)](https://github.com/lucaskleinsteuber/Aurelia/commit/2f27e9a3c6a589a446e6f6e828fe83039ebdce43) - 04.10.2026

### Fixed

- Continuous hero artwork on Home and collection pages.

## [Mac/server 1.3.1 (40)](https://github.com/lucaskleinsteuber/Aurelia/commit/34c8af0c6145757521fa9682b43dd554b94dfe83) - 04.10.2026

### Fixed

- Continuous, aspect-filled artwork on title pages.

## [Mac/server 1.3 (39)](https://github.com/lucaskleinsteuber/Aurelia/commit/817c098aabae8e085f7257fd010c2e4678323ba8) - 04.10.2026

### Changed

- Fullscreen composition and manual metadata matching.
- Keep the sidebar toggle clear of fullscreen window controls.
- Improve the manual metadata-match workflow without resetting the library.

## [Mac/server 1.2.6 (38)](https://github.com/lucaskleinsteuber/Aurelia/commit/323faa0e50f43169a9bf8e56119b433eec3d2ea6) - 03.10.2026

### Changed

- Keep verified local ownership when reconnecting to a hosted server.
- Reject invalid test-launch configurations before they can access normal host settings.

### Fixed

- Local-host identity retention and isolated preflight startup.

## [Mac/server 1.2.5 (37)](https://github.com/lucaskleinsteuber/Aurelia/commit/2ce6428ba702b72b077450842e32c7746ae55052) - 03.10.2026

### Changed

- Treat duplicate hover and focus-end callbacks idempotently.
- Keep the video tracking area stable when the layout updates.

### Fixed

- Player controls repeatedly hiding and reappearing without input.

## [Mac/server 1.2.4 (36)](https://github.com/lucaskleinsteuber/Aurelia/commit/ee1f62bf8b0c4b496d1ca003c520cdfd4b62b5ab) - 03.10.2026

### Changed

- Open the selected movie or episode directly from Continue Watching.
- Retain the correct resume target when saved progress and Home refreshes overlap.

### Fixed

- Continue Watching refreshes and direct resumption of the selected episode.

## [Mac/server 1.2.3 (35)](https://github.com/lucaskleinsteuber/Aurelia/commit/e62adfe16b9056af8978148dead18c764b90f649) - 03.10.2026

### Changed

- Consistent card paging, title information, collection controls and settings layout.
- Page through complete cards in episode, trailer, people and Home shelves.
- Keep consistent native controls for title information, collections and settings.

## [Mac/server 1.2.1 (33, 34)](https://github.com/lucaskleinsteuber/Aurelia/commit/dc4193948012ca51e2be5dfc289f7d21f4ed07be) - 02.10.2026

### Added

- Native metadata editor and editable import previews with contextual title and episode matching.

### Changed

- Review and edit a complete import preview before a newly added storage location starts scanning.
- Edit general metadata, release details, credits, artwork and protected file bindings in a resizable native editor.
- Keep confirmed review decisions and manual metadata during rescans.

## [Mac/server 1.2 (32)](https://github.com/lucaskleinsteuber/Aurelia/commit/df2f566ca5ab14b8f1eaeeb86f439d0442260754) - 01.10.2026

### Added

- Server settings, library access controls, devices, diagnostics and backup administration.

### Changed

- Separate network, hosting, users, devices, jobs, backups and diagnostics in native settings.
- Apply library grants consistently to search, details, artwork and streaming.

## [Mac/server 1.1.2 (21, 22, 23, 24, 27, 28, 31)](https://github.com/lucaskleinsteuber/Aurelia/commit/aaa51ac376592e72b371cedc265d6259d01ac1e2) - 29.09.2026

### Changed

- Let title artwork fade into the canvas while maintaining a softened sidebar backdrop.
- Align Home and detail shelves with a consistent left gutter.
- Simplify movie and series information and restore matching development profiles.

### Fixed

- Full-bleed hero artwork, sidebar spacing, readable title information and development signing.

## [Mac/server 1.1.1 (20)](https://github.com/lucaskleinsteuber/Aurelia/commit/f83e63c4a5d8caebb1ec83319cab00fcb77acab9) - 24.09.2026

### Added

- Aurelia app icon, verified database backups and safer database recovery.

### Changed

- Include committed SQLite WAL data in verified backups.
- Retain daily and weekly snapshots and stop upgrades when required backup or integrity checks fail.

## [Mac/server 1.1.0 (19)](https://github.com/lucaskleinsteuber/Aurelia/commit/b6754d2b10805dd4586dc9b61fcfb352f688b109) - 24.09.2026

### Changed

- Resolve imported movie, season and episode structures more consistently.
- Keep uncertain metadata matches available for review instead of silently choosing one.

### Fixed

- More reliable import and metadata matching.

## [Mac/server 1.0.18 (18)](https://github.com/lucaskleinsteuber/Aurelia/commit/010a7cdd62b2ce4aaa2ec427a01c5285fc0c4aa3) - 23.09.2026

### Added

- Trailer discovery with persistent manual assignment and import-review decisions.

### Changed

- Automatically attach an explicitly named trailer only when one movie is an exact match.
- Let administrators assign ambiguous trailers or ignore them without changing the media files.

## [Mac/server 1.0.17 (17)](https://github.com/lucaskleinsteuber/Aurelia/commit/1987933928b693de2683d201cf9d8c16bf313aec) - 23.09.2026

### Fixed

- Player control layout and repeated video-surface updates.

## [Mac/server 1.0.16 (16)](https://github.com/lucaskleinsteuber/Aurelia/commit/bf800d73e7d4da6a74927abcba563bfd5b335b0b) - 21.09.2026

### Changed

- Native sidebar navigation, consistent canvas colors and content beneath the transparent title bar.
- Replace the custom navigation shell with native split-view and sidebar controls.
- Remove the empty top strip and use the same neutral canvas across screens.

## [Mac/server 1.0.15 (15)](https://github.com/lucaskleinsteuber/Aurelia/commit/253558e4c2b4320ea13170fdfef0ac5e5bc107e0) - 20.09.2026

### Added

- Complete native player controls, chapters, sleep timer and recovery after interrupted server startup.

### Changed

- Choose sound, subtitles, speed, chapters, volume and a sleep timer from restrained player controls.
- Seek with the timeline or keyboard and use native fullscreen and picture-in-picture.
- Hide controls only when playback and interaction state allow it.

## [Mac/server 1.0.14 (14)](https://github.com/lucaskleinsteuber/Aurelia/commit/ff7248fb221279bfac3dd2c4283e1b4a5ee106a5) - 19.09.2026

### Changed

- Unified the native Mac interface, first-run setup, library, title pages and player.
- Offer a clear choice between hosting on this Mac and connecting to another server.
- Add the Home recommendation hero, consistent artwork cards and unified title details.
- Keep native window controls, a transparent title bar and reduced-motion behavior.

## [Mac/server 1.0.13 (13)](https://github.com/lucaskleinsteuber/Aurelia/commit/62234aad4794fee2ed432ae75e36305fc4f41392) - 19.09.2026

### Added

- Automatic library monitoring, durable background jobs and identity-preserving media discovery.

### Changed

- Resume scans after storage reconnects and retain missing titles without losing favorites or progress.
- Coalesce filesystem changes and defer growing files instead of importing incomplete copies.
- Use paged search, catalog synchronization and cache validators to reduce repeated work.

## [Mac/server 1.0.12 (12)](https://github.com/lucaskleinsteuber/Aurelia/commit/9ba8b1404f3ccd93e585c239ec2c8913f09d9e99) - 14.09.2026

### Added

- Unified media manager with multiple typed storage locations.
- Restorable scan state and scan history.
- Migrate existing setup and profiles while retaining rollback data.

## [Mac/server 0.1.0 (11)](https://github.com/lucaskleinsteuber/Aurelia/commit/796083033e151f4ca95722e116926be6d03c581e) - 13.09.2026

### Fixed

- Start the Mac-hosted server reliably by default.
- Use a validated, transient App Group handoff to the hosting helper.
- Remember deliberate remote-client choices and make host retries safe.

## [Mac/server 0.1.0 (10)](https://github.com/lucaskleinsteuber/Aurelia/commit/6c37da00ed699061b980d9fddc0cff995739b015) - 12.09.2026

### Changed

- Native Home recommendations, shared catalog cards and bundled movie/series detail pages.
- Structured search and consistent metadata editors.
- Authenticated in-memory artwork loading and a content-first player layout.

## [Mac/server 0.1.0 (9)](https://github.com/lucaskleinsteuber/Aurelia/commit/d5a0e8fad167afb4bdda41aee6410516f213c148) - 09.09.2026

### Added

- Optional English TMDB metadata with bounded authenticated artwork downloads.
- Review uncertain matches and preserve manually selected metadata.
- Collections, favorites and richer title search.

## [Mac/server 0.1.0 (8)](https://github.com/lucaskleinsteuber/Aurelia/commit/96194c05b1d33774b98a06bb7eeca59abf25d5af) - 09.09.2026

### Added

- Automatic storage locations replace separate movie and TV setup steps.
- Persist import-review choices and support targeted rescans.
- Shorter first-run setup while preserving read-only media access.

## [Mac/server 0.1.0 (7)](https://github.com/lucaskleinsteuber/Aurelia/commit/9be4bbf667f673570ffd723039ec2a6ebe8fb92a) - 08.09.2026

### Added

- Bundle the self-contained server and a separately signed native hosting helper with the Mac app.
- Set up the owner, sign in locally and manage storage, scans, pairing and sessions inside Aurelia.
- Keep the hosted server lifecycle tied to its owning application.

## [Mac/server 0.1.0 (6)](https://github.com/lucaskleinsteuber/Aurelia/commit/9dbccf46bc5189ce44635a19c1428373868ec7a2) - 07.09.2026

### Fixed

- Move runnable Mac test products outside privacy-protected development folders.
- Use a stable app-owned Keychain identity and signing configuration.
- Document the client/server handoff and isolate synthetic test credentials.

## [Mac/server 0.1.0 (5)](https://github.com/lucaskleinsteuber/Aurelia/commit/3bfa559750b34843bcf222ca05954f701b19898a) - 07.09.2026

### Added

- Native VLCKit Direct Play with an authenticated loopback streaming relay.
- Playback controls, seeking, audio and subtitle selection.
- Per-profile progress saving and resuming at the saved position.

## [Mac/server 0.1.0 (4)](https://github.com/lucaskleinsteuber/Aurelia/commit/6ff4a087e87671957fd57d47d7deab34fc8524cf) - 06.09.2026

### Added

- First independent native SwiftUI Mac client with movie and series browsing.
- HTTPS on the local network, Bonjour discovery and explicit server-fingerprint trust.
- Pairing and Keychain-backed saved connections.

## [Mac/server 0.1.0 (3)](https://github.com/lucaskleinsteuber/Aurelia/commit/dd42b9ea29ef2e8a8e7a649b011f79198a359a47) - 06.09.2026

### Added

- Authenticated streaming through short-lived playback tickets.
- HTTP Range and HEAD support for seeking without downloading an entire video.
- Validate the requested source and keep original media read-only.

## [Mac/server 0.1.0 (2)](https://github.com/lucaskleinsteuber/Aurelia/commit/16022e266e2c5c14b815a15cc5c9e242466b258e) - 06.09.2026

### Added

- Read-only movie and TV library scans for explicitly selected storage locations.
- Stable catalog records for series, seasons, episodes and supplementary files.
- Catalog APIs expose media identity and availability without moving original media.

## [Mac/server 0.1.0 (1)](https://github.com/lucaskleinsteuber/Aurelia/commit/10fb3bfcf397ef15e7236a04b84cb202db57ad3d) - 06.09.2026

### Added

- Self-hosted server foundation with a versioned JSON API and local command-line tools.
- SQLite storage, first-owner setup and authenticated sessions.
- Isolated server tests and a local health endpoint.
