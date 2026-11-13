import AppKit
import Foundation
import XCTest

@testable import Aurelia

@MainActor
final class WishAndSleepGoodNightTests: XCTestCase {
  func testPlaybackPreferencesDecodeLegacyJsonWithShowGoodNightOff() throws {
    let legacyJson = """
      {
        "automaticResume": true,
        "defaultPlaybackRate": 1.0,
        "defaultVolume": 0.8,
        "controlsAutoHideDelay": 3.0,
        "seekInterval": 15,
        "preventSleepDuringPlayback": true,
        "automaticallyPlayNextEpisode": true,
        "nightMode": false
      }
      """
    let decoded = try JSONDecoder().decode(PlaybackPreferences.self, from: Data(legacyJson.utf8))
    XCTAssertFalse(decoded.showGoodNightOnSleepTimer)

    var updated = decoded
    updated.showGoodNightOnSleepTimer = true
    let reencoded = try JSONEncoder().encode(updated)
    let roundTripped = try JSONDecoder().decode(PlaybackPreferences.self, from: reencoded)
    XCTAssertTrue(roundTripped.showGoodNightOnSleepTimer)
  }

  func testScreenTimeTextGoodNightFormatsSleepTimerAndPowerModes() {
    let sleeping = SleepTimerEndedResponse(powerMode: "sleep", afterSleepTimer: true, minutes: 5)
    let sleepCopy = ScreenTimeText.goodNight(sleepTimerStatus: sleeping, name: "Robin")
    XCTAssertEqual(sleepCopy.title, "Good night, Robin")
    XCTAssertEqual(
      sleepCopy.text,
      "Sleep well. The server goes to sleep in about 5 minutes unless someone keeps watching.")

    let shuttingDown = SleepTimerEndedResponse(
      powerMode: "shutdown", afterSleepTimer: true, minutes: 1)
    let shutdownCopy = ScreenTimeText.goodNight(sleepTimerStatus: shuttingDown, name: "")
    XCTAssertEqual(shutdownCopy.title, "Good night")
    XCTAssertEqual(
      shutdownCopy.text,
      "Sleep well. The server turns off in about 1 minute unless someone keeps watching.")

    let disabled = SleepTimerEndedResponse(powerMode: "sleep", afterSleepTimer: false, minutes: 5)
    XCTAssertEqual(
      ScreenTimeText.goodNight(sleepTimerStatus: disabled, name: "Robin").text, "Sleep well.")

    let stopMode = SleepTimerEndedResponse(powerMode: "stop", afterSleepTimer: true, minutes: 5)
    XCTAssertEqual(
      ScreenTimeText.goodNight(sleepTimerStatus: stopMode, name: "Robin").text, "Sleep well.")
  }

  func testSleepTimerShowsGoodNightReleasesWakeLockAndAutoClosesAfterFiveMinutes() async throws {
    let source = Self.makeSource()
    let client = SleepGoodNightClientFake(source: source)
    client.sleepEndedResponse = SleepTimerEndedResponse(
      powerMode: "sleep", afterSleepTimer: true, minutes: 5)
    let engine = SleepGoodNightEngineFake()
    let relay = SleepGoodNightRelayFake()
    let clock = SleepGoodNightClockFake()
    var prefs = PlaybackPreferences.defaultValue
    prefs.showGoodNightOnSleepTimer = true
    prefs.preventSleepDuringPlayback = true

    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(mediaId: source.mediaId, title: "Night Film", subtitle: nil),
      engine: engine,
      preferences: prefs,
      relayFactory: { _, _ in relay },
      sleepTimerSleep: clock.sleep)

    await controller.start()
    XCTAssertTrue(controller.preventsSystemSleep)

    controller.setSleepTimer(.minutes(1))
    await clock.waitUntilPendingCount(1)
    XCTAssertEqual(clock.delays, [60])

    clock.wakeFirst()
    for _ in 0..<1_000 {
      if controller.showsGoodNight && clock.delays.count >= 2 && controller.sleepTimerEndedStatus != nil {
        break
      }
      await Task.yield()
    }

