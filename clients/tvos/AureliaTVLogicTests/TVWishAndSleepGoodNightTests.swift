import Foundation
import Testing

@Suite("Apple TV Family Wishes and Sleep Timer Good Night")
struct TVWishAndSleepGoodNightTests {
  private static let fingerprint = String(repeating: "A", count: 64)
  private static let serverID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  private static let profileID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
  private static let baseURL = URL(string: "https://synthetic-server.local:43111")!

  private static var connection: TVStoredConnection {
    TVStoredConnection(
      serverID: serverID, name: "Synthetic server", baseURL: baseURL,
      fingerprint: fingerprint, deviceToken: String(repeating: "D", count: 43),
      deviceSessionID: UUID())
  }

  private static var session: TVProfileSession {
    TVProfileSession(
      user: TVUser(id: profileID, username: "Viewer", role: "user"),
      sessionId: UUID(), token: String(repeating: "P", count: 43),
      expiresAt: "2099-01-01T00:00:00Z")
  }

  @Test func legacyPlaybackPreferencesDecodeSleepGoodNightAsFalse() throws {
    let legacy = #"{"automaticResume":true,"automaticallyPlayNextEpisode":true,"seekInterval":15}"#
    let prefs = try JSONDecoder().decode(TVPlaybackPreferences.self, from: Data(legacy.utf8))
    #expect(!prefs.showGoodNightOnSleepTimer)

    var updated = prefs
    updated.showGoodNightOnSleepTimer = true
    let encoded = try JSONEncoder().encode(updated)
    let roundTripped = try JSONDecoder().decode(TVPlaybackPreferences.self, from: encoded)
    #expect(roundTripped.showGoodNightOnSleepTimer)
  }

  @Test func sleepTimerGoodNightFormatsPowerLineOnlyForSleepOrShutdown() {
    let sleep = TVScreenTimeText.goodNight(
      sleepTimerStatus: TVSleepTimerEndedResponse(
        powerMode: "sleep", afterSleepTimer: true, minutes: 5),
      name: "Sam")
    #expect(sleep.title == "Good night, Sam")
    #expect(sleep.text == "The server goes to sleep in about 5 minutes.")
    #expect(!sleep.text.contains("See you"))

    let shutdownOne = TVScreenTimeText.goodNight(
      sleepTimerStatus: TVSleepTimerEndedResponse(
        powerMode: "shutdown", afterSleepTimer: true, minutes: 1),
      name: "")
    #expect(shutdownOne.title == "Good night")
    #expect(shutdownOne.text == "The server turns off in about 1 minute.")

    let off = TVScreenTimeText.goodNight(
      sleepTimerStatus: TVSleepTimerEndedResponse(
        powerMode: "off", afterSleepTimer: true, minutes: 5),
      name: "Sam")
    #expect(off.text.isEmpty)

    let stop = TVScreenTimeText.goodNight(
      sleepTimerStatus: TVSleepTimerEndedResponse(
        powerMode: "stop", afterSleepTimer: true, minutes: 5),
      name: "Sam")
    #expect(stop.text.isEmpty)

    let disabled = TVScreenTimeText.goodNight(
      sleepTimerStatus: TVSleepTimerEndedResponse(
        powerMode: "sleep", afterSleepTimer: false, minutes: 5),
      name: "Sam")
    #expect(disabled.text.isEmpty)

    let legacy = TVScreenTimeText.goodNight(sleepTimerStatus: nil, name: "Sam")
    #expect(legacy.title == "Good night, Sam")
    #expect(legacy.text.isEmpty)
  }

