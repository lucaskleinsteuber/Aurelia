import Combine
import Foundation

// Movie Night on iPhone and iPad: the same night protocol as the browser and the other apps,
// written for this client. Everyone swipes one deck; the first title every voter liked wins.

struct IOSMovieNightSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let hostName: String
  let hostDevice: String
  let memberCount: Int
  let phase: String
}

struct IOSMovieNightMember: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let deviceName: String
  let isVoting: Bool
  let isHost: Bool
  let isYou: Bool
  let swiped: Int
}

struct IOSMovieNightCard: Codable, Identifiable, Equatable, Sendable {
  let mediaId: UUID
  let kind: IOSMediaKind
  let title: String
  let year: Int?
  let overview: String?
  let genres: [String]
  let runtimeMinutes: Int?
  let poster: IOSArtwork?
  let backdrop: IOSArtwork?

  var id: UUID { mediaId }

  /// "2019 · 1h 53m · Comedy · Crime".
  var meta: String {
    ([year.map(String.init), IOSMovieNightRules.runtime(runtimeMinutes)].compactMap { $0 }
      + genres.prefix(2)).joined(separator: " · ")
  }
}

struct IOSMovieNightVote: Codable, Equatable, Sendable {
  let mediaId: UUID
  let like: Bool
}

struct IOSMovieNightAward: Codable, Equatable, Sendable {
  let title: String
  let name: String
  let line: String
}

struct IOSMovieNightResult: Codable, Equatable, Sendable {
  let card: IOSMovieNightCard?
  let likes: Int
  let voters: Int
  let isUnanimous: Bool
  let headline: String
  let line: String
  let awards: [IOSMovieNightAward]
}

struct IOSMovieNightState: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let phase: String
  let revision: Int64
  let round: Int
  let deckVersion: Int
  let kinds: String
  let genre: String?
  let genreOptions: [String]
  /// From server 2.7.0: the era and length the host picked; older servers send none.
  var era: String? = nil
  var length: String? = nil
  let members: [IOSMovieNightMember]
  let deck: [IOSMovieNightCard]?
  let yourVotes: [IOSMovieNightVote]
  let result: IOSMovieNightResult?
  let lastAction: String?
  let lastActionBy: String?

  var me: IOSMovieNightMember? { members.first { $0.isYou } }
  var host: IOSMovieNightMember? { members.first { $0.isHost } }
  var voters: [IOSMovieNightMember] { members.filter(\.isVoting) }
}

/// What a screen shows for the night.
enum IOSMovieNightScreen: Equatable, Sendable {
  case intro, lobby, swipe, waiting, match, noMatch
}

enum IOSMovieNightChoice: Equatable, Sendable { case like, nope }

/// The rules that need no screen, so the logic tests can check them.
enum IOSMovieNightRules {
  /// How far a card travels, in points, before letting go counts as a vote.
  static let swipeDistance: Double = 110

  /// The vote for a card let go `offset` points to the side, moving at `velocity` points per second.
  static func choice(offset: Double, velocity: Double = 0, width: Double = 360) -> IOSMovieNightChoice? {
    let limit = min(swipeDistance, max(60, width * 0.3))
    if offset >= limit || (velocity > 600 && offset > 30) { return .like }
    if offset <= -limit || (velocity < -600 && offset < -30) { return .nope }
    return nil
  }

  /// The cards this person has not swiped yet, in deck order.
  static func remaining(
    deck: [IOSMovieNightCard], votes: [IOSMovieNightVote], pending: [UUID: Bool]
  ) -> [IOSMovieNightCard] {
    let voted = Set(votes.map(\.mediaId)).union(pending.keys)
    return deck.filter { !voted.contains($0.mediaId) }
  }

  /// "1h 52m", "48m", or nil.
  static func runtime(_ minutes: Int?) -> String? {
    guard let minutes, minutes > 0 else { return nil }
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest)m" }
    return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
  }

  static func screen(_ state: IOSMovieNightState?, remaining: Int) -> IOSMovieNightScreen {
    guard let state else { return .intro }
    switch state.phase {
    case "lobby": return .lobby
    case "match": return .match
    case "no-match": return .noMatch
    default: return state.me?.isVoting == true && remaining > 0 ? .swipe : .waiting
    }
  }

  /// The voters still swiping, slowest first.
  static func slowpokes(_ state: IOSMovieNightState, deckSize: Int) -> [IOSMovieNightMember] {
    state.voters.filter { $0.swiped < deckSize }.sorted { $0.swiped < $1.swiped }
  }
}

