import AppKit
import Combine
import Foundation

enum CatalogWatchFilter: String, Codable, CaseIterable, Sendable {
  case all
  case unwatched
  case inProgress
  case watched

  var title: String {
    switch self {
    case .all: "All"
    case .unwatched: "Unwatched"
    case .inProgress: "In Progress"
    case .watched: "Watched"
    }
  }
}

enum CatalogBrowseSort: String, Codable, CaseIterable, Sendable {
  case title
  case dateAdded
  case releaseYear
  case lastPlayed

  var title: String {
    switch self {
    case .title: "Title"
    case .dateAdded: "Recently Added"
    case .releaseYear: "Release Year"
    case .lastPlayed: "Last Watched"
    }
  }
}

struct CatalogBrowseQuery: Codable, Equatable, Sendable {
  var kind: MediaKind? = nil
  var favoritesOnly = false
  var genre: String? = nil
  var yearFrom: Int? = nil
  var yearTo: Int? = nil
  var watchState: CatalogWatchFilter = .all
  var sort: CatalogBrowseSort? = nil
  var descending = false

  var hasFilters: Bool {
    kind != nil || favoritesOnly || genre != nil || yearFrom != nil || yearTo != nil
      || watchState != .all
  }

  var requestKey: String {
    [
      kind?.rawValue ?? "", String(favoritesOnly), genre ?? "",
      yearFrom.map(String.init) ?? "", yearTo.map(String.init) ?? "",
      watchState.rawValue, sort?.rawValue ?? "", String(descending),
    ].joined(separator: "\u{1f}")
  }

  mutating func clearFilters(preserving kind: MediaKind? = nil) {
    self.kind = kind
    favoritesOnly = false
    genre = nil
    yearFrom = nil
    yearTo = nil
    watchState = .all
  }
}

enum CatalogBrowseSection: String, Codable, CaseIterable, Sendable {
  case library
  case movies
  case tvShows
  case recentlyAdded

  var title: String {
    switch self {
    case .library: "Library"
    case .movies: "Movies"
    case .tvShows: "TV Shows"
    case .recentlyAdded: "Recently Added"
    }
  }

  var fixedKind: MediaKind? {
    switch self {
    case .movies: .movie
    case .tvShows: .series
    case .library, .recentlyAdded: nil
    }
  }

  var defaultQuery: CatalogBrowseQuery {
    var query = CatalogBrowseQuery(kind: fixedKind)
    if self == .recentlyAdded {
      query.sort = .dateAdded
      query.descending = true
    }
    return query
  }

  func constraining(_ stored: CatalogBrowseQuery) -> CatalogBrowseQuery {
    var query = stored
    if let fixedKind { query.kind = fixedKind }
    if query.kind != nil, query.kind != .movie, query.kind != .series { query.kind = fixedKind }
    if let from = query.yearFrom, let to = query.yearTo, from > to { query.yearTo = from }
    return query
  }

  func hasUserFilters(_ query: CatalogBrowseQuery) -> Bool {
    var query = query
    if fixedKind != nil { query.kind = nil }
    return query.hasFilters
  }
}

/// Search text and credentials never enter the persistent preference payload.
struct LibraryBrowsePreferenceStore {
  let defaults: UserDefaults

  @MainActor static let applicationDefaults: UserDefaults = {
    #if DEBUG
      if ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"] != nil {
        let suite =
          ProcessInfo.processInfo.environment["AURELIA_BROWSE_PREFERENCES_SUITE"]
          ?? "Aurelia.LibraryBrowse.UI.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
      }
    #endif
    return .standard
  }()

  func load(serverId: UUID, userId: UUID, section: CatalogBrowseSection) -> CatalogBrowseQuery {
    guard let data = defaults.data(forKey: key(serverId, userId, section)),
      let stored = try? JSONDecoder().decode(CatalogBrowseQuery.self, from: data)
    else { return section.defaultQuery }
    return section.constraining(stored)
  }

  func save(
    _ query: CatalogBrowseQuery, serverId: UUID, userId: UUID, section: CatalogBrowseSection
  ) {
    guard let encoded = try? JSONEncoder().encode(section.constraining(query)) else { return }
    defaults.set(encoded, forKey: key(serverId, userId, section))
  }

  private func key(_ serverId: UUID, _ userId: UUID, _ section: CatalogBrowseSection) -> String {
    "aurelia.library-browse.v1.\(serverId.uuidString).\(userId.uuidString).\(section.rawValue)"
  }
}

/// An older query, a profile switch, and a view teardown cannot publish stale cards.
@MainActor final class LibraryBrowseController: ObservableObject {
  @Published private(set) var items: [CatalogItemSummary] = []
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  private var generation = UUID()

  func invalidate() {
    generation = UUID()
    items = []
    errorMessage = nil
    isLoading = false
  }

  func load(
    query: CatalogBrowseQuery, search: String, debounce: Duration = .milliseconds(220),
    operation: (CatalogBrowseQuery, String) async throws -> [CatalogItemSummary]
  ) async {
    invalidate()
    let request = generation
    let normalized = search.trimmingCharacters(in: .whitespacesAndNewlines)
    isLoading = true
    defer { if request == generation { isLoading = false } }
    do {
      if !normalized.isEmpty { try await Task.sleep(for: debounce) }
      try Task.checkCancellation()
      let result = try await operation(query, normalized)
      try Task.checkCancellation()
      guard request == generation else { return }
      items = result
    } catch {
      guard request == generation, !Task.isCancelled, !(error is CancellationError) else { return }
      errorMessage = error.localizedDescription
    }
  }
}

enum LibraryFindShortcutPolicy {
  static func consumes(
    characters: String?, modifiers: NSEvent.ModifierFlags, isRepeat: Bool,
    activeShellWindow: Bool, blocked: Bool
  ) -> Bool {
    characters?.lowercased() == "f"
      && modifiers.intersection([.command, .control, .option, .shift]) == .command
      && !isRepeat && activeShellWindow && !blocked
  }
}
