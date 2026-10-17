import Foundation
import Testing

@testable import Aurelia

@MainActor
struct ContinueWatchingTests {
  @Test
  func episodeUsesItsOwnPlaybackIDNotTheSeriesDetailRoute() throws {
    let episode = item(kind: .episode)
    let presentation = try #require(CatalogPlaybackLogic.presentation(for: episode))
    #expect(presentation.mediaId == episode.id)
    #expect(presentation.title == "Pilot")
    #expect(presentation.subtitle == "Example Show · Season 1 · Episode 1")
    #expect(presentation.queue.isEmpty)
    #expect(CatalogPlaybackLogic.subtitle(for: item(kind: .movie)) == nil)
    #expect(CatalogPlaybackLogic.presentation(for: item(kind: .series)) == nil)
    #expect(CatalogPlaybackLogic.presentation(for: item(kind: .episode, available: false)) == nil)
  }

  @Test
  func aSlowOlderHomeCannotEraseNewlySavedProgress() async throws {
    let fetcher = ControlledHomeFetcher()
    let loader = HomeRefreshCoordinator(fetch: fetcher.fetch)
    let oldRequest = loader.beginRequest()
    let oldLoad = Task { try await loader.load(request: oldRequest, profile: profile) }
    try await fetcher.waitForRequests(1)

    let newRequest = loader.beginRequest()
    let newLoad = Task { try await loader.load(request: newRequest, profile: profile) }
    try await fetcher.waitForRequests(2)
    let latest = home(continueWatching: [item(kind: .episode)])
    fetcher.complete(1, with: .success(latest))
    #expect(try await newLoad.value == latest)

    fetcher.complete(0, with: .success(home(continueWatching: [])))
    #expect(try await oldLoad.value == nil)
    #expect(!loader.isCurrent(oldRequest))
    #expect(loader.isCurrent(newRequest))
  }

  @Test
  func aLoadedSnapshotBecomesStaleWhileOtherCatalogRequestsFinish() async throws {
    let loader = HomeRefreshCoordinator { _ in home(continueWatching: []) }
    let fullRefresh = loader.beginRequest()
    #expect(try await loader.load(request: fullRefresh, profile: profile) != nil)
    let afterPlayback = loader.beginRequest()
    #expect(!loader.isCurrent(fullRefresh))
    #expect(loader.isCurrent(afterPlayback))
  }

  @Test
  func aHomeOnlyRefreshDuringASnapshotIsDeferredInsteadOfSupersedingIt() async throws {
    let fetcher = ControlledHomeFetcher()
    let loader = HomeRefreshCoordinator(fetch: fetcher.fetch)
    let snapshot = loader.beginSnapshot()
    let snapshotLoad = Task { try await loader.load(request: snapshot, profile: profile) }
    try await fetcher.waitForRequests(1)

    // The library view appears and asks for Home while the unlock snapshot loads.
    #expect(loader.beginHomeOnlyRequest() == nil)
    #expect(loader.isCurrent(snapshot))
    let loaded = home(continueWatching: [item(kind: .movie)])
    fetcher.complete(0, with: .success(loaded))
    #expect(try await snapshotLoad.value == loaded)
    #expect(loader.isCurrent(snapshot))

    #expect(loader.endSnapshot())
    #expect(!loader.endSnapshot())
    let deferred = try #require(loader.beginHomeOnlyRequest())
    #expect(!loader.isCurrent(snapshot))
    #expect(loader.isCurrent(deferred))
  }

  @Test
  func aSnapshotWithoutDeferredHomeRequestsDoesNotRefreshAgain() {
    let loader = HomeRefreshCoordinator { _ in home(continueWatching: []) }
    _ = loader.beginSnapshot()
    _ = loader.beginSnapshot()
    #expect(!loader.endSnapshot())
    #expect(loader.beginHomeOnlyRequest() == nil)
    #expect(loader.endSnapshot())
    #expect(loader.beginHomeOnlyRequest() != nil)
  }

  @Test
  func obsoleteErrorsAreIgnoredButCurrentErrorsRemainVisible() async throws {
    let fetcher = ControlledHomeFetcher()
    let loader = HomeRefreshCoordinator(fetch: fetcher.fetch)
    let request = loader.beginRequest()
    let pending = Task { try await loader.load(request: request, profile: profile) }
    try await fetcher.waitForRequests(1)
    loader.invalidate()
    fetcher.complete(0, with: .failure(URLError(.notConnectedToInternet)))
    #expect(try await pending.value == nil)

    let current = loader.beginRequest()
    let newest = Task { try await loader.load(request: current, profile: profile) }
    try await fetcher.waitForRequests(2)
    fetcher.complete(1, with: .failure(URLError(.notConnectedToInternet)))
    do {
      _ = try await newest.value
      Issue.record("A current connection failure must not be silently reported as success.")
    } catch {
      #expect((error as? URLError)?.code == .notConnectedToInternet)
    }
  }

  @Test
  func disconnectAndCancellationCannotPublishAnInFlightHome() async throws {
    let fetcher = ControlledHomeFetcher()
    let loader = HomeRefreshCoordinator(fetch: fetcher.fetch)
    let request = loader.beginRequest()
    let pending = Task { try await loader.load(request: request, profile: profile) }
    try await fetcher.waitForRequests(1)
    loader.invalidate()
    fetcher.complete(0, with: .success(home(continueWatching: [item(kind: .movie)])))
    #expect(try await pending.value == nil)

    let next = loader.beginRequest()
    let cancelled = Task { try await loader.load(request: next, profile: profile) }
    try await fetcher.waitForRequests(2)
    cancelled.cancel()
    fetcher.complete(1, with: .success(home(continueWatching: [])))
    #expect(try await cancelled.value == nil)
  }

  private var profile: StoredServerProfile {
    StoredServerProfile(
      serverId: UUID(), name: "Synthetic Server", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "0", count: 64), token: "test-only",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
  }

  private func home(continueWatching: [CatalogItemSummary]) -> HomeResponse {
    HomeResponse(
      recommendation: nil, continueWatching: continueWatching, recentlyAdded: [], favorites: [],
      collections: [], recommendationChangesAt: "2099-01-01T00:00:00Z")
  }

  private func item(kind: MediaKind, available: Bool = true) -> CatalogItemSummary {
    CatalogItemSummary(
      id: UUID(), kind: kind, title: "Pilot", originalTitle: nil, year: 2020,
      overview: nil, genres: [], poster: nil, backdrop: nil,
      availability: available ? .available : .missing, isFavorite: false, progress: nil,
      addedAt: "2026-10-03T00:00:00Z", parentTitle: "Example Show", seasonNumber: 1,
      episodeNumber: 1)
  }
}

@MainActor
private final class ControlledHomeFetcher {
  private var requests: [CheckedContinuation<HomeResponse, any Error>] = []

  func fetch(_ profile: StoredServerProfile) async throws -> HomeResponse {
    try await withCheckedThrowingContinuation { requests.append($0) }
  }

  func waitForRequests(_ count: Int) async throws {
    for _ in 0..<100 where requests.count < count { await Task.yield() }
    try #require(requests.count == count)
  }

  func complete(_ index: Int, with result: Result<HomeResponse, any Error>) {
    requests[index].resume(with: result)
  }
}