    XCTAssertTrue(controller.showsGoodNight)
    XCTAssertTrue(controller.showsSleepTimerGoodNight)
    XCTAssertFalse(controller.sleepTimerFinished)
    XCTAssertFalse(controller.preventsSystemSleep, "Wake lock must end when Good Night shows.")
    XCTAssertEqual(controller.sleepTimerEndedStatus?.powerMode, "sleep")
    XCTAssertEqual(controller.sleepTimerEndedStatus?.minutes, 5)
    XCTAssertEqual(engine.pauseCalls, 1)
    XCTAssertEqual(clock.delays, [60, 300], "Auto-close waits 5 minutes (300 seconds).")

    clock.wakeFirst()
    for _ in 0..<1_000 {
      if controller.sleepTimerFinished { break }
      await Task.yield()
    }
    XCTAssertTrue(controller.sleepTimerFinished)
    await controller.shutdown(saveProgress: false)
  }

  func testSleepTimerGoodNightDismissalCancelsAutoCloseTimer() async throws {
    let source = Self.makeSource()
    let client = SleepGoodNightClientFake(source: source)
    let engine = SleepGoodNightEngineFake()
    let relay = SleepGoodNightRelayFake()
    let clock = SleepGoodNightClockFake()
    var prefs = PlaybackPreferences.defaultValue
    prefs.showGoodNightOnSleepTimer = true

    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(mediaId: source.mediaId, title: "Night Film", subtitle: nil),
      engine: engine,
      preferences: prefs,
      relayFactory: { _, _ in relay },
      sleepTimerSleep: clock.sleep)

    await controller.start()
    controller.setSleepTimer(.minutes(1))
    await clock.waitUntilPendingCount(1)
    clock.wakeFirst()
    await clock.waitUntilPendingCount(1)
    XCTAssertTrue(controller.showsSleepTimerGoodNight)
    XCTAssertFalse(controller.sleepTimerFinished)

    controller.dismissSleepGoodNight()
    XCTAssertFalse(controller.showsSleepTimerGoodNight)
    XCTAssertNil(controller.sleepTimerEndedStatus)

    clock.wakeFirst()
    for _ in 0..<30 { await Task.yield() }
    XCTAssertFalse(controller.sleepTimerFinished)
    await controller.shutdown(saveProgress: false)
  }

  func testWishPresentationBadgeNotificationAndYearValidation() {
    let summary = WishSummaryResponse(openCount: 3, newlyFulfilledCount: 2)
    XCTAssertEqual(WishPresentation.badgeCount(summary: summary, isAdmin: false), 2)
    XCTAssertEqual(WishPresentation.badgeCount(summary: summary, isAdmin: true), 5)
    XCTAssertEqual(WishPresentation.badgeCount(summary: nil, isAdmin: true), 0)

    XCTAssertNil(
      WishPresentation.notificationEvent(previous: nil, current: summary, isAdmin: true))

    let prev = WishSummaryResponse(openCount: 1, newlyFulfilledCount: 0)
    let newOpen = WishSummaryResponse(openCount: 2, newlyFulfilledCount: 0)
    let sampleWish = WishSummary(
      id: UUID(),
      userId: UUID(),
      userName: "Mama",
      kind: .series,
      provider: "tmdb",
      providerMediaId: "42",
      title: "Top Gear Specials",
      year: 2007,
      overview: nil,
      posterPath: "/poster.jpg",
      posterUrl: nil,
      ageRating: nil,
      minimumAge: nil,
      note: nil,
      state: .open,
      resolvedByUserId: nil,
      resolvedByUserName: nil,
      resolutionNote: nil,
      fulfilledMediaItemId: nil,
      createdAt: "2026-11-13T10:00:00Z",
      resolvedAt: nil,
      seenByWisherAt: nil,
      canSupport: true,
      supportedByCaller: false,
      supporters: [],
      suggestions: [])

    let adminEvent = WishPresentation.notificationEvent(
      previous: prev, current: newOpen, isAdmin: true, latestWish: sampleWish)
    XCTAssertEqual(adminEvent?.title, "New wish: Top Gear Specials")
    XCTAssertEqual(adminEvent?.body, "From Mama.")
    XCTAssertNil(
      WishPresentation.notificationEvent(previous: prev, current: newOpen, isAdmin: false))

    let fulfilled = WishSummaryResponse(openCount: 0, newlyFulfilledCount: 1)
    let userEvent = WishPresentation.notificationEvent(
      previous: prev, current: fulfilled, isAdmin: false, latestWish: sampleWish)
    XCTAssertEqual(userEvent?.title, "Your wish is here")
    XCTAssertEqual(userEvent?.body, "Top Gear Specials is now in the library.")

    XCTAssertEqual(WishPresentation.parseYear("").year, nil)
    XCTAssertNil(WishPresentation.parseYear("").error)
    XCTAssertEqual(WishPresentation.parseYear("2024").year, 2024)
    XCTAssertNotNil(WishPresentation.parseYear("1800").error)
    XCTAssertNotNil(WishPresentation.parseYear("abcd").error)
  }

  func testWishNotificationDelegateHopsFromBackgroundQueueOntoMainActor() {
    let lock = NSLock()
    var openCount = 0
    var ranOnMain = false
    let delegate = WishNotificationDelegate {
      dispatchPrecondition(condition: .onQueue(.main))
      lock.lock()
      openCount += 1
      ranOnMain = Thread.isMainThread
      lock.unlock()
    }

    let matchedDone = expectation(description: "matched notification hops onto main actor")
    DispatchQueue.global(qos: .userInitiated).async {
      delegate.handleNotificationActivation(
        categoryIdentifier: WishNotificationCenter.categoryIdentifier
      ) {
        matchedDone.fulfill()
      }
    }
    wait(for: [matchedDone], timeout: 5)
    lock.lock()
    XCTAssertEqual(openCount, 1)
    XCTAssertTrue(ranOnMain)
    lock.unlock()

    let ignoredDone = expectation(description: "unrelated category completes without opening wishes")
    DispatchQueue.global(qos: .background).async {
      delegate.handleNotificationActivation(categoryIdentifier: "other.category") {
        ignoredDone.fulfill()
      }
    }
    wait(for: [ignoredDone], timeout: 5)
    lock.lock()
    XCTAssertEqual(openCount, 1)
    lock.unlock()
  }

  func testWishPosterCacheDeduplicatesRequestsAndPrunesBoundedDiskCache() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AureliaWishPosterCacheTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let disk = ArtworkDiskCache(directory: tempDir, byteLimit: 512)
    let profile = Self.makeProfile()
    // Valid 1x1 transparent PNG
    let pngBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    let pngData = Data(base64Encoded: pngBase64)!

    var fetchCalls: [String] = []
    let cache = WishPosterCache(diskCache: disk) { path, _, _ in
      fetchCalls.append(path)
      if path == "/broken.jpg" { throw APIClientError.invalidResponse }
      return pngData
    }

    let img1 = await cache.image(posterPath: "/valid.jpg", width: 185, profile: profile)
    let img2 = await cache.image(posterPath: "/valid.jpg", width: 185, profile: profile)
    XCTAssertNotNil(img1)
    XCTAssertNotNil(img2)
    XCTAssertEqual(fetchCalls.filter { $0 == "/valid.jpg" }.count, 1)

    let failed1 = await cache.image(posterPath: "/broken.jpg", width: 185, profile: profile)
    let failed2 = await cache.image(posterPath: "/broken.jpg", width: 185, profile: profile)
    XCTAssertNil(failed1)
    XCTAssertNil(failed2)
    XCTAssertEqual(
      fetchCalls.filter { $0 == "/broken.jpg" }.count, 1,
      "Failed poster paths are remembered up to cap instead of refetching endlessly.")

    for i in 0..<8 {
      disk.store(Data(repeating: UInt8(i), count: 200), forKey: "key-\(i)")
    }
    disk.prune()
    let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.fileSizeKey])
    let totalBytes = try files.reduce(0) { sum, url in
      sum + ((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    XCTAssertLessThanOrEqual(totalBytes, 512)
  }

  func testSidebarAndDestinationStoreIncludeWishes() {
    XCTAssertTrue(SidebarPreferences.defaultOrder.contains(.wishes))
    let suite = "Aurelia.WishDestinationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = LibraryDestinationStore(defaults: defaults)
    let serverId = UUID()
    let userId = UUID()
    store.save(.wishes, serverId: serverId, userId: userId)
    XCTAssertEqual(store.load(serverId: serverId, userId: userId), .wishes)
  }

  private static func makeProfile() -> StoredServerProfile {
    StoredServerProfile(
      serverId: UUID(),
      name: "Test Server",
      baseURL: URL(string: "https://server.test:43111")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "synthetic-test-token",
      sessionId: UUID(),
      expiresAt: "2099-01-01T00:00:00Z")
  }

  private static func makeSource() -> PlaybackSourceResponse {
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
        positionMilliseconds: 0,
        durationMilliseconds: 120_000,
        isCompleted: false,
        lastPlayedAt: nil,
        updatedAt: nil))
  }
}

