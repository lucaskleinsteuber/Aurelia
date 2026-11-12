import Foundation
import Testing

/// Movie Night and Wrapped on iPhone and iPad with an invented night, year and server; nothing is played.
@Suite("iOS Movie Night and Wrapped")
@MainActor
struct IOSMovieNightTests {
  static let ids = (1...3).map { UUID(uuidString: "00000000-0000-4000-8000-0000000000a\($0)")! }
  static let deck = ids.enumerated().map { index, id in
    IOSMovieNightCard(
      mediaId: id, kind: .movie, title: "Invented Film \(index + 1)", year: 2020 + index, overview: nil,
      genres: ["Comedy", "Crime", "Drama"], runtimeMinutes: 95 + index * 25, poster: nil, backdrop: nil)
  }

  static func night(
    phase: String = "voting", revision: Int64 = 2, round: Int = 1, deck: [IOSMovieNightCard]? = deck,
    votes: [IOSMovieNightVote] = [], voting: Bool = true
  ) -> IOSMovieNightState {
    IOSMovieNightState(
      id: UUID(uuidString: "00000000-0000-4000-8000-0000000000b1")!, phase: phase, revision: revision,
      round: round, deckVersion: round, kinds: "movies", genre: nil, genreOptions: ["Comedy"],
      members: [
        IOSMovieNightMember(
          id: UUID(), name: "Invented Phone", deviceName: "iPhone", isVoting: voting, isHost: true, isYou: true,
          swiped: votes.count),
        IOSMovieNightMember(
          id: UUID(), name: "Mia", deviceName: "Browser", isVoting: true, isHost: false, isYou: false, swiped: 1),
      ],
      deck: deck, yourVotes: votes, result: nil, lastAction: nil, lastActionBy: nil)
  }

  @Test func aCardCountsOnceItTravelsFarEnoughOrIsFlicked() {
    #expect(IOSMovieNightRules.choice(offset: 120) == .like)
    #expect(IOSMovieNightRules.choice(offset: -120) == .nope)
    #expect(IOSMovieNightRules.choice(offset: 40) == nil)
    #expect(IOSMovieNightRules.choice(offset: 40, velocity: 900) == .like)
    #expect(IOSMovieNightRules.choice(offset: -40, velocity: -900) == .nope)
    #expect(IOSMovieNightRules.choice(offset: 80, width: 260) == .like)
  }

  @Test func theScreenFollowsTheNight() {
    #expect(IOSMovieNightRules.screen(nil, remaining: 0) == .intro)
    #expect(IOSMovieNightRules.screen(Self.night(phase: "lobby"), remaining: 3) == .lobby)
    #expect(IOSMovieNightRules.screen(Self.night(), remaining: 3) == .swipe)
    #expect(IOSMovieNightRules.screen(Self.night(), remaining: 0) == .waiting)
    #expect(IOSMovieNightRules.screen(Self.night(voting: false), remaining: 3) == .waiting)
    #expect(IOSMovieNightRules.screen(Self.night(phase: "match"), remaining: 1) == .match)
    #expect(IOSMovieNightRules.screen(Self.night(phase: "no-match"), remaining: 0) == .noMatch)
    #expect(IOSMovieNightRules.runtime(95) == "1h 35m")
    #expect(IOSMovieNightRules.runtime(120) == "2h")
    #expect(IOSMovieNightRules.runtime(nil) == nil)
    #expect(Self.deck[0].meta == "2020 · 1h 35m · Comedy · Crime")
    #expect(IOSMovieNightRules.slowpokes(Self.night(votes: Self.deck.map { .init(mediaId: $0.mediaId, like: true) }), deckSize: 3).map(\.name) == ["Mia"])
  }

