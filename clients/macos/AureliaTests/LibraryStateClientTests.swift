import Foundation
import Testing

@testable import Aurelia

@MainActor struct LibraryStateClientTests {
  @Test func olderCatalogPayloadKeepsPlaybackWithoutNewStateFields() throws {
    let json = """
      {"id":"10000000-0000-0000-0000-000000000001","kind":"movie","title":"Synthetic",
      "genres":[],"availability":"available","isFavorite":false,"addedAt":"2026-10-01T00:00:00Z"}
      """
    let item = try JSONDecoder().decode(CatalogItemSummary.self, from: Data(json.utf8))
    #expect(item.isPlayable)
    #expect(item.watchState == nil)
    #expect(item.libraryAvailability == nil)
    #expect(!item.continueWatchingHidden)
  }

  @Test func combinedQueryEncodesReservedCharactersAndExplicitSearchSorting() throws {
    let query = CatalogBrowseQuery(
      favoritesOnly: true, genre: "Crime & Drama+",
      yearFrom: 1990, yearTo: 2025, watchState: .watched, sort: .releaseYear, descending: true)
    let queryString = try APIClient.catalogQuery(query, search: "One + Two & Three?")
    let encoded = try #require(queryString)
    let components = try #require(URLComponents(string: "https://fixture.invalid/?" + encoded))
    let values = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(values["query"] == "One + Two & Three?")
    #expect(values["genre"] == "Crime & Drama+")
    #expect(values["favorite"] == "true")
    #expect(values["watchState"] == "completed")
    #expect(values["sort"] == "releaseYear")
    #expect(values["direction"] == "descending")
    #expect(try APIClient.catalogQuery(CatalogBrowseQuery(), search: "Pilot") == "query=Pilot")
  }

  @Test(arguments: [false, true])
  func lateItemPlanCannotReplaceLaterPlaybackOrDismissal(dismiss: Bool) async throws {
    let client = PendingLibraryStateClient()
    let model = makeModel(client)
    let oldItem = item()
    model.startPlayback(item: oldItem)
    try await client.waitForRequest()
    let newer = UUID()
    model.startPlayback(mediaId: newer, title: "New selection")
    if dismiss { model.dismissPlayback() }
    client.complete(oldItem)
    for _ in 0..<20 { await Task.yield() }
    #expect(model.playback?.mediaId == (dismiss ? nil : newer))
    #expect(model.visibleErrorMessage == nil)
  }

  @Test func lateExplicitPlanCannotReopenAfterPlayerClose() async throws {
    let client = PendingLibraryStateClient()
    let model = makeModel(client)
    let oldItem = item()
    let request = Task { try await model.startPlannedPlayback(mediaId: oldItem.id) }
    try await client.waitForRequest()
    await model.closePlayback()
    client.complete(oldItem)
    do {
      try await request.value
      Issue.record("Retired playback intent was accepted")
    } catch { #expect(error is CancellationError) }
    #expect(model.playback == nil)
  }

  @Test(arguments: [false, true])
  func conflictNoticeSurvivesCatalogReloadAndDoesNotRetry(hidden: Bool) async throws {
    let client = PendingLibraryStateClient()
    client.rejectStateChanges = true
    let model = makeModel(client)
    let revision = model.catalogVisibilityRevision
    do {
      if hidden {
        _ = try await model.setContinueWatchingHidden(mediaId: UUID(), isHidden: true)
      } else {
        _ = try await model.setWatchState(mediaId: UUID(), isWatched: true, stateToken: "original")
      }
      Issue.record("A conflicting mutation was accepted")
    } catch { #expect((error as? APIClientError)?.httpStatus == 409) }
    #expect(model.catalogVisibilityRevision > revision)
    #expect(model.visibleErrorMessage?.contains("Review the current status") == true)
    #expect(client.mutationRequests == 1)
  }

  private func makeModel(_ client: PendingLibraryStateClient) -> AppModel {
    let profile = StoredServerProfile(
      serverId: UUID(), name: "Synthetic",
      baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "synthetic-only-token", sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z",
      user: UserSummary(
        id: UUID(), username: "Viewer", role: .user, createdAt: "2026-01-01T00:00:00Z"))
    return AppModel(
      store: InMemoryServerProfileStore(), initialProfile: profile,
      profileSelectionEnabled: false, initialLibraryCapabilities: ["library-state-v1"],
      libraryStateClientFactory: { _ in client })
  }

  private func item() -> CatalogItemSummary {
    CatalogItemSummary(
      id: UUID(), kind: .movie, title: "Synthetic", originalTitle: nil, year: 2026,
      overview: nil, genres: [], poster: nil, backdrop: nil, availability: .available,
      isFavorite: false,
      progress: nil, addedAt: "2026-10-01T00:00:00Z")
  }
}

@MainActor private final class PendingLibraryStateClient: LibraryStateServing {
  private var pending: CheckedContinuation<PlaybackPlanResponse, Error>?
  var rejectStateChanges = false
  private(set) var mutationRequests = 0
  func playbackPlan(mediaId: UUID) async throws -> PlaybackPlanResponse {
    try await withCheckedThrowingContinuation { pending = $0 }
  }
  func waitForRequest() async throws {
    for _ in 0..<1_000 {
      if pending != nil { return }
      await Task.yield()
    }
    throw APIClientError.invalidResponse
  }
  func complete(_ item: CatalogItemSummary) {
    pending?.resume(
      returning: PlaybackPlanResponse(
        target: item, seriesId: nil, queue: [], action: .play, continueWatchingEligible: false))
    pending = nil
  }
  func watchState(mediaId: UUID, scope: WatchStateScope, seasonNumber: Int?) async throws
    -> WatchStateResponse
  {
    WatchStateResponse(
      mediaId: mediaId, scope: scope, seasonNumber: seasonNumber, watchState: .inProgress,
      affectedCount: 1, stateToken: "original", continueWatchingHidden: false)
  }
  func setWatchState(mediaId: UUID, request: SetWatchStateRequest) async throws
    -> WatchStateResponse
  { try rejectMutation() }
  func setContinueWatchingHidden(mediaId: UUID, request: SetContinueWatchingRequest) async throws
    -> WatchStateResponse
  { try rejectMutation() }

  private func rejectMutation() throws -> WatchStateResponse {
    mutationRequests += 1
    if rejectStateChanges {
      throw APIClientError.httpFailure(
        status: 409, retryAfter: nil, code: "library_state_conflict",
        message: "Reload before saving.")
    }
    throw APIClientError.invalidResponse
  }
}
