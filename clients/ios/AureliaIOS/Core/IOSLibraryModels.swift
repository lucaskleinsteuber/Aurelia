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
  var rulesJson: String? = nil
  var overview: String? = nil
  var backdrop: IOSArtwork? = nil
  var provider: String? = nil
  var canEdit: Bool = false
  var itemCount: Int = 0
  var watchedCount: Int = 0
  var yearRange: String? = nil
  var sortMode: String? = nil

  init(
    id: UUID,
    name: String,
    poster: IOSArtwork?,
    items: [IOSCatalogItem],
    isSmart: Bool = false,
    totalCount: Int = 0,
    isShared: Bool = true,
    userId: UUID? = nil,
    rulesJson: String? = nil,
    overview: String? = nil,
    backdrop: IOSArtwork? = nil,
    provider: String? = nil,
    canEdit: Bool = false,
    itemCount: Int = 0,
    watchedCount: Int = 0,
    yearRange: String? = nil,
    sortMode: String? = nil
  ) {
    self.id = id
    self.name = name
    self.poster = poster
    self.items = items
    self.isSmart = isSmart
    let count = totalCount == 0 ? items.count : totalCount
    self.totalCount = count
    self.isShared = isShared
    self.userId = userId
    self.rulesJson = rulesJson
    self.overview = overview
    self.backdrop = backdrop
    self.provider = provider
    self.canEdit = canEdit
    self.itemCount = itemCount == 0 ? count : itemCount
    self.watchedCount = watchedCount
    self.yearRange = yearRange
    self.sortMode = sortMode
  }

  enum CodingKeys: String, CodingKey {
    case id, name, poster, items, isSmart, totalCount, isShared, userId, rulesJson
    case overview, backdrop, provider, canEdit, itemCount, watchedCount, yearRange, sortMode
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
    rulesJson = try container.decodeIfPresent(String.self, forKey: .rulesJson)
    overview = try container.decodeIfPresent(String.self, forKey: .overview)
    backdrop = try container.decodeIfPresent(IOSArtwork.self, forKey: .backdrop)
    provider = try container.decodeIfPresent(String.self, forKey: .provider)
    canEdit = try container.decodeIfPresent(Bool.self, forKey: .canEdit) ?? false
    let decodedItemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
    itemCount = decodedItemCount == 0 ? totalCount : decodedItemCount
    watchedCount = try container.decodeIfPresent(Int.self, forKey: .watchedCount) ?? 0
    yearRange = try container.decodeIfPresent(String.self, forKey: .yearRange)
    sortMode = try container.decodeIfPresent(String.self, forKey: .sortMode)
  }
}

struct IOSCollectionMember: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let kind: IOSMediaKind
  let title: String
  var seasonNumber: Int? = nil
  var item: IOSCatalogItem? = nil
  var episodes: [IOSCatalogItem]? = nil
  var watchedCount: Int? = nil
  var itemCount: Int? = nil
  var totalRuntimeSeconds: Int64? = nil

  init(
    id: UUID = UUID(),
    mediaId: UUID,
    kind: IOSMediaKind,
    title: String,
    seasonNumber: Int? = nil,
    item: IOSCatalogItem? = nil,
    episodes: [IOSCatalogItem]? = nil,
    watchedCount: Int? = nil,
    itemCount: Int? = nil,
    totalRuntimeSeconds: Int64? = nil
  ) {
    self.id = id
    self.mediaId = mediaId
    self.kind = kind
    self.title = title
    self.seasonNumber = seasonNumber
    self.item = item
    self.episodes = episodes
    self.watchedCount = watchedCount
    self.itemCount = itemCount
    self.totalRuntimeSeconds = totalRuntimeSeconds
  }

  private enum CodingKeys: String, CodingKey {
    case id, memberId, mediaId, kind, title, seasonNumber, item, episodes, watchedCount, itemCount
    case totalRuntimeSeconds
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id =
      try container.decodeIfPresent(UUID.self, forKey: .id)
      ?? container.decodeIfPresent(UUID.self, forKey: .memberId)
      ?? UUID()
    mediaId = try container.decode(UUID.self, forKey: .mediaId)
    kind = try container.decodeIfPresent(IOSMediaKind.self, forKey: .kind) ?? .unknown
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
    item = try container.decodeIfPresent(IOSCatalogItem.self, forKey: .item)
    episodes = try container.decodeIfPresent([IOSCatalogItem].self, forKey: .episodes)
    watchedCount = try container.decodeIfPresent(Int.self, forKey: .watchedCount)
    itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount)
    totalRuntimeSeconds = try container.decodeIfPresent(Int64.self, forKey: .totalRuntimeSeconds)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(mediaId, forKey: .mediaId)
    try container.encode(kind, forKey: .kind)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(seasonNumber, forKey: .seasonNumber)
    try container.encodeIfPresent(item, forKey: .item)
    try container.encodeIfPresent(episodes, forKey: .episodes)
    try container.encodeIfPresent(watchedCount, forKey: .watchedCount)
    try container.encodeIfPresent(itemCount, forKey: .itemCount)
    try container.encodeIfPresent(totalRuntimeSeconds, forKey: .totalRuntimeSeconds)
  }

  var displayTitle: String {
    guard let seasonNumber else { return title }
    let label = seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)"
    if let base = item?.title, !base.isEmpty { return "\(base) · \(label)" }
    return title.isEmpty ? label : title
  }
}