/// The requests Movie Night needs; `IOSAPIClient` answers them.
protocol IOSMovieNightAPI: Sendable {
  func movieNights() async throws -> [IOSMovieNightSummary]
  func createMovieNight(deviceName: String, voting: Bool) async throws -> IOSMovieNightState
  func joinMovieNight(id: UUID, deviceName: String, voting: Bool) async throws -> IOSMovieNightState
  func movieNight(id: UUID, after: Int64?, deckVersion: Int?, waitMilliseconds: Int) async throws
    -> IOSMovieNightState
  func movieNightSettings(id: UUID, program: IOSMovieNightProgram) async throws
    -> IOSMovieNightState
  func dealMovieNight(id: UUID) async throws -> IOSMovieNightState
  func voteMovieNight(id: UUID, mediaID: UUID, like: Bool) async throws -> IOSMovieNightState
  func keepSwiping(id: UUID) async throws -> IOSMovieNightState
  func movieNightRole(id: UUID, voting: Bool) async throws -> IOSMovieNightState
  func leaveMovieNight(id: UUID) async throws
}

/// The night this iPhone or iPad is in. Swipes count here at once and are sent behind; the
/// deck is kept between polls, which only carry it again when it changed.
@MainActor
final class IOSMovieNightSession: ObservableObject {
  @Published private(set) var state: IOSMovieNightState?
  @Published private(set) var deck: [IOSMovieNightCard] = []
  @Published private(set) var pending: [UUID: Bool] = [:]
  @Published var errorText: String?

  private let api: any IOSMovieNightAPI
  private let deviceName: String
  private var pollTask: Task<Void, Never>?

  init(api: any IOSMovieNightAPI, deviceName: String) {
    self.api = api
    self.deviceName = deviceName
  }

  var remaining: [IOSMovieNightCard] {
    guard let state else { return [] }
    return IOSMovieNightRules.remaining(deck: deck, votes: state.yourVotes, pending: pending)
  }

  var screen: IOSMovieNightScreen { IOSMovieNightRules.screen(state, remaining: remaining.count) }

  func start(voting: Bool = true) async {
    let name = deviceName
    await run { [api] in try await api.createMovieNight(deviceName: name, voting: voting) }
  }

  func join(_ night: IOSMovieNightSummary, voting: Bool = true) async {
    let name = deviceName
    await run { [api] in try await api.joinMovieNight(id: night.id, deviceName: name, voting: voting) }
  }

  func settings(_ program: IOSMovieNightProgram) async {
    guard let id = state?.id else { return }
    await run { [api] in try await api.movieNightSettings(id: id, program: program) }
  }

  func deal() async {
    guard let id = state?.id else { return }
    await run { [api] in try await api.dealMovieNight(id: id) }
  }

  func keepSwiping() async {
    guard let id = state?.id else { return }
    await run { [api] in try await api.keepSwiping(id: id) }
  }

  func setVoting(_ voting: Bool) async {
    guard let id = state?.id else { return }
    await run { [api] in try await api.movieNightRole(id: id, voting: voting) }
  }

  /// Counts at once; the server's answer follows.
  func vote(_ card: IOSMovieNightCard, like: Bool) {
    guard let id = state?.id else { return }
    pending[card.mediaId] = like
    Task { [api] in
      do {
        receive(try await api.voteMovieNight(id: id, mediaID: card.mediaId, like: like))
      } catch {
        pending[card.mediaId] = nil
        errorText = Self.message(error, fallback: "That swipe didn't reach the server. Try it again.")
      }
    }
  }

  func leave() async {
    pollTask?.cancel()
    pollTask = nil
    let id = state?.id
    state = nil
    deck = []
    pending = [:]
    if let id { try? await api.leaveMovieNight(id: id) }
  }

  func receive(_ next: IOSMovieNightState) {
    // Answers can arrive out of order; an older state never undoes a newer one.
    if let state, state.id == next.id, next.revision < state.revision { return }
    if let nextDeck = next.deck {
      deck = nextDeck
      let inDeck = Set(nextDeck.map(\.mediaId))
      pending = pending.filter { inDeck.contains($0.key) }
    }
    if let state, state.round != next.round { pending = [:] }
    for vote in next.yourVotes { pending[vote.mediaId] = nil }
    state = next
  }

  private func run(_ action: @escaping @Sendable () async throws -> IOSMovieNightState) async {
    do {
      receive(try await action())
      errorText = nil
      startPolling()
    } catch {
      errorText = Self.message(error, fallback: "Movie Night isn't available right now.")
    }
  }

