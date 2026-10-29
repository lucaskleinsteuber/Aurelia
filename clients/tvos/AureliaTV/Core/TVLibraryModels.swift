import Foundation

enum TVWatchFilter: String, Codable, CaseIterable, Sendable {
  case all, unwatched, inProgress, watched
  var title: String {
    switch self {
    case .all: "All"
    case .unwatched: "Unwatched"
    case .inProgress: "In Progress"
    case .watched: "Watched"
    }
  }
  var wireValue: String? {
    switch self {
    case .all: nil
    case .unwatched: "unplayed"
    case .inProgress: "inProgress"
    case .watched: "completed"
    }
  }
}

enum TVBrowseSort: String, Codable, CaseIterable, Sendable {
  case title, dateAdded, releaseYear, lastPlayed
  var title: String {
    switch self {
    case .title: "Title"
    case .dateAdded: "Date Added"
    case .releaseYear: "Release Year"
    case .lastPlayed: "Last Watched"
    }
  }
}

struct TVBrowseQuery: Codable, Equatable, Sendable {
  var kind: TVMediaKind?
  var favoritesOnly = false
  var genre: String?
  var yearFrom: Int?
  var yearTo: Int?
  var watchState: TVWatchFilter = .all
  var sort: TVBrowseSort?
  var descending = false

  var hasFilters: Bool {
    kind != nil || favoritesOnly || genre != nil || yearFrom != nil || yearTo != nil
      || watchState != .all
  }
  var summary: String {
    var labels: [String] = []
    if favoritesOnly { labels.append("Favorites") }
    if let genre { labels.append(genre) }
    if let yearFrom { labels.append("From \(yearFrom)") }
    if let yearTo { labels.append("To \(yearTo)") }
    if watchState != .all { labels.append(watchState.title) }
    return labels.joined(separator: " · ")
  }
  func queryItems(search: String) throws -> [URLQueryItem] {
    let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard term.count <= 200, kind == nil || kind == .movie || kind == .series,
      yearFrom.map({ (1800...3000).contains($0) }) ?? true,
      yearTo.map({ (1800...3000).contains($0) }) ?? true,
      (genre?.count ?? 0) <= 100,
      yearFrom == nil || yearTo == nil || yearFrom! <= yearTo!
    else { throw TVCoreError.invalidResponse }
    var values: [URLQueryItem] = []
    if !term.isEmpty { values.append(URLQueryItem(name: "query", value: term)) }
    if let kind { values.append(URLQueryItem(name: "kind", value: kind.rawValue)) }
    if favoritesOnly { values.append(URLQueryItem(name: "favorite", value: "true")) }
    if let genre, !genre.isEmpty { values.append(URLQueryItem(name: "genre", value: genre)) }
    if let yearFrom { values.append(URLQueryItem(name: "yearFrom", value: String(yearFrom))) }
    if let yearTo { values.append(URLQueryItem(name: "yearTo", value: String(yearTo))) }
    if let value = watchState.wireValue {
      values.append(URLQueryItem(name: "watchState", value: value))
    }
    if let sort {
      values.append(URLQueryItem(name: "sort", value: sort.rawValue))
      values.append(URLQueryItem(name: "direction", value: descending ? "descending" : "ascending"))
    }
    return values
  }
}

enum TVBrowseSection: String, Codable, Sendable {
  case movies, shows, search, favorites, recentlyAdded, continueWatching, watchlist
  var fixedKind: TVMediaKind? {
    switch self {
    case .movies: .movie
    case .shows: .series
    default: nil
    }
  }
  var title: String {
    switch self {
    case .movies: "Movies"
    case .shows: "TV Shows"
    case .search: "Search"
    case .favorites: "Favorites"
    case .recentlyAdded: "Recently Added"
    case .continueWatching: "Continue Watching"
    case .watchlist: "Watchlist"
    }
  }
  var defaultQuery: TVBrowseQuery {
    var value = TVBrowseQuery(kind: fixedKind)
    if self == .recentlyAdded {
      value.sort = .dateAdded
      value.descending = true
    }
    if self == .continueWatching {
      value.watchState = .inProgress
      value.sort = .lastPlayed
      value.descending = true
    }
    if self == .favorites { value.favoritesOnly = true }
    return value
  }
  func constrain(_ value: TVBrowseQuery) -> TVBrowseQuery {
    var value = value
    if let fixedKind { value.kind = fixedKind }
    if value.kind != nil && value.kind != .movie && value.kind != .series { value.kind = fixedKind }
    if self == .favorites { value.favoritesOnly = true }
    if self == .continueWatching { value.watchState = .inProgress }
    if let from = value.yearFrom, let to = value.yearTo, from > to { value.yearTo = from }
    return value
  }
}

