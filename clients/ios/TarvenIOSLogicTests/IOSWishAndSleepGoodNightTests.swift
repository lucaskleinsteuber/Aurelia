import Foundation
import Testing
@preconcurrency import UserNotifications

@Suite("iPhone and iPad Family Wishes and Sleep Timer Good Night")
struct IOSWishAndSleepGoodNightTests {
  private static let fingerprint = String(repeating: "a1", count: 32)
  private static let serverID = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!
  private static let profileID = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000002")!
  private static let mediaID = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000003")!
  private static let wishID = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000004")!

  private static var baseURL: URL { URL(string: "https://192.168.1.50:43111")! }
  private static var connection: IOSStoredConnection {
    IOSStoredConnection(
      serverID: serverID, name: "Home Server", baseURL: baseURL, fingerprint: fingerprint,
      deviceToken: "device-token-synthetic-00000000000000000001", deviceSessionID: UUID())
  }
  private static var session: IOSProfileSession {
    IOSProfileSession(
      user: IOSUser(id: profileID, username: "Lucas", role: "owner"),
      sessionId: UUID(),
      token: "profile-token-synthetic-00000000000000000001",
      expiresAt: IOSServerDate.string(Date().addingTimeInterval(3600)))
  }

  @Test func legacyPlaybackPreferencesDecodeSleepGoodNightAsFalse() throws {
    let legacyJSON = """
      {"automaticResume":true,"automaticallyPlayNextEpisode":false,"defaultPlaybackRate":1.25}
      """
    let decoded = try JSONDecoder().decode(IOSPlaybackPreferences.self, from: Data(legacyJSON.utf8))
    #expect(!decoded.showGoodNightOnSleepTimer)
    #expect(!decoded.automaticallyPlayNextEpisode)
    #expect(decoded.defaultPlaybackRate == 1.25)

    var updated = decoded
    updated.showGoodNightOnSleepTimer = true
    let roundTripped = try JSONDecoder().decode(
      IOSPlaybackPreferences.self, from: JSONEncoder().encode(updated))
    #expect(roundTripped.showGoodNightOnSleepTimer)
  }

  @Test func sleepTimerGoodNightFormatsPowerLineOnlyForSleepOrShutdown() {
    let off = IOSScreenTimeText.goodNight(
      sleepTimerStatus: IOSSleepTimerEndedResponse(
        powerMode: "off", afterSleepTimer: false, minutes: 0),
      name: "Mina")
    #expect(off.title == "Good night, Mina")
    #expect(off.text.isEmpty)

    let stopped = IOSScreenTimeText.goodNight(
      sleepTimerStatus: IOSSleepTimerEndedResponse(
        powerMode: "stop", afterSleepTimer: true, minutes: 5),
      name: "Mina")
    #expect(stopped.text.isEmpty)

    let sleep = IOSScreenTimeText.goodNight(
      sleepTimerStatus: IOSSleepTimerEndedResponse(
        powerMode: "sleep", afterSleepTimer: true, minutes: 12),
      name: "Mina")
    #expect(sleep.text == "The server goes to sleep in about 12 minutes.")

    let sleepSoon = IOSScreenTimeText.goodNight(
      sleepTimerStatus: IOSSleepTimerEndedResponse(
        powerMode: "sleep", afterSleepTimer: true, minutes: 0),
      name: "")
    #expect(sleepSoon.title == "Good night")
    #expect(sleepSoon.text == "The server goes to sleep soon.")

    let shutdown = IOSScreenTimeText.goodNight(
      sleepTimerStatus: IOSSleepTimerEndedResponse(
        powerMode: "shutdown", afterSleepTimer: true, minutes: 1),
      name: "Mina")
    #expect(shutdown.text == "The server turns off in about 1 minute.")
  }

