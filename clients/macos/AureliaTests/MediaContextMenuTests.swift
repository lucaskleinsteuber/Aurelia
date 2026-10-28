import Foundation
import Testing

@testable import Aurelia

@MainActor
struct MediaContextMenuTests {
  @Test func episodesNavigateToTheSeriesAndNeverToTheirOwnIdentity() {
    let parent = UUID()
    let episode = item(kind: .episode, parent: parent)
    #expect(MediaContextMenuPolicy.seriesID(episode) == parent)
    #expect(MediaContextMenuPolicy.seriesID(item(kind: .movie, parent: parent)) == nil)
    #expect(MediaContextMenuPolicy.seriesID(item(kind: .episode)) == nil)
  }

  @Test func resumeRequiresProgressAndCompletedTitlesKeepPlayAvailable() {
    #expect(!MediaContextMenuPolicy.canResume(item(kind: .movie)))
    #expect(MediaContextMenuPolicy.canResume(item(kind: .episode, position: 10_000)))
    #expect(
      !MediaContextMenuPolicy.canResume(item(kind: .movie, position: 10_000, completed: true)))
    #expect(MediaContextMenuPolicy.canResume(item(kind: .series, state: .inProgress)))
  }

  @Test(arguments: [MediaKind.movie, .series, .episode, .extra, .trailer])
  func favoritesOnlyUseServerSupportedIdentities(kind: MediaKind) {
    #expect(
      MediaContextMenuPolicy.canFavorite(item(kind: kind)) == (kind == .movie || kind == .series))
  }

  private func item(
    kind: MediaKind, parent: UUID? = nil, position: Int64 = 0, completed: Bool = false,
    state: CatalogWatchState? = nil
  ) -> CatalogItemSummary {
    let id = UUID()
    return CatalogItemSummary(
      id: id, kind: kind, title: "Invented Title", originalTitle: nil, year: nil, overview: nil,
      genres: [], poster: nil, backdrop: nil, availability: .available, isFavorite: false,
      progress: position == 0
        ? nil
        : PlaybackProgressResponse(
          mediaId: id, positionMilliseconds: position, durationMilliseconds: 100_000,
          isCompleted: completed, lastPlayedAt: nil, updatedAt: nil),
      addedAt: "", watchState: state, parentId: parent)
  }
}