struct IOSCollectionNextResponse: Codable, Equatable, Sendable {
  let item: IOSCatalogItem
  let resume: Bool
  let positionMilliseconds: Int64
  let itemIndex: Int
  let totalItems: Int
}

struct IOSCollectionDetail: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  var overview: String?
  var poster: IOSArtwork?
  var backdrop: IOSArtwork?
  var provider: String?
  var canEdit: Bool
  var isSmart: Bool
  var isShared: Bool
  var userId: UUID?
  var rulesJson: String?
  var sortMode: String
  var itemCount: Int
  var watchedCount: Int
  var yearRange: String?
  var totalRuntimeSeconds: Int64
  var genres: [String]
  var members: [IOSCollectionMember]
  var nextItem: IOSCollectionNextResponse?

  init(
    id: UUID,
    name: String,
    overview: String? = nil,
    poster: IOSArtwork? = nil,
    backdrop: IOSArtwork? = nil,
    provider: String? = nil,
    canEdit: Bool = false,
    isSmart: Bool = false,
    isShared: Bool = true,
    userId: UUID? = nil,
    rulesJson: String? = nil,
    sortMode: String = "custom",
    itemCount: Int = 0,
    watchedCount: Int = 0,
    yearRange: String? = nil,
    totalRuntimeSeconds: Int64 = 0,
    genres: [String] = [],
    members: [IOSCollectionMember] = [],
    nextItem: IOSCollectionNextResponse? = nil
  ) {
    self.id = id
    self.name = name
    self.overview = overview
    self.poster = poster
    self.backdrop = backdrop
    self.provider = provider
    self.canEdit = canEdit
    self.isSmart = isSmart
    self.isShared = isShared
    self.userId = userId
    self.rulesJson = rulesJson
    self.sortMode = sortMode
    self.itemCount = itemCount == 0 ? members.count : itemCount
    self.watchedCount = watchedCount
    self.yearRange = yearRange
    self.totalRuntimeSeconds = totalRuntimeSeconds
    self.genres = genres
    self.members = members
    self.nextItem = nextItem
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, overview, poster, backdrop, provider, canEdit, isSmart, isShared, userId
    case rulesJson, sortMode, itemCount, watchedCount, yearRange, totalRuntimeSeconds, genres
    case members, nextItem
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    overview = try container.decodeIfPresent(String.self, forKey: .overview)
    poster = try container.decodeIfPresent(IOSArtwork.self, forKey: .poster)
    backdrop = try container.decodeIfPresent(IOSArtwork.self, forKey: .backdrop)
    provider = try container.decodeIfPresent(String.self, forKey: .provider)
    canEdit = try container.decodeIfPresent(Bool.self, forKey: .canEdit) ?? false
    isSmart = try container.decodeIfPresent(Bool.self, forKey: .isSmart) ?? false
    isShared = try container.decodeIfPresent(Bool.self, forKey: .isShared) ?? true
    userId = try container.decodeIfPresent(UUID.self, forKey: .userId)
    rulesJson = try container.decodeIfPresent(String.self, forKey: .rulesJson)
    sortMode = try container.decodeIfPresent(String.self, forKey: .sortMode) ?? "custom"
    let decodedMembers = try container.decodeIfPresent([IOSCollectionMember].self, forKey: .members) ?? []
    members = decodedMembers
    let count = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
    itemCount = count == 0 ? decodedMembers.count : count
    watchedCount = try container.decodeIfPresent(Int.self, forKey: .watchedCount) ?? 0
    yearRange = try container.decodeIfPresent(String.self, forKey: .yearRange)
    totalRuntimeSeconds = try container.decodeIfPresent(Int64.self, forKey: .totalRuntimeSeconds) ?? 0
    genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
    nextItem = try container.decodeIfPresent(IOSCollectionNextResponse.self, forKey: .nextItem)
  }

  var summary: IOSCollection {
    IOSCollection(
      id: id,
      name: name,
      poster: poster,
      items: members.compactMap(\.item),
      isSmart: isSmart,
      totalCount: itemCount,
      isShared: isShared,
      userId: userId,
      rulesJson: rulesJson,
      overview: overview,
      backdrop: backdrop,
      provider: provider,
      canEdit: canEdit,
      itemCount: itemCount,
      watchedCount: watchedCount,
      yearRange: yearRange,
      sortMode: sortMode)
  }
}

