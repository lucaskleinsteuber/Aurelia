# System callback boundaries

Registering a callback on MainActor does not make its framework call it there.
An unannotated closure created inside a MainActor function can inherit that
isolation, including a runtime actor check, even when an Objective-C API accepts
the closure. Keep the callback's delivery contract explicit.

- Prepare UI-owned inputs on MainActor. Build background-callable handlers in a
  `nonisolated` factory and mark the closure `@Sendable`; capture only Sendable
  values or a documented immutable wrapper. Do not capture a mutable NSImage,
  view or model in an artwork request handler.
- MediaPlayer artwork requests may run on its private access queue. The artwork
  callback uses immutable CGImage pixels and value geometry. Remote command
  callbacks use a thread-safe eligibility snapshot, then explicitly schedule
  controller actions on MainActor and recheck registration ownership there.
- A `NotificationCenter` observer with `queue: nil` follows the posting thread.
  A publisher does not add a scheduler. UI subscribers must explicitly receive
  on the main queue unless the source contract guarantees main-thread delivery.
- Use `MainActor.assumeIsolated` only behind a proven main-thread/main-queue
  boundary. An inner MainActor Task does not remove an actor check inherited by
  the outer framework callback.

The Mac callback audit covers MediaPlayer artwork/commands, workspace sleep/wake
and application launch APIs, notification publishers/observers, NSEvent monitors,
VLCKit delegates, URLSession, Process/FileHandle and Network framework handlers.
VLC observers explicitly choose the main queue; thumbnail delegates are
nonisolated and hop to MainActor. NSEvent monitor callbacks have a main-thread
contract. SDK Sendable completion handlers and nonactor serial/locked delegates
retain their existing boundaries. There are no active NSItemProvider,
AVAsset/AVPlayer observer, Timer or CVDisplayLink callback registrations.

Regression tests must invoke the production factory's callback from a real
background queue. Test MediaPlayer artwork with a generated CGImage-backed
NSImage, requesting fitted sizes through `MPMediaItemArtwork.image(at:)`.
Test the native command adapter without registering a real system media session,
including rejected/retired callbacks. Continue testing nil artwork, title
replacement, cancellation and unregistering with injected transports.

The original artwork tests checked sizing and lifecycle on MainActor; fake
transport tests bypassed the native adapter. They could not detect a callback
that trapped only when MediaPlayer invoked it off-main. These tests do not play
media and do not establish physical media-key or Control Center UI coverage.