  // Audit B-5: after the sleep timer ended the server turned off, and the app woke it again
  // 33 seconds later. For an hour only someone asking (Try Again, Wake Server) wakes it.
  @Test func anEndedSleepTimerKeepsTheAppFromWakingTheServerForAnHour() throws {
    let defaults = try #require(UserDefaults(suiteName: "tarven-sleep-wake-\(UUID().uuidString)"))
    let ended = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(IOSSleepTimerWakeRule.mayWakeAutomatically(defaults, now: ended))
    IOSSleepTimerWakeRule.markEnded(defaults, now: ended)
    #expect(
      !IOSSleepTimerWakeRule.mayWakeAutomatically(defaults, now: ended.addingTimeInterval(33)))
    #expect(
      !IOSSleepTimerWakeRule.mayWakeAutomatically(defaults, now: ended.addingTimeInterval(3599)))
    #expect(
      IOSSleepTimerWakeRule.mayWakeAutomatically(defaults, now: ended.addingTimeInterval(3600)))
    IOSSleepTimerWakeRule.markEnded(defaults, now: ended)
    IOSSleepTimerWakeRule.clear(defaults)
    #expect(IOSSleepTimerWakeRule.mayWakeAutomatically(defaults, now: ended.addingTimeInterval(60)))
  }

  @Test func sleepTimerGoodNightPolicyRespectsSettingAndNeverSwitchesProfile() {
    #expect(IOSSleepTimerGoodNightPolicy.autoCloseDurationSeconds == 300)
    #expect(
      !IOSSleepTimerGoodNightPolicy.shouldShowGoodNight(
        timerEnded: true, showGoodNightOnSleepTimer: false, closed: false))
    #expect(
      IOSSleepTimerGoodNightPolicy.shouldShowGoodNight(
        timerEnded: true, showGoodNightOnSleepTimer: true, closed: false))
    #expect(
      !IOSSleepTimerGoodNightPolicy.shouldShowGoodNight(
        timerEnded: true, showGoodNightOnSleepTimer: true, closed: true))
    #expect(
      IOSSleepTimerGoodNightPolicy.shouldCloseWholeProfile(
        closesWholeProfile: true, showsSleepTimerGoodNight: false))
    #expect(
      !IOSSleepTimerGoodNightPolicy.shouldCloseWholeProfile(
        closesWholeProfile: true, showsSleepTimerGoodNight: true))
  }

  @Test func sleepTimerEndedDecodesStatusAndHandlesEmptyLegacyResponse() async throws {
    let payload = #"{"powerMode":"sleep","afterSleepTimer":true,"minutes":8}"#
    let transport = IOSWishFakeTransport(responses: [
      IOSHTTPResponse(
        statusCode: 200, headers: [:], body: Data(payload.utf8), fingerprint: Self.fingerprint),
      IOSHTTPResponse(statusCode: 204, headers: [:], body: Data(), fingerprint: Self.fingerprint),
    ])
    let client = IOSAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)

    let rich = try await client.sleepTimerEnded()
    #expect(
      rich == IOSSleepTimerEndedResponse(powerMode: "sleep", afterSleepTimer: true, minutes: 8))
    let legacy = try await client.sleepTimerEnded()
    #expect(legacy == nil)
  }

  @Test func wishPresentationCalculatesBadgesNotificationsAndYearValidation() {
    #expect(
      IOSWishPresentation.isAdministrator(IOSUser(id: Self.profileID, username: "a", role: "owner"))
    )
    #expect(
      IOSWishPresentation.isAdministrator(IOSUser(id: Self.profileID, username: "b", role: "admin"))
    )
    #expect(
      !IOSWishPresentation.isAdministrator(IOSUser(id: Self.profileID, username: "c", role: "user"))
    )

    let summary = IOSWishSummaryResponse(openCount: 3, newlyFulfilledCount: 2)
    #expect(IOSWishPresentation.badgeCount(summary: summary, isAdmin: true) == 5)
    #expect(IOSWishPresentation.badgeCount(summary: summary, isAdmin: false) == 2)

    let baseline = IOSWishSummaryResponse(openCount: 1, newlyFulfilledCount: 0)
    #expect(
      IOSWishPresentation.notificationEvent(
        previous: nil, current: baseline, isAdmin: true) == nil)
    let adminAlert = IOSWishPresentation.notificationEvent(
      previous: baseline, current: IOSWishSummaryResponse(openCount: 2, newlyFulfilledCount: 0),
      isAdmin: true)
    #expect(adminAlert?.kind == .newWishes)
    #expect(
      IOSWishPresentation.notificationEvent(
        previous: baseline, current: IOSWishSummaryResponse(openCount: 2, newlyFulfilledCount: 0),
        isAdmin: false) == nil)

    let memberAlert = IOSWishPresentation.notificationEvent(
      previous: baseline, current: IOSWishSummaryResponse(openCount: 1, newlyFulfilledCount: 1),
      isAdmin: false)
    #expect(memberAlert?.title == "Your wish is here")

    #expect(IOSWishPresentation.parseYear("").year == nil)
    #expect(IOSWishPresentation.parseYear(" 2024 ").year == 2024)
    #expect(IOSWishPresentation.parseYear("1700").error != nil)
    #expect(IOSWishPresentation.parseYear("abcd").error != nil)
  }

  @Test func apiClientHandlesWishesEndpointsAndAlreadyInLibraryConflict() async throws {
    let listJSON = """
      {"wishes":[],"openCount":1,"newlyFulfilledCount":0,"providerEnabled":true}
      """
    let searchJSON = """
      {"results":[{"provider":"tmdb","providerMediaId":"55","kind":"series","title":"Nebula Express","year":2025,"overview":"A journey.","posterPath":"/nebula.jpg","posterUrl":null,"alreadyInLibrary":false,"existingMediaId":null,"alreadyWished":false,"existingWishId":null,"supportedByCaller":false}],"providerEnabled":true}
      """
    let conflictJSON = """
      {"code":"already_in_library","message":"Already in the library.","mediaId":"\(Self.mediaID.uuidString)","title":"Quiet Orbit","kind":"movie"}
      """
    let summaryJSON = """
      {"openCount":2,"newlyFulfilledCount":0}
      """
    let transport = IOSWishFakeTransport(responses: [
      IOSHTTPResponse(
        statusCode: 200, headers: [:], body: Data(listJSON.utf8), fingerprint: Self.fingerprint),
      IOSHTTPResponse(
        statusCode: 200, headers: [:], body: Data(searchJSON.utf8), fingerprint: Self.fingerprint),
      IOSHTTPResponse(
        statusCode: 409, headers: [:], body: Data(conflictJSON.utf8), fingerprint: Self.fingerprint),
      IOSHTTPResponse(statusCode: 204, headers: [:], body: Data(), fingerprint: Self.fingerprint),
      IOSHTTPResponse(
        statusCode: 200, headers: [:], body: Data(summaryJSON.utf8), fingerprint: Self.fingerprint),
    ])
    let client = IOSAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)

    let list = try await client.wishes(state: .open, offset: 0, limit: 30)
    #expect(list.openCount == 1)
    let search = try await client.wishSearch(query: "Nebula", kind: .series)
    #expect(search.results.first?.title == "Nebula Express")

    let outcome = try await client.createWish(
      IOSCreateWishRequest(
        kind: .movie, title: "Quiet Orbit", year: 2024, provider: nil, providerMediaId: nil,
        overview: nil, posterPath: nil, note: nil))
    if case .alreadyInLibrary(let problem) = outcome {
      #expect(problem.mediaId == Self.mediaID)
    } else {
      Issue.record("Expected alreadyInLibrary conflict outcome.")
    }

    let seen = try await client.markWishesSeen()
    #expect(seen.newlyFulfilledCount == 0)
    let requests = await transport.requests
    #expect(requests.count == 5)
    #expect(requests[3].httpMethod == "POST")
    #expect(requests[3].url?.path == "/api/v1/wishes/seen")
    #expect(requests[3].value(forHTTPHeaderField: "X-Tarven-Background") == nil)
    #expect(requests[4].httpMethod == "GET")
    #expect(requests[4].url?.path == "/api/v1/wishes/summary")
    #expect(requests[4].value(forHTTPHeaderField: "X-Tarven-Background") == "1")
  }

  @Test func wishSupportAndResolutionUsePutWithoutMarkingTheMutationAsBackground() async throws {
    func wish(_ supported: Bool, state: String = "open") -> IOSHTTPResponse {
      let json = """
        {"id":"\(Self.wishID)","userId":"\(Self.mediaID)","userName":"Mia","kind":"movie",
        "title":"Moonlit Garden","year":2025,"state":"\(state)","createdAt":"2026-11-16T00:00:00Z",
        "canSupport":true,"supportedByCaller":\(supported),"supporters":[],"suggestions":[]}
        """
      return IOSHTTPResponse(
        statusCode: 200, headers: [:], body: Data(json.utf8), fingerprint: Self.fingerprint)
    }
    let transport = IOSWishFakeTransport(responses: [
      wish(true), wish(false), wish(false, state: "declined"),
    ])
    let client = IOSAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)
    try await IOSAPIClient.withBackgroundRequests {
      let supported = try await client.setWishSupport(id: Self.wishID, supported: true)
      #expect(supported.supportedByCaller)
      let removed = try await client.setWishSupport(id: Self.wishID, supported: false)
      #expect(!removed.supportedByCaller)
      let declined = try await client.updateWishState(
        id: Self.wishID,
        requestBody: .init(
          state: .declined, resolutionNote: "Not available yet", fulfilledMediaItemId: nil))
      #expect(declined.state == .declined)
    }
    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(requests.allSatisfy { $0.httpMethod == "PUT" })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Tarven-Background") == nil })
    #expect(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/json" })
    #expect(
      requests[0].url?.path == "/api/v1/wishes/\(Self.wishID.uuidString.lowercased())/support")
    #expect(requests[1].url?.path == requests[0].url?.path)
    #expect(
      requests[2].url?.path == "/api/v1/wishes/\(Self.wishID.uuidString.lowercased())/state")
    let addBody = try #require(requests[0].httpBody)
    let removeBody = try #require(requests[1].httpBody)
    let stateBody = try #require(requests[2].httpBody)
    let add = try #require(JSONSerialization.jsonObject(with: addBody) as? [String: Bool])
    let remove = try #require(JSONSerialization.jsonObject(with: removeBody) as? [String: Bool])
    #expect(add == ["supported": true])
    #expect(remove == ["supported": false])
    let state = try #require(JSONSerialization.jsonObject(with: stateBody) as? [String: String])
    #expect(state == ["state": "declined", "resolutionNote": "Not available yet"])
  }

  @MainActor
  @Test func wishPosterByteCacheDeduplicatesInFlightAndRespectsDiskLimit() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tarven-ios-wish-poster-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let disk = IOSArtworkDiskCache(directory: temp, byteLimit: 1024)
    let counter = IOSWishCounter()
    let client = IOSAPIClient(
      connection: Self.connection, session: Self.session,
      transport: IOSWishFakeTransport(responses: []))
    let cache = IOSWishPosterByteCache(
      memoryLimitBytes: 1024, itemLimit: 10, diskCache: disk,
      fetcher: { path, _, _ in
        await counter.increment()
        try await Task.sleep(for: .milliseconds(25))
        return Data(repeating: path.utf8.first ?? 1, count: 700)
      })

    async let a = cache.data(posterPath: "/p1.jpg", width: 342, client: client)
    async let b = cache.data(posterPath: "/p1.jpg", width: 342, client: client)
    let (first, second) = await (a, b)
    #expect(first?.count == 700)
    #expect(second?.count == 700)
    #expect(await counter.value == 1)

    _ = await cache.data(posterPath: "/p2.jpg", width: 342, client: client)
    try await Task.sleep(for: .milliseconds(50))
    disk.prune()
    #expect(disk.byteCount() <= 1024)
  }

  @MainActor
  @Test func wishPosterRetriesAfterATemporaryNetworkFailure() async {
    let clock = IOSWishPosterTestClock()
    let counter = IOSWishCounter()
    let client = IOSAPIClient(
      connection: Self.connection, session: Self.session,
      transport: IOSWishFakeTransport(responses: []))
    let cache = IOSWishPosterByteCache(
      diskCache: nil, failureRetryInterval: 30, now: { clock.now },
      fetcher: { _, _, _ in
        await counter.increment()
        if await counter.value == 1 { throw URLError(.notConnectedToInternet) }
        return Data([7, 8, 9])
      })
    #expect(await cache.data(posterPath: "/retry.jpg", client: client) == nil)
    #expect(await cache.data(posterPath: "/retry.jpg", client: client) == nil)
    #expect(await counter.value == 1, "A failing server is not hammered on each view update.")
    clock.now = clock.now.addingTimeInterval(30)
    #expect(await cache.data(posterPath: "/retry.jpg", client: client) == Data([7, 8, 9]))
    #expect(
      await counter.value == 2, "The old failure must not hide the poster for the whole session.")
  }

  @MainActor
  @Test func clearingWishPostersRejectsAnUncancellableOldFetch() async {
    let gate = IOSWishPosterFetchGate()
    let client = IOSAPIClient(
      connection: Self.connection, session: Self.session,
      transport: IOSWishFakeTransport(responses: []))
    let cache = IOSWishPosterByteCache(diskCache: nil, fetcher: { _, _, _ in await gate.fetch() })
    let fetching = Task { await cache.data(posterPath: "/old.jpg", client: client) }
    await gate.waitForRequest()
    cache.clear()
    await gate.finish(Data([1, 2, 3]))
    #expect(await fetching.value == nil)
    #expect(cache.cachedData(posterPath: "/old.jpg", serverID: Self.serverID) == nil)
  }

  @MainActor
  @Test func notificationDelegateHopsFromBackgroundQueueAndRespectsSettings() async {
    let suite = "tarven.ios.wish.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let deliverer = IOSFakeNotificationDeliverer()
    let center = IOSWishNotificationCenter(defaults: defaults, deliverer: deliverer)
    #expect(center.isEnabledInSettings)

    await center.requestPermissionOnFirstVisitIfNeeded()
    #expect(deliverer.requestCount == 1)
    await center.requestPermissionOnFirstVisitIfNeeded()
    #expect(deliverer.requestCount == 1)

    await center.notify(
      IOSWishNotificationEvent(kind: .wishFulfilled, title: "Your wish is here", body: "Ready"))
    #expect(deliverer.posted.count == 1)

    center.isEnabledInSettings = false
    await center.notify(
      IOSWishNotificationEvent(kind: .newWishes, title: "Ignored", body: "Off"))
    #expect(deliverer.posted.count == 1)

    let recorder = IOSMainActorHopRecorder()
    let delegate = IOSWishNotificationDelegate {
      recorder.record(isMainThread: Thread.isMainThread)
    }
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        delegate.handleNotificationActivation(
          categoryIdentifier: IOSWishNotificationCenter.categoryIdentifier
        ) {
          continuation.resume()
        }
      }
    }
    #expect(recorder.openCount == 1)
    #expect(recorder.wasMainThread)
  }
}

