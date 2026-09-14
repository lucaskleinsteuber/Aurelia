import AppKit
import Foundation
import XCTest

@testable import Aurelia

@MainActor
final class PlaybackControllerTests: XCTestCase {
  func testResumePauseSeekTrackSelectionAndShutdownSave() async throws {
    let mediaID = UUID()
    let playbackID = UUID()
    let source = PlaybackSourceResponse(
      id: playbackID,
      mediaId: mediaID,
      streamPath: "/api/v1/streams/test-ticket",
      contentType: "video/x-matroska",
      contentLength: 4_096,
      expiresAt: "2099-01-01T12:00:00Z",
      progress: PlaybackProgressResponse(
        mediaId: mediaID,
        positionMilliseconds: 30_000,
        durationMilliseconds: 120_000,
        isCompleted: false,
        lastPlayedAt: nil,
        updatedAt: nil))
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: mediaID,
        title: "Pilot",
        subtitle: "Breaking Bad · S01 E01"),
      engine: engine,
      relayFactory: { _, _ in relay })

    await controller.start()
    XCTAssertEqual(engine.loadedURL, relay.localURL)
    XCTAssertTrue(engine.isPlaying)
    XCTAssertEqual(engine.currentTimeMilliseconds, 30_000)
    XCTAssertEqual(controller.currentTimeMilliseconds, 30_000)

    controller.togglePlayback()
    XCTAssertFalse(engine.isPlaying)
    controller.seek(to: 45_000)
    controller.selectAudioTrack(2)
    controller.selectSubtitleTrack(7)
    XCTAssertEqual(controller.selectedAudioTrackID, 2)
    XCTAssertEqual(controller.selectedSubtitleTrackID, 7)

    await controller.shutdown()
    XCTAssertTrue(engine.didStop)
    XCTAssertTrue(relay.didStop)
    XCTAssertEqual(client.revokedIDs, [playbackID])
    XCTAssertEqual(client.updates.last?.position, 45_000)
    XCTAssertEqual(client.updates.last?.duration, 120_000)
    XCTAssertFalse(client.updates.last?.finished ?? true)
  }

  func testEngineEndStoresCompletedProgress() async throws {
    let source = Self.source(position: 0, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(mediaId: source.mediaId, title: "Movie", subtitle: nil),
      engine: engine,
      relayFactory: { _, _ in relay })

    await controller.start()
    engine.currentTimeMilliseconds = engine.durationMilliseconds
    engine.isPlaying = false
    engine.onEnded?()
    await controller.shutdown()
    XCTAssertTrue(client.updates.contains(where: { $0.finished }))
  }

  private static func source(
    position: Int64,
    completed: Bool
  ) -> PlaybackSourceResponse {
    let mediaID = UUID()
    return PlaybackSourceResponse(
      id: UUID(),
      mediaId: mediaID,
      streamPath: "/api/v1/streams/test-ticket",
      contentType: "video/mp4",
      contentLength: 100,
      expiresAt: "2099-01-01T12:00:00Z",
      progress: PlaybackProgressResponse(
        mediaId: mediaID,
        positionMilliseconds: position,
        durationMilliseconds: 120_000,
        isCompleted: completed,
        lastPlayedAt: nil,
        updatedAt: nil))
  }
}

@MainActor
private final class FakePlaybackClient: PlaybackClientProtocol {
  struct Update: Equatable {
    let position: Int64
    let duration: Int64
    let finished: Bool
  }

  let profile = StoredServerProfile(
    serverId: UUID(),
    name: "Test",
    baseURL: URL(string: "https://server.test:43111")!,
    publicKeyFingerprint: String(repeating: "A", count: 64),
    token: "not-a-real-token",
    sessionId: UUID(),
    expiresAt: "2099-01-01T00:00:00Z")
  let source: PlaybackSourceResponse
  var updates: [Update] = []
  var revokedIDs: [UUID] = []

  init(source: PlaybackSourceResponse) {
    self.source = source
  }

  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse { source }

  func updatePlaybackProgress(
    mediaId: UUID,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64,
    isFinished: Bool
  ) async throws -> PlaybackProgressResponse {
    updates.append(Update(
      position: positionMilliseconds,
      duration: durationMilliseconds,
      finished: isFinished))
    return PlaybackProgressResponse(
      mediaId: mediaId,
      positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds,
      isCompleted: isFinished,
      lastPlayedAt: nil,
      updatedAt: nil)
  }

  func revokePlayback(id: UUID) async throws {
    revokedIDs.append(id)
  }

  func streamURL(path: String) throws -> URL {
    URL(string: path, relativeTo: profile.baseURL)!.absoluteURL
  }
}

@MainActor
private final class FakePlaybackRelay: PlaybackRelayProtocol {
  let localURL = URL(string: "http://127.0.0.1:54321/stream/local-secret")!
  var didStop = false

  func start() async throws -> URL { localURL }
  func updateSourceURL(_ url: URL) {}
  func stop() { didStop = true }
}

@MainActor
private final class FakePlaybackEngine: PlaybackEngine {
  var onUpdate: (() -> Void)?
  var onEnded: (() -> Void)?
  var onError: ((String) -> Void)?
  var isPlaying = false
  var currentTimeMilliseconds: Int64 = 0
  var durationMilliseconds: Int64 = 120_000
  var volume: Double = 1
  var isMuted = false
  let audioTracks = [PlaybackTrack(id: 2, title: "Main - [English]")]
  let subtitleTracks = [PlaybackTrack(id: 7, title: "English SDH - [English]")]
  var selectedAudioTrackID: Int32?
  var selectedSubtitleTrackID: Int32?
  var loadedURL: URL?
  var didStop = false

  func attach(to view: NSView) {}
  func load(url: URL) { loadedURL = url }
  func play() {
    isPlaying = true
    onUpdate?()
  }
  func pause() {
    isPlaying = false
    onUpdate?()
  }
  func stop() { didStop = true }
  func seek(to milliseconds: Int64) {
    currentTimeMilliseconds = milliseconds
    onUpdate?()
  }
  func selectAudioTrack(id: Int32) {
    selectedAudioTrackID = id
    onUpdate?()
  }
  func selectSubtitleTrack(id: Int32?) {
    selectedSubtitleTrackID = id
    onUpdate?()
  }
}
