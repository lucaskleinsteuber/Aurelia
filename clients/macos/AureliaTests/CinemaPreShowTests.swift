import Foundation
import Testing

@testable import Aurelia

struct CinemaPreShowTests {
  private let film = PlaybackPresentation(mediaId: UUID(), title: "Arrival", subtitle: "2016")
  private let features: Set<String> = [ServerFeatureNames.cinemaTrailers]

  private var cinema: PlaybackPreferences {
    var preferences = PlaybackPreferences.defaultValue
    preferences.cinemaMode = true
    return preferences
  }

  private func item(_ title: String, kind: MediaKind) -> CatalogItemSummary {
    CatalogItemSummary(
      id: UUID(), kind: kind, title: title, originalTitle: nil, year: 1985, overview: nil,
      genres: [], poster: nil, backdrop: nil, availability: .available, isFavorite: false,
      progress: nil, addedAt: "2026-11-09T00:00:00Z")
  }

  private func progress(minutes: Int64, completed: Bool = false) -> PlaybackProgressResponse {
    PlaybackProgressResponse(
      mediaId: film.mediaId, positionMilliseconds: minutes * 60_000,
      durationMilliseconds: 6_960_000, isCompleted: completed, lastPlayedAt: nil, updatedAt: nil)
  }

  @Test func onlyAFilmFromTheServerWithCinemaModeOnGetsAPreShow() {
    #expect(!PlaybackPreferences.defaultValue.cinemaMode)
    #expect(
      !CinemaPreShowPlan.wanted(
        preferences: .defaultValue, presentation: film, capabilities: features,
        watchingTogether: false))
    #expect(
      CinemaPreShowPlan.wanted(
        preferences: cinema, presentation: film, capabilities: features, watchingTogether: false))

    let episode = PlaybackPresentation(
      mediaId: UUID(), title: "Pilot", subtitle: nil, trackScope: UUID())
    var download = film
    download.offlineID = film.mediaId
    var nothingToShow = cinema
    nothingToShow.cinemaAds = false
    nothingToShow.cinemaTrailers = 0
    #expect(
      !CinemaPreShowPlan.wanted(
        preferences: cinema, presentation: episode, capabilities: features,
        watchingTogether: false))
    #expect(
      !CinemaPreShowPlan.wanted(
        preferences: cinema, presentation: download, capabilities: features,
        watchingTogether: false))
    #expect(
      !CinemaPreShowPlan.wanted(
        preferences: cinema, presentation: film, capabilities: features, watchingTogether: true))
    #expect(
      !CinemaPreShowPlan.wanted(
        preferences: cinema, presentation: film, capabilities: [], watchingTogether: false))
    #expect(
      !CinemaPreShowPlan.wanted(
        preferences: nothingToShow, presentation: film, capabilities: features,
        watchingTogether: false))
  }

  @Test func aFilmPickedUpInTheMiddleStartsWithoutAPreShow() {
    var preferences = cinema
    #expect(
      !CinemaPreShowPlan.startsAtBeginning(
        intent: .resume, progress: progress(minutes: 40), preferences: preferences))
    #expect(
      CinemaPreShowPlan.startsAtBeginning(
        intent: .play, progress: progress(minutes: 40), preferences: preferences))
    #expect(
      CinemaPreShowPlan.startsAtBeginning(
        intent: .resume, progress: progress(minutes: 110, completed: true),
        preferences: preferences))
    // Barely started counts as the beginning when the player would start over anyway.
    preferences.resumeThresholdSeconds = 120
    #expect(
      CinemaPreShowPlan.startsAtBeginning(
        intent: .resume, progress: progress(minutes: 1), preferences: preferences))
    preferences.automaticResume = false
    #expect(
      CinemaPreShowPlan.startsAtBeginning(
        intent: .resume, progress: progress(minutes: 40), preferences: preferences))
  }

  @Test func theAdComesFirstThenTrailersThenTheCurtain() {
    let trailers = ["Heat", "Brazil"].map {
      CinemaTrailer(trailer: item("Trailer", kind: .trailer), title: item($0, kind: .movie))
    }
    #expect(
      CinemaPreShowPlan.acts(ad: .popcorn, trailers: trailers, film: film.mediaId, title: "Arrival")
        == [
          .ad(.popcorn), .trailer(trailers[0]), .trailer(trailers[1]), .feature(title: "Arrival"),
        ])
    #expect(
      CinemaPreShowPlan.acts(ad: nil, trailers: [trailers[0]], film: film.mediaId, title: "Arrival")
        == [.trailer(trailers[0]), .feature(title: "Arrival")])
    // Without an ad or a trailer there is no curtain on its own either.
    #expect(
      CinemaPreShowPlan.acts(ad: nil, trailers: [], film: film.mediaId, title: "Arrival").isEmpty)
  }

  @Test func theFilmsOwnTrailerNeverRunsBeforeIt() {
    let own = CinemaTrailer(
      trailer: item("Trailer", kind: .trailer),
      title: CatalogItemSummary(
        id: film.mediaId, kind: .movie, title: "Arrival", originalTitle: nil, year: 2016,
        overview: nil, genres: [], poster: nil, backdrop: nil, availability: .available,
        isFavorite: false, progress: nil, addedAt: "2026-11-09T00:00:00Z"))
    var teaser = item("Teaser", kind: .trailer)
    teaser.parentId = film.mediaId
    let fromElsewhere = CinemaTrailer(trailer: teaser, title: item("Heat", kind: .movie))
    let other = CinemaTrailer(trailer: item("Trailer", kind: .trailer), title: item("Heat", kind: .movie))
    #expect(
      CinemaPreShowPlan.acts(
        ad: nil, trailers: [own, fromElsewhere, other], film: film.mediaId, title: "Arrival")
        == [.trailer(other), .feature(title: "Arrival")])
    #expect(
      CinemaPreShowPlan.acts(ad: nil, trailers: [own], film: film.mediaId, title: "Arrival")
        .isEmpty)
  }

  @Test func theAdsTakeTurns() {
    var last: String?
    var seen: [CinemaAd] = []
    for _ in 0..<(CinemaAd.allCases.count * 2) {
      let ad = CinemaPreShowPlan.ad(after: last)
      #expect(ad.rawValue != last)
      seen.append(ad)
      last = ad.rawValue
    }
    #expect(Set(seen) == Set(CinemaAd.allCases))
    #expect(CinemaPreShowPlan.ad(after: "something old") == CinemaAd.allCases[0])
  }

  @Test func settingsSavedBeforeCinemaModeKeepItOff() throws {
    var older = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(PlaybackPreferences.defaultValue)) as! [String: Any]
    for key in ["cinemaMode", "cinemaAds", "cinemaTrailers"] { older[key] = nil }
    let decoded = try JSONDecoder().decode(
      PlaybackPreferences.self, from: JSONSerialization.data(withJSONObject: older))
    #expect(!decoded.cinemaMode && decoded.cinemaAds && decoded.cinemaTrailers == 2)

    var saved = cinema
    saved.cinemaAds = false
    saved.cinemaTrailers = 3
    let again = try JSONDecoder().decode(
      PlaybackPreferences.self, from: JSONEncoder().encode(saved))
    #expect(again == saved)
    saved.cinemaTrailers = 9
    #expect(saved.normalized.cinemaTrailers == 3)
  }

  @Test func theServersTrailersDecode() throws {
    let film = UUID()
    let json = """
      {"trailers":[{"trailer":{"id":"\(UUID().uuidString)","kind":"trailer","title":"Trailer",
      "genres":[],"availability":"available","isFavorite":false,"addedAt":"2026-11-09T00:00:00Z",
      "parentId":"\(film.uuidString)"},
      "title":{"id":"\(film.uuidString)","kind":"movie","title":"Brazil","year":1985,
      "genres":[],"availability":"available","isFavorite":false,"addedAt":"2026-11-09T00:00:00Z"}}]}
      """
    let response = try JSONDecoder().decode(CinemaTrailersResponse.self, from: Data(json.utf8))
    let trailer = try #require(response.trailers.first)
    #expect(trailer.title.title == "Brazil" && trailer.trailer.kind == .trailer)
  }

  @Test func theTunesFitTheirPicturesAndStayBelowClipping() {
    for ad in CinemaAd.allCases {
      let notes = CinemaTunes.notes(for: ad)
      #expect(!notes.isEmpty)
      #expect(notes.allSatisfy { $0.time >= 0 && $0.time + $0.length <= CinemaAd.duration })
      let samples = CinemaSynth.samples(notes)
      let peak = samples.map(abs).max() ?? 0
      #expect(peak > 0.05 && peak <= 0.9 + 1e-6, "\(ad)")
      #expect(Double(samples.count) / CinemaSynth.sampleRate <= CinemaAd.duration + 1.5)
    }
    // The call ends before the curtain can open; the answer before the curtain is gone.
    #expect(
      CinemaTunes.fanfareCall.allSatisfy {
        $0.time + $0.length <= CinemaPreShowPlan.curtainEarliestOpening
      })
    #expect(
      CinemaTunes.fanfareAnswer.allSatisfy {
        $0.time + $0.length <= CinemaPreShowPlan.curtainOpeningSeconds - 0.5
      })
    #expect(
      CinemaSynth.samples(CinemaTunes.fanfareCall) == CinemaSynth.samples(CinemaTunes.fanfareCall))
    #expect(
      CinemaPopcorn.kernels.count > 20
        && CinemaPopcorn.kernels.allSatisfy { $0.launch >= 1.6 && $0.launch < 10 })
    #expect(
      CinemaPhones.notifications.allSatisfy { $0.time + 0.8 <= CinemaPhones.silence })
  }

  @Test func theCurtainStaysClosedUntilTheFilmIsPlayingBehindIt() {
    let waiting = CinemaCurtainTiming(opensAt: nil)
    for time in [0.0, 3.3, 8, 30] {
      #expect(waiting.open(time) == (0, 0) || waiting.open(time).top == 0)
      #expect(waiting.revealed(time) == 0 && waiting.gone(time) == 0)
    }
    #expect(waiting.spot(2) == 1)

    let playing = CinemaCurtainTiming(opensAt: 5)
    #expect(playing.open(4.9).top == 0 && playing.revealed(5) == 0)
    #expect(playing.open(8).top == 1 && playing.open(9).hem == 1)
    #expect(playing.revealed(7) == 1 && playing.spot(7) == 0 && playing.dimmed(7) == 0)
    // The house lights stay down while the film plays.
    #expect(playing.lightsDown(7) == 1)
    #expect(playing.gone(5 + CinemaPreShowPlan.curtainOpeningSeconds) == 1)
    #expect(abs(playing.sway(5.1)) < 1e-9 && abs(playing.sway(12)) < 0.002)
  }
}