  private func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      var failures = 0
      while !Task.isCancelled {
        guard let self, let state = self.state else { return }
        do {
          let next = try await self.api.movieNight(
            id: state.id, after: state.revision, deckVersion: state.deckVersion, waitMilliseconds: 20_000)
          failures = 0
          guard !Task.isCancelled else { return }
          self.receive(next)
        } catch {
          if Task.isCancelled { return }
          if case IOSCoreError.server(let status, _, _, _) = error, status == 403 || status == 404 {
            return self.ended("This Movie Night has ended.")
          }
          failures += 1
          if failures >= 6 { return self.ended("Lost the connection to Movie Night.") }
          try? await Task.sleep(for: .seconds(2))
        }
      }
    }
  }

  private func ended(_ message: String) {
    pollTask = nil
    state = nil
    deck = []
    pending = [:]
    errorText = message
  }

  private static func message(_ error: Error, fallback: String) -> String {
    if case IOSCoreError.server(_, _, let message, _) = error, let message, !message.isEmpty { return message }
    return fallback
  }
}

extension IOSAPIClient: IOSMovieNightAPI {
  private static func night(_ id: UUID, _ tail: String = "") -> String {
    "/api/v1/movie-night/\(id.uuidString.lowercased())\(tail)"
  }

  func movieNights() async throws -> [IOSMovieNightSummary] {
    try await getWatchTogether("/api/v1/movie-night")
  }

  func createMovieNight(deviceName: String, voting: Bool) async throws -> IOSMovieNightState {
    struct Body: Encodable {
      let deviceName: String
      let isVoting: Bool
    }
    return try await postWatchTogether("/api/v1/movie-night", Body(deviceName: deviceName, isVoting: voting))
  }

  func joinMovieNight(id: UUID, deviceName: String, voting: Bool) async throws -> IOSMovieNightState {
    struct Body: Encodable {
      let deviceName: String
      let isVoting: Bool
    }
    return try await postWatchTogether(Self.night(id, "/join"), Body(deviceName: deviceName, isVoting: voting))
  }

  func movieNight(id: UUID, after: Int64?, deckVersion: Int?, waitMilliseconds: Int) async throws
    -> IOSMovieNightState
  {
    var query: [URLQueryItem] = []
    if let after {
      query = [
        URLQueryItem(name: "after", value: String(after)),
        URLQueryItem(name: "waitMs", value: String(waitMilliseconds)),
      ]
      if let deckVersion { query.append(URLQueryItem(name: "deckVersion", value: String(deckVersion))) }
    }
    return try await getWatchTogether(Self.night(id), query: query)
  }

  func movieNightSettings(id: UUID, program: IOSMovieNightProgram) async throws
    -> IOSMovieNightState
  {
    try await postWatchTogether(Self.night(id, "/settings"), program)
  }

  func dealMovieNight(id: UUID) async throws -> IOSMovieNightState {
    try await postWatchTogether(Self.night(id, "/deal"), [String: String]())
  }

  func voteMovieNight(id: UUID, mediaID: UUID, like: Bool) async throws -> IOSMovieNightState {
    struct Body: Encodable {
      let mediaId: UUID
      let like: Bool
    }
    return try await postWatchTogether(Self.night(id, "/votes"), Body(mediaId: mediaID, like: like))
  }

  func keepSwiping(id: UUID) async throws -> IOSMovieNightState {
    try await postWatchTogether(Self.night(id, "/keep-swiping"), [String: String]())
  }

  func movieNightRole(id: UUID, voting: Bool) async throws -> IOSMovieNightState {
    struct Body: Encodable { let isVoting: Bool }
    return try await postWatchTogether(Self.night(id, "/role"), Body(isVoting: voting))
  }

  func leaveMovieNight(id: UUID) async throws {
    try await deleteWatchTogether(Self.night(id, "/members/me"))
  }
}

/// Tonight's program: what the host deals (as on the Mac and in the browser).
struct IOSMovieNightProgram: Codable, Equatable, Sendable {
  var kinds: String
  var genre: String?
  var era: String
  var length: String

  static let kinds = [("movies", "Movies"), ("all", "Movies and shows")]
  static let eras = [
    ("any", "Any time"), ("2020s", "2020s"), ("2010s", "2010s"), ("2000s", "2000s"),
    ("older", "Older"),
  ]
  static let lengths = [
    ("any", "Any length"), ("short", "Short, up to 1h 40m"), ("standard", "Up to 2h 10m"),
  ]

  /// The night's current program; a server without eras and lengths keeps "any".
  init(_ state: IOSMovieNightState) {
    kinds = state.kinds
    genre = state.genre?.isEmpty == false ? state.genre : nil
    era = state.era ?? "any"
    length = state.length ?? "any"
  }

  init(kinds: String, genre: String?, era: String, length: String) {
    self.kinds = kinds
    self.genre = genre
    self.era = era
    self.length = length
  }

  /// "Movies · Comedy · 2010s · Short" for the program card's foot.
  var summary: String {
    [
      kinds == "all" ? "Movies and shows" : "Movies", genre,
      era == "any" ? nil : Self.eras.first { $0.0 == era }?.1,
      length == "short" ? "Short" : length == "standard" ? "Up to 2h 10m" : nil,
    ].compactMap { $0 }.joined(separator: " · ")
  }
}
