import AppKit
import Foundation
import XCTest

@testable import Aurelia

@MainActor
final class PlaybackControllerTests: XCTestCase {
  func testPlaybackPreferencesPersistAndNormalize() throws {
    let suite = "PlaybackControllerTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = PlaybackPreferencesStore(defaults: defaults)
    store.preferences.seekInterval = 30
    store.preferences.defaultVolume = 0.35
    store.preferences.defaultPlaybackRate = 1.25
    store.preferences.controlsAutoHideDelay = 5

    let reloaded = PlaybackPreferencesStore(defaults: defaults)
    XCTAssertEqual(reloaded.preferences.seekInterval, 30)
    XCTAssertEqual(reloaded.preferences.defaultVolume, 0.35)
    XCTAssertEqual(reloaded.preferences.defaultPlaybackRate, 1.25)
    XCTAssertEqual(reloaded.preferences.controlsAutoHideDelay, 5)

    reloaded.preferences.seekInterval = 500
    let normalized = PlaybackPreferencesStore(defaults: defaults)
    XCTAssertEqual(normalized.preferences.seekInterval, 60)
  }

  /// Night mode is applied by opening the title again; playback continues where it was, with the
  /// series' track choices, and no progress at zero is saved in between.
  func testReopeningForNightModeResumesAtTheSamePosition() async throws {
    let mediaID = UUID()
    let seriesID = UUID()
    let source = PlaybackSourceResponse(
      id: UUID(), mediaId: mediaID, streamPath: "/api/v1/streams/test-ticket",
      contentType: "video/x-matroska", contentLength: 4_096, expiresAt: "2099-01-01T12:00:00Z",
      progress: PlaybackProgressResponse(
        mediaId: mediaID, positionMilliseconds: 30_000, durationMilliseconds: 120_000,
        isCompleted: false, lastPlayedAt: nil, updatedAt: nil))
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: mediaID, title: "Pilot", subtitle: "Breaking Bad · S01 E01",
        trackScope: seriesID),
      engine: engine,
      relayFactory: { _, _ in relay })

    await controller.start()
    controller.seek(to: 45_000)
    let savedBefore = client.updates.count
    controller.reopenForAudioChange()

    XCTAssertEqual(engine.loadedScopes, [seriesID, seriesID])
    XCTAssertEqual(engine.loadedURL, relay.localURL)
    XCTAssertTrue(engine.isPlaying)
    XCTAssertEqual(engine.currentTimeMilliseconds, 45_000)
    XCTAssertEqual(controller.currentTimeMilliseconds, 45_000)
    XCTAssertFalse(client.updates.dropFirst(savedBefore).contains { $0.position == 0 })
    await controller.shutdown()
    XCTAssertEqual(client.updates.last?.position, 45_000)
  }

  private func resumingController(engine: FakePlaybackEngine) -> PlaybackController {
    let mediaID = UUID()
    let source = PlaybackSourceResponse(
      id: UUID(), mediaId: mediaID, streamPath: "/api/v1/streams/test-ticket",
      contentType: "video/mp4", contentLength: 4_096, expiresAt: "2099-01-01T12:00:00Z",
      progress: PlaybackProgressResponse(
        mediaId: mediaID, positionMilliseconds: 30_000, durationMilliseconds: 120_000,
        isCompleted: false, lastPlayedAt: nil, updatedAt: nil))
    let relay = FakePlaybackRelay()
    return PlaybackController(
      client: FakePlaybackClient(source: source),
      presentation: PlaybackPresentation(
        mediaId: mediaID, title: "Pilot", subtitle: nil, startIntent: .resume),
      engine: engine,
      relayFactory: { _, _ in relay })
  }

  func testSystemMediaSeekEligibilityRequiresAStartedSeekableInputAndStopsOnShutdown() async {
    let engine = FakePlaybackEngine()
    let controller = resumingController(engine: engine)
    XCTAssertFalse(controller.canSeek)
    XCTAssertFalse(controller.canPlayNext)
    XCTAssertFalse(controller.playNextFromSystemMedia())
    await controller.start()
    XCTAssertTrue(controller.canSeek)
    engine.isSeekable = false
    engine.onUpdate?()
    XCTAssertFalse(controller.isSeekable)
    XCTAssertFalse(controller.canSeek)
    engine.isSeekable = true
    engine.onUpdate?()
    XCTAssertTrue(controller.isSeekable)
    XCTAssertTrue(controller.canSeek)
    engine.durationMilliseconds = 0
    engine.onUpdate?()
    XCTAssertFalse(controller.canSeek)
    await controller.shutdown(saveProgress: false)
    XCTAssertFalse(controller.canSeek)
    XCTAssertFalse(controller.canPlayNext)
  }

  func testResumeOpensAtThePositionAndKeepsTheStartScreenUntilThePictureMoves() async {
    let engine = FakePlaybackEngine()
    engine.opensAtStartPosition = true
    let controller = resumingController(engine: engine)
    XCTAssertTrue(controller.showsStartScreen)

    await controller.start()
    XCTAssertEqual(engine.startPositions, [30_000])
    // The title is known but its clock has not arrived yet: no seek back to the beginning.
    engine.onUpdate?()
    engine.currentTimeMilliseconds = 30_040
    engine.onUpdate?()
    XCTAssertTrue(engine.seekTargets.isEmpty)
    XCTAssertTrue(controller.showsStartScreen)

    engine.currentTimeMilliseconds = 30_600
    engine.onUpdate?()
    XCTAssertFalse(controller.showsStartScreen)
    XCTAssertEqual(controller.currentTimeMilliseconds, 30_600)
    await controller.shutdown()
  }

  func testAContainerThatIgnoresTheStartPositionStillResumes() async {
    let engine = FakePlaybackEngine()
    engine.opensAtStartPosition = true
    let controller = resumingController(engine: engine)
    await controller.start()
    // The clock starts at the beginning instead of the resume position.
    engine.currentTimeMilliseconds = 400
    engine.onUpdate?()
    XCTAssertEqual(engine.seekTargets, [30_000])
    XCTAssertEqual(controller.currentTimeMilliseconds, 30_000)
    await controller.shutdown()
  }

  func testEnginesWithoutAStartPositionSeekAsBefore() async {
    let engine = FakePlaybackEngine()
    let controller = resumingController(engine: engine)
    await controller.start()
    XCTAssertEqual(engine.seekTargets, [30_000])
    controller.pause()
    // Pausing before the picture moves shows the paused player instead of the start screen.
    XCTAssertFalse(controller.showsStartScreen)
    await controller.shutdown()
  }

  func testPreviewsUseTheirOwnRelayThatCannotFailPlayback() async throws {
    let mediaID = UUID()
    let source = PlaybackSourceResponse(
      id: UUID(), mediaId: mediaID, streamPath: "/api/v1/streams/test-ticket",
      contentType: "video/x-matroska", contentLength: 4_096, expiresAt: "2099-01-01T12:00:00Z",
      progress: PlaybackProgressResponse(
        mediaId: mediaID, positionMilliseconds: 0, durationMilliseconds: 120_000,
        isCompleted: false, lastPlayedAt: nil, updatedAt: nil))
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    let preview = FakePlaybackRelay(localURL: URL(string: "http://127.0.0.1:54322/stream/p")!)
    var previewSources: [URL] = []
    let controller = PlaybackController(
      client: FakePlaybackClient(source: source),
      presentation: PlaybackPresentation(mediaId: mediaID, title: "Pilot", subtitle: nil),
      engine: engine,
      relayFactory: { _, _ in relay },
      previewRelayFactory: { url, _ in
        previewSources.append(url)
        return preview
      })

    await controller.start()
    for _ in 0..<50 where controller.previewSourceURL == nil { await Task.yield() }

    XCTAssertEqual(engine.loadedURL, relay.localURL)
    XCTAssertEqual(controller.previewSourceURL, preview.localURL)
    XCTAssertEqual(previewSources.count, 1)
    XCTAssertTrue(relay.hasFailureHandler)
    // A busy or failing preview read is never reported to playback.
    XCTAssertFalse(preview.hasFailureHandler)

    // Night mode reopens the player on its own relay, never the preview one.
    controller.reopenForAudioChange()
    XCTAssertEqual(engine.loadedURL, relay.localURL)

    await controller.shutdown()
    XCTAssertTrue(relay.didStop)
    XCTAssertTrue(preview.didStop)
    XCTAssertNil(controller.previewSourceURL)
  }

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
        subtitle: "Breaking Bad · S01 E01", startIntent: .resume),
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

  func testShutdownClearsPublishedPlaybackStateWithoutLosingProgressSnapshot() async throws {
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
    controller.seek(to: 45_000)
    XCTAssertTrue(engine.isPlaying)
    XCTAssertTrue(controller.isPlaying)
    let duration = controller.durationMilliseconds

    await controller.shutdown()

    XCTAssertTrue(engine.didStop)
    XCTAssertTrue(relay.didStop)
    XCTAssertFalse(engine.isPlaying)
    XCTAssertFalse(controller.isPlaying)
    XCTAssertFalse(controller.isPreparing)
    XCTAssertEqual(controller.currentTimeMilliseconds, 45_000)
    XCTAssertEqual(controller.durationMilliseconds, duration)
    XCTAssertEqual(client.updates.last?.position, 45_000)
    XCTAssertEqual(client.updates.last?.duration, duration)
    XCTAssertFalse(client.updates.last?.finished ?? true)
  }

  func testPauseDuringDecoderOpeningIsAppliedAtStartAndResume() async throws {
    let source = Self.source(position: 30_000, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    engine.deferPlayStateChange = true
    let relay = FakePlaybackRelay()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: source.mediaId, title: "Movie", subtitle: nil, startIntent: .resume),
      engine: engine,
      relayFactory: { _, _ in relay })

    await controller.start()
    XCTAssertEqual(engine.playCalls, 1)
    XCTAssertFalse(engine.isPlaying)
    XCTAssertTrue(controller.pause())
    XCTAssertTrue(controller.pause())
    XCTAssertEqual(engine.pauseCalls, 0)

    engine.completeDeferredPlay()
    XCTAssertEqual(engine.pauseCalls, 1)
    XCTAssertFalse(engine.isPlaying)
    XCTAssertFalse(controller.isPlaying)
    XCTAssertEqual(controller.currentTimeMilliseconds, 30_000)

    XCTAssertTrue(controller.play())
    XCTAssertEqual(engine.playCalls, 2)
    XCTAssertTrue(controller.pause())
    engine.completeDeferredPlay()
    XCTAssertEqual(engine.pauseCalls, 2)
    XCTAssertFalse(engine.isPlaying)
    XCTAssertFalse(controller.isPlaying)
    await controller.shutdown()
  }

  func testPendingDecoderPauseIsNotRepeatedOrPublishedAsPlaying() async throws {
    let source = Self.source(position: 0, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    engine.deferPauseStateChange = true
    let relay = FakePlaybackRelay()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(mediaId: source.mediaId, title: "Movie", subtitle: nil),
      engine: engine,
      relayFactory: { _, _ in relay })

    await controller.start()
    XCTAssertTrue(controller.isPlaying)
    XCTAssertTrue(controller.pause())
    XCTAssertTrue(engine.isPlaying)
    XCTAssertFalse(controller.isPlaying)
    for _ in 0..<3 {
      engine.onUpdate?()
      XCTAssertTrue(controller.pause())
    }
    XCTAssertEqual(engine.pauseCalls, 1)
    XCTAssertFalse(controller.isPlaying)

    engine.completeDeferredPause()
    XCTAssertFalse(engine.isPlaying)
    XCTAssertTrue(controller.play())
    XCTAssertTrue(controller.isPlaying)
    XCTAssertTrue(controller.pause())
    XCTAssertEqual(engine.pauseCalls, 2)
    XCTAssertFalse(controller.isPlaying)
    engine.completeDeferredPause()
    await controller.shutdown()
  }

  func testPauseDuringRecoveryDecoderOpeningRetainsIntentAndPosition() async throws {
    let source = Self.source(position: 30_000, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(mediaId: source.mediaId, title: "Movie", subtitle: nil),
      engine: engine,
      relayFactory: { _, _ in relay },
      recoverySleep: { _ in })

    await controller.start()
    controller.seek(to: 45_000)
    engine.deferPlayStateChange = true
    engine.onError?("Synthetic decoder interruption")
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while engine.playCalls < 2 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(engine.playCalls, 2)
    XCTAssertFalse(engine.isPlaying)
    XCTAssertTrue(controller.pause())
    engine.completeDeferredPlay()
    XCTAssertEqual(engine.pauseCalls, 1)
    XCTAssertFalse(engine.isPlaying)
    XCTAssertFalse(controller.isPlaying)
    XCTAssertEqual(controller.currentTimeMilliseconds, 45_000)
    XCTAssertFalse(controller.diagnostics.events.contains { $0.kind == .recovered })

    XCTAssertTrue(controller.play())
    engine.completeDeferredPlay()
    XCTAssertTrue(controller.isPlaying)
    engine.currentTimeMilliseconds = 46_000
    engine.onUpdate?()
    XCTAssertTrue(controller.diagnostics.events.contains { $0.kind == .recovered })
    XCTAssertEqual(client.createdMediaIDs, [source.mediaId, source.mediaId])
    await controller.shutdown()
  }

  func testPreferencesControlResumeRateVolumeAndChapters() async throws {
    let source = Self.source(position: 30_000, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    let preferences = PlaybackPreferences(
      automaticResume: false,
      defaultPlaybackRate: 1.5,
      defaultVolume: 0.4,
      controlsAutoHideDelay: 5,
      seekInterval: 15,
      preventSleepDuringPlayback: false,
      automaticallyPlayNextEpisode: false,
      nightMode: false)
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(mediaId: source.mediaId, title: "Movie", subtitle: nil),
      engine: engine,
      preferences: preferences,
      relayFactory: { _, _ in relay })

    await controller.start()
    XCTAssertEqual(controller.currentTimeMilliseconds, 0)
    XCTAssertEqual(controller.playbackRate, 1.5)
    XCTAssertEqual(controller.volume, 0.4)
    XCTAssertEqual(controller.chapters.count, 2)

    controller.selectChapter(engine.chapters[1])
    controller.setPlaybackRate(0.75)
    XCTAssertEqual(engine.currentChapterIndex, 1)
    XCTAssertEqual(controller.currentTimeMilliseconds, 60_000)
    XCTAssertEqual(engine.playbackRate, 0.75)
    await controller.shutdown()
  }

  func testEndOfEpisodeAdvancesOnlyWhenEnabled() async throws {
    let source = Self.source(position: 42_000, completed: false)
    let nextID = UUID()
    let currentArtwork = ArtworkSummary(
      id: UUID(), kind: .poster, path: "/api/v1/artwork/current", contentType: "image/png",
      contentLength: 64)
    let nextArtwork = ArtworkSummary(
      id: UUID(), kind: .poster, path: "/api/v1/artwork/next", contentType: "image/png",
      contentLength: 64)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    var preferences = PlaybackPreferences.defaultValue
    preferences.preventSleepDuringPlayback = false
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: source.mediaId,
        title: "Episode 1",
        subtitle: "Series · S01 E01",
        queue: [
          PlaybackQueueItem(
            mediaId: source.mediaId, title: "Episode 1", subtitle: nil, artwork: currentArtwork),
          PlaybackQueueItem(
            mediaId: nextID,
            title: "Episode 2",
            subtitle: "Series · S01 E02", artwork: nextArtwork),
        ], artwork: currentArtwork),
      engine: engine,
      preferences: preferences,
      relayFactory: { _, _ in relay })

    XCTAssertFalse(controller.canPlayNext)
    await controller.start()
    XCTAssertEqual(controller.presentation.artwork, currentArtwork)
    XCTAssertTrue(controller.canPlayNext)
    engine.currentTimeMilliseconds = engine.durationMilliseconds
    engine.isPlaying = false
    engine.onEnded?()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while controller.presentation.mediaId != nextID && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }

    XCTAssertEqual(controller.presentation.mediaId, nextID)
    XCTAssertEqual(controller.presentation.artwork, nextArtwork)
    XCTAssertEqual(client.createdMediaIDs, [source.mediaId, nextID])
    XCTAssertEqual(engine.startPositions, [0, 0])
    await controller.shutdown()
  }

  func testPlayIgnoresStoredProgressWhileExplicitResumeUsesIt() async {
    for intent in [PlaybackStartIntent.play, .resume] {
      let source = Self.source(position: 42_000, completed: false)
      let client = FakePlaybackClient(source: source)
      let engine = FakePlaybackEngine()
      let controller = PlaybackController(
        client: client,
        presentation: PlaybackPresentation(
          mediaId: source.mediaId, title: "Synthetic", subtitle: nil, startIntent: intent),
        engine: engine, relayFactory: { _, _ in FakePlaybackRelay() })
      await controller.start()
      XCTAssertEqual(engine.startPositions, [intent == .resume ? 42_000 : 0])
      await controller.shutdown(saveProgress: false)
    }
  }

  func testExplicitRetryAfterAnInitialFailureKeepsTheResumeIntent() async {
    let source = Self.source(position: 42_000, completed: false)
    let client = FakePlaybackClient(source: source)
    client.nextCreationError = APIClientError.serverRejected(
      code: "media_not_playable", message: "Synthetic initial failure")
    let engine = FakePlaybackEngine()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: source.mediaId, title: "Synthetic", subtitle: nil, startIntent: .resume),
      engine: engine, relayFactory: { _, _ in FakePlaybackRelay() })
    await controller.start()
    XCTAssertNotNil(controller.errorMessage)
    XCTAssertTrue(engine.startPositions.isEmpty)
    await controller.retry()
    XCTAssertEqual(engine.startPositions, [42_000])
    await controller.shutdown(saveProgress: false)
  }

  func testExplicitResumeSurvivesInitialAndNextAuthorizationOrRelayStartupFailure() async {
    for nextEpisode in [false, true] {
      for relayFailure in [false, true] {
        let source = Self.source(position: 42_000, completed: false)
        let nextID = UUID()
        let client = FakePlaybackClient(source: source)
        let engine = FakePlaybackEngine()
        var failRelay = false
        let controller = PlaybackController(
          client: client,
          presentation: PlaybackPresentation(
            mediaId: source.mediaId, title: "Synthetic", subtitle: nil,
            queue: [PlaybackQueueItem(mediaId: nextID, title: "Next", subtitle: nil)],
            startIntent: nextEpisode ? .play : .resume), engine: engine,
          relayFactory: { _, _ in
            if failRelay {
              failRelay = false
              throw URLError(.networkConnectionLost)
            }
            return FakePlaybackRelay()
          }, recoverySleep: { _ in await Task.yield() })
        if !nextEpisode {
          if relayFailure { failRelay = true } else { client.failNextCreations = 1 }
        }
        await controller.start()
        if nextEpisode {
          if relayFailure { failRelay = true } else { client.failNextCreations = 1 }
          XCTAssertTrue(controller.resumeNextNow())
        }
        let expected = nextEpisode ? 2 : 1
        for _ in 0..<2_000 {
          if engine.startPositions.count >= expected { break }
          await Task.yield()
        }
        XCTAssertEqual(engine.startPositions, nextEpisode ? [0, 42_000] : [42_000])
        XCTAssertEqual(controller.presentation.mediaId, nextEpisode ? nextID : source.mediaId)
        await controller.shutdown(saveProgress: false)
      }
    }
  }

  func testAnAcknowledgedSeekToZeroOverridesOldResumeProgressDuringRecovery() async {
    let source = Self.source(position: 42_000, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: source.mediaId, title: "Synthetic", subtitle: nil, startIntent: .resume),
      engine: engine, relayFactory: { _, _ in FakePlaybackRelay() },
      recoverySleep: { _ in await Task.yield() })
    await controller.start()
    XCTAssertEqual(controller.currentTimeMilliseconds, 42_000)
    controller.seek(to: 0)
    engine.onError?("Synthetic failure after seeking to zero")
    for _ in 0..<2_000 {
      if engine.startPositions.count >= 2 { break }
      await Task.yield()
    }
    XCTAssertEqual(engine.startPositions, [42_000, 0])
    await controller.retry()
    XCTAssertEqual(engine.startPositions, [42_000, 0, 0])
    await controller.shutdown(saveProgress: false)
  }

  func testResumePositionSurvivesAnEngineFailureBeforeItsFirstClock() async {
    let source = Self.source(position: 42_000, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    engine.opensAtStartPosition = true
    engine.deferPlayStateChange = true
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: source.mediaId, title: "Synthetic", subtitle: nil, startIntent: .resume),
      engine: engine, relayFactory: { _, _ in FakePlaybackRelay() },
      recoverySleep: { _ in await Task.yield() })
    await controller.start()
    XCTAssertEqual(controller.currentTimeMilliseconds, 0)
    XCTAssertEqual(engine.startPositions, [42_000])
    engine.onError?("Synthetic failure before the first clock")
    for _ in 0..<2_000 {
      if engine.startPositions.count >= 2 { break }
      await Task.yield()
    }
    XCTAssertEqual(engine.startPositions, [42_000, 42_000])
    await controller.retry()
    XCTAssertEqual(engine.startPositions, [42_000, 42_000, 42_000])
    await controller.shutdown(saveProgress: false)
  }

  func testOnlyTheExplicitUpNextResumeActionUsesTheNextEpisodesProgress() async {
    for resume in [false, true] {
      let source = Self.source(position: 42_000, completed: false)
      let next = UUID()
      let client = FakePlaybackClient(source: source)
      let engine = FakePlaybackEngine()
      let controller = PlaybackController(
        client: client,
        presentation: PlaybackPresentation(
          mediaId: source.mediaId, title: "Episode 10", subtitle: nil,
          queue: [PlaybackQueueItem(mediaId: next, title: "Episode 11", subtitle: nil)]),
        engine: engine, relayFactory: { _, _ in FakePlaybackRelay() })
      await controller.start()
      if resume { XCTAssertTrue(controller.resumeNextNow()) } else { controller.playNextNow() }
      for _ in 0..<1_000 {
        if controller.presentation.mediaId == next && !controller.isPreparing { break }
        await Task.yield()
      }
      XCTAssertEqual(controller.presentation.mediaId, next)
      XCTAssertEqual(engine.startPositions, [0, resume ? 42_000 : 0])
      XCTAssertEqual(controller.presentation.startIntent, resume ? .resume : .play)
      XCTAssertTrue(controller.canPlayPrevious)
      await controller.shutdown(saveProgress: false)
    }
  }

  func testPauseAndShutdownDuringManualNavigationNeverMarkTheOldEpisodeFinished() async {
    for closeImmediately in [false, true] {
      let source = Self.source(position: 42_000, completed: false)
      let client = FakePlaybackClient(source: source)
      let engine = FakePlaybackEngine()
      let outbox = PlaybackProgressOutbox()
      let controller = PlaybackController(
        client: client,
        presentation: PlaybackPresentation(
          mediaId: source.mediaId, title: "Episode 10", subtitle: nil,
          queue: [PlaybackQueueItem(mediaId: UUID(), title: "Episode 11", subtitle: nil)],
          startIntent: .resume), engine: engine, relayFactory: { _, _ in FakePlaybackRelay() },
        progressOutbox: outbox)
      await controller.start()
      await outbox.flush()
      client.updates.removeAll()
      var pending: CheckedContinuation<Void, Never>?
      var delayed = false
      client.beforeProgressReturn = {
        if !delayed {
          delayed = true
          await withCheckedContinuation { pending = $0 }
        }
      }
      controller.playNextNow()
      for _ in 0..<1_000 {
        if pending != nil { break }
        await Task.yield()
      }
      XCTAssertNotNil(pending)
      if !closeImmediately { _ = controller.pause() }
      let shutdown = Task { await controller.shutdown() }
      await Task.yield()
      pending?.resume()
      await shutdown.value
      XCTAssertFalse(client.updates.isEmpty)
      XCTAssertFalse(client.updates.contains { $0.finished })
      XCTAssertTrue(client.updates.allSatisfy { $0.position == 42_000 })
      XCTAssertEqual(client.createdMediaIDs, [source.mediaId])
    }
  }

  func testMiddleEpisodeCanNavigateBothDirectionsFromZeroAndRespectSeriesBoundaries() async throws {
    let source = Self.source(position: 42_000, completed: false)
    let firstID = UUID()
    let lastID = UUID()
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: source.mediaId, title: "Episode 10", subtitle: nil,
        queue: [PlaybackQueueItem(mediaId: lastID, title: "Episode 11", subtitle: nil)],
        previousItems: [PlaybackQueueItem(mediaId: firstID, title: "Episode 9", subtitle: nil)],
        startIntent: .resume), engine: engine, relayFactory: { _, _ in FakePlaybackRelay() })
    XCTAssertFalse(controller.canPlayPrevious)
    await controller.start()
    XCTAssertEqual(engine.startPositions, [42_000])
    XCTAssertTrue(controller.canPlayPrevious && controller.canPlayNext)
    XCTAssertTrue(controller.playPreviousFromSystemMedia())
    // A second command during transition cannot duplicate a source request.
    XCTAssertFalse(controller.playPreviousFromSystemMedia())
    for _ in 0..<1_000 {
      if controller.presentation.mediaId == firstID && !controller.isPreparing { break }
      await Task.yield()
    }
    XCTAssertEqual(controller.presentation.mediaId, firstID)
    XCTAssertEqual(engine.startPositions, [42_000, 0])
    XCTAssertFalse(controller.canPlayPrevious)
    XCTAssertTrue(controller.canPlayNext)
    XCTAssertTrue(controller.playNextFromSystemMedia())
    for _ in 0..<1_000 {
      if controller.presentation.mediaId == source.mediaId && !controller.isPreparing { break }
      await Task.yield()
    }
    XCTAssertEqual(engine.startPositions, [42_000, 0, 0])
    XCTAssertTrue(controller.canPlayPrevious && controller.canPlayNext)
    controller.playNextNow()
    for _ in 0..<1_000 {
      if controller.presentation.mediaId == lastID && !controller.isPreparing { break }
      await Task.yield()
    }
    XCTAssertEqual(engine.startPositions, [42_000, 0, 0, 0])
    XCTAssertEqual(client.createdMediaIDs, [source.mediaId, firstID, source.mediaId, lastID])
    XCTAssertFalse(controller.canPlayNext)
    XCTAssertTrue(controller.canPlayPrevious)
    XCTAssertFalse(client.updates.contains { $0.finished })
    await controller.shutdown(saveProgress: false)
    XCTAssertFalse(controller.canPlayPrevious || controller.canPlayNext)
  }

  private func upNextController(
    engine: FakePlaybackEngine, client: FakePlaybackClient, nextID: UUID
  ) -> PlaybackController {
    var preferences = PlaybackPreferences.defaultValue
    preferences.preventSleepDuringPlayback = false
    let relay = FakePlaybackRelay()
    engine.durationMilliseconds = 2_700_000
    return PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: client.source.mediaId, title: "Episode 1", subtitle: "Series · S01 E01",
        queue: [
          PlaybackQueueItem(mediaId: nextID, title: "Episode 2", subtitle: "Series · S01 E02")
        ]),
      engine: engine, preferences: preferences, relayFactory: { _, _ in relay })
  }

  func testUpNextCountsDownInTheLastSecondsAndPlaysNow() async throws {
    let source = Self.source(position: 0, completed: false)
    let nextID = UUID()
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let controller = upNextController(engine: engine, client: client, nextID: nextID)
    await controller.start()

    engine.currentTimeMilliseconds = 2_600_000
    engine.onUpdate?()
    XCTAssertNil(controller.upNext)
    engine.currentTimeMilliseconds = 2_685_000
    engine.onUpdate?()
    XCTAssertEqual(
      controller.upNext,
      PlaybackUpNext(title: "Episode 2", subtitle: "Series · S01 E02", seconds: 15))

    controller.playNextNow()
    XCTAssertNil(controller.upNext)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while controller.presentation.mediaId != nextID && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(controller.presentation.mediaId, nextID)
    // Next Episode in the credits counts the episode as watched, like its real end.
    XCTAssertEqual(client.updates.last?.finished, true)
    XCTAssertEqual(client.updates.last?.position, 2_685_000)
    await controller.shutdown()
  }

  func testNextEpisodeEarlyKeepsThePositionAndInTheCreditsMarksItWatched() async throws {
    for (position, watched) in [(Int64(1_350_000), false), (Int64(2_500_000), true)] {
      let source = Self.source(position: 0, completed: false)
      let nextID = UUID()
      let client = FakePlaybackClient(source: source)
      let engine = FakePlaybackEngine()
      let controller = upNextController(engine: engine, client: client, nextID: nextID)
      await controller.start()
      // Halfway, or in the last tenth before the Up Next card shows.
      engine.currentTimeMilliseconds = position
      engine.onUpdate?()
      XCTAssertNil(controller.upNext)
      controller.playNextNow()
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while controller.presentation.mediaId != nextID && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      XCTAssertEqual(controller.presentation.mediaId, nextID)
      XCTAssertEqual(client.updates.last?.finished, watched)
      XCTAssertEqual(client.updates.last?.position, position)
      await controller.shutdown()
    }
  }

  func testCancellingUpNextStopsAtTheEnd() async throws {
    let source = Self.source(position: 0, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let controller = upNextController(engine: engine, client: client, nextID: UUID())
    await controller.start()
    engine.currentTimeMilliseconds = 2_690_000
    engine.onUpdate?()
    XCTAssertNotNil(controller.upNext)

    controller.dismissUpNext()
    engine.onUpdate?()
    XCTAssertNil(controller.upNext)
    engine.currentTimeMilliseconds = engine.durationMilliseconds
    engine.isPlaying = false
    engine.onEnded?()
    for _ in 0..<3 { await Task.yield() }
    XCTAssertEqual(controller.presentation.mediaId, source.mediaId)
    XCTAssertEqual(client.createdMediaIDs, [source.mediaId])
    await controller.shutdown()
  }

  // MARK: Intro and credits times from the server

  private func segmentsController(
    engine: FakePlaybackEngine, client: FakePlaybackClient, nextID: UUID?,
    skipsAutomatically: Bool = false
  ) -> PlaybackController {
    var preferences = PlaybackPreferences.defaultValue
    preferences.preventSleepDuringPlayback = false
    preferences.skipIntrosAutomatically = skipsAutomatically
    let relay = FakePlaybackRelay()
    engine.durationMilliseconds = 2_700_000
    return PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: client.source.mediaId, title: "Episode 1", subtitle: "Series · S01 E01",
        queue: nextID.map {
          [PlaybackQueueItem(mediaId: $0, title: "Episode 2", subtitle: "Series · S01 E02")]
        } ?? []),
      engine: engine, preferences: preferences, relayFactory: { _, _ in relay })
  }

  private static let segments = MediaSegments(
    introStartMilliseconds: 60_000, introEndMilliseconds: 150_000,
    creditsStartMilliseconds: 2_400_000)

  private func waitForEpisode(_ id: UUID, in controller: PlaybackController) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while controller.presentation.mediaId != id && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(controller.presentation.mediaId, id)
  }

  func testSkipIntroIsOfferedOnlyWhileTheIntroPlaysAndJumpsToItsEnd() async throws {
    var source = Self.source(position: 0, completed: false)
    source.segments = Self.segments
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let controller = segmentsController(engine: engine, client: client, nextID: UUID())
    await controller.start()

    // From one second before the intro until two seconds before its end.
    for (position, offered) in [
      (Int64(58_999), false), (59_000, true), (100_000, true), (147_999, true), (148_000, false),
      (150_000, false),
    ] {
      engine.currentTimeMilliseconds = position
      engine.onUpdate?()
      XCTAssertEqual(controller.showsSkipIntro, offered, "at \(position) ms")
    }
    // Without the automatic setting nothing moves on its own.
    XCTAssertFalse(engine.seekTargets.contains(150_000))

    engine.currentTimeMilliseconds = 100_000
    engine.onUpdate?()
    controller.skipIntro()
    XCTAssertEqual(engine.seekTargets.last, 150_000)
    XCTAssertFalse(controller.showsSkipIntro)
    await controller.shutdown(saveProgress: false)
  }

  func testAutomaticSkipHappensExactlyOncePerEpisode() async throws {
    var source = Self.source(position: 0, completed: false)
    source.segments = Self.segments
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let controller = segmentsController(
      engine: engine, client: client, nextID: UUID(), skipsAutomatically: true)
    await controller.start()

    engine.currentTimeMilliseconds = 59_500
    engine.onUpdate?()
    XCTAssertEqual(engine.seekTargets.filter { $0 == 150_000 }.count, 1)
    XCTAssertFalse(controller.showsSkipIntro)

    // Going back into the intro afterwards plays it; Skip Intro is offered again instead.
    controller.seek(to: 100_000)
    engine.currentTimeMilliseconds = 101_000
    engine.onUpdate?()
    XCTAssertEqual(engine.seekTargets.filter { $0 == 150_000 }.count, 1)
    XCTAssertTrue(controller.showsSkipIntro)
    await controller.shutdown(saveProgress: false)
  }

  func testNoAutomaticSkipAfterMovingIntoTheIntroByHand() async throws {
    var source = Self.source(position: 0, completed: false)
    source.segments = Self.segments
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let controller = segmentsController(
      engine: engine, client: client, nextID: UUID(), skipsAutomatically: true)
    await controller.start()
    engine.currentTimeMilliseconds = 10_000
    engine.onUpdate?()

    controller.seek(to: 80_000)
    engine.currentTimeMilliseconds = 81_000
    engine.onUpdate?()
    XCTAssertFalse(engine.seekTargets.contains(150_000))
    XCTAssertTrue(controller.showsSkipIntro)
    await controller.shutdown(saveProgress: false)
  }

  func testCreditsShowUpNextWithACountdownThatStartsTheNextEpisode() async throws {
    var source = Self.source(position: 0, completed: false)
    source.segments = Self.segments
    let nextID = UUID()
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let controller = segmentsController(engine: engine, client: client, nextID: nextID)
    await controller.start()

    engine.currentTimeMilliseconds = 2_399_000
    engine.onUpdate?()
    XCTAssertNil(controller.upNext)
    engine.currentTimeMilliseconds = 2_400_000
    engine.onUpdate?()
    XCTAssertEqual(
      controller.upNext,
      PlaybackUpNext(
        title: "Episode 2", subtitle: "Series · S01 E02", seconds: 20, duringCredits: true))
    engine.currentTimeMilliseconds = 2_410_000
    engine.onUpdate?()
    XCTAssertEqual(controller.upNext?.seconds, 10)
    XCTAssertEqual(controller.presentation.mediaId, source.mediaId)

    // The countdown runs out long before the file ends: the next episode starts, and this one
    // counts as watched.
    engine.currentTimeMilliseconds = 2_420_000
    engine.onUpdate?()
    try await waitForEpisode(nextID, in: controller)
    XCTAssertEqual(client.updates.last?.finished, true)
    XCTAssertEqual(client.updates.last?.position, 2_420_000)
    // The next episode came without times: nothing is offered there.
    XCTAssertFalse(controller.showsSkipIntro)
    await controller.shutdown()
  }

  func testWatchCreditsPlaysThemAndContinuesAtTheEnd() async throws {
    var source = Self.source(position: 0, completed: false)
    source.segments = Self.segments
    let nextID = UUID()
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let controller = segmentsController(engine: engine, client: client, nextID: nextID)
    await controller.start()
    engine.currentTimeMilliseconds = 2_405_000
    engine.onUpdate?()
    XCTAssertEqual(controller.upNext?.duringCredits, true)

    controller.dismissUpNext()
    for position in [Int64(2_430_000), 2_690_000] {
      engine.currentTimeMilliseconds = position
      engine.onUpdate?()
      XCTAssertNil(controller.upNext)
      XCTAssertEqual(controller.presentation.mediaId, source.mediaId)
    }
    engine.currentTimeMilliseconds = engine.durationMilliseconds
    engine.isPlaying = false
    engine.onEnded?()
    try await waitForEpisode(nextID, in: controller)
    await controller.shutdown()
  }

  func testMovingIntoTheCreditsStartsTheCountdownThere() async throws {
    var source = Self.source(position: 0, completed: false)
    source.segments = Self.segments
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let controller = segmentsController(engine: engine, client: client, nextID: UUID())
    await controller.start()
    engine.currentTimeMilliseconds = 1_000_000
    engine.onUpdate?()

    controller.seek(to: 2_500_000)
    engine.currentTimeMilliseconds = 2_500_000
    engine.onUpdate?()
    XCTAssertEqual(controller.upNext?.seconds, 20)
    XCTAssertEqual(controller.presentation.mediaId, source.mediaId)
    await controller.shutdown(saveProgress: false)
  }

  func testChoicesTurnSkipIntroAndTheCreditsCardOff() async throws {
    var source = Self.source(position: 0, completed: false)
    source.segments = Self.segments
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    var preferences = PlaybackPreferences.defaultValue
    preferences.preventSleepDuringPlayback = false
    preferences.introSkipping = .off
    preferences.upNextAtCredits = false
    let relay = FakePlaybackRelay()
    engine.durationMilliseconds = 2_700_000
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: source.mediaId, title: "Episode 1", subtitle: nil,
        queue: [PlaybackQueueItem(mediaId: UUID(), title: "Episode 2", subtitle: nil)]),
      engine: engine, preferences: preferences, relayFactory: { _, _ in relay })
    await controller.start()
    engine.currentTimeMilliseconds = 100_000
    engine.onUpdate?()
    XCTAssertFalse(controller.showsSkipIntro)
    // Credits known but turned off: the card waits for the last seconds.
    engine.currentTimeMilliseconds = 2_450_000
    engine.onUpdate?()
    XCTAssertNil(controller.upNext)
    engine.currentTimeMilliseconds = 2_685_000
    engine.onUpdate?()
    XCTAssertEqual(controller.upNext?.duringCredits, false)
    await controller.shutdown(saveProgress: false)
  }

  func testWithoutANextEpisodeOrWithoutTimesNothingChanges() async throws {
    // The last episode gets no card in its credits.
    var last = Self.source(position: 0, completed: false)
    last.segments = Self.segments
    let lastEngine = FakePlaybackEngine()
    let lastController = segmentsController(
      engine: lastEngine, client: FakePlaybackClient(source: last), nextID: nil)
    await lastController.start()
    lastEngine.currentTimeMilliseconds = 2_450_000
    lastEngine.onUpdate?()
    XCTAssertNil(lastController.upNext)
    await lastController.shutdown(saveProgress: false)

    // A server without times: no Skip Intro, and Up Next only in the last seconds, with Cancel.
    let plain = Self.source(position: 0, completed: false)
    let engine = FakePlaybackEngine()
    let controller = segmentsController(
      engine: engine, client: FakePlaybackClient(source: plain), nextID: UUID(),
      skipsAutomatically: true)
    await controller.start()
    engine.currentTimeMilliseconds = 100_000
    engine.onUpdate?()
    XCTAssertFalse(controller.showsSkipIntro)
    engine.currentTimeMilliseconds = 2_450_000
    engine.onUpdate?()
    XCTAssertNil(controller.upNext)
    engine.currentTimeMilliseconds = 2_685_000
    engine.onUpdate?()
    XCTAssertEqual(
      controller.upNext,
      PlaybackUpNext(title: "Episode 2", subtitle: "Series · S01 E02", seconds: 15))
    XCTAssertTrue(engine.seekTargets.isEmpty)
    await controller.shutdown(saveProgress: false)
  }

  private static func screenTime(_ state: ScreenTimeState) -> ScreenTimeStatus {
    ScreenTimeStatus(
      state: state, reason: state == .open ? .none : .bedtime, watchedMinutesToday: 40,
      limitMinutes: nil, remainingMinutes: nil, closesAt: "2027-11-09T19:30:00Z",
      titleEndsBy: "2027-11-09T20:00:00Z", opensAt: state == .open ? nil : "2027-11-10T07:00:00Z",
      lockScope: .playbackOnly, ending: .finishTitle, oneMoreTitleAvailable: false)
  }

  func testScreenTimeEndsWithTheGoodNightScreenInsteadOfTheNextEpisode() async throws {
    var source = Self.source(position: 0, completed: false)
    source.screenTime = Self.screenTime(.open)
    let client = FakePlaybackClient(source: source)
    client.ownScreenTimeStatus = Self.screenTime(.closed)
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    var preferences = PlaybackPreferences.defaultValue
    preferences.preventSleepDuringPlayback = false
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: source.mediaId, title: "Episode 1", subtitle: nil,
        queue: [PlaybackQueueItem(mediaId: UUID(), title: "Episode 2", subtitle: nil)]),
      engine: engine, preferences: preferences, relayFactory: { _, _ in relay })

    await controller.start()
    XCTAssertEqual(controller.screenTime?.state, .open)
    engine.currentTimeMilliseconds = engine.durationMilliseconds
    engine.isPlaying = false
    engine.onEnded?()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !controller.showsGoodNight && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }

    XCTAssertTrue(controller.showsGoodNight)
    XCTAssertEqual(client.createdMediaIDs, [source.mediaId], "The next episode must not start.")
    XCTAssertNil(controller.errorMessage)
    XCTAssertNil(controller.upNext)
    await controller.shutdown()
  }

  func testAnOpenProfileStillPlaysTheNextEpisode() async throws {
    var source = Self.source(position: 0, completed: false)
    source.screenTime = Self.screenTime(.open)
    let client = FakePlaybackClient(source: source)
    client.ownScreenTimeStatus = Self.screenTime(.open)
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    var preferences = PlaybackPreferences.defaultValue
    preferences.preventSleepDuringPlayback = false
    let nextID = UUID()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: source.mediaId, title: "Episode 1", subtitle: nil,
        queue: [PlaybackQueueItem(mediaId: nextID, title: "Episode 2", subtitle: nil)]),
      engine: engine, preferences: preferences, relayFactory: { _, _ in relay })

    await controller.start()
    engine.currentTimeMilliseconds = engine.durationMilliseconds
    engine.isPlaying = false
    engine.onEnded?()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while controller.presentation.mediaId != nextID && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(controller.presentation.mediaId, nextID)
    XCTAssertFalse(controller.showsGoodNight)
    await controller.shutdown()
  }

  func testAScreenTimeRefusalShowsTheGoodNightScreenNotAnError() async throws {
    let source = Self.source(position: 0, completed: false)
    let client = FakePlaybackClient(source: source)
    client.ownScreenTimeStatus = Self.screenTime(.closed)
    client.nextCreationError = APIClientError.httpFailure(
      status: 403, retryAfter: nil, code: "screen_time_bedtime",
      message: "It's bedtime. Aurelia opens again at 07:00.")
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(mediaId: source.mediaId, title: "Episode 1", subtitle: nil),
      engine: engine, relayFactory: { _, _ in relay })

    await controller.start()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !controller.showsGoodNight && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(controller.showsGoodNight)
    XCTAssertNil(controller.errorMessage)
    XCTAssertEqual(controller.screenTime?.state, .closed)
    await controller.shutdown()
  }

  func testEndOfEpisodeSleepTimerStopsQueueAdvance() async throws {
    let source = Self.source(position: 0, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: source.mediaId,
        title: "Episode 1",
        subtitle: nil,
        queue: [PlaybackQueueItem(mediaId: UUID(), title: "Episode 2", subtitle: nil)]),
      engine: engine,
      relayFactory: { _, _ in relay })

    await controller.start()
    controller.setSleepTimer(.endOfEpisode)
    engine.currentTimeMilliseconds = engine.durationMilliseconds
    engine.onEnded?()
    for _ in 0..<3 { await Task.yield() }

    XCTAssertEqual(controller.presentation.mediaId, source.mediaId)
    XCTAssertEqual(client.createdMediaIDs, [source.mediaId])
    XCTAssertEqual(controller.sleepTimer, .off)
    await controller.shutdown()
  }

  func testTimedSleepTimerPausesPlaybackAndResets() async throws {
    let source = Self.source(position: 0, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    var preferences = PlaybackPreferences.defaultValue
    preferences.preventSleepDuringPlayback = false
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: source.mediaId,
        title: "Movie",
        subtitle: nil),
      engine: engine,
      preferences: preferences,
      relayFactory: { _, _ in relay })

    await controller.start()
    XCTAssertTrue(controller.isPlaying)
    controller.setSleepTimer(.minutes(0))
    for _ in 0..<5 { await Task.yield() }

    XCTAssertFalse(controller.isPlaying)
    XCTAssertFalse(engine.isPlaying)
    XCTAssertEqual(controller.sleepTimer, .off)
    await controller.shutdown()
  }

  func testImmediateSleepTimerDoesNotRepeatAnUnacknowledgedDecoderPause() async throws {
    let source = Self.source(position: 0, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    engine.deferPauseStateChange = true
    let relay = FakePlaybackRelay()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(mediaId: source.mediaId, title: "Movie", subtitle: nil),
      engine: engine,
      relayFactory: { _, _ in relay })

    await controller.start()
    controller.setSleepTimer(.minutes(0))
    XCTAssertEqual(engine.pauseCalls, 1)
    XCTAssertTrue(engine.isPlaying)
    XCTAssertFalse(controller.isPlaying)
    XCTAssertEqual(controller.sleepTimer, .off)
    for _ in 0..<3 { engine.onUpdate?() }
    XCTAssertEqual(engine.pauseCalls, 1)
    engine.completeDeferredPause()
    XCTAssertFalse(engine.isPlaying)
    XCTAssertFalse(controller.isPlaying)
    await controller.shutdown(saveProgress: false)
  }

  func testPausingLetsTheMacSleepAndPlayingKeepsItAwakeAgain() async throws {
    let source = Self.source(position: 0, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    var preferences = PlaybackPreferences.defaultValue
    preferences.preventSleepDuringPlayback = true
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(mediaId: source.mediaId, title: "Movie", subtitle: nil),
      engine: engine,
      preferences: preferences,
      relayFactory: { _, _ in FakePlaybackRelay() })

    await controller.start()
    XCTAssertTrue(controller.preventsSystemSleep)
    XCTAssertTrue(controller.pause())
    XCTAssertFalse(controller.preventsSystemSleep)
    XCTAssertTrue(controller.play())
    XCTAssertTrue(controller.preventsSystemSleep)
    await controller.shutdown(saveProgress: false)
    XCTAssertFalse(controller.preventsSystemSleep)
  }

  func testExpiringSleepTimerDoesNotRepeatAnUnacknowledgedDecoderPause() async throws {
    let source = Self.source(position: 0, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    engine.deferPauseStateChange = true
    let relay = FakePlaybackRelay()
    let clock = SleepTimerTestClock()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(mediaId: source.mediaId, title: "Movie", subtitle: nil),
      engine: engine,
      relayFactory: { _, _ in relay },
      sleepTimerSleep: clock.sleep)

    await controller.start()
    controller.setSleepTimer(.minutes(1))
    for _ in 0..<1_000 {
      if clock.pending != nil { break }
      await Task.yield()
    }
    XCTAssertNotNil(clock.pending)
    XCTAssertEqual(clock.delays, [60])
    clock.wake()
    for _ in 0..<1_000 {
      if controller.sleepTimer == .off { break }
      await Task.yield()
    }
    XCTAssertEqual(controller.sleepTimer, .off)
    for _ in 0..<1_000 {
      if client.sleepTimerSignals > 0 { break }
      await Task.yield()
    }
    XCTAssertEqual(client.sleepTimerSignals, 1, "The server learns that the sleep timer ended.")
    XCTAssertTrue(controller.sleepTimerFinished, "The player closes when the sleep timer ends.")
    XCTAssertFalse(controller.preventsSystemSleep, "The Mac may sleep once the timer ended.")
    XCTAssertEqual(engine.pauseCalls, 1)
    XCTAssertTrue(engine.isPlaying)
    XCTAssertFalse(controller.isPlaying)
    for _ in 0..<3 { engine.onUpdate?() }
    XCTAssertEqual(engine.pauseCalls, 1)
    engine.completeDeferredPause()
    XCTAssertFalse(engine.isPlaying)
    await controller.shutdown(saveProgress: false)
  }

  func testShutdownQuarantinesAnUncooperativeSleepTimerCompletion() async throws {
    let source = Self.source(position: 0, completed: false)
    let client = FakePlaybackClient(source: source)
    let engine = FakePlaybackEngine()
    let relay = FakePlaybackRelay()
    let clock = SleepTimerTestClock()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(mediaId: source.mediaId, title: "Movie", subtitle: nil),
      engine: engine,
      relayFactory: { _, _ in relay },
      sleepTimerSleep: clock.sleep)

    await controller.start()
    controller.setSleepTimer(.minutes(1))
    for _ in 0..<1_000 {
      if clock.pending != nil { break }
      await Task.yield()
    }
    XCTAssertNotNil(clock.pending)
    await controller.shutdown(saveProgress: false)
    let pauseCalls = engine.pauseCalls
    let playCalls = engine.playCalls
    clock.wake()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(engine.pauseCalls, pauseCalls)
    XCTAssertEqual(engine.playCalls, playCalls)
    XCTAssertTrue(engine.didStop)
    XCTAssertFalse(controller.isPlaying)
    XCTAssertFalse(controller.isPreparing)
    XCTAssertEqual(client.sleepTimerSignals, 0)
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
private final class SleepTimerTestClock {
  var delays: [TimeInterval] = []
  var pending: CheckedContinuation<Void, Never>?

