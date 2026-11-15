import Foundation
import Testing

@testable import Aurelia

/// Rules behind the library review fixes, with invented titles only; nothing is played or fetched.
@MainActor
struct LibraryReviewFixTests {
  private func item(
    kind: MediaKind = .episode, title: String = "Invented",
    progress: PlaybackProgressResponse? = nil,
    addedAt: String = "2026-11-01T00:00:00Z", genres: [String] = [], isFavorite: Bool = false
  ) -> CatalogItemSummary {
    CatalogItemSummary(
      id: UUID(), kind: kind, title: title, originalTitle: nil, year: 2020, overview: nil,
      genres: genres, poster: nil, backdrop: nil, availability: .available,
      isFavorite: isFavorite, progress: progress, addedAt: addedAt)
  }

  private func episode(season: Int, number: Int) -> EpisodePresentation {
    EpisodePresentation(
      item: item(title: "S\(season)E\(number)"), seasonNumber: season, episodeNumber: number)
  }

  private func download(
    title: String, parentId: UUID?, parentTitle: String?, episode: Int, downloadedAt: Date
  ) -> OfflineTitle {
    var result = OfflineTitle(
      id: UUID(), serverId: UUID(), userId: UUID(), title: title, subtitle: nil, kind: "episode",
      fileName: "title.mkv", contentType: "video/x-matroska", bytes: 4,
      downloadedAt: downloadedAt, positionMilliseconds: 0, durationMilliseconds: 0,
      isCompleted: false, progressSavedAt: nil, progressDirty: false, subtitles: [])
    result.parentId = parentId
    result.parentTitle = parentTitle
    result.seasonNumber = 1
    result.episodeNumber = episode
    return result
  }

  @Test
  func seriesPlayStartsWithTheFirstRegularEpisodeNotSpecials() {
    let episodes = [
      episode(season: 0, number: 1), episode(season: 1, number: 1), episode(season: 1, number: 2),
    ]
    #expect(DetailPlaybackPresentation.firstEpisode(episodes)?.seasonNumber == 1)
    #expect(DetailPlaybackPresentation.firstEpisode(episodes)?.episodeNumber == 1)
  }

  @Test
  func seriesWithOnlySpecialsStillPlaysTheFirstSpecial() {
    let specials = [episode(season: 0, number: 1), episode(season: 0, number: 2)]
    #expect(DetailPlaybackPresentation.firstEpisode(specials)?.episodeNumber == 1)
    #expect(DetailPlaybackPresentation.firstEpisode([]) == nil)
  }

  @Test
  func resumeShowsTheTimeLeft() {
    let id = UUID()
    let started = item(
      kind: .movie,
      progress: PlaybackProgressResponse(
        mediaId: id, positionMilliseconds: 600_000, durationMilliseconds: 2_000_000,
        isCompleted: false, lastPlayedAt: nil, updatedAt: nil))
    #expect(DetailPlaybackPresentation.remainingText(for: started) == "23 min left")

    let finished = item(
      kind: .movie,
      progress: PlaybackProgressResponse(
        mediaId: id, positionMilliseconds: 2_000_000, durationMilliseconds: 2_000_000,
        isCompleted: true, lastPlayedAt: nil, updatedAt: nil))
    #expect(DetailPlaybackPresentation.remainingText(for: finished) == nil)
    #expect(DetailPlaybackPresentation.remainingText(for: item(kind: .movie)) == nil)
  }

  @Test
  func downloadsGroupEpisodesBySeriesIdNotName() {
    let now = Date()
    let first = UUID()
    let second = UUID()
    let groups = OfflineTitlePresentation.seriesGroups([
      download(
        title: "A1", parentId: first, parentTitle: "Same Name", episode: 2, downloadedAt: now),
      download(
        title: "A2", parentId: first, parentTitle: "Same Name", episode: 1,
        downloadedAt: now.addingTimeInterval(-60)),
      download(
        title: "B1", parentId: second, parentTitle: "Same Name", episode: 1,
        downloadedAt: now.addingTimeInterval(-120)),
    ])
    #expect(groups.count == 2)
    #expect(groups.first?.id == "id:\(first.uuidString)")
    #expect(groups.first?.episodes.map(\.title) == ["A2", "A1"])
    #expect(groups.last?.episodes.map(\.title) == ["B1"])
  }

  @Test
  func downloadsWithoutSeriesIdFallBackToTheSeriesName() {
    let now = Date()
    let groups = OfflineTitlePresentation.seriesGroups([
      download(title: "E1", parentId: nil, parentTitle: "Old Show", episode: 1, downloadedAt: now),
      download(title: "E2", parentId: nil, parentTitle: "Old Show", episode: 2, downloadedAt: now),
    ])
    #expect(groups.count == 1)
    #expect(groups.first?.name == "Old Show")
  }

  @Test
  func smartListPreviewCountsAddedWithin() {
    let now = ServerDate.parse("2026-11-15T00:00:00Z")!
    let items = [
      item(kind: .movie, title: "Recent", addedAt: "2026-11-10T00:00:00Z"),
      item(kind: .movie, title: "Old", addedAt: "2026-01-01T00:00:00Z"),
    ]
    let rules = SmartCollectionRules(addedWithinDays: 30, match: "all")
    #expect(SmartCollectionPreview.matchCount(items, rules: rules, now: now) == 1)
  }

  @Test
  func smartListPreviewCombinesRulesWithAnyOrAll() {
    let now = ServerDate.parse("2026-11-15T00:00:00Z")!
    let items = [
      item(kind: .movie, title: "Recent Drama", addedAt: "2026-11-10T00:00:00Z", genres: ["Drama"]),
      item(kind: .movie, title: "Old Drama", addedAt: "2026-01-01T00:00:00Z", genres: ["Drama"]),
      item(kind: .movie, title: "Old Comedy", addedAt: "2026-01-01T00:00:00Z", genres: ["Comedy"]),
    ]
    let all = SmartCollectionRules(genres: ["drama"], addedWithinDays: 30, match: "all")
    let any = SmartCollectionRules(genres: ["drama"], addedWithinDays: 30, match: "any")
    #expect(SmartCollectionPreview.matchCount(items, rules: all, now: now) == 1)
    #expect(SmartCollectionPreview.matchCount(items, rules: any, now: now) == 2)
  }
}