struct IOSCollectionMemberInput: Codable, Equatable, Sendable, Identifiable {
  let mediaId: UUID
  var seasonNumber: Int? = nil

  var id: String { "\(mediaId.uuidString):\(seasonNumber.map(String.init) ?? "all")" }
}

struct IOSArtworkCrop: Codable, Equatable, Sendable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double
}

struct IOSSaveCollectionArtwork: Codable, Equatable, Sendable {
  var uploadId: UUID? = nil
  var crop: IOSArtworkCrop? = nil
}

struct IOSCollectionOrderRequest: Codable, Equatable, Sendable {
  let members: [IOSCollectionMemberInput]
  var sortMode: String? = nil
}

struct IOSUploadedEditorImage: Codable, Equatable, Sendable {
  let id: UUID
  var path: String? = nil
  let width: Int
  let height: Int
}

enum IOSCollectionRules {
  static let maximumNameLength = 80
  static let maximumOverviewLength = 8_192

  /// A smart list or automatic franchise chooses its own titles; a personal collection is its
  /// profile's, a shared one the administrators'.
  static func canEdit(
    _ collection: IOSCollection, userID: UUID?, role: String?, supportsV3: Bool = false
  ) -> Bool {
    if supportsV3 || collection.provider != nil { return collection.canEdit }
    guard !collection.isSmart else { return false }
    if collection.canEdit { return true }
    if collection.isShared { return role == "owner" || role == "admin" }
    return collection.userId == nil || collection.userId == userID
  }

  /// The name trimmed and within its limit, or nil when nothing is left.
  static func cleanedName(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : String(trimmed.prefix(maximumNameLength))
  }

  static func cleanedOverview(_ overview: String) -> String? {
    let trimmed = overview.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : String(trimmed.prefix(maximumOverviewLength))
  }

  static func providerLabel(_ provider: String?) -> String? {
    switch provider {
    case "tmdb": "TMDB Collection"
    case "universe": "Universe"
    case let value? where !value.isEmpty: value
    default: nil
    }
  }

