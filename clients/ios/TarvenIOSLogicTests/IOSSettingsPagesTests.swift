import Foundation
import Testing

@Suite("iOS settings pages")
struct IOSSettingsPagesTests {
  private let fingerprint = String(repeating: "B", count: 64)

  @Test func emptyHomeDoesNotCallALimitedProfilesLibraryEmpty() {
    let child = IOSUser(id: UUID(), username: "mia", role: "user", ageLimit: 6)
    let childText = IOSEmptyLibraryText(user: child, managesStorage: false)
    #expect(childText.title == "Nothing to Watch Yet")
    #expect(childText.message.contains("FSK 6"))
    let chosen = IOSUser(
      id: UUID(), username: "sam", role: "user", accessMode: "selectedTitles")
    #expect(
      IOSEmptyLibraryText(user: chosen, managesStorage: false).title == "Nothing to Watch Yet")
    let owner = IOSUser(id: UUID(), username: "alex", role: "owner")
    let ownerText = IOSEmptyLibraryText(user: owner, managesStorage: true)
    #expect(ownerText.title == "Your Library Is Empty")
    #expect(ownerText.message == "Add a storage location in Settings › Library.")
    #expect(
      IOSEmptyLibraryText(user: nil, managesStorage: false).message
        == "Ask the server owner to add a storage location.")
  }

  // MARK: Which pages a profile sees

  @Test func importReviewCountsUseSingularAndPluralAndIncludeTrailers() {
    let single = IOSImportPreviewCounts(
      files: 4, movies: 1, series: 1, episodes: 1, extras: 0, trailers: 1,
      pending: 0, ignored: 0, errors: 0)
    #expect(IOSLibraryAdminText.importSummary(single) == "1 movie · 1 show · 1 episode · 1 extra")
    let empty = IOSImportPreviewCounts(
      files: 0, movies: 0, series: 0, episodes: 0, extras: 0, trailers: 0,
      pending: 0, ignored: 0, errors: 0)
    #expect(
      IOSLibraryAdminText.importSummary(empty) == "0 movies · 0 shows · 0 episodes · 0 extras")
    let many = IOSImportPreviewCounts(
      files: 8, movies: 2, series: 2, episodes: 2, extras: 1, trailers: 1,
      pending: 0, ignored: 0, errors: 0)
    #expect(IOSLibraryAdminText.importSummary(many) == "2 movies · 2 shows · 2 episodes · 2 extras")
  }

  @Test func theOwnerSeesEveryServerPageIncludingPowerAndUpdates() {
    let visibility = IOSSettingsPage.Visibility(
      permissions: IOSAdminPermissions(role: "owner", accessMode: nil), supportsWishes: true,
      supportsPersonalization: true, supportsSecurity: true)
    #expect(
      visibility.pages(in: .server)
        == [.library, .metadata, .people, .security, .server, .power, .updates])
    #expect(visibility.pages(in: .you).contains(.wishes))
    #expect(visibility.pages(in: .connection) == [.connection])
  }

  @Test func anAdministratorManagesTheLibraryButNotTheServer() {
    let visibility = IOSSettingsPage.Visibility(
      permissions: IOSAdminPermissions(role: "admin", accessMode: "entireLibrary"),
      supportsSecurity: true)
    #expect(visibility.pages(in: .server) == [.library, .metadata, .people])
  }

  @Test func anAdministratorWithChosenTitlesCannotManageStorage() {
    let visibility = IOSSettingsPage.Visibility(
      permissions: IOSAdminPermissions(role: "admin", accessMode: "selectedTitles"))
    #expect(!visibility.shows(.library))
    #expect(visibility.shows(.metadata))
  }

  @Test func aViewerSeesOnlyTheirOwnPages() {
    let visibility = IOSSettingsPage.Visibility(
      permissions: IOSAdminPermissions(role: "user", accessMode: nil))
    #expect(visibility.pages(in: .server).isEmpty)
    #expect(!visibility.shows(.wishes))
    #expect(!visibility.shows(.nameAndPicture))
    #expect(visibility.shows(.playback) && visibility.shows(.connection))
  }

  @Test func securityNeedsTheServerFeature() {
    let owner = IOSAdminPermissions(role: "owner", accessMode: nil)
    #expect(!IOSSettingsPage.Visibility(permissions: owner).shows(.security))
  }

  @Test func everyPageSaysWhatItIsFor() {
    for page in IOSSettingsPage.allCases {
      #expect(!page.title.isEmpty)
      #expect(page.subtitle.count >= 10, "\(page) needs a real explanation")
      #expect(IOSSettingsPage(rawValue: page.rawValue) == page)
    }
    #expect(Set(IOSSettingsPage.allCases.map(\.title)).count == IOSSettingsPage.allCases.count)
  }

  @Test func unavailablePagesSayWhy() {
    #expect(IOSUnavailableReason.power(hosting: "macApp").contains("Mac"))
    #expect(IOSUnavailableReason.power(hosting: "linuxApp").contains("Linux"))
    #expect(IOSUnavailableReason.power(hosting: nil).contains("Linux package"))
    #expect(IOSUnavailableReason.updates.contains("tarven update"))
  }

  // MARK: Library words

  @Test func aScanSummaryLeavesOutWhatDidNotHappen() throws {
    let running = try scan(
      state: "running", discovered: 1240, processed: 530, added: 12, updated: 2)
    #expect(IOSLibraryAdminText.summary(running) == "530 of 1240 files · 12 new · 2 changed")
    let done = try scan(state: "completed", discovered: 1, processed: 1, added: 0, updated: 0)
    #expect(IOSLibraryAdminText.summary(done) == "1 file")
    #expect(IOSLibraryAdminText.trigger("fileChange") == "Noticed a change")
    #expect(IOSLibraryAdminText.trigger("somethingNew") == nil)
  }

  @Test func aLocationWaitingForReviewSaysSoAndCannotBeScanned() throws {
    let waiting = try library(review: true)
    #expect(IOSLibraryAdminText.isWaitingForReview(waiting))
    #expect(
      IOSLibraryAdminText.status(waiting, scanning: false) == "Waiting for your import review")
    let normal = try library(review: false)
    #expect(!IOSLibraryAdminText.isWaitingForReview(normal))
    #expect(IOSLibraryAdminText.status(normal, scanning: true) == "Scanning…")
    #expect(IOSLibraryAdminText.status(normal, scanning: false) == "Movies · Available")
  }

  @Test func aNewLocationIsNamedAfterItsFolder() {
    #expect(IOSLibraryAdminText.suggestedName(for: "/mnt/media/Movies") == "Movies")
    #expect(IOSLibraryAdminText.suggestedName(for: "/mnt/media/TV Shows/") == "TV Shows")
    #expect(IOSLibraryAdminText.suggestedName(for: "/") == "/")
  }

  @Test func aTypedPathMustLookLikeAFolderOnTheServer() {
    #expect(IOSLibraryAdminText.typedPath("  /mnt/media ") == "/mnt/media")
    #expect(IOSLibraryAdminText.typedPath("D:\\Videos") == "D:\\Videos")
    #expect(IOSLibraryAdminText.typedPath("~/Movies") == "~/Movies")
    #expect(IOSLibraryAdminText.typedPath("Movies") == nil)
    #expect(IOSLibraryAdminText.typedPath("") == nil)
    #expect(IOSLibraryAdminText.typedPath("/a\0b") == nil)
  }

  // MARK: Searches for matching and assigning

  @Test func assigningAFileSearchesOnlyMoviesOfItsLocation() async throws {
    let library = UUID(uuidString: "75000000-0000-0000-0000-0000000000aa")!
    let transport = IOSSettingsTestTransport(
      body: #"{"items":[],"offset":0,"limit":25,"total":0,"revision":"r"}"#)
    _ = try await api(transport).searchMovies("  Lighthouse ", library: library)
    let url = try #require(await transport.requests.first?.url)
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(url.path == "/api/v1/catalog/search")
    #expect(query.contains(URLQueryItem(name: "query", value: "Lighthouse")))
    #expect(query.contains(URLQueryItem(name: "kind", value: "movie")))
    #expect(query.contains(URLQueryItem(name: "libraryId", value: library.uuidString.lowercased())))
    let empty = try await api(transport).searchMovies("   ", library: library)
    #expect(empty.isEmpty)
    #expect(await transport.requests.count == 1)
  }

  @Test func matchingATitleAsksTheServerForCandidates() async throws {
    let media = UUID(uuidString: "75000000-0000-0000-0000-0000000000bb")!
    let transport = IOSSettingsTestTransport(
      body:
        #"[{"provider":"tmdb","providerMediaId":"42","mediaType":"movie","title":"Holiday","originalTitle":null,"year":2024,"overview":null,"posterPath":null,"confidence":0.8}]"#
    )
    let candidates = try await api(transport).searchMetadata(mediaId: media, query: "Holiday")
    #expect(candidates.map(\.title) == ["Holiday"])
    let url = try #require(await transport.requests.first?.url)
    #expect(url.path == "/api/v1/media/\(media.uuidString.lowercased())/metadata/search")
  }

  // MARK: Helpers

  private func scan(state: String, discovered: Int, processed: Int, added: Int, updated: Int) throws
    -> IOSLibraryScan
  {
    let text = """
      {"id":"75000000-0000-0000-0000-000000000001","libraryId":"75000000-0000-0000-0000-000000000002",
      "state":"\(state)","createdAt":"2026-01-01T00:00:00Z","startedAt":null,"completedAt":null,
      "filesDiscovered":\(discovered),"filesProcessed":\(processed),"addedFiles":\(added),
      "updatedFiles":\(updated),"missingFiles":0,"skippedFiles":0,"error":null,"issues":[]}
      """
    return try JSONDecoder().decode(IOSLibraryScan.self, from: Data(text.utf8))
  }

  private func library(review: Bool) throws -> IOSLibrarySummary {
    let text = """
      {"id":"75000000-0000-0000-0000-000000000003","name":"Movies","path":"/mnt/media/Movies",
      "kind":"movies","availability":"available","createdAt":"2026-01-01T00:00:00Z",
      "lastScanStartedAt":null,"lastScanCompletedAt":null,"lastError":null,
      "importPreviewRequired":\(review)}
      """
    return try JSONDecoder().decode(IOSLibrarySummary.self, from: Data(text.utf8))
  }

  private func api(_ transport: IOSSettingsTestTransport) -> IOSAPIClient {
    let connection = IOSStoredConnection(
      serverID: UUID(), name: "Synthetic server",
      baseURL: URL(string: "https://fixture.invalid:43111")!, fingerprint: fingerprint,
      deviceToken: String(repeating: "D", count: 43), deviceSessionID: UUID())
    let session = IOSProfileSession(
      user: IOSUser(id: UUID(), username: "Owner", role: "owner"),
      sessionId: UUID(), token: String(repeating: "P", count: 43),
      expiresAt: "2099-01-01T00:00:00Z")
    return IOSAPIClient(connection: connection, session: session, transport: transport)
  }
}