@MainActor
private final class SleepGoodNightClockFake {
  var delays: [TimeInterval] = []
  var pending: [CheckedContinuation<Void, Error>] = []

  func sleep(_ delay: TimeInterval) async throws {
    delays.append(delay)
    try await withCheckedThrowingContinuation { continuation in
      pending.append(continuation)
    }
  }

  func wakeFirst() {
    guard !pending.isEmpty else { return }
    let next = pending.removeFirst()
    next.resume()
  }

  func waitUntilPendingCount(_ target: Int) async {
    for _ in 0..<1_000 {
      if pending.count >= target { break }
      await Task.yield()
    }
  }
}

@MainActor
private final class SleepGoodNightClientFake: PlaybackClientProtocol {
  let profile = StoredServerProfile(
    serverId: UUID(),
    name: "Test",
    baseURL: URL(string: "https://server.test:43111")!,
    publicKeyFingerprint: String(repeating: "A", count: 64),
    token: "synthetic-token",
    sessionId: UUID(),
    expiresAt: "2099-01-01T00:00:00Z")
  let source: PlaybackSourceResponse
  var sleepEndedResponse: SleepTimerEndedResponse?

  init(source: PlaybackSourceResponse) {
    self.source = source
  }

  func sleepTimerEnded() async {}
  func sleepTimerEndedStatus() async -> SleepTimerEndedResponse? { sleepEndedResponse }

  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse { source }