  static func cardSubtitle(_ collection: IOSCollection) -> String {
    var parts: [String] = []
    if let badge = providerLabel(collection.provider) {
      parts.append(badge)
    } else if collection.isSmart {
      parts.append("Smart List")
    }
    if let range = collection.yearRange, !range.isEmpty { parts.append(range) }
    let total =
      collection.itemCount > 0
      ? collection.itemCount
      : (collection.totalCount > 0 ? collection.totalCount : collection.items.count)
    if total > 0, collection.watchedCount > 0 {
      parts.append("\(collection.watchedCount) of \(total) watched")
    } else if total > 0, parts.isEmpty {
      parts.append(total == 1 ? "1 title" : "\(total) titles")
    }
    return parts.isEmpty ? "Collection" : parts.joined(separator: " · ")
  }

  static func statsLine(_ detail: IOSCollectionDetail) -> String {
    let count = detail.itemCount > 0 ? detail.itemCount : detail.members.count
    var parts: [String] = [count == 1 ? "1 title" : "\(count) titles"]
    if count > 0 { parts.append("\(detail.watchedCount) of \(count) watched") }
    if let range = detail.yearRange, !range.isEmpty { parts.append(range) }
    if detail.totalRuntimeSeconds >= 60 {
      let totalMinutes = Int((detail.totalRuntimeSeconds + 30) / 60)
      let hours = totalMinutes / 60
      let minutes = totalMinutes % 60
      if hours > 0 {
        parts.append(minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h")
      } else {
        parts.append("\(minutes) min")
      }
    }
    return parts.joined(separator: " · ")
  }

  static func playLabel(_ next: IOSCollectionNextResponse?) -> String {
    guard let next else { return "Play" }
    let prefix = next.resume ? "Resume" : "Play"
    if next.item.kind == .episode, let episode = next.item.episodeLabel {
      return "\(prefix) · \(episode)"
    }
    return next.item.title.isEmpty ? prefix : "\(prefix) · \(next.item.title)"
  }

  static func playableItems(from detail: IOSCollectionDetail) -> [IOSCatalogItem] {
    var seen = Set<UUID>()
    var ordered: [IOSCatalogItem] = []
    for member in detail.members {
      let units: [IOSCatalogItem]
      if let episodes = member.episodes, !episodes.isEmpty {
        units = episodes
      } else if let item = member.item, item.kind == .movie || item.kind == .episode {
        units = [item]
      } else {
        units = []
      }
      for unit in units where unit.isPlayable && seen.insert(unit.id).inserted {
        ordered.append(unit)
      }
    }
    return ordered
  }

  static func queue(in detail: IOSCollectionDetail, startingAt target: IOSCatalogItem)
    -> [IOSCatalogItem]
  {
    let all = playableItems(from: detail)
    if let index = all.firstIndex(where: { $0.id == target.id }) {
      return Array(all.dropFirst(index + 1))
    }
    return all.filter { $0.id != target.id }
  }
}
struct IOSHome: Codable, Equatable, Sendable {
  let recommendation: IOSCatalogItem?
  let continueWatching: [IOSCatalogItem]
  let recentlyAdded: [IOSCatalogItem]
  let favorites: [IOSCatalogItem]
  let collections: [IOSCollection]
  let recommendationChangesAt: String
  /// "Because You Watched …" rails; servers before 2.11.0 send none.
  var becauseYouWatched: [IOSHomeSuggestionRail]? = nil
}

/// What to watch next with its reason in words ("suggestions-v1").
struct IOSMediaSuggestion: Codable, Equatable, Sendable, Identifiable {
  let item: IOSCatalogItem
  let kind: String
  let reason: String

  var id: UUID { item.id }
}

struct IOSMediaSuggestionsResponse: Codable, Equatable, Sendable {
  let mediaId: UUID
  let suggestions: [IOSMediaSuggestion]
}

struct IOSHomeSuggestionRail: Codable, Equatable, Sendable, Identifiable {
  let sourceId: UUID
  let sourceTitle: String
  let suggestions: [IOSMediaSuggestion]

  var id: UUID { sourceId }
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

/// A new or changed collection / Box Set.
struct IOSSaveCollection: Codable, Equatable, Sendable {
  let name: String
  var mediaIds: [UUID]? = nil
  var isSmart = false
  var isShared = false
  var rulesJson: String? = nil
  var overview: String? = nil
  var sortMode: String? = nil
  var members: [IOSCollectionMemberInput]? = nil
}
