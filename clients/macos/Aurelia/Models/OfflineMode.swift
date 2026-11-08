import Foundation

/// The offline mode: Aurelia without the server, showing only the downloads on this Mac.
enum OfflineModeState: Equatable {
  /// Choosing whose downloads to show.
  case choosingProfile
  /// One profile's downloads.
  case open(OfflineSession)
}

/// The profile whose downloads the offline mode shows.
struct OfflineSession: Equatable, Sendable {
  let serverId: UUID
  let userId: UUID
  let name: String
  let pictureKey: String?
  let pictureRevision: Int64

  init(serverId: UUID, userId: UUID, name: String, pictureKey: String?, pictureRevision: Int64) {
    self.serverId = serverId
    self.userId = userId
    self.name = name
    self.pictureKey = pictureKey
    self.pictureRevision = pictureRevision
  }

  init(card: OfflineProfileCard) {
    self.init(
      serverId: card.serverId, userId: card.userId, name: card.name,
      pictureKey: card.pictureKey, pictureRevision: card.pictureRevision)
  }
}

/// A profile with downloads on this Mac, and its offline card if it has one.
struct OfflineProfileChoice: Identifiable, Equatable {
  let userId: UUID
  let card: OfflineProfileCard?
  var id: UUID { userId }
}

/// How the offline library arranges a profile's downloads.
struct OfflineLibraryLayout: Equatable {
  struct Series: Identifiable, Equatable {
    let id: String
    let title: String
    let episodes: [OfflineTitle]
  }

  /// The title the large picture at the top shows: the last one in progress, else the newest.
  let featured: OfflineTitle?
  let continueWatching: [OfflineTitle]
  let movies: [OfflineTitle]
  let series: [Series]

  init(_ titles: [OfflineTitle]) {
    let inProgress = titles.filter(\.isInProgress).sorted {
      ($0.progressSavedAt ?? $0.downloadedAt) > ($1.progressSavedAt ?? $1.downloadedAt)
    }
    featured = inProgress.first ?? titles.max { $0.downloadedAt < $1.downloadedAt }
    continueWatching = inProgress
    movies = titles.filter { !$0.isEpisode }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    let episodes = titles.filter(\.isEpisode)
    let grouped = Dictionary(grouping: episodes) { episode in
      episode.parentId?.uuidString ?? Self.seriesName(episode)
    }
    series = grouped.map { key, episodes in
      Series(
        id: key,
        title: episodes.first.map(Self.seriesName) ?? "TV Show",
        episodes: episodes.sorted {
          ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0, $0.title)
            < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0, $1.title)
        })
    }
    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  /// The series of an episode; older downloads only have it in front of "S1 E3" in the subtitle.
  static func seriesName(_ episode: OfflineTitle) -> String {
    if let parent = episode.parentTitle, !parent.isEmpty { return parent }
    if let subtitle = episode.subtitle,
      let name = subtitle.components(separatedBy: " · ").first, !name.isEmpty
    {
      return name
    }
    return "TV Show"
  }
}