  @Test func sleepTimerGoodNightPolicyRespectsSettingAndNeverSwitchesProfile() {
    #expect(TVSleepTimerGoodNightPolicy.autoCloseDurationSeconds == 300)
    #expect(
      !TVSleepTimerGoodNightPolicy.shouldShowGoodNight(
        timerEnded: true, showGoodNightOnSleepTimer: false, closed: false))
    #expect(
      TVSleepTimerGoodNightPolicy.shouldShowGoodNight(
        timerEnded: true, showGoodNightOnSleepTimer: true, closed: false))
    #expect(
      !TVSleepTimerGoodNightPolicy.shouldShowGoodNight(
        timerEnded: true, showGoodNightOnSleepTimer: true, closed: true))

    #expect(
      TVSleepTimerGoodNightPolicy.shouldCloseWholeProfile(
        closesWholeProfile: true, showsSleepTimerGoodNight: false))
    #expect(
      !TVSleepTimerGoodNightPolicy.shouldCloseWholeProfile(
        closesWholeProfile: true, showsSleepTimerGoodNight: true))
  }

  @Test func sleepTimerEndedDecodesStatusAndHandlesEmptyLegacyResponse() async throws {
    let statusBody = Data(
      #"{"powerMode":"sleep","afterSleepTimer":true,"minutes":3}"#.utf8)
    let transport = TVWishStubTransport(responses: [
      TVHTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: statusBody, fingerprint: Self.fingerprint),
      TVHTTPResponse(
        statusCode: 204, headers: [:], body: Data(), fingerprint: Self.fingerprint),
    ])
    let client = TVAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)

    let first = try await client.sleepTimerEnded()
    #expect(
      first
        == TVSleepTimerEndedResponse(powerMode: "sleep", afterSleepTimer: true, minutes: 3))

    let second = try await client.sleepTimerEnded()
    #expect(second == nil)
  }

  @Test func capabilitiesAndReadOnlyWishesDecodeCleanly() throws {
    let caps = try JSONDecoder().decode(
      TVCapabilities.self,
      from: Data(
        #"{"formatVersion":2,"minimumClientVersion":"2.0.0","capabilities":["wishes-v1","adaptive-streaming-v1"]}"#
          .utf8))
    #expect(caps.supportsWishes)

    let olderCaps = try JSONDecoder().decode(
      TVCapabilities.self,
      from: Data(#"{"formatVersion":2,"minimumClientVersion":"2.0.0","capabilities":[]}"#.utf8))
    #expect(!olderCaps.supportsWishes)

    let wishID = UUID()
    let supporterID = UUID()
    let listJSON = """
      {
        "wishes": [
          {
            "id": "\(wishID.uuidString)",
            "userId": "\(Self.profileID.uuidString)",
            "userName": "Mia",
            "kind": "movie",
            "provider": "tmdb",
            "providerMediaId": "101",
            "title": "Dune",
            "year": 2021,
            "overview": "Desert planet epic.",
            "posterPath": "/dune.jpg",
            "posterUrl": "/api/v1/wishes/poster?path=/dune.jpg&width=342",
            "ageRating": "PG-13",
            "minimumAge": 12,
            "note": "Friday movie night",
            "state": "fulfilled",
            "resolvedByUserId": "\(supporterID.uuidString)",
            "resolvedByUserName": "Alex",
            "resolutionNote": "Added in 4K",
            "fulfilledMediaItemId": null,
            "createdAt": "2026-11-12T10:00:00Z",
            "resolvedAt": "2026-11-12T11:00:00Z",
            "seenByWisherAt": null,
            "canSupport": false,
            "supportedByCaller": false,
            "supporters": [
              {"userId": "\(Self.profileID.uuidString)", "name": "Mia"},
              {"userId": "\(supporterID.uuidString)", "name": "Alex"}
            ],
            "suggestions": []
          }
        ],
        "openCount": 0,
        "newlyFulfilledCount": 1,
        "providerEnabled": true
      }
      """
    let decoded = try JSONDecoder().decode(TVWishListResponse.self, from: Data(listJSON.utf8))
    #expect(decoded.wishes.count == 1)
    #expect(decoded.wishes[0].state == .fulfilled)
    #expect(decoded.wishes[0].supporters.count == 2)
    #expect(decoded.newlyFulfilledCount == 1)
    #expect(TVWishPresentation.kindLabel(.movie) == "Movie")
    #expect(TVWishPresentation.kindLabel(.series) == "TV Series")
    #expect(TVWishPresentation.stateLabel(.open) == "Waiting")
    #expect(TVWishPresentation.stateLabel(.fulfilled) == "In Library")
    #expect(TVWishPresentation.stateLabel(.declined) == "Declined")
  }

  @Test func apiClientFetchesWishesAndValidatesProxiedPoster() async throws {
    let listJSON = Data(
      #"{"wishes":[],"openCount":2,"newlyFulfilledCount":1,"providerEnabled":true}"#.utf8)
    let posterBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let transport = TVWishStubTransport(responses: [
      TVHTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: listJSON, fingerprint: Self.fingerprint),
      TVHTTPResponse(
        statusCode: 200, headers: ["Content-Type": "image/jpeg"],
        body: posterBytes, fingerprint: Self.fingerprint),
      TVHTTPResponse(
        statusCode: 200, headers: ["Content-Type": "text/html"],
        body: Data("<html></html>".utf8), fingerprint: Self.fingerprint),
    ])
    let client = TVAPIClient(
      connection: Self.connection, session: Self.session, transport: transport)

    let list = try await client.wishes(state: .open, offset: 30, limit: 30)
    #expect(list.openCount == 2)

    let poster = try await client.wishPosterData(path: "/poster.jpg", width: 342)
    #expect(poster == posterBytes)

    await #expect(throws: TVCoreError.invalidResponse) {
      _ = try await client.wishPosterData(path: "/bad.jpg", width: 342)
    }

    let requests = await transport.requests
    #expect(requests.count == 3)
    let firstURL = try #require(requests[0].request.url)
    #expect(firstURL.path == "/api/v1/wishes")
    let query = try #require(
      URLComponents(url: firstURL, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first { $0.name == "state" }?.value == "open")
    #expect(query.first { $0.name == "offset" }?.value == "30")
    #expect(query.first { $0.name == "limit" }?.value == "30")
    #expect(requests[1].request.url?.path == "/api/v1/wishes/poster")
  }

  @Test @MainActor func wishPosterByteCacheDeduplicatesInFlightAndRespectsDiskLimit() async {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("aurelia-tv-wish-poster-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let disk = TVArtworkDiskCache(directory: tempDir, byteLimit: 1_200)
    final class Counter: @unchecked Sendable { var calls = 0 }
    let counter = Counter()

    let cache = TVWishPosterByteCache(
      memoryLimitBytes: 1024 * 1024,
      itemLimit: 10,
      diskCache: disk,
      fetcher: { path, _, _ in
        counter.calls += 1
        try await Task.sleep(for: .milliseconds(40))
        return Data(repeating: UInt8(path.utf8.first ?? 1), count: 700)
      })
    let client = TVAPIClient(connection: Self.connection, session: Self.session)

    async let a = cache.data(posterPath: "/same.jpg", width: 342, client: client)
    async let b = cache.data(posterPath: "/same.jpg", width: 342, client: client)
    let (dataA, dataB) = await (a, b)
    #expect(dataA == dataB)
    #expect(dataA?.count == 700)
    #expect(counter.calls == 1)

    cache.clear()
    let fromDisk = await cache.data(posterPath: "/same.jpg", width: 342, client: client)
    #expect(fromDisk?.count == 700)
    #expect(counter.calls == 1)

    _ = await cache.data(posterPath: "/second.jpg", width: 342, client: client)
    disk.prune()
    let files =
      (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil))
      ?? []
    #expect(files.count <= 1)
  }
}

private actor TVWishStubTransport: TVHTTPTransport {
  struct Captured: Sendable {
    let request: URLRequest
    let trust: TVTrustMode
  }

  private var responses: [TVHTTPResponse]
  private(set) var requests: [Captured] = []

  init(responses: [TVHTTPResponse]) {
    self.responses = responses
  }

  func execute(_ request: URLRequest, trust: TVTrustMode) async throws -> TVHTTPResponse {
    requests.append(Captured(request: request, trust: trust))
    guard !responses.isEmpty else { throw TVCoreError.invalidResponse }
    return responses.removeFirst()
  }
}
