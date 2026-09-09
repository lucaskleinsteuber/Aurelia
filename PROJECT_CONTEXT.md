# Aurelia Home Project Context

This document is the durable handoff for a new developer or Codex task. Read it
together with `AGENTS.md`, `README.md`, the current Git status, and the newest
external build summary before changing the product.

## What Aurelia Home is

Aurelia Home is Lucas's self-hosted media system. Its product idea is comparable
to Jellyfin in architecture and freedom: one server owns the library, accounts,
playback authorization, and watch state, while clients connect from other
devices. Its primary experience is deliberately native rather than a browser UI.
An optional responsive web client can be added later for devices that cannot run
a native app, but it must never replace the server/native-client architecture.

The first-class client is macOS. It is written in Swift and SwiftUI because that
is the best route to a genuinely excellent Mac experience. The server and JSON
protocol are platform-independent, so later Linux and Windows clients can use
their own suitable UI technology without changing how the media system works.

## Responsibility and playback flow

The server is the source of truth. It scans only explicitly selected storage
locations, classifies clear movie and TV structures locally, stores only catalog
and account data in SQLite, authenticates devices,
issues short-lived playback tickets, streams requested byte ranges over HTTPS,
and stores progress per user. It never copies, opens for analysis, hashes,
converts, remuxes, transcodes, or caches a complete video file.

The native client discovers or connects to a server, verifies its certificate
fingerprint during pairing, stores the paired profile securely, presents the
library, and asks for playback authorization. VLCKit decodes audio and video on
the Mac. Because VLCKit cannot use Aurelia Home's certificate-pinning delegate
directly, an internal relay listens only on `127.0.0.1`, validates a random local
secret, and incrementally forwards GET, HEAD, Range, and If-Range requests over
the pinned HTTPS session. Neither the long-lived device token nor the playback
ticket is exposed to VLCKit or written to logs.

The complete path is:

1. A library scan records stable media IDs and filesystem facts in SQLite.
2. A user pairs a native client and verifies the server fingerprint.
3. The client requests a single-file, short-lived playback ticket.
4. VLCKit requests only the byte ranges it needs through the loopback relay.
5. The server reads those ranges from the original file and sends them unchanged.
6. The client decodes locally and periodically stores progress on the server.

## Current completed foundation

- Build 1 created the server, authentication, SQLite foundation, and local CLI.
- Build 2 added safe read-only movie and TV library scanning and catalog APIs.
- Build 3 added authenticated, seekable HTTP Range streaming.
- Build 4 added HTTPS LAN access, Bonjour discovery, pairing, pinning, and the
  first native SwiftUI catalog client.
- Build 5 added VLCKit Direct Play, the pinned loopback relay, native player
  controls, and per-user watch progress.
- Build 6 moves Mac tests outside privacy-protected folders, adopts a fresh
  app-owned Keychain namespace with stable signing, and makes this handoff
  durable.
- Build 7 embeds both self-contained macOS server architectures, adds a
  separately signed native host helper, and provides owner setup, local login,
  libraries, scans, pairing, and session management inside the Mac app.
- Build 8 replaces separate movie and TV setup with automatic storage locations,
  persistent review decisions, targeted rescans, and a shorter first-run flow.
- Build 9 adds optional English TMDB metadata and bounded authenticated artwork,
  cautious match review, manual precedence, collections, favorites, search, and
  the server-side data required by the future Home and detail experience.

The Build 7 host handoff keeps the primary app sandboxed. Launch Services opens
the separately signed, windowless helper; a non-secret launch description is
validated against the exact live Aurelia Home PID and executable, and its
random 256-bit control secret is transferred only through a short-lived FIFO.
The description and FIFO are deleted after consumption. Secrets never enter
arguments, persisted settings, or logs, and the helper shuts down when its
owning app disappears.

The system is functional but not visually finished. Treat a passing build as
engineering evidence, not as proof that every UI route, network, codec, or
physical device has been exercised.

## Product and design direction

The visual reference is the existing Aurelia app and Lucas's supplied design
screenshots. The direction is one consistent Apple TV and macOS 26 language:
content-first composition, a transparent sidebar with scrolling detail content
visible beneath it, no gray or black title strip above content, restrained
player controls that disappear automatically, and native macOS fullscreen
behavior. Never draw fake traffic-light buttons in fullscreen.

A later Home screen will rotate one movie or series recommendation every hour.
Library, detail, metadata, and editing screens must eventually be rebuilt as one
coherent system; do not preserve inconsistent old Aurelia editor menus merely
because code exists for them. During infrastructure milestones, avoid unrelated
visual redesigns.

## Workspace map and safety boundary

- Active repository: `/Users/lucas/Documents/Aurelia Home`
- Read-only behavior and design reference: `/Users/lucas/Documents/Aurelia`
- Generated builds, caches, tests, databases, and logs:
  `/Users/lucas/Documents/Aurelia Home Other`
- External summaries: `Aurelia Home Other/Aurelia Home Build summarys`
- Replaced app backups: `Aurelia Home Other/Aurelia Home - Build Backup`

Never edit the original Aurelia repository while working here. Do not copy its
binaries or database into Aurelia Home. Do not put generated files, media,
credentials, runtime databases, or large packages in this repository. Breaking
Bad and El Camino test media are read in place only for explicitly bounded
playback checks; record size and modification time before and after those checks.

Because this repository and `Aurelia Home Other` live in Documents, runnable Mac
test products must be staged under
`~/Library/Caches/AureliaHome/TestRuns/<run-id>`. Only logs and results are copied
back after execution. Pre-install smoke candidates use
`/private/tmp/AureliaHome/<run-id>`, and installed candidates run from
`/Applications`, never from build output under Documents.

## How a new task should begin

1. Read `AGENTS.md`, this file, `README.md`, and the newest build summary.
2. Inspect `git status`, the current branch, recent commits, and `origin/main`.
3. Understand the relevant server, client, database, and test paths before edits.
4. Consult `/Users/lucas/Documents/Aurelia` only as a read-only behavior or
   design reference; do not blindly port old code or dependencies.
5. Make the smallest coherent product change and keep user-facing text English.
6. Use external output directories and the private temporary Mac test runner.
7. Run the pinned restore, formatting, warning-free builds, full tests, database
   integrity checks, architecture checks, and a risk-proportionate smoke test.
8. Verify the candidate before backing up and replacing the installed app.
9. Audit the diff for media, databases, binaries, local-only paths, tokens,
   credentials, and generated files.
10. Commit directly to `main` using the exact product version as the commit
    message (`1.0.9` for Build 9), push immediately, verify the remote hash, and
    write exactly one English external summary for the completed build.

## Planned direction

The next milestone is Build 10: use the Build 9 presentation APIs for the
dedicated Apple-TV-style Home, library, detail, metadata review, and editing
redesign. The supplied Aurelia screenshots remain the visual reference, while
the existing server/native-client boundary stays unchanged. Automatic file
watchers, the optional web client, broader administration, Linux and Windows
native clients, and advanced playback features should follow as deliberate
milestones rather than being mixed into that visual work.
