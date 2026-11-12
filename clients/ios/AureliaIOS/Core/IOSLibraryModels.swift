import Foundation

enum IOSWatchFilter: String, Codable, CaseIterable, Sendable {
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

enum IOSBrowseSort: String, Codable, CaseIterable, Sendable {
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

struct IOSBrowseQuery: Codable, Equatable, Sendable {
  var kind: IOSMediaKind?
  var favoritesOnly = false
  var genre: String?
  var yearFrom: Int?
  var yearTo: Int?
  var watchState: IOSWatchFilter = .all
  var sort: IOSBrowseSort?
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
    else { throw IOSCoreError.invalidRequest }
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

enum IOSBrowseSection: String, Codable, Sendable {
  case movies, shows, search, favorites, recentlyAdded, continueWatching, watchlist
  var fixedKind: IOSMediaKind? {
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
  var defaultQuery: IOSBrowseQuery {
    var value = IOSBrowseQuery(kind: fixedKind)
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
  func constrain(_ value: IOSBrowseQuery) -> IOSBrowseQuery {
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
struct IOSBrowsePreferenceStore {
  let defaults: UserDefaults?
  func load(serverID: UUID, profileID: UUID, section: IOSBrowseSection) -> IOSBrowseQuery {
    guard let data = defaults?.data(forKey: key(serverID, profileID, section)),
      let query = try? JSONDecoder().decode(IOSBrowseQuery.self, from: data)
    else { return section.defaultQuery }
    return section.constrain(query)
  }
  func save(_ query: IOSBrowseQuery, serverID: UUID, profileID: UUID, section: IOSBrowseSection) {
    guard let data = try? JSONEncoder().encode(section.constrain(query)), data.count <= 4096 else {
      return
    }
    defaults?.set(data, forKey: key(serverID, profileID, section))
  }
  private func key(_ serverID: UUID, _ profileID: UUID, _ section: IOSBrowseSection) -> String {
    "aurelia.tv.browse.v1.\(serverID).\(profileID).\(section.rawValue)"
  }
}

struct IOSCollection: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let poster: IOSArtwork?
  let items: [IOSCatalogItem]
  let isSmart: Bool
  let totalCount: Int
  let isShared: Bool
  /// The profile a personal collection belongs to; nil for a shared one.
  var userId: UUID? = nil

  init(
    id: UUID,
    name: String,
    poster: IOSArtwork?,
    items: [IOSCatalogItem],
    isSmart: Bool = false,
    totalCount: Int = 0,
    isShared: Bool = true
  ) {
    self.id = id
    self.name = name
    self.poster = poster
    self.items = items
    self.isSmart = isSmart
    self.totalCount = totalCount == 0 ? items.count : totalCount
    self.isShared = isShared
  }

  enum CodingKeys: String, CodingKey {
    case id, name, poster, items, isSmart, totalCount, isShared, userId
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    poster = try container.decodeIfPresent(IOSArtwork.self, forKey: .poster)
    items = try container.decodeIfPresent([IOSCatalogItem].self, forKey: .items) ?? []
    isSmart = try container.decodeIfPresent(Bool.self, forKey: .isSmart) ?? false
    let count = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
    totalCount = count == 0 ? items.count : count
    isShared = try container.decodeIfPresent(Bool.self, forKey: .isShared) ?? true
    userId = try container.decodeIfPresent(UUID.self, forKey: .userId)
  }
}

enum IOSCollectionRules {
  static let maximumNameLength = 80

  /// A smart list chooses its own titles; a personal collection is its profile's, a shared one
  /// the administrators'.
  static func canEdit(_ collection: IOSCollection, userID: UUID?, role: String?) -> Bool {
    guard !collection.isSmart else { return false }
    if collection.isShared { return role == "owner" || role == "admin" }
    return collection.userId == nil || collection.userId == userID
  }

  /// The name trimmed and within its limit, or nil when nothing is left.
  static func cleanedName(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : String(trimmed.prefix(maximumNameLength))
  }
}
struct IOSHome: Codable, Equatable, Sendable {
  let recommendation: IOSCatalogItem?
  let continueWatching: [IOSCatalogItem]
  let recentlyAdded: [IOSCatalogItem]
  let favorites: [IOSCatalogItem]
  let collections: [IOSCollection]
  let recommendationChangesAt: String
}

enum IOSWatchScope: String, Codable, Sendable { case title, season, series }
struct IOSWatchState: Codable, Equatable, Sendable {
  let mediaId: UUID
  let scope: IOSWatchScope
  let seasonNumber: Int?
  let watchState: String
  let affectedCount: Int
  let stateToken: String
  let continueWatchingHidden: Bool
  func validate(mediaID: UUID, scope: IOSWatchScope, season: Int?) throws {
    guard mediaId == mediaID, self.scope == scope, seasonNumber == season,
      affectedCount >= 0, !stateToken.isEmpty, stateToken.utf8.count <= 4096
    else { throw IOSCoreError.invalidResponse }
  }
}
struct IOSSetWatchState: Encodable, Sendable {
  let isWatched: Bool
  let scope: IOSWatchScope
  let seasonNumber: Int?
  let stateToken: String
  let clientMutationId: UUID
}
struct IOSSetContinueWatching: Encodable, Sendable {
  let isHidden: Bool
  let stateToken: String
  let clientMutationId: UUID
}
struct IOSSyncChanges: Decodable, Sendable {
  let cursor: Int64
  let resetRequired: Bool
  let changedAreas: [String]
  let changedMediaIds: [UUID]
  let generation: String?
}

extension IOSCatalogItem {
  var kindLabel: String {
    switch kind {
    case .series: "TV Show"
    case .episode: "Episode"
    case .movie: "Movie"
    default: "Video"
    }
  }

  var cardSubtitle: String {
    if kind == .episode {
      let series = parentTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
      let context = [series.flatMap { $0.isEmpty ? nil : $0 }, episodeLabel]
        .compactMap { $0 }.joined(separator: " · ")
      return context.isEmpty ? "Episode" : context
    }
    return availabilityMessage ?? year.map(String.init) ?? kindLabel
  }

  func replacing(progress: IOSPlaybackProgress? = nil, favorite: Bool? = nil) -> IOSCatalogItem {
    IOSCatalogItem(
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

/// A new or changed collection; smart lists are made on the Mac or in the browser.
struct IOSSaveCollection: Codable, Equatable, Sendable {
  let name: String
  let mediaIds: [UUID]
  var isSmart = false
  var isShared = false
  var rulesJson: String? = nil
}