  func sleep(_ delay: TimeInterval) async throws {
    delays.append(delay)
    await withCheckedContinuation { pending = $0 }
  }

  func wake() {
    let continuation = pending
    pending = nil
    continuation?.resume()
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
  var createdMediaIDs: [UUID] = []
  var sleepTimerSignals = 0
  var failNextCreations = 0
  var nextCreationError: Error?
  var beforeProgressReturn: (() async -> Void)?

  func sleepTimerEnded() async { sleepTimerSignals += 1 }

  /// What the server says about the profile's screen time when the player asks.
  var ownScreenTimeStatus: ScreenTimeStatus?
  func ownScreenTime() async throws -> ScreenTimeStatus? { ownScreenTimeStatus }

  init(source: PlaybackSourceResponse) {
    self.source = source
  }

  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
    createdMediaIDs.append(mediaId)
    if let error = nextCreationError {
      nextCreationError = nil
      throw error
    }
    if failNextCreations > 0 {
      failNextCreations -= 1
      throw URLError(.networkConnectionLost)
    }
    if mediaId == source.mediaId { return source }
    return PlaybackSourceResponse(
      id: UUID(),
      mediaId: mediaId,
      streamPath: source.streamPath,
      contentType: source.contentType,
      contentLength: source.contentLength,
      expiresAt: source.expiresAt,
      progress: PlaybackProgressResponse(
        mediaId: mediaId,
        positionMilliseconds: source.progress.positionMilliseconds,
        durationMilliseconds: source.progress.durationMilliseconds,
        isCompleted: source.progress.isCompleted,
        lastPlayedAt: source.progress.lastPlayedAt,
        updatedAt: source.progress.updatedAt))
  }

