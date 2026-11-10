import Foundation
import Testing

/// Movie Night on Apple TV with an invented night and server; nothing is played.
@Suite("Apple TV Movie Night")
@MainActor
struct TVMovieNightTests {
  static let ids = (1...3).map { UUID(uuidString: "00000000-0000-4000-8000-0000000000a\($0)")! }
  static let deck = ids.enumerated().map { index, id in
    TVMovieNightCard(
      mediaId: id, kind: .movie, title: "Invented Film \(index + 1)", year: 2020 + index, overview: nil,
      genres: ["Comedy", "Crime", "Drama"], runtimeMinutes: 95 + index * 25, poster: nil, backdrop: nil)
  }

  static func night(
    phase: String = "voting", revision: Int64 = 2, round: Int = 1, deck: [TVMovieNightCard]? = deck,
    votes: [TVMovieNightVote] = [], voting: Bool = true
  ) -> TVMovieNightState {
    TVMovieNightState(
      id: UUID(uuidString: "00000000-0000-4000-8000-0000000000b1")!, phase: phase, revision: revision,
      round: round, deckVersion: round, kinds: "movies", genre: nil, genreOptions: ["Comedy"],
      members: [
        TVMovieNightMember(
          id: UUID(), name: "Invented TV", deviceName: "iPhone", isVoting: voting, isHost: true, isYou: true,
          swiped: votes.count),
        TVMovieNightMember(
          id: UUID(), name: "Mia", deviceName: "Browser", isVoting: true, isHost: false, isYou: false, swiped: 1),
      ],
      deck: deck, yourVotes: votes, result: nil, lastAction: nil, lastActionBy: nil)
  }

  @Test func aCardCountsOnceItTravelsFarEnoughOrIsFlicked() {
    #expect(TVMovieNightRules.choice(offset: 120) == .like)
    #expect(TVMovieNightRules.choice(offset: -120) == .nope)
    #expect(TVMovieNightRules.choice(offset: 40) == nil)
    #expect(TVMovieNightRules.choice(offset: 40, velocity: 900) == .like)
    #expect(TVMovieNightRules.choice(offset: -40, velocity: -900) == .nope)
    #expect(TVMovieNightRules.choice(offset: 80, width: 260) == .like)
  }

  @Test func theScreenFollowsTheNight() {
    #expect(TVMovieNightRules.screen(nil, remaining: 0) == .intro)
    #expect(TVMovieNightRules.screen(Self.night(phase: "lobby"), remaining: 3) == .lobby)
    #expect(TVMovieNightRules.screen(Self.night(), remaining: 3) == .swipe)
    #expect(TVMovieNightRules.screen(Self.night(), remaining: 0) == .waiting)
    #expect(TVMovieNightRules.screen(Self.night(voting: false), remaining: 3) == .waiting)
    #expect(TVMovieNightRules.screen(Self.night(phase: "match"), remaining: 1) == .match)
    #expect(TVMovieNightRules.screen(Self.night(phase: "no-match"), remaining: 0) == .noMatch)
    #expect(TVMovieNightRules.runtime(95) == "1h 35m")
    #expect(TVMovieNightRules.runtime(120) == "2h")
    #expect(TVMovieNightRules.runtime(nil) == nil)
    #expect(Self.deck[0].meta == "2020 · 1h 35m · Comedy · Crime")
    #expect(TVMovieNightRules.slowpokes(Self.night(votes: Self.deck.map { .init(mediaId: $0.mediaId, like: true) }), deckSize: 3).map(\.name) == ["Mia"])
  }

  @Test func aSwipeCountsAtOnceAndTheDeckIsKeptBetweenPolls() async {
    let api = FakeMovieNightAPI(answers: [
      Self.night(),
      Self.night(revision: 3, deck: nil, votes: [.init(mediaId: Self.ids[0], like: true)]),
    ])
    let session = TVMovieNightSession(api: api, deviceName: "Invented TV")
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

}

private actor FakeMovieNightAPI: TVMovieNightAPI {
  private var answers: [TVMovieNightState]
  private(set) var votes: [TVMovieNightVote] = []

  init(answers: [TVMovieNightState]) { self.answers = answers }

  private func next() throws -> TVMovieNightState {
    guard !answers.isEmpty else { throw CancellationError() }
    return answers.removeFirst()
  }

  func movieNights() async throws -> [TVMovieNightSummary] { [] }
  func createMovieNight(deviceName: String, voting: Bool) async throws -> TVMovieNightState { try next() }
  func joinMovieNight(id: UUID, deviceName: String, voting: Bool) async throws -> TVMovieNightState { try next() }
  func movieNight(id: UUID, after: Int64?, deckVersion: Int?, waitMilliseconds: Int) async throws
    -> TVMovieNightState
  {
    // The long poll waits until the test ends.
    try await Task.sleep(for: .seconds(60))
    throw CancellationError()
  }
  func movieNightSettings(id: UUID, kinds: String, genre: String?) async throws -> TVMovieNightState { try next() }
  func dealMovieNight(id: UUID) async throws -> TVMovieNightState { try next() }
  func voteMovieNight(id: UUID, mediaID: UUID, like: Bool) async throws -> TVMovieNightState {
    votes.append(.init(mediaId: mediaID, like: like))
    return try next()
  }
  func keepSwiping(id: UUID) async throws -> TVMovieNightState { try next() }
  func movieNightRole(id: UUID, voting: Bool) async throws -> TVMovieNightState { try next() }
  func leaveMovieNight(id: UUID) async throws {}
}