  @Test func aSwipeCountsAtOnceAndTheDeckIsKeptBetweenPolls() async {
    let api = FakeMovieNightAPI(answers: [
      Self.night(),
      Self.night(revision: 3, deck: nil, votes: [.init(mediaId: Self.ids[0], like: true)]),
    ])
    let session = IOSMovieNightSession(api: api, deviceName: "Invented Phone")
    await session.start()
    #expect(session.screen == .swipe)
    #expect(session.remaining.count == 3)

    session.vote(Self.deck[0], like: true)
    #expect(session.remaining.map(\.mediaId) == Array(Self.ids[1...]))
    for _ in 0..<50 where session.state?.revision != 3 { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(session.state?.revision == 3)
    #expect(session.deck.count == 3)
    #expect(session.pending.isEmpty)
    #expect(await api.votes == [.init(mediaId: Self.ids[0], like: true)])

    // An older answer never undoes a newer one; a new round starts everyone over.
    session.receive(Self.night(revision: 1, deck: nil))
    #expect(session.state?.revision == 3)
    session.receive(Self.night(revision: 4, round: 2))
    #expect(session.remaining.count == 3)
    await session.leave()
    #expect(session.state == nil)
  }

  @Test func aMonthIsReadyFromTheSecondAndNewOnHomeForAWeek() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
      calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
    let second = IOSWrapped.readyMonth(today: day(2026, 11, 2), calendar: calendar)
    #expect(second.year == 2026 && second.month == 10 && second.name == "October")
    #expect(IOSWrapped.readyMonth(today: day(2026, 11, 1), calendar: calendar).month == 9)
    let january = IOSWrapped.readyMonth(today: day(2027, 1, 5), calendar: calendar)
    #expect(january.year == 2026 && january.month == 12)
    #expect(!IOSWrapped.monthIsNew(today: day(2026, 11, 1), calendar: calendar))
    #expect(IOSWrapped.monthIsNew(today: day(2026, 11, 8), calendar: calendar))
    #expect(!IOSWrapped.monthIsNew(today: day(2026, 11, 9), calendar: calendar))
  }

  @Test func wrappedCountsPlainNumbersAndClosesAfterTheLastSlide() {
    #expect(IOSWrapped.countTarget("143") == 143)
    #expect(IOSWrapped.countTarget("02:47") == nil)
    #expect(IOSWrapped.countTarget(nil) == nil)
    #expect(IOSWrapped.countValue(143, fraction: 0) == 0)
    #expect(IOSWrapped.countValue(143, fraction: 1) == 143)
    #expect(IOSWrapped.countValue(100, fraction: 0.5) > 50)
    #expect(IOSWrapped.step(from: 0, count: 3, forward: true) == 1)
    #expect(IOSWrapped.step(from: 2, count: 3, forward: true) == nil)
    #expect(IOSWrapped.step(from: 0, count: 3, forward: false) == 0)
    for name in ["night", "ember", "violet", "gold", "rose", "mint", "ocean", "lime"] {
      #expect(IOSWrapped.accents[name] != nil)
    }
    #expect(IOSWrapped.accent("invented") == IOSWrapped.accents["night"])
  }

  @Test func wrappedSlidesDecodeTheServersFields() throws {
    let json = """
      {"year":2026,"profileName":"Invented","slides":[{"kind":"hours","eyebrow":"Time well spent?",
      "headline":"You watched for","bigNumber":"143","unit":"hours","detail":null,"quip":"Seek help.",
      "accent":"ember","mediaId":null,"poster":null,"posters":null,"facts":null,"futureField":1}]}
      """
    let wrapped = try JSONDecoder().decode(IOSYearWrapped.self, from: Data(json.utf8))
    #expect(wrapped.slides.first?.bigNumber == "143")
    #expect(wrapped.slides.first?.accent == "ember")
  }
}

private actor FakeMovieNightAPI: IOSMovieNightAPI {
  private var answers: [IOSMovieNightState]
  private(set) var votes: [IOSMovieNightVote] = []

  init(answers: [IOSMovieNightState]) { self.answers = answers }

  private func next() throws -> IOSMovieNightState {
    guard !answers.isEmpty else { throw CancellationError() }
    return answers.removeFirst()
  }

  func movieNights() async throws -> [IOSMovieNightSummary] { [] }
  func createMovieNight(deviceName: String, voting: Bool) async throws -> IOSMovieNightState { try next() }
  func joinMovieNight(id: UUID, deviceName: String, voting: Bool) async throws -> IOSMovieNightState { try next() }
  func movieNight(id: UUID, after: Int64?, deckVersion: Int?, waitMilliseconds: Int) async throws
    -> IOSMovieNightState
  {
    // The long poll waits until the test ends.
    try await Task.sleep(for: .seconds(60))
    throw CancellationError()
  }
  func movieNightSettings(id: UUID, program: IOSMovieNightProgram) async throws
    -> IOSMovieNightState
  { try next() }
  func dealMovieNight(id: UUID) async throws -> IOSMovieNightState { try next() }
  func voteMovieNight(id: UUID, mediaID: UUID, like: Bool) async throws -> IOSMovieNightState {
    votes.append(.init(mediaId: mediaID, like: like))
    return try next()
  }
  func keepSwiping(id: UUID) async throws -> IOSMovieNightState { try next() }
  func movieNightRole(id: UUID, voting: Bool) async throws -> IOSMovieNightState { try next() }
  func leaveMovieNight(id: UUID) async throws {}
}
