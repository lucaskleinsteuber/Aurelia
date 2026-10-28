import AppKit
import Foundation
import Testing

@testable import Aurelia

@MainActor struct LibraryBrowseTests {
  @Test func preferencesStaySeparateByServerProfileAndPageAndContainNoSearch() throws {
    let suite = "Aurelia.LibraryBrowseTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = LibraryBrowsePreferenceStore(defaults: defaults)
    let server = UUID()
    let user = UUID()
    let saved = CatalogBrowseQuery(
      kind: .movie, favoritesOnly: true, genre: "Crime", yearFrom: 1990, yearTo: 2020,
      watchState: .unwatched, sort: .lastPlayed, descending: true)
    store.save(saved, serverId: server, userId: user, section: .library)
    #expect(store.load(serverId: server, userId: user, section: .library) == saved)
    #expect(store.load(serverId: UUID(), userId: user, section: .library) == .init())
    #expect(store.load(serverId: server, userId: UUID(), section: .library) == .init())
    #expect(store.load(serverId: server, userId: user, section: .movies) == .init(kind: .movie))
    let recentlyAdded = store.load(serverId: server, userId: user, section: .recentlyAdded)
    #expect(recentlyAdded.sort == .dateAdded)
    #expect(recentlyAdded.descending)
    let payload = try #require(
      defaults.dictionaryRepresentation().first(where: {
        $0.key.hasPrefix("aurelia.library-browse.v1.")
      })?.value as? Data)
    let fields = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    #expect(fields["search"] == nil)
    #expect(fields["token"] == nil)
    #expect(fields["sessionId"] == nil)
  }

  @Test func destinationStorePersistsPerServerAndUserAndFallsBackToHome() throws {
    let suite = "Aurelia.LibraryDestinationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = LibraryDestinationStore(defaults: defaults)
    let server1 = UUID()
    let server2 = UUID()
    let user1 = UUID()
    let user2 = UUID()

    #expect(store.load(serverId: server1, userId: user1) == .home)

    store.save(.movies, serverId: server1, userId: user1)
    store.save(.tvShows, serverId: server1, userId: user2)
    store.save(.watchlist, serverId: server2, userId: user1)

    #expect(store.load(serverId: server1, userId: user1) == .movies)
    #expect(store.load(serverId: server1, userId: user2) == .tvShows)
    #expect(store.load(serverId: server2, userId: user1) == .watchlist)
    #expect(store.load(serverId: server2, userId: user2) == .home)

    defaults.set(
      "unknown-screen",
      forKey: "aurelia.library-destination.v1.\(server1.uuidString).\(user1.uuidString)")
    #expect(store.load(serverId: server1, userId: user1) == .home)
  }

  @Test func resettingFiltersRetainsSortingAndThePagesMediaLimit() {
    var query = CatalogBrowseQuery(
      kind: .series, favoritesOnly: true, genre: "Drama", yearFrom: 2000, yearTo: 2020,
      watchState: .watched, sort: .releaseYear, descending: true)
    #expect(CatalogBrowseSection.tvShows.hasUserFilters(query))
    query.clearFilters(preserving: CatalogBrowseSection.tvShows.fixedKind)
    #expect(query.kind == .series)
    #expect(!CatalogBrowseSection.tvShows.hasUserFilters(query))
    #expect(query.sort == .releaseYear)
    #expect(query.descending)
    #expect(CatalogBrowseSection.library.hasUserFilters(query))
    query.clearFilters()
    #expect(!query.hasFilters)
  }

  @Test func restoredPreferencesCannotChangeFixedMediaTypesOrLeaveAnInvertedYearRange() {
    let restored = CatalogBrowseSection.movies.constraining(
      CatalogBrowseQuery(kind: .series, yearFrom: 2020, yearTo: 1990))
    #expect(restored.kind == .movie)
    #expect(restored.yearFrom == 2020)
    #expect(restored.yearTo == 2020)
    #expect(CatalogBrowseSection.library.defaultQuery.sort == nil)
    #expect(CatalogBrowseSection.tvShows.defaultQuery.kind == .series)
    #expect(CatalogBrowseSection.library.constraining(.init(kind: .episode)).kind == nil)
  }

  @Test func olderSearchCannotPublishAfterANewerFilterRequest() async throws {
    let fetcher = ControlledBrowseFetcher()
    let browser = LibraryBrowseController()
    let old = Task {
      await browser.load(query: .init(), search: " old ", debounce: .zero, operation: fetcher.fetch)
    }
    try await fetcher.waitForRequests(1)
    #expect(fetcher.searches == ["old"])
    let query = CatalogBrowseQuery(favoritesOnly: true, genre: "Crime", sort: .title)
    let current = Task {
      await browser.load(query: query, search: "new", debounce: .zero, operation: fetcher.fetch)
    }
    try await fetcher.waitForRequests(2)
    #expect(fetcher.queries.last == query)
    let newer = item(title: "New")
    fetcher.complete(1, with: .success([newer]))
    await current.value
    #expect(browser.items == [newer])
    fetcher.complete(0, with: .success([item(title: "Old")]))
    await old.value
    #expect(browser.items == [newer])
    #expect(!browser.isLoading)
  }

  @Test func profileInvalidationAndTaskCancellationDiscardLateCardsAndFailures() async throws {
    let fetcher = ControlledBrowseFetcher()
    let browser = LibraryBrowseController()
    let pending = Task {
      await browser.load(query: .init(), search: "", operation: fetcher.fetch)
    }
    try await fetcher.waitForRequests(1)
    browser.invalidate()
    fetcher.complete(0, with: .failure(URLError(.notConnectedToInternet)))
    await pending.value
    #expect(browser.items.isEmpty)
    #expect(browser.errorMessage == nil)
    #expect(!browser.isLoading)
    let cancelled = Task {
      await browser.load(query: .init(), search: "", operation: fetcher.fetch)
    }
    try await fetcher.waitForRequests(2)
    cancelled.cancel()
    fetcher.complete(1, with: .success([item(title: "Cancelled")]))
    await cancelled.value
    #expect(browser.items.isEmpty)
    #expect(browser.errorMessage == nil)
  }

  @Test func currentErrorIsVisibleAndTheNextRequestRecovers() async throws {
    let browser = LibraryBrowseController()
    await browser.load(query: .init(), search: "") { _, _ in
      throw URLError(.notConnectedToInternet)
    }
    #expect(browser.errorMessage != nil)
    #expect(!browser.isLoading)
    let recovered = item(title: "Recovered")
    await browser.load(query: .init(), search: "") { _, _ in [recovered] }
    #expect(browser.items == [recovered])
    #expect(browser.errorMessage == nil)
  }

  @Test func findShortcutOnlyBelongsToTheActiveUnblockedShellWindow() {
    func consumes(
      _ modifiers: NSEvent.ModifierFlags = .command, characters: String = "f",
      active: Bool = true, blocked: Bool = false, repeated: Bool = false
    ) -> Bool {
      LibraryFindShortcutPolicy.consumes(
        characters: characters, modifiers: modifiers, isRepeat: repeated,
        activeShellWindow: active, blocked: blocked)
    }
    #expect(consumes())
    #expect(consumes(characters: "F"))
    #expect(!consumes([]))
    #expect(!consumes([.command, .option]))
    #expect(!consumes([.command, .control]))
    #expect(!consumes([.command, .shift]))
    #expect(!consumes(characters: "x"))
    #expect(!consumes(active: false))
    #expect(!consumes(blocked: true))
    #expect(!consumes(repeated: true))
  }

  private func item(title: String) -> CatalogItemSummary {
    CatalogItemSummary(
      id: UUID(), kind: .movie, title: title, originalTitle: nil, year: 2020, overview: nil,
      genres: [], poster: nil, backdrop: nil, availability: .available, isFavorite: false,
      progress: nil, addedAt: "2026-10-14T00:00:00Z")
  }
}

@MainActor private final class ControlledBrowseFetcher {
  private var requests: [CheckedContinuation<[CatalogItemSummary], any Error>] = []
  private(set) var queries: [CatalogBrowseQuery] = []
  private(set) var searches: [String] = []

  func fetch(query: CatalogBrowseQuery, search: String) async throws -> [CatalogItemSummary] {
    queries.append(query)
    searches.append(search)
    return try await withCheckedThrowingContinuation { requests.append($0) }
  }

  func waitForRequests(_ count: Int) async throws {
    for _ in 0..<100 where requests.count < count { await Task.yield() }
    try #require(requests.count == count)
  }

  func complete(_ index: Int, with result: Result<[CatalogItemSummary], any Error>) {
    requests[index].resume(with: result)
  }
}
