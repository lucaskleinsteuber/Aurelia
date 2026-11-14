import Foundation
import Testing

@Suite("iOS Siri")
struct IOSSiriTests {
  @Test func aSpokenRequestSplitsIntoTitleSeasonAndEpisode() {
    #expect(IOSTitleRequest.parse("Breaking Bad season 3 episode 4") == .init(title: "Breaking Bad", season: 3, episode: 4))
    #expect(IOSTitleRequest.parse("breaking bad S3E4") == .init(title: "breaking bad", season: 3, episode: 4))
    #expect(IOSTitleRequest.parse("An Invented Show 2x07") == .init(title: "An Invented Show", season: 2, episode: 7))
    #expect(IOSTitleRequest.parse("Spiele Dark Staffel 1 Folge 2") == .init(title: "Dark", season: 1, episode: 2))
    #expect(IOSTitleRequest.parse("The Lighthouse Keeper") == .init(title: "The Lighthouse Keeper"))
    #expect(IOSTitleRequest.parse("play Arrival.") == .init(title: "Arrival"))
  }

  @Test func theBestMatchPrefersTheExactNameAndAShowForAnEpisode() {
    let movie = IOSIntegrationTitle(
      id: UUID(), kind: "movie", title: "Dark Waters", year: 2019, parentTitle: nil, seasonNumber: nil, episodeNumber: nil)
    let show = IOSIntegrationTitle(
      id: UUID(), kind: "series", title: "Dark", year: 2017, parentTitle: nil, seasonNumber: nil, episodeNumber: nil)
    #expect(IOSTitleRequest.best([movie, show], for: .init(title: "dark")) == show)
    #expect(IOSTitleRequest.best([movie, show], for: .init(title: "Waters", season: 1, episode: 1)) == show)
    #expect(IOSTitleRequest.best([], for: .init(title: "x")) == nil)
  }

  @Test func theAppleTVIsTheDefaultPlayer() {
    let tv = IOSIntegrationPlayer(deviceId: "tv", deviceName: "Living Room", clientType: "tvos", isPlaying: false, title: nil, isPaused: false)
    let mac = IOSIntegrationPlayer(deviceId: "mac", deviceName: "Study Mac", clientType: "macos", isPlaying: false, title: nil, isPaused: false)
    #expect(IOSTitleRequest.player([mac, tv], named: nil) == tv)
    #expect(IOSTitleRequest.player([mac, tv], named: "study") == mac)
    #expect(IOSTitleRequest.player([mac], named: nil) == mac)
    #expect(IOSTitleRequest.player([], named: nil) == nil)
  }

  @Test func onlyIntegrationKeysAreKept() {
    #expect(IOSSiriKeyStore.isKey("aur_it_" + String(repeating: "A", count: 43)))
    #expect(!IOSSiriKeyStore.isKey("not-a-key"))
    #expect(!IOSSiriKeyStore.isKey("aur_it_ with space " + String(repeating: "A", count: 40)))
  }

  @Test func siriPlaysWithItsKeyOnTheChosenDevice() async throws {
    let transport = IOSSiriTestTransport()
    let connection = IOSStoredConnection(
      serverID: UUID(), name: "Synthetic server", baseURL: URL(string: "https://fixture.invalid:43111")!,
      fingerprint: String(repeating: "B", count: 64), deviceToken: String(repeating: "D", count: 43), deviceSessionID: UUID())
    let key = "aur_it_" + String(repeating: "K", count: 43)
    let media = UUID(uuidString: "77000000-0000-0000-0000-000000000001")!
    try await IOSIntegrationClient(connection: connection, key: key, transport: transport).play(media, on: "living-room-tv")
    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/api/v1/integration/players/living-room-tv/commands")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
    let body = try #require(request.httpBody)
    #expect(String(decoding: body, as: UTF8.self).contains("77000000-0000-0000-0000-000000000001"))
  }
}

private actor IOSSiriTestTransport: IOSHTTPTransport {
  private(set) var requests: [URLRequest] = []
  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    requests.append(request)
    return IOSHTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"commandId":"77000000-0000-0000-0000-000000000002","status":"queued"}"#.utf8),
      fingerprint: String(repeating: "B", count: 64))
  }
}
