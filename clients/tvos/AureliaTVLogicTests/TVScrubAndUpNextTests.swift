import Foundation
import Testing

@Suite("TV scrub previews, resume and Up Next")
struct TVScrubAndUpNextTests {
  @Test func previewStepsCoverTheTimelineCoarseFirstAndOnlyOnce() {
    #expect(TVScrubPreviewPlan.interval(for: 45 * 60_000) == 10_000)
    #expect(TVScrubPreviewPlan.interval(for: 3 * 3_600_000) == 15_000)
    let order = TVScrubPreviewPlan.order(duration: 265_000, interval: 10_000)
    #expect(order.count == 27)
    #expect(Set(order) == Set((0..<27).map { Int64($0) * 10_000 }))
    #expect(Array(order.prefix(4)) == [0, 80_000, 160_000, 240_000])
    #expect(TVScrubPreviewPlan.order(duration: 0, interval: 10_000).isEmpty)
  }

  @Test func framesAreTakenMidStepButNotAtTheVeryEnd() {
    #expect(
      TVScrubPreviewPlan.snapshotPosition(bucket: 20_000, interval: 10_000, duration: 60_000)
        == 25_000)
    #expect(
      TVScrubPreviewPlan.snapshotPosition(
        bucket: 3_610_000, interval: 10_000, duration: 3_611_480) == 3_608_480)
  }

  @Test func aNearbyPreparedFrameStandsInUntilTheExactOneArrives() {
    let prepared: Set<Int64> = [0, 80_000]
    #expect(
      TVScrubPreviewPlan.nearest(to: 80_000, interval: 10_000) { prepared.contains($0) } == 80_000)
    #expect(
      TVScrubPreviewPlan.nearest(to: 50_000, interval: 10_000) { prepared.contains($0) } == 80_000)
    #expect(
      TVScrubPreviewPlan.nearest(to: 200_000, interval: 10_000) { prepared.contains($0) } == nil)
  }

  @Test func severalDecodersOnlyWhereTheServerKeepsPreviewsApart() {
    #expect(TVScrubPreviewPlan.workers(parallel: false, cores: 6) == 1)
    #expect(TVScrubPreviewPlan.workers(parallel: true, cores: 6) == 4)
    #expect(TVScrubPreviewPlan.workers(parallel: true, cores: 2) == 2)
    // With the scrub position's own decoder this stays within the server's 8 per device.
    #expect(TVScrubPreviewPlan.workers(parallel: true, cores: 64) + 1 <= 8)
  }

  @Test func scrubStepsGrowWhilePressesFollowQuickly() {
    #expect(TVPlayerPolicy.scrubStep(base: 10_000, repeats: 0) == 10_000)
    #expect(TVPlayerPolicy.scrubStep(base: 10_000, repeats: 5) == 30_000)
    #expect(TVPlayerPolicy.scrubStep(base: 10_000, repeats: 12) == 60_000)
  }

  @Test func resumeIsKeptWhenTheDecoderOpensThere() {
    #expect(TVPlayerPolicy.openedAtResume(clock: 600_305, resume: 600_000))
    // A container that ignores the start position starts near zero and still seeks.
    #expect(!(TVPlayerPolicy.openedAtResume(clock: 400, resume: 600_000)))
  }

  @Test func upNextAppearsInTheLastSecondsOnlyWhenTheNextEpisodeWouldStart() {
    func shows(
      position: Int64, duration: Int64 = 2_700_000, hasNext: Bool = true, autoplay: Bool = true,
      stopsAtEnd: Bool = false, dismissed: Bool = false
    ) -> Bool {
      TVPlayerPolicy.showsUpNext(
        position: position, duration: duration, hasNext: hasNext, autoplay: autoplay,
        stopsAtEnd: stopsAtEnd, dismissed: dismissed)
    }
    #expect(!(shows(position: 2_670_000)))
    #expect(shows(position: 2_685_000))
    #expect(!(shows(position: 2_685_000, hasNext: false)))
    #expect(!(shows(position: 2_685_000, autoplay: false)))
    #expect(!(shows(position: 2_685_000, stopsAtEnd: true)))
    #expect(!(shows(position: 2_685_000, dismissed: true)))
    // Trailers and extras are too short for a card.
    #expect(!(shows(position: 100_000, duration: 110_000)))
    #expect(TVPlayerPolicy.upNextSeconds(position: 2_685_000, duration: 2_700_000) == 15)
    #expect(TVPlayerPolicy.upNextSeconds(position: 2_699_500, duration: 2_700_000) == 1)
  }

  @Test func upNextAppearsWithTrustedCreditsAndCountsDownFromThere() {
    let credits = TVPlayerPolicy.credits(2_400_000, duration: 2_700_000)
    #expect(credits == 2_400_000)
    #expect(TVPlayerPolicy.credits(600_000, duration: 2_700_000) == nil)
    #expect(TVPlayerPolicy.credits(2_699_500, duration: 2_700_000) == nil)
    #expect(
      TVPlayerPolicy.showsUpNext(
        position: 2_400_000, duration: 2_700_000, hasNext: true, autoplay: true,
        stopsAtEnd: false, dismissed: false, creditsStart: 2_400_000))
    #expect(
      TVPlayerPolicy.showsForCredits(position: 2_400_500, duration: 2_700_000, creditsStart: 2_400_000))
    #expect(
      TVPlayerPolicy.upNextSeconds(position: 2_405_000, duration: 2_700_000, creditsAnchor: 2_400_000)
        == 15)
    #expect(
      TVPlayerPolicy.nextFinishesCurrent(
        position: 2_400_000, duration: 2_700_000, upNextShown: false, creditsStart: 2_400_000))
    #expect(
      !TVPlayerPolicy.nextFinishesCurrent(
        position: 1_000_000, duration: 2_700_000, upNextShown: false, creditsStart: 2_400_000))
  }

  @Test func skipIntroShowsDuringTheIntroAndSkipsAutomaticallyOnlyOnce() {
    #expect(!TVPlayerPolicy.showsSkipIntro(position: 58_999, introStart: 60_000, introEnd: 90_000))
    #expect(TVPlayerPolicy.showsSkipIntro(position: 59_000, introStart: 60_000, introEnd: 90_000))
    #expect(!TVPlayerPolicy.showsSkipIntro(position: 88_000, introStart: 60_000, introEnd: 90_000))
    #expect(
      TVPlayerPolicy.skipsIntroAutomatically(
        setting: .automatic, alreadySkipped: false, movedIntoIntro: false, buttonShown: true))
    #expect(
      !TVPlayerPolicy.skipsIntroAutomatically(
        setting: .button, alreadySkipped: false, movedIntoIntro: false, buttonShown: true))
    #expect(
      !TVPlayerPolicy.skipsIntroAutomatically(
        setting: .automatic, alreadySkipped: false, movedIntoIntro: true, buttonShown: true))
    #expect(TVMediaSegments(introStartMilliseconds: 90_000, introEndMilliseconds: 60_000).intro == nil)
  }

  @Test func introAndCreditsChoicesDecodeWithDefaultsFromOlderSettings() throws {
    let old = try JSONDecoder().decode(TVPlaybackPreferences.self, from: Data("{}".utf8))
    #expect(old.introSkipping == .button)
    #expect(old.upNextAtCredits)
    var changed = TVPlaybackPreferences()
    changed.introSkipping = .automatic
    changed.upNextAtCredits = false
    let round = try JSONDecoder().decode(
      TVPlaybackPreferences.self, from: JSONEncoder().encode(changed))
    #expect(round.introSkipping == .automatic)
    #expect(!round.upNextAtCredits)
    let ticket = try JSONDecoder().decode(
      TVPlaybackTicket.self,
      from: Data(
        """
        {"id":"00000000-0000-0000-0000-000000000001","mediaId":"00000000-0000-0000-0000-000000000002",
        "streamPath":"/s","contentType":"video/mp4","contentLength":1,"expiresAt":"x",
        "progress":{"mediaId":"00000000-0000-0000-0000-000000000002","positionMilliseconds":0,
        "durationMilliseconds":1,"isCompleted":false,"revision":1},
        "segments":{"introStartMilliseconds":1000,"introEndMilliseconds":2000,"creditsStartMilliseconds":null}}
        """.utf8))
    #expect(ticket.segments?.intro?.end == 2_000)
  }
}

