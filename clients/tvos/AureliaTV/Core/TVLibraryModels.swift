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
    else { throw TVCoreError.invalidRequest }
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
  var overview: String? = nil
  let poster: TVArtwork?
  var backdrop: TVArtwork? = nil
  let items: [TVCatalogItem]
  let isSmart: Bool
  let totalCount: Int
  let isShared: Bool
  var provider: String? = nil
  var canEdit: Bool? = nil
  var itemCount: Int? = nil
  var watchedCount: Int? = nil
  var yearRange: String? = nil
  var sortMode: String? = nil

  init(
    id: UUID,
    name: String,
    overview: String? = nil,
    poster: TVArtwork?,
    backdrop: TVArtwork? = nil,
    items: [TVCatalogItem],
    isSmart: Bool = false,
    totalCount: Int = 0,
    isShared: Bool = true,
    provider: String? = nil,
    canEdit: Bool? = nil,
    itemCount: Int? = nil,
    watchedCount: Int? = nil,
    yearRange: String? = nil,
    sortMode: String? = nil
  ) {
    self.id = id
    self.name = name
    self.overview = overview
    self.poster = poster
    self.backdrop = backdrop
    self.items = items
    self.isSmart = isSmart
    self.totalCount = totalCount == 0 ? items.count : totalCount
    self.isShared = isShared
    self.provider = provider
    self.canEdit = canEdit
    self.itemCount = itemCount
    self.watchedCount = watchedCount
    self.yearRange = yearRange
    self.sortMode = sortMode
  }

  enum CodingKeys: String, CodingKey {
    case id, name, overview, poster, backdrop, items, isSmart, totalCount, isShared
    case provider, canEdit, itemCount, watchedCount, yearRange, sortMode
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    overview = try container.decodeIfPresent(String.self, forKey: .overview)
    poster = try container.decodeIfPresent(TVArtwork.self, forKey: .poster)
    backdrop = try container.decodeIfPresent(TVArtwork.self, forKey: .backdrop)
    items = try container.decodeIfPresent([TVCatalogItem].self, forKey: .items) ?? []
    isSmart = try container.decodeIfPresent(Bool.self, forKey: .isSmart) ?? false
    let count = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
    totalCount = count == 0 ? items.count : count
    isShared = try container.decodeIfPresent(Bool.self, forKey: .isShared) ?? true
    provider = try container.decodeIfPresent(String.self, forKey: .provider)
    canEdit = try container.decodeIfPresent(Bool.self, forKey: .canEdit)
    itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount)
    watchedCount = try container.decodeIfPresent(Int.self, forKey: .watchedCount)
    yearRange = try container.decodeIfPresent(String.self, forKey: .yearRange)
    sortMode = try container.decodeIfPresent(String.self, forKey: .sortMode)
  }

  var effectiveItemCount: Int {
    if let itemCount, itemCount > 0 { return itemCount }
    return totalCount > 0 ? totalCount : items.count
  }

  var effectiveWatchedCount: Int {
    if let watchedCount { return max(0, min(watchedCount, effectiveItemCount)) }
    return items.filter { $0.watchState == "completed" || $0.progress?.isCompleted == true }.count
  }

  var progressFraction: Double? {
    let total = effectiveItemCount
    guard total > 0 else { return nil }
    let watched = effectiveWatchedCount
    guard watched > 0 else { return nil }
    return min(1, Double(watched) / Double(total))
  }
}

