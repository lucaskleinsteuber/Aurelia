import Foundation
import Testing

@testable import Aurelia

/// The offline mode's profile check and library layout, with invented profiles and titles.
struct OfflineModeTests {
  private let server = UUID()

  private func profile(pin: Bool) -> WatchingProfile {
    WatchingProfile(
      id: UUID(), name: "Invented Viewer", role: .user, needsPinSetup: false,
      pinProtectionEnabled: pin)
  }

  @Test
  func aCardOpensOnlyWithItsPinAndKeepsNoPin() throws {
    let card = try #require(OfflineProfileCard.make(serverId: server, profile: profile(pin: true), pin: "2468"))
    #expect(card.accepts("2468"))
    #expect(!card.accepts("2469"))
    #expect(!card.accepts(""))
    #expect(!card.accepts("24680000x"))
    let stored = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
    #expect(!stored.contains("2468"))
  }

  @Test
  func aProfileWithoutPinOpensWithoutOne() throws {
    let card = try #require(OfflineProfileCard.make(serverId: server, profile: profile(pin: false), pin: ""))
    #expect(card.accepts(""))
    #expect(card.check == nil)
  }

  @Test
  func cardsStayWithTheirServerUntilItIsForgotten() throws {
    let store = MemoryOfflineProfileStore()
    let other = UUID()
    store.remember(try #require(OfflineProfileCard.make(serverId: server, profile: profile(pin: false), pin: "")))
    store.remember(try #require(OfflineProfileCard.make(serverId: other, profile: profile(pin: false), pin: "")))
    #expect(store.cards(serverId: server).count == 1)
    store.forget(serverId: server)
    #expect(store.cards(serverId: server).isEmpty)
    #expect(store.cards(serverId: other).count == 1)
  }

  private func title(
    _ name: String, episode: (series: String, season: Int, number: Int)? = nil,
    position: Int64 = 0, savedAt: Date? = nil
  ) -> OfflineTitle {
    var title = OfflineTitle(
      id: UUID(), serverId: server, userId: UUID(), title: name,
      subtitle: episode.map { "\($0.series) · S\($0.season) E\($0.number)" }, kind: episode == nil ? "movie" : "episode",
      fileName: "title.mkv", contentType: "video/x-matroska", bytes: 1, downloadedAt: Date(),
      positionMilliseconds: position, durationMilliseconds: 1_000_000, isCompleted: false,
      progressSavedAt: savedAt, progressDirty: false, subtitles: [])
    title.seasonNumber = episode?.season
    title.episodeNumber = episode?.number
    return title
  }

  @Test
  func theLibraryGroupsEpisodesBySeriesInOrderAndFeaturesTheLastStarted() {
    let later = title("Pilot", episode: ("Invented Show", 1, 1), position: 5000, savedAt: Date())
    let titles = [
      title("Second", episode: ("Invented Show", 1, 2)),
      later,
      title("Invented Film", position: 1000, savedAt: Date().addingTimeInterval(-60)),
      title("Another Film"),
    ]
    let layout = OfflineLibraryLayout(titles)
    #expect(layout.featured?.id == later.id)
    #expect(layout.continueWatching.count == 2)
    #expect(layout.movies.map(\.title) == ["Another Film", "Invented Film"])
    #expect(layout.series.count == 1)
    #expect(layout.series[0].title == "Invented Show")
    #expect(layout.series[0].episodes.map(\.title) == ["Pilot", "Second"])
  }

  @Test
  func downloadsFromBeforeArtworkWasKeptStillLoad() throws {
    let old = """
      [{"id":"\(UUID().uuidString)","serverId":"\(server.uuidString)","userId":"\(UUID().uuidString)",
      "title":"Invented Film","kind":"movie","fileName":"title.mkv","contentType":"video/mp4",
      "bytes":1,"downloadedAt":0,"positionMilliseconds":0,"durationMilliseconds":0,
      "isCompleted":false,"progressDirty":false,"subtitles":[]}]
      """
    let titles = try JSONDecoder().decode([OfflineTitle].self, from: Data(old.utf8))
    #expect(titles.count == 1)
    #expect(titles[0].posterFile == nil)
    #expect(!titles[0].hasArtwork)
  }
}