@Suite("TV cinema mode")
struct TVCinemaTests {
  private func item(_ id: UUID, parent: UUID? = nil, kind: TVMediaKind = .trailer) throws
    -> TVCatalogItem
  {
    let json = """
      {"id":"\(id)","kind":"\(kind.rawValue)","title":"Synthetic","originalTitle":null,"year":2024,
      "overview":null,"genres":[],"poster":null,"backdrop":null,"availability":"available",
      "isFavorite":false,"progress":null,"addedAt":"2026-01-01T00:00:00Z","parentTitle":null,
      "seasonNumber":null,"episodeNumber":null,"parentId":\(parent.map { "\"\($0)\"" } ?? "null"),
      "watchState":null,"libraryAvailability":null}
      """
    return try JSONDecoder().decode(TVCatalogItem.self, from: Data(json.utf8))
  }

  @Test func onlyFilmsWithCinemaModeAndATrailerServerGetAPreShow() {
    var preferences = TVPlaybackPreferences()
    #expect(
      !TVCinemaPlan.wanted(
        preferences: preferences, isEpisode: false, capabilities: [TVCinemaPlan.feature],
        watchingTogether: false))
    preferences.cinemaMode = true
    #expect(
      TVCinemaPlan.wanted(
        preferences: preferences, isEpisode: false, capabilities: [TVCinemaPlan.feature],
        watchingTogether: false))
    #expect(
      !TVCinemaPlan.wanted(
        preferences: preferences, isEpisode: true, capabilities: [TVCinemaPlan.feature],
        watchingTogether: false))
    #expect(
      !TVCinemaPlan.wanted(
        preferences: preferences, isEpisode: false, capabilities: [], watchingTogether: false))
    #expect(
      !TVCinemaPlan.wanted(
        preferences: preferences, isEpisode: false, capabilities: [TVCinemaPlan.feature],
        watchingTogether: true))
    preferences.cinemaAds = false
    preferences.cinemaTrailers = 0
    #expect(
      !TVCinemaPlan.wanted(
        preferences: preferences, isEpisode: false, capabilities: [TVCinemaPlan.feature],
        watchingTogether: false))
  }

  @Test func aFilmPickedUpInTheMiddleGetsNoPreShow() throws {
    let progress = try JSONDecoder().decode(
      TVPlaybackProgress.self,
      from: Data(
        """
        {"mediaId":"00000000-0000-0000-0000-000000000002","positionMilliseconds":600000,
        "durationMilliseconds":6000000,"isCompleted":false,"revision":1}
        """.utf8))
    #expect(
      !TVCinemaPlan.startsAtBeginning(startOver: false, progress: progress, automaticResume: true))
    #expect(
      TVCinemaPlan.startsAtBeginning(startOver: true, progress: progress, automaticResume: true))
    #expect(
      TVCinemaPlan.startsAtBeginning(startOver: false, progress: progress, automaticResume: false))
    #expect(TVCinemaPlan.startsAtBeginning(startOver: false, progress: nil, automaticResume: true))
  }

  @Test func actsLeaveOutTheFilmsOwnTrailerAndEndWithTheCurtain() throws {
    let film = UUID()
    let other = UUID()
    let own = TVCinemaTrailer(
      trailer: try item(UUID(), parent: film), title: try item(film, kind: .movie))
    let foreign = TVCinemaTrailer(
      trailer: try item(UUID(), parent: other), title: try item(other, kind: .movie))
    let acts = TVCinemaPlan.acts(ad: .popcorn, trailers: [own, foreign], film: film, title: "Film")
    #expect(acts == [.ad(.popcorn), .trailer(foreign), .feature(title: "Film")])
    #expect(TVCinemaPlan.acts(ad: nil, trailers: [own], film: film, title: "Film").isEmpty)
    #expect(TVCinemaPlan.ad(after: nil) == .iceCream)
    #expect(TVCinemaPlan.ad(after: "phones") == .iceCream)
    #expect(TVCinemaPlan.ad(after: "iceCream") == .popcorn)
  }

  @Test func cinemaChoicesDecodeWithDefaults() throws {
    let old = try JSONDecoder().decode(TVPlaybackPreferences.self, from: Data("{}".utf8))
    #expect(!old.cinemaMode)
    #expect(old.cinemaAds)
    #expect(old.cinemaTrailers == 2)
    var odd = TVPlaybackPreferences()
    odd.cinemaTrailers = 9
    #expect(odd.normalized.cinemaTrailers == 3)
  }
}
