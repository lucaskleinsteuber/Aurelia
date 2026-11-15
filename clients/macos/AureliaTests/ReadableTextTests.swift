import Foundation
import Testing

@testable import Aurelia

/// Words the app shows instead of raw server codes, player track tags and kind names.
@MainActor
struct ReadableTextTests {
  @Test func kindsReadAsPeopleSayThem() {
    #expect(MediaKind.movie.displayName == "Movie")
    #expect(MediaKind.series.displayName == "TV Show")
    #expect(MediaKind.episode.displayName == "Episode")
    #expect(MediaKind.extra.displayName == "Extra")
    #expect(MediaKind.trailer.displayName == "Trailer")
  }

  @Test func episodeCardsNameShowSeasonAndEpisode() {
    #expect(
      CatalogPlaybackLogic.episodeEyebrow(
        for: item(.episode, parent: "Test Show", season: 4, episode: 3)) == "Test Show · S4 · E3")
    #expect(
      CatalogPlaybackLogic.episodeEyebrow(
        for: item(.episode, parent: "Test Show", season: 0, episode: 2)) == "Test Show · Special · E2")
    #expect(
      CatalogPlaybackLogic.episodeEyebrow(for: item(.episode, parent: nil, season: 2, episode: nil))
        == "S2")
    #expect(CatalogPlaybackLogic.episodeEyebrow(for: item(.episode, parent: "", season: nil, episode: nil)) == nil)
    #expect(CatalogPlaybackLogic.episodeEyebrow(for: item(.movie, parent: "Test Show", season: 1, episode: 1)) == nil)
  }

  @Test func serverIssuesReadAsSentences() {
    #expect(ServerIssueText.title(for: "metadata_authentication_failed") == "TMDB refused the token")
    #expect(
      ServerIssueText.title(for: "rate_limited")
        == ServerIssueText.title(for: "request_rate_limited"))
    #expect(ServerIssueText.title(for: "some_new_code") == "Some new code")
  }

  @Test func serverStatesReadAsWords() {
    #expect(ReadableState.text("waitingForStorage") == "Waiting for storage")
    #expect(ReadableState.text("scan_failed") == "Scan failed")
    #expect(ReadableState.text("running") == "Running")
    #expect(ReadableState.text("") == "")
  }

  @Test func playerTracksDropVLCNumbering() {
    #expect(PlaybackTrackNames.plain("Track 1 - [English]") == "English")
    #expect(PlaybackTrackNames.plain("Commentary - [English]") == "Commentary (English)")
    #expect(PlaybackTrackNames.plain("English SDH - [English]") == "English SDH")
    #expect(PlaybackTrackNames.plain("Disable") == "Disable")
    #expect(PlaybackTrackNames.plain("  ") == "  ")
  }

  @Test func sameNamedTracksAreNumbered() {
    let tracks = [
      PlaybackTrack(id: 1, title: "Track 1 - [English]"),
      PlaybackTrack(id: 2, title: "Track 2 - [German]"),
      PlaybackTrack(id: 3, title: "Track 3 - [English]"),
    ]
    #expect(tracks.map { PlaybackTrackNames.menuTitle(for: $0, in: tracks) } == [
      "English", "German", "English (2)",
    ])
    // The saved preference still matches the original title.
    #expect(tracks[2].title == "Track 3 - [English]")
  }

  private func item(_ kind: MediaKind, parent: String?, season: Int?, episode: Int?)
    -> CatalogItemSummary
  {
    CatalogItemSummary(
      id: UUID(), kind: kind, title: "Pilot", originalTitle: nil, year: nil,
      overview: nil, genres: [], poster: nil, backdrop: nil,
      availability: .available, isFavorite: false, progress: nil,
      addedAt: "2026-09-26T00:00:00Z", parentTitle: parent, seasonNumber: season,
      episodeNumber: episode)
  }
}