struct TVCollectionMember: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let kind: TVMediaKind
  let title: String
  var seasonNumber: Int? = nil
  var item: TVCatalogItem? = nil
  var episodes: [TVCatalogItem]? = nil
  var watchedCount: Int? = nil
  var itemCount: Int? = nil
  var totalRuntimeSeconds: Int64? = nil

  init(
    id: UUID = UUID(),
    mediaId: UUID,
    kind: TVMediaKind,
    title: String,
    seasonNumber: Int? = nil,
    item: TVCatalogItem? = nil,
    episodes: [TVCatalogItem]? = nil,
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
    kind = try container.decodeIfPresent(TVMediaKind.self, forKey: .kind) ?? .unknown
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
    item = try container.decodeIfPresent(TVCatalogItem.self, forKey: .item)
    episodes = try container.decodeIfPresent([TVCatalogItem].self, forKey: .episodes)
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

struct TVCollectionNextResponse: Codable, Equatable, Sendable {
  let item: TVCatalogItem?
  let resume: Bool
  let positionMilliseconds: Int64
  let itemIndex: Int
  let totalItems: Int
}

struct TVCollectionDetail: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  var overview: String? = nil
  var poster: TVArtwork? = nil
  var backdrop: TVArtwork? = nil
  let items: [TVCatalogItem]
  let isSmart: Bool
  let totalCount: Int
  let isShared: Bool
  var provider: String? = nil
  var canEdit: Bool? = nil
  var itemCount: Int? = nil
  var watchedCount: Int? = nil
  var yearRange: String? = nil
  var sortMode: String? = nil
  var totalRuntimeSeconds: Int64? = nil
  var genres: [String]? = nil
  var members: [TVCollectionMember]? = nil
  var isEditable: Bool? = nil
  var nextItem: TVCollectionNextResponse? = nil

  init(collection: TVCollection) {
    self.id = collection.id
    self.name = collection.name
    self.overview = collection.overview
    self.poster = collection.poster
    self.backdrop = collection.backdrop
    self.items = collection.items
    self.isSmart = collection.isSmart
    self.totalCount = collection.totalCount
    self.isShared = collection.isShared
    self.provider = collection.provider
    self.canEdit = collection.canEdit
    self.itemCount = collection.itemCount
    self.watchedCount = collection.watchedCount
    self.yearRange = collection.yearRange
    self.sortMode = collection.sortMode
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, overview, poster, backdrop, items, isSmart, totalCount, isShared
    case provider, canEdit, itemCount, watchedCount, yearRange, sortMode
    case totalRuntimeSeconds, genres, members, isEditable, nextItem
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    overview = try container.decodeIfPresent(String.self, forKey: .overview)
    poster = try container.decodeIfPresent(TVArtwork.self, forKey: .poster)
    backdrop = try container.decodeIfPresent(TVArtwork.self, forKey: .backdrop)
    items = try container.decodeIfPresent([TVCatalogItem].self, forKey: .items) ?? []
    isSmart = try container.decodeIfPresent(Bool.self, forKey: .isSmart) ?? false
    let count = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
    totalCount = count == 0 ? items.count : count
    isShared = try container.decodeIfPresent(Bool.self, forKey: .isShared) ?? true
    provider = try container.decodeIfPresent(String.self, forKey: .provider)
    canEdit = try container.decodeIfPresent(Bool.self, forKey: .canEdit)
    itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount)
    watchedCount = try container.decodeIfPresent(Int.self, forKey: .watchedCount)
    yearRange = try container.decodeIfPresent(String.self, forKey: .yearRange)
    sortMode = try container.decodeIfPresent(String.self, forKey: .sortMode)
    totalRuntimeSeconds = try container.decodeIfPresent(Int64.self, forKey: .totalRuntimeSeconds)
    genres = try container.decodeIfPresent([String].self, forKey: .genres)
    members = try container.decodeIfPresent([TVCollectionMember].self, forKey: .members)
    isEditable = try container.decodeIfPresent(Bool.self, forKey: .isEditable)
    nextItem = try container.decodeIfPresent(TVCollectionNextResponse.self, forKey: .nextItem)
  }

  var summary: TVCollection {
    TVCollection(
      id: id, name: name, overview: overview, poster: poster, backdrop: backdrop, items: items,
      isSmart: isSmart, totalCount: totalCount, isShared: isShared, provider: provider,
      canEdit: canEdit, itemCount: itemCount, watchedCount: watchedCount, yearRange: yearRange,
      sortMode: sortMode)
  }

  var resolvedMembers: [TVCollectionMember] {
    if let members, !members.isEmpty { return members }
    return items.map { item in
      TVCollectionMember(
        id: item.id, mediaId: item.id, kind: item.kind, title: item.title,
        seasonNumber: item.seasonNumber, item: item, episodes: nil,
        watchedCount: (item.watchState == "completed" || item.progress?.isCompleted == true) ? 1 : 0,
        itemCount: 1, totalRuntimeSeconds: nil)
    }
  }
}