private actor IOSWishFakeTransport: IOSHTTPTransport {
  private var queued: [IOSHTTPResponse]
  private(set) var requests: [URLRequest] = []
  init(responses: [IOSHTTPResponse]) { queued = responses }
  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    requests.append(request)
    guard !queued.isEmpty else { throw IOSCoreError.invalidResponse }
    return queued.removeFirst()
  }
}

private actor IOSWishCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

@MainActor
private final class IOSWishPosterTestClock {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
}

private actor IOSWishPosterFetchGate {
  private var pending: CheckedContinuation<Data, Never>?
  private var requestWaiter: CheckedContinuation<Void, Never>?

  func fetch() async -> Data {
    await withCheckedContinuation { continuation in
      pending = continuation
      requestWaiter?.resume()
      requestWaiter = nil
    }
  }

  func waitForRequest() async {
    if pending != nil { return }
    await withCheckedContinuation { requestWaiter = $0 }
  }

  func finish(_ data: Data) {
    pending?.resume(returning: data)
    pending = nil
  }
}

@MainActor
private final class IOSFakeNotificationDeliverer: IOSWishNotificationDelivering {
  var status: UNAuthorizationStatus = .notDetermined
  var requestCount = 0
  var posted: [(id: String, title: String, body: String)] = []

  func authorizationStatus() async -> UNAuthorizationStatus { status }
  func requestAuthorization() async -> Bool {
    requestCount += 1
    status = .authorized
    return true
  }
  func post(identifier: String, title: String, body: String) async {
    posted.append((identifier, title, body))
  }
}

@MainActor
private final class IOSMainActorHopRecorder {
  private(set) var openCount = 0
  private(set) var wasMainThread = false
  func record(isMainThread: Bool) {
    openCount += 1
    wasMainThread = isMainThread
  }
}
