import Foundation
import Testing

@Suite("TV library contracts and filters")
struct TVLibraryLogicTests {
  private let serverID = UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
  private let profileID = UUID(uuidString: "72000000-0000-0000-0000-000000000001")!
  private let mediaID = UUID(uuidString: "73000000-0000-0000-0000-000000000001")!
  private let fingerprint = String(repeating: "A", count: 64)

  @Test func combinedSearchKeepsAllFiltersAndExplicitSort() throws {
    var query = TVBrowseQuery(kind: .series)
    query.favoritesOnly = true
    query.genre = "Science Fiction & Fantasy"
    query.yearFrom = 1999
    query.yearTo = 2026
    query.watchState = .inProgress
    query.sort = .releaseYear
    query.descending = true
    let values = try query.queryItems(search: "  Rätsel: Pilot  ")
    let fields = Dictionary(uniqueKeysWithValues: values.map { ($0.name, $0.value ?? "") })
    #expect(
      fields == [
        "query": "Rätsel: Pilot", "kind": "series", "favorite": "true",
        "genre": "Science Fiction & Fantasy", "yearFrom": "1999", "yearTo": "2026",
        "watchState": "inProgress", "sort": "releaseYear", "direction": "descending",
      ])
  }

  @Test func defaultSearchUsesServerRelevanceWithoutInventedSort() throws {
    let values = try TVBrowseQuery().queryItems(search: "two words")
    #expect(values == [URLQueryItem(name: "query", value: "two words")])
  }

  @Test(arguments: TVWatchFilter.allCases)
  func watchFiltersUseExistingServerVocabulary(_ filter: TVWatchFilter) throws {
    var query = TVBrowseQuery()
    query.watchState = filter
    let value = try query.queryItems(search: "").first { $0.name == "watchState" }?.value
    #expect(value == filter.wireValue)
  }

  @Test(arguments: TVBrowseSort.allCases)
  func sortDirectionIsExplicitOnlyWhenSortIsChosen(_ sort: TVBrowseSort) throws {
    var query = TVBrowseQuery()
    query.sort = sort
    #expect(
      try query.queryItems(search: "").contains(URLQueryItem(name: "direction", value: "ascending"))
    )
    query.descending = true
    #expect(
      try query.queryItems(search: "").contains(
        URLQueryItem(name: "direction", value: "descending")))
  }

  @Test func invalidYearRangeAndUnsupportedKindsNeverSendRequests() throws {
    var query = TVBrowseQuery(kind: .episode)
    #expect(throws: TVCoreError.invalidResponse) { try query.queryItems(search: "") }
    query.kind = nil
    query.yearFrom = 2026
    query.yearTo = 2000
    #expect(throws: TVCoreError.invalidResponse) { try query.queryItems(search: "") }
    query.yearFrom = -1
    query.yearTo = nil
    #expect(throws: TVCoreError.invalidResponse) { try query.queryItems(search: "") }
    #expect(throws: TVCoreError.invalidResponse) {
      try TVBrowseQuery().queryItems(search: String(repeating: "a", count: 201))
    }
  }

  @MainActor @Test func browsePreferencesArePartitionedAndContainNoSearchText() throws {
    let suite = "Aurelia.TV.LibraryTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TVBrowsePreferenceStore(defaults: defaults)
    var query = TVBrowseQuery(kind: .series)
    query.genre = "Drama"
    query.sort = .lastPlayed
    query.descending = true
    store.save(query, serverID: serverID, profileID: profileID, section: .search)
    #expect(store.load(serverID: serverID, profileID: profileID, section: .search) == query)
    #expect(store.load(serverID: UUID(), profileID: profileID, section: .search) == .init())
    #expect(store.load(serverID: serverID, profileID: UUID(), section: .search) == .init())
    #expect(store.load(serverID: serverID, profileID: profileID, section: .movies).kind == .movie)
    let values = defaults.dictionaryRepresentation().filter {
      $0.key.hasPrefix("aurelia.tv.browse.")
    }
    let data = try #require(values.values.first as? Data)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["search"] == nil && payload["token"] == nil && payload["query"] == nil)
  }

  @Test func viewConstraintsRetainFixedKindAndMandatorySectionFilters() {
    var query = TVBrowseQuery(kind: .series)
    query.yearFrom = 2020
    query.yearTo = 2000
    #expect(TVBrowseSection.movies.constrain(query).kind == .movie)
    #expect(TVBrowseSection.movies.constrain(query).yearTo == 2020)
    #expect(TVBrowseSection.favorites.constrain(query).favoritesOnly)
    #expect(TVBrowseSection.continueWatching.constrain(query).watchState == .inProgress)
    #expect(TVBrowseSection.recentlyAdded.defaultQuery.sort == .dateAdded)
    #expect(TVBrowseSection.recentlyAdded.defaultQuery.descending)
  }

  @Test func searchUsesExistingEndpointAndRevisionedPages() async throws {
    let transport = TVLibraryTestTransport(responses: [try response(page())])
    var query = TVBrowseQuery(kind: .movie)
    query.sort = .title
    query.descending = true
    let result = try await api(transport).browsePage(query: query, search: "Pilot & Rätsel")
    #expect(result.total == 0)
    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/api/v1/catalog/search")
    let values = try #require(
      URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(values.contains(URLQueryItem(name: "query", value: "Pilot & Rätsel")))
    #expect(values.contains(URLQueryItem(name: "limit", value: "60")))
    #expect(values.contains(URLQueryItem(name: "sort", value: "title")))
    #expect(
      request.value(forHTTPHeaderField: "Authorization")
        == "Bearer \(String(repeating: "P", count: 43))")
  }

  @Test func pagedCatalogPreservesRevisionAndRejectsDuplicateIDs() async throws {
    let duplicate = TVPage(items: [item(), item()], offset: 0, limit: 60, total: 2, revision: "r1")
    let transport = TVLibraryTestTransport(responses: [try response(duplicate)])
    await #expect(throws: TVCoreError.invalidResponse) {
      try await api(transport).browsePage(query: .init())
    }
    let changed = TVLibraryTestTransport(responses: [try response(page(revision: "r2"))])
    await #expect(throws: TVCoreError.invalidResponse) {
      try await api(changed).browsePage(query: .init(), revision: "r1")
    }
  }

  @Test func ordinaryCatalogDoesNotAcceptEpisodeCardsButSearchDoes() async throws {
    let episode = item(kind: .episode)
    let response = try response(
      TVPage(items: [episode], offset: 0, limit: 60, total: 1, revision: "r1"))
    let transport = TVLibraryTestTransport(responses: [response, response])
    await #expect(throws: TVCoreError.invalidResponse) {
      try await api(transport).browsePage(query: .init())
    }
    let found = try await api(transport).browsePage(query: .init(), search: "episode")
    #expect(found.items.first?.id == mediaID)
  }

  @Test func watchMutationCarriesExactStateTokenAndUniqueMutationOnlyInBody() async throws {
    let transport = TVLibraryTestTransport(responses: [
      try response(watch(scope: .season, season: 2))
    ])
    let mutation = UUID()
    _ = try await api(transport).setWatchState(
      mediaID: mediaID,
      request: TVSetWatchState(
        isWatched: true, scope: .season, seasonNumber: 2,
        stateToken: "synthetic-state-token", clientMutationId: mutation))
    let request = try #require(await transport.requests.first)
    let body = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.query == nil)
    #expect(payload["stateToken"] as? String == "synthetic-state-token")
    #expect(
      (payload["clientMutationId"] as? String)?.lowercased() == mutation.uuidString.lowercased())
    #expect(payload["scope"] as? String == "season")
    #expect(payload["seasonNumber"] as? Int == 2)
  }

  @Test func staleWatchStateDoesNotRetryOrBlindlyOverwrite() async throws {
    let conflict = TVHTTPResponse(
      statusCode: 409, headers: [:],
      body: Data(#"{"code":"library_state_changed","message":"Reload state."}"#.utf8),
      fingerprint: fingerprint)
    let transport = TVLibraryTestTransport(responses: [conflict])
    do {
      _ = try await api(transport).setWatchState(
        mediaID: mediaID,
        request: TVSetWatchState(
          isWatched: false, scope: .series, seasonNumber: nil,
          stateToken: "stale", clientMutationId: UUID()))
      Issue.record("Expected conflict")
    } catch let error as TVCoreError { #expect(error.isConflict) }
    #expect(await transport.requests.count == 1)
  }

  @Test func wrongScopeOrMediaInWatchResponseIsRejected() async throws {
    let transport = TVLibraryTestTransport(responses: [try response(watch(scope: .series))])
    await #expect(throws: TVCoreError.invalidResponse) {
      try await api(transport).watchState(mediaID: mediaID, scope: .season, season: 2)
    }
  }

  @Test func hideContinueWatchingUsesSeparateMutationAndPreservesProgressEndpoint() async throws {
    let state = TVWatchState(
      mediaId: mediaID, scope: .title, seasonNumber: nil,
      watchState: "inProgress", affectedCount: 1, stateToken: "next", continueWatchingHidden: true)
    let transport = TVLibraryTestTransport(responses: [try response(state)])
    _ = try await api(transport).setContinueWatchingHidden(
      mediaID: mediaID,
      request: TVSetContinueWatching(
        isHidden: true, stateToken: "current", clientMutationId: UUID()))
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests[0].url?.path.hasSuffix("/continue-watching") == true)
    #expect(requests.allSatisfy { $0.url?.path.hasSuffix("/progress") != true })
  }

  @Test func collectionsKeepServerOrderAndDoNotExposeWriteEndpoints() async throws {
    let first = item()
    let second = item(id: UUID())
    let collection = TVCollection(
      id: UUID(), name: "A collection", poster: nil, items: [second, first])
    let transport = TVLibraryTestTransport(responses: [try response([collection])])
    let found = try await api(transport).collections(offset: 60)
    #expect(found.first?.items.map(\.id) == [second.id, first.id])
    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/api/v1/catalog/collections")
    #expect(request.url?.query?.contains("offset=60") == true)
  }

  @Test func homeAndSyncDecodeAdditionalUnknownFields() throws {
    let homeJSON =
      #"{"recommendation":null,"continueWatching":[],"recentlyAdded":[],"favorites":[],"collections":[],"recommendationChangesAt":"2099-01-01T00:00:00Z","future":true}"#
    #expect(
      try JSONDecoder().decode(TVHome.self, from: Data(homeJSON.utf8)).continueWatching.isEmpty)
    let syncJSON =
      #"{"cursor":12,"resetRequired":false,"changedAreas":["userState","futureArea"],"changedMediaIds":[],"future":true}"#
    let changes = try JSONDecoder().decode(TVSyncChanges.self, from: Data(syncJSON.utf8))
    #expect(changes.cursor == 12 && changes.generation == nil)
    #expect(changes.changedAreas.contains("futureArea"))
  }

  @Test func localProgressOverlayKeepsMetadataAndMarksOnlyIntendedTitle() {
    let original = item()
    let progress = TVPlaybackProgress(
      mediaId: mediaID, positionMilliseconds: 140_000,
      durationMilliseconds: 1_000_000, isCompleted: false, lastPlayedAt: nil,
      updatedAt: nil, revision: 7, lastMutationId: UUID())
    let updated = original.replacing(progress: progress)
    #expect(updated.progress == progress && updated.watchState == "inProgress")
    #expect(updated.title == original.title && updated.genres == original.genres)
    #expect(updated.poster == original.poster && updated.isFavorite == original.isFavorite)
  }

  private func api(_ transport: TVLibraryTestTransport) -> TVAPIClient {
    let connection = TVStoredConnection(
      serverID: serverID, name: "Synthetic server",
      baseURL: URL(string: "https://fixture.invalid:43111")!, fingerprint: fingerprint,
      deviceToken: String(repeating: "D", count: 43), deviceSessionID: UUID())
    let session = TVProfileSession(
      user: TVUser(id: profileID, username: "Viewer", role: "user"),
      sessionId: UUID(), token: String(repeating: "P", count: 43), expiresAt: "2099-01-01T00:00:00Z"
    )
    return TVAPIClient(connection: connection, session: session, transport: transport)
  }
  private func item(id: UUID? = nil, kind: TVMediaKind = .movie) -> TVCatalogItem {
    TVCatalogItem(
      id: id ?? mediaID, kind: kind, title: "Synthetic title", originalTitle: nil,
      year: 2026, overview: nil, genres: ["Drama"], poster: nil, backdrop: nil,
      availability: .available, isFavorite: false, progress: nil, addedAt: "2026-01-01T00:00:00Z",
      parentTitle: nil, seasonNumber: kind == .episode ? 1 : nil,
      episodeNumber: kind == .episode ? 1 : nil, parentId: nil, watchState: "unplayed",
      libraryAvailability: .available, continueWatchingHidden: false)
  }
  private func page(revision: String = "r1") -> TVPage<TVCatalogItem> {
    TVPage(items: [], offset: 0, limit: 60, total: 0, revision: revision)
  }
  private func watch(scope: TVWatchScope, season: Int? = nil) -> TVWatchState {
    TVWatchState(
      mediaId: mediaID, scope: scope, seasonNumber: season, watchState: "completed",
      affectedCount: 4, stateToken: "synthetic-state-token", continueWatchingHidden: false)
  }
  private func response(_ value: some Encodable) throws -> TVHTTPResponse {
    TVHTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try JSONEncoder().encode(value), fingerprint: fingerprint)
  }
}

private actor TVLibraryTestTransport: TVHTTPTransport {
  var responses: [TVHTTPResponse]
  private(set) var requests: [URLRequest] = []
  init(responses: [TVHTTPResponse]) { self.responses = responses }
  func execute(_ request: URLRequest, trust: TVTrustMode) async throws -> TVHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw TVCoreError.invalidResponse }
    return responses.removeFirst()
  }
}
