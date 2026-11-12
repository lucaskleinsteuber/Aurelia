import Foundation
import Testing

@Suite("iOS scrub previews, resume and Up Next")
struct IOSScrubAndUpNextTests {
  @Test func suggestionsFollowAMovieOrALastEpisodeWithoutACountdown() throws {
    let duration: Int64 = 6_000_000
    #expect(!IOSPlayerPolicy.wantsSuggestions(position: 2_000_000, duration: duration, hasNext: false))
    #expect(IOSPlayerPolicy.wantsSuggestions(position: 3_000_000, duration: duration, hasNext: false))
    #expect(!IOSPlayerPolicy.wantsSuggestions(position: 5_000_000, duration: duration, hasNext: true))
    #expect(
      IOSPlayerPolicy.showsSuggestion(
        position: 5_500_000, duration: duration, hasNext: false, hasSuggestion: true,
        dismissed: false, creditsStart: 5_400_000))
    #expect(
      !IOSPlayerPolicy.showsSuggestion(
        position: 5_300_000, duration: duration, hasNext: false, hasSuggestion: true,
        dismissed: false, creditsStart: 5_400_000))
    #expect(
      IOSPlayerPolicy.showsSuggestion(
        position: 5_985_000, duration: duration, hasNext: false, hasSuggestion: true,
        dismissed: false, creditsStart: nil))
    #expect(
      !IOSPlayerPolicy.showsSuggestion(
        position: 5_500_000, duration: duration, hasNext: false, hasSuggestion: true,
        dismissed: true, creditsStart: 5_400_000))
    let json = Data(
      """
      {"recommendation":null,"continueWatching":[],"recentlyAdded":[],"favorites":[],
      "collections":[],"recommendationChangesAt":"2026-11-12T12:00:00Z","becauseYouWatched":[
      {"sourceId":"10000000-0000-0000-0000-000000000001","sourceTitle":"Toy Tale","suggestions":[
      {"kind":"nextPart","reason":"Next in Toy Tale Collection","item":{
      "id":"10000000-0000-0000-0000-000000000002","kind":"movie","title":"Toy Tale 2","year":1999,
      "genres":[],"availability":"available","isFavorite":false,"addedAt":"2026-11-12T10:00:00Z"}}]}]}
      """.utf8)
    let home = try JSONDecoder().decode(IOSHome.self, from: json)
    let suggestion = try #require(home.becauseYouWatched?.first?.suggestions.first)
    #expect(IOSPlayerPolicy.suggestionCaption(suggestion) == "Next in Toy Tale Collection · 1999")
    #expect(!IOSPlaybackPreferences().playSuggestionsAutomatically)
  }

  @Test func previewStepsCoverTheTimelineCoarseFirstAndOnlyOnce() {
    #expect(IOSScrubPreviewPlan.interval(for: 45 * 60_000) == 10_000)
    #expect(IOSScrubPreviewPlan.interval(for: 3 * 3_600_000) == 15_000)
    let order = IOSScrubPreviewPlan.order(duration: 265_000, interval: 10_000)
    #expect(order.count == 27)
    #expect(Set(order) == Set((0..<27).map { Int64($0) * 10_000 }))
    #expect(Array(order.prefix(4)) == [0, 80_000, 160_000, 240_000])
    #expect(IOSScrubPreviewPlan.order(duration: 0, interval: 10_000).isEmpty)
  }

  @Test func framesAreTakenMidStepButNotAtTheVeryEnd() {
    #expect(
      IOSScrubPreviewPlan.snapshotPosition(bucket: 20_000, interval: 10_000, duration: 60_000)
        == 25_000)
    #expect(
      IOSScrubPreviewPlan.snapshotPosition(
        bucket: 3_610_000, interval: 10_000, duration: 3_611_480) == 3_608_480)
  }

  @Test func aNearbyPreparedFrameStandsInUntilTheExactOneArrives() {
    let prepared: Set<Int64> = [0, 80_000]
    #expect(
      IOSScrubPreviewPlan.nearest(to: 80_000, interval: 10_000) { prepared.contains($0) } == 80_000)
    #expect(
      IOSScrubPreviewPlan.nearest(to: 50_000, interval: 10_000) { prepared.contains($0) } == 80_000)
    #expect(
      IOSScrubPreviewPlan.nearest(to: 200_000, interval: 10_000) { prepared.contains($0) } == nil)
  }

  @Test func severalDecodersOnlyWhereTheServerKeepsPreviewsApart() {
    #expect(IOSScrubPreviewPlan.workers(parallel: false, cores: 6) == 1)
    #expect(IOSScrubPreviewPlan.workers(parallel: true, cores: 6) == 4)
    #expect(IOSScrubPreviewPlan.workers(parallel: true, cores: 2) == 2)
    // With the scrub position's own decoder this stays within the server's 8 per device.
    #expect(IOSScrubPreviewPlan.workers(parallel: true, cores: 64) + 1 <= 8)
  }

  @Test func scrubStepsGrowWhilePressesFollowQuickly() {
    #expect(IOSPlayerPolicy.scrubStep(base: 10_000, repeats: 0) == 10_000)
    #expect(IOSPlayerPolicy.scrubStep(base: 10_000, repeats: 5) == 30_000)
    #expect(IOSPlayerPolicy.scrubStep(base: 10_000, repeats: 12) == 60_000)
  }

  @Test func resumeIsKeptWhenTheDecoderOpensThere() {
    #expect(IOSPlayerPolicy.openedAtResume(clock: 600_305, resume: 600_000))
    // A container that ignores the start position starts near zero and still seeks.
    #expect(!(IOSPlayerPolicy.openedAtResume(clock: 400, resume: 600_000)))
  }

  @Test func upNextAppearsInTheLastSecondsOnlyWhenTheNextEpisodeWouldStart() {
    func shows(
      position: Int64, duration: Int64 = 2_700_000, hasNext: Bool = true, autoplay: Bool = true,
      stopsAtEnd: Bool = false, dismissed: Bool = false
    ) -> Bool {
      IOSPlayerPolicy.showsUpNext(
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
    #expect(IOSPlayerPolicy.upNextSeconds(position: 2_685_000, duration: 2_700_000) == 15)
    #expect(IOSPlayerPolicy.upNextSeconds(position: 2_699_500, duration: 2_700_000) == 1)
  }

  @Test func upNextAppearsWithTrustedCreditsAndCountsDownFromThere() {
    let credits = IOSPlayerPolicy.credits(2_400_000, duration: 2_700_000)
    #expect(credits == 2_400_000)
    #expect(IOSPlayerPolicy.credits(600_000, duration: 2_700_000) == nil)
    #expect(IOSPlayerPolicy.credits(2_699_500, duration: 2_700_000) == nil)
    #expect(
      IOSPlayerPolicy.showsUpNext(
        position: 2_400_000, duration: 2_700_000, hasNext: true, autoplay: true,
        stopsAtEnd: false, dismissed: false, creditsStart: 2_400_000))
    #expect(
      IOSPlayerPolicy.showsForCredits(position: 2_400_500, duration: 2_700_000, creditsStart: 2_400_000))
    #expect(
      IOSPlayerPolicy.upNextSeconds(position: 2_405_000, duration: 2_700_000, creditsAnchor: 2_400_000)
        == 15)
    #expect(
      IOSPlayerPolicy.nextFinishesCurrent(
        position: 2_400_000, duration: 2_700_000, upNextShown: false, creditsStart: 2_400_000))
    #expect(
      !IOSPlayerPolicy.nextFinishesCurrent(
        position: 1_000_000, duration: 2_700_000, upNextShown: false, creditsStart: 2_400_000))
  }

  @Test func skipIntroShowsDuringTheIntroAndSkipsAutomaticallyOnlyOnce() {
    #expect(!IOSPlayerPolicy.showsSkipIntro(position: 58_999, introStart: 60_000, introEnd: 90_000))
    #expect(IOSPlayerPolicy.showsSkipIntro(position: 59_000, introStart: 60_000, introEnd: 90_000))
    #expect(!IOSPlayerPolicy.showsSkipIntro(position: 88_000, introStart: 60_000, introEnd: 90_000))
    #expect(
      IOSPlayerPolicy.skipsIntroAutomatically(
        setting: .automatic, alreadySkipped: false, movedIntoIntro: false, buttonShown: true))
    #expect(
      !IOSPlayerPolicy.skipsIntroAutomatically(
        setting: .button, alreadySkipped: false, movedIntoIntro: false, buttonShown: true))
    #expect(
      !IOSPlayerPolicy.skipsIntroAutomatically(
        setting: .automatic, alreadySkipped: false, movedIntoIntro: true, buttonShown: true))
    #expect(IOSMediaSegments(introStartMilliseconds: 90_000, introEndMilliseconds: 60_000).intro == nil)
  }

  @Test func introAndCreditsChoicesDecodeWithDefaultsFromOlderSettings() throws {
    let old = try JSONDecoder().decode(IOSPlaybackPreferences.self, from: Data("{}".utf8))
    #expect(old.introSkipping == .button)
    #expect(old.upNextAtCredits)
    var changed = IOSPlaybackPreferences()
    changed.introSkipping = .automatic
    changed.upNextAtCredits = false
    let round = try JSONDecoder().decode(
      IOSPlaybackPreferences.self, from: JSONEncoder().encode(changed))
    #expect(round.introSkipping == .automatic)
    #expect(!round.upNextAtCredits)
    let ticket = try JSONDecoder().decode(
      IOSPlaybackTicket.self,
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

@Suite("iOS cinema mode")
struct IOSCinemaTests {
  private func item(_ id: UUID, parent: UUID? = nil, kind: IOSMediaKind = .trailer) throws
    -> IOSCatalogItem
  {
    let json = """
      {"id":"\(id)","kind":"\(kind.rawValue)","title":"Synthetic","originalTitle":null,"year":2024,
      "overview":null,"genres":[],"poster":null,"backdrop":null,"availability":"available",
      "isFavorite":false,"progress":null,"addedAt":"2026-01-01T00:00:00Z","parentTitle":null,
      "seasonNumber":null,"episodeNumber":null,"parentId":\(parent.map { "\"\($0)\"" } ?? "null"),
      "watchState":null,"libraryAvailability":null}
      """
    return try JSONDecoder().decode(IOSCatalogItem.self, from: Data(json.utf8))
  }

  @Test func onlyFilmsWithCinemaModeAndATrailerServerGetAPreShow() {
    var preferences = IOSPlaybackPreferences()
    #expect(
      !IOSCinemaPlan.wanted(
        preferences: preferences, isEpisode: false, capabilities: [IOSCinemaPlan.feature],
        watchingTogether: false))
    preferences.cinemaMode = true
    #expect(
      IOSCinemaPlan.wanted(
        preferences: preferences, isEpisode: false, capabilities: [IOSCinemaPlan.feature],
        watchingTogether: false))
    #expect(
      !IOSCinemaPlan.wanted(
        preferences: preferences, isEpisode: true, capabilities: [IOSCinemaPlan.feature],
        watchingTogether: false))
    #expect(
      !IOSCinemaPlan.wanted(
        preferences: preferences, isEpisode: false, capabilities: [], watchingTogether: false))
    #expect(
      !IOSCinemaPlan.wanted(
        preferences: preferences, isEpisode: false, capabilities: [IOSCinemaPlan.feature],
        watchingTogether: true))
    preferences.cinemaAds = false
    preferences.cinemaTrailers = 0
    #expect(
      !IOSCinemaPlan.wanted(
        preferences: preferences, isEpisode: false, capabilities: [IOSCinemaPlan.feature],
        watchingTogether: false))
  }

  @Test func aFilmPickedUpInTheMiddleGetsNoPreShow() throws {
    let progress = try JSONDecoder().decode(
      IOSPlaybackProgress.self,
      from: Data(
        """
        {"mediaId":"00000000-0000-0000-0000-000000000002","positionMilliseconds":600000,
        "durationMilliseconds":6000000,"isCompleted":false,"revision":1}
        """.utf8))
    #expect(
      !IOSCinemaPlan.startsAtBeginning(startOver: false, progress: progress, automaticResume: true))
    #expect(
      IOSCinemaPlan.startsAtBeginning(startOver: true, progress: progress, automaticResume: true))
    #expect(
      IOSCinemaPlan.startsAtBeginning(startOver: false, progress: progress, automaticResume: false))
    #expect(IOSCinemaPlan.startsAtBeginning(startOver: false, progress: nil, automaticResume: true))
  }

  @Test func actsLeaveOutTheFilmsOwnTrailerAndEndWithTheCurtain() throws {
    let film = UUID()
    let other = UUID()
    let own = IOSCinemaTrailer(
      trailer: try item(UUID(), parent: film), title: try item(film, kind: .movie))
    let foreign = IOSCinemaTrailer(
      trailer: try item(UUID(), parent: other), title: try item(other, kind: .movie))
    let acts = IOSCinemaPlan.acts(ad: .popcorn, trailers: [own, foreign], film: film, title: "Film")
    #expect(acts == [.ad(.popcorn), .trailer(foreign), .feature(title: "Film")])
    #expect(IOSCinemaPlan.acts(ad: nil, trailers: [own], film: film, title: "Film").isEmpty)
    #expect(IOSCinemaPlan.ad(after: nil) == .iceCream)
    #expect(IOSCinemaPlan.ad(after: "phones") == .iceCream)
    #expect(IOSCinemaPlan.ad(after: "iceCream") == .popcorn)
  }

  @Test func cinemaChoicesDecodeWithDefaults() throws {
    let old = try JSONDecoder().decode(IOSPlaybackPreferences.self, from: Data("{}".utf8))
    #expect(!old.cinemaMode)
    #expect(old.cinemaAds)
    #expect(old.cinemaTrailers == 2)
    var odd = IOSPlaybackPreferences()
    odd.cinemaTrailers = 9
    #expect(odd.normalized.cinemaTrailers == 3)
  }
}