@MainActor
struct TVBrowsePreferenceStore {
  let defaults: UserDefaults?
  func load(serverID: UUID, profileID: UUID, section: TVBrowseSection) -> TVBrowseQuery {
    guard let data = defaults?.data(forKey: key(serverID, profileID, section)),
      let query = try? JSONDecoder().decode(TVBrowseQuery.self, from: data)
    else { return section.defaultQuery }
    return section.constrain(query)
  }
  func save(_ query: TVBrowseQuery, serverID: UUID, profileID: UUID, section: TVBrowseSection) {
    guard let data = try? JSONEncoder().encode(section.constrain(query)), data.count <= 4096 else {
      return
    }
    defaults?.set(data, forKey: key(serverID, profileID, section))
  }
  private func key(_ serverID: UUID, _ profileID: UUID, _ section: TVBrowseSection) -> String {
    "aurelia.tv.browse.v1.\(serverID).\(profileID).\(section.rawValue)"
  }
}

struct TVCollection: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let poster: TVArtwork?
  let items: [TVCatalogItem]
}
struct TVHome: Codable, Equatable, Sendable {
  let recommendation: TVCatalogItem?
  let continueWatching: [TVCatalogItem]
  let recentlyAdded: [TVCatalogItem]
  let favorites: [TVCatalogItem]
  let collections: [TVCollection]
  let recommendationChangesAt: String
}

enum TVWatchScope: String, Codable, Sendable { case title, season, series }
struct TVWatchState: Codable, Equatable, Sendable {
  let mediaId: UUID
  let scope: TVWatchScope
  let seasonNumber: Int?
  let watchState: String
  let affectedCount: Int
  let stateToken: String
  let continueWatchingHidden: Bool
  func validate(mediaID: UUID, scope: TVWatchScope, season: Int?) throws {
    guard mediaId == mediaID, self.scope == scope, seasonNumber == season,
      affectedCount >= 0, !stateToken.isEmpty, stateToken.utf8.count <= 4096
    else { throw TVCoreError.invalidResponse }
  }
}
struct TVSetWatchState: Encodable, Sendable {
  let isWatched: Bool
  let scope: TVWatchScope
  let seasonNumber: Int?
  let stateToken: String
  let clientMutationId: UUID
}
struct TVSetContinueWatching: Encodable, Sendable {
  let isHidden: Bool
  let stateToken: String
  let clientMutationId: UUID
}
struct TVSyncChanges: Decodable, Sendable {
  let cursor: Int64
  let resetRequired: Bool
  let changedAreas: [String]
  let changedMediaIds: [UUID]
  let generation: String?
}

extension TVCatalogItem {
  func replacing(progress: TVPlaybackProgress? = nil, favorite: Bool? = nil) -> TVCatalogItem {
    TVCatalogItem(
      id: id, kind: kind, title: title, originalTitle: originalTitle, year: year,
      overview: overview,
      genres: genres, poster: poster, backdrop: backdrop, availability: availability,
      isFavorite: favorite ?? isFavorite, progress: progress ?? self.progress, addedAt: addedAt,
      parentTitle: parentTitle, seasonNumber: seasonNumber, episodeNumber: episodeNumber,
      parentId: parentId,
      watchState: progress.map {
        $0.isCompleted ? "completed" : $0.positionMilliseconds > 0 ? "inProgress" : "unplayed"
      } ?? watchState,
      libraryAvailability: libraryAvailability, continueWatchingHidden: continueWatchingHidden)
  }
  var detailID: UUID { kind == .episode ? parentId ?? id : id }
}