private actor IOSSettingsTestTransport: IOSHTTPTransport {
  let body: String
  private(set) var requests: [URLRequest] = []
  init(body: String) { self.body = body }
  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    requests.append(request)
    return IOSHTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8),
      fingerprint: String(repeating: "B", count: 64))
  }
}

@Suite("iOS power now")
struct IOSPowerNowTests {
  @Test func newAndOlderServersOfferItWithTheSameWords() throws {
    #expect(IOSPowerNowText.isOffered(by: ["power-now-v1"]))
    #expect(IOSPowerNowText.isOffered(by: ["automation-v1"]))
    #expect(!IOSPowerNowText.isOffered(by: ["people-v1"]))
    #expect(!IOSPowerNowText.isOffered(by: nil))
    let options = try JSONDecoder().decode(
      IOSPowerNowOptions.self, from: Data(#"{"actions":["sleep","reboot","shutdown","stop"]}"#.utf8)
    )
    #expect(
      IOSPowerNowText.known(options.actions).map(IOSPowerNowText.title)
        == ["Sleep Now", "Turn Off Now", "Stop Tarven Now"])
    let legacy = try JSONDecoder().decode(
      IOSLegacyPowerNowOptions.self,
      from: Data(#"{"webhooks":[],"powerActions":["stop"],"somethingNew":true}"#.utf8))
    #expect(legacy.powerActions == ["stop"])
  }
}