enum TVCollectionPresentation {
  static func cleanedOverview(_ overview: String?) -> String? {
    guard let trimmed = overview?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  static func providerLabel(_ provider: String?, isSmart: Bool = false) -> String? {
    switch provider?.lowercased() {
    case "tmdb": return "TMDB"
    case "universe": return "Universe"
    case "rule", "smart": return "Smart"
    default: return isSmart ? "Smart" : nil
    }
  }

  static func providerLabel(for collection: TVCollection) -> String? {
    providerLabel(collection.provider, isSmart: collection.isSmart)
  }

  static func cardSubtitle(_ collection: TVCollection) -> String {
    let count = collection.effectiveItemCount
    let countText = count == 1 ? "1 title" : "\(count) titles"
    let watched = collection.effectiveWatchedCount
    var parts: [String] = []
    if count > 1 && watched > 0 {
      parts.append("\(watched) of \(count) watched")
    } else if count == 1 && watched == 1 {
      parts.append("Watched")
    } else {
      parts.append(countText)
    }
    if let range = collection.yearRange, !range.isEmpty { parts.append(range) }
    return parts.joined(separator: " · ")
  }

  static func statsLine(_ detail: TVCollectionDetail) -> String? {
    var parts: [String] = []
    if let range = detail.yearRange, !range.isEmpty { parts.append(range) }
    let total = detail.summary.effectiveItemCount
    if total > 0 { parts.append(total == 1 ? "1 title" : "\(total) titles") }
    if let seconds = detail.totalRuntimeSeconds, seconds > 0 {
      parts.append(formattedRuntime(seconds))
    }
    let watched = detail.summary.effectiveWatchedCount
    if total > 0 && watched > 0 { parts.append("\(watched) of \(total) watched") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  static func playLabel(for detail: TVCollectionDetail) -> String {
    if let next = detail.nextItem, let item = next.item {
      if next.resume {
        if let label = item.episodeLabel { return "Resume \(label)" }
        return "Resume Box Set"
      }
      if let label = item.episodeLabel { return "Play \(label)" }
      return "Play Box Set"
    }
    let items = playableItems(in: detail)
    if let first = items.first,
      let progress = first.progress, progress.positionMilliseconds > 0, !progress.isCompleted
    {
      return "Resume Box Set"
    }
    return "Play Box Set"
  }

  static func playableItems(in detail: TVCollectionDetail) -> [TVCatalogItem] {
    if let members = detail.members, !members.isEmpty {
      var list: [TVCatalogItem] = []
      var seen: Set<UUID> = []
      for member in members {
        if let episodes = member.episodes, !episodes.isEmpty {
          for episode in episodes where episode.isPlayable && seen.insert(episode.id).inserted {
            list.append(episode)
          }
        } else if let item = member.item, item.isPlayable, seen.insert(item.id).inserted {
          list.append(item)
        }
      }
      if !list.isEmpty { return list }
    }
    return detail.items.filter(\.isPlayable)
  }

  static func playbackQueue(in detail: TVCollectionDetail, startingAt targetID: UUID)
    -> [TVCatalogItem]
  {
    let list = playableItems(in: detail)
    guard let index = list.firstIndex(where: { $0.id == targetID }) else { return [] }
    return Array(list.dropFirst(index + 1))
  }

  private static func formattedRuntime(_ seconds: Int64) -> String {
    let totalMinutes = max(1, Int((seconds + 30) / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
    if hours > 0 { return "\(hours)h" }
    return "\(minutes)m"
  }
}
struct TVHome: Codable, Equatable, Sendable {
  let recommendation: TVCatalogItem?
  let continueWatching: [TVCatalogItem]
  let recentlyAdded: [TVCatalogItem]
  let favorites: [TVCatalogItem]
  let collections: [TVCollection]
  let recommendationChangesAt: String
  /// "Because You Watched …" rails; servers before 2.11.0 send none.
  var becauseYouWatched: [TVHomeSuggestionRail]? = nil
}

/// What to watch next with its reason in words ("suggestions-v1").
struct TVMediaSuggestion: Codable, Equatable, Sendable, Identifiable {
  let item: TVCatalogItem
  let kind: String
  let reason: String

  var id: UUID { item.id }
}

struct TVMediaSuggestionsResponse: Codable, Equatable, Sendable {
  let mediaId: UUID
  let suggestions: [TVMediaSuggestion]
}

struct TVHomeSuggestionRail: Codable, Equatable, Sendable, Identifiable {
  let sourceId: UUID
  let sourceTitle: String
  let suggestions: [TVMediaSuggestion]

  var id: UUID { sourceId }
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