  func updatePlaybackProgress(
    mediaId: UUID,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64,
    isFinished: Bool
  ) async throws -> PlaybackProgressResponse {
    updates.append(
      Update(
        position: positionMilliseconds,
        duration: durationMilliseconds,
        finished: isFinished))
    await beforeProgressReturn?()
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
final class FakePlaybackRelay: PlaybackRelayProtocol {
  let localURL: URL
  var didStop = false
  private(set) var sourceURLs: [URL] = []
  private(set) var hasFailureHandler = false

  init(localURL: URL = URL(string: "http://127.0.0.1:54321/stream/local-secret")!) {
    self.localURL = localURL
  }

  func start() async throws -> URL { localURL }
  func updateSourceURL(_ url: URL) { sourceURLs.append(url) }
  func setFailureHandler(
    _ handler: @escaping @MainActor @Sendable (PlaybackStreamFailure) -> Void
  ) {
    hasFailureHandler = true
  }
  func stop() { didStop = true }
}

@MainActor
final class FakePlaybackEngine: PlaybackEngine {
  var onUpdate: (() -> Void)?
  var onEnded: (() -> Void)?
  var onError: ((String) -> Void)?
  var isPlaying = false
  var isSeekable = true
  var currentTimeMilliseconds: Int64 = 0
  var durationMilliseconds: Int64 = 120_000
  var volume: Double = 1
  var isMuted = false
  var playbackRate: Double = 1
  let audioTracks = [PlaybackTrack(id: 2, title: "Main - [English]")]
  let subtitleTracks = [PlaybackTrack(id: 7, title: "English SDH - [English]")]
  let chapters = [
    PlaybackChapter(
      index: 0, title: "Chapter 1", timeOffsetMilliseconds: 0, durationMilliseconds: 60_000),
    PlaybackChapter(
      index: 1, title: "Chapter 2", timeOffsetMilliseconds: 60_000, durationMilliseconds: 60_000),
  ]
  var currentChapterIndex: Int32? = 0
  var selectedAudioTrackID: Int32?
  var selectedSubtitleTrackID: Int32?
  var loadedURL: URL?
  var trackScope: UUID?
  private(set) var loadedScopes: [UUID?] = []
  var didStop = false
  var playCalls = 0
  var pauseCalls = 0
  var deferPlayStateChange = false
  var deferPauseStateChange = false
  var deferSeekStateChange = false
  private(set) var pendingSeekTarget: Int64?
  var opensAtStartPosition = false
  private(set) var startPositions: [Int64] = []
  private(set) var seekTargets: [Int64] = []

  func attach(to view: NSView) {}
  func load(url: URL, startAt milliseconds: Int64) {
    startPositions.append(milliseconds)
    load(url: url)
  }
  func load(url: URL) {
    loadedURL = url
    loadedScopes.append(trackScope)
    currentTimeMilliseconds = 0
    isPlaying = false
    pendingSeekTarget = nil
  }
  func play() {
    playCalls += 1
    if !deferPlayStateChange { isPlaying = true }
    onUpdate?()
  }
  func pause() {
    pauseCalls += 1
    if !deferPauseStateChange { isPlaying = false }
    // Also exercises a synchronous update while an asynchronous pause is still
    // pending. The controller must not recursively issue additional pauses.
    onUpdate?()
  }
  func completeDeferredPlay() {
    isPlaying = true
    onUpdate?()
  }
  func completeDeferredPause() {
    isPlaying = false
    onUpdate?()
  }
  func stop() {
    didStop = true
    isPlaying = false
    pendingSeekTarget = nil
  }
  func seek(to milliseconds: Int64) {
    seekTargets.append(milliseconds)
    if deferSeekStateChange {
      pendingSeekTarget = milliseconds
      return
    }
    currentTimeMilliseconds = milliseconds
    onUpdate?()
  }
  func completeDeferredSeek() {
    guard let pendingSeekTarget else { return }
    self.pendingSeekTarget = nil
    currentTimeMilliseconds = pendingSeekTarget
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
  func selectChapter(index: Int32) {
    currentChapterIndex = index
    if let chapter = chapters.first(where: { $0.index == index }) {
      currentTimeMilliseconds = chapter.timeOffsetMilliseconds
    }
    onUpdate?()
  }
}