  func updatePlaybackProgress(
    mediaId: UUID, positionMilliseconds: Int64, durationMilliseconds: Int64, isFinished: Bool
  ) async throws -> PlaybackProgressResponse {
    PlaybackProgressResponse(
      mediaId: mediaId,
      positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds,
      isCompleted: isFinished,
      lastPlayedAt: nil,
      updatedAt: nil)
  }

  func revokePlayback(id: UUID) async throws {}

  func streamURL(path: String) throws -> URL {
    URL(string: path, relativeTo: profile.baseURL)!.absoluteURL
  }
}

@MainActor
private final class SleepGoodNightRelayFake: PlaybackRelayProtocol {
  func start() async throws -> URL { URL(string: "http://127.0.0.1:54321/stream/synthetic")! }
  func updateSourceURL(_ url: URL) {}
  func stop() {}
}

@MainActor
private final class SleepGoodNightEngineFake: PlaybackEngine {
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
  var audioTracks: [PlaybackTrack] = []
  var subtitleTracks: [PlaybackTrack] = []
  var chapters: [PlaybackChapter] = []
  var currentChapterIndex: Int32?
  var selectedAudioTrackID: Int32?
  var selectedSubtitleTrackID: Int32?
  var pauseCalls = 0

  func attach(to view: NSView) {}
  func load(url: URL) {}
  func play() {
    isPlaying = true
    onUpdate?()
  }
  func pause() {
    pauseCalls += 1
    isPlaying = false
    onUpdate?()
  }
  func stop() { isPlaying = false }
  func seek(to milliseconds: Int64) {
    currentTimeMilliseconds = milliseconds
    onUpdate?()
  }
  func selectAudioTrack(id: Int32) { selectedAudioTrackID = id }
  func selectSubtitleTrack(id: Int32?) { selectedSubtitleTrackID = id }
  func selectChapter(index: Int32) { currentChapterIndex = index }
}
