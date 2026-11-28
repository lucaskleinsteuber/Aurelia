import Foundation

/// The "relay" of a download: the file on this device and its subtitle files.
final class IOSOfflineRelay: IOSPlaybackRelay, @unchecked Sendable {
  private let file: URL
  private let subtitles: [Int: URL]

  init(file: URL, subtitles: [Int: URL]) {
    self.file = file
    self.subtitles = subtitles
  }

  func start() async throws -> URL { file }
  func stop() {}
  func updateSourceURL(_ url: URL) {}
  func setFailureHandler(_ handler: @escaping @MainActor @Sendable (IOSStreamFailure) -> Void) {}
  func subtitleURL(index: Int) -> URL? { subtitles[index] }
}

/// Everything the normal player needs to play downloads with no server.
@MainActor
struct IOSOfflinePlayback {
  let api: IOSAPIClient
  let runtime: IOSPlaybackRuntime
  let outbox: IOSProgressOutbox
  let session: IOSProfileSession
  let queue: [IOSCatalogItem]

  /// `title` and the downloaded episodes after it, played from this device's files. Progress
  /// is saved with the download and goes to the server later.
  init(
    title: IOSOfflineTitle, profile: IOSOfflineSession, connection: IOSStoredConnection,
    store: IOSOfflineStore, base: IOSPlaybackRuntime
  ) {
    let mine = store.titles(serverID: profile.serverID, profileID: profile.profileID)
    let following = IOSOfflineRules.followingEpisodes(after: title, in: mine)
    let files = Dictionary(
      uniqueKeysWithValues: ([title] + following).map {
        ($0.id, (store.fileURL(for: $0), store.subtitleURLs($0)))
      })
    let relay: (URL, String, String) throws -> any IOSPlaybackRelay = { url, _, _ in
      guard let id = IOSOfflineTransport.mediaID(streamURL: url), let source = files[id] else {
        throw IOSStreamRelayError.unavailable
      }
      return IOSOfflineRelay(file: source.0, subtitles: source.1)
    }
    runtime = IOSPlaybackRuntime(
      engine: base.engine, makeRelay: relay, managesAudioSession: base.managesAudioSession,
      // Timeline previews read the same file; with previews off (UI tests) they stay off.
      makePreviewRelay: base.makePreviewRelay == nil ? nil : relay)
    session = profile.playerSession
    let serverID = profile.serverID
    let profileID = profile.profileID
    api = IOSAPIClient(
      connection: connection, session: session,
      transport: IOSOfflineTransport(
        title: { id in
          await MainActor.run {
            store.title(id).flatMap {
              $0.serverID == serverID && $0.profileID == profileID ? $0 : nil
            }
          }
        },
        save: { id, position, duration, finished in
          await MainActor.run {
            store.saveProgress(id, position: position, duration: duration, finished: finished)
          }
        }))
    // Its own journal in memory: offline positions never mix with the server's queue.
    outbox = IOSProgressOutbox()
    queue = following.map(\.catalogItem)
    let scope = IOSProgressScope(connection: connection, session: session)
    Task { [outbox, api, session] in
      await outbox.activate(scope: scope, client: api, sessionID: session.sessionId)
    }
  }

  func controller(
    title: IOSOfflineTitle, connection: IOSStoredConnection,
    preferences: IOSPlaybackPreferencesStore, onClose: @escaping @MainActor () -> Void
  ) -> IOSPlaybackController {
    IOSPlaybackController(
      connection: connection, session: session, mediaID: title.id, title: title.playerTitle,
      outbox: outbox, api: api, runtime: runtime, queue: queue,
      seriesID: title.isEpisode ? title.parentID : nil, preferencesStore: preferences,
      onClose: onClose, isOffline: true)
  }
}
