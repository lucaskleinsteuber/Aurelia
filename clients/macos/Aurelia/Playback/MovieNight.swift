import Combine
import Foundation

// Movie Night on the Mac: the same night protocol as the browser and the other apps, written
// for this client. Everyone swipes one deck; the first title every voter liked wins.

struct MovieNightSummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let hostName: String
  let hostDevice: String
  let memberCount: Int
  let phase: String
}

struct MovieNightMember: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let deviceName: String
  let isVoting: Bool
  let isHost: Bool
  let isYou: Bool
  let swiped: Int
}

struct MovieNightCard: Codable, Identifiable, Equatable, Sendable {
  let mediaId: UUID
  let kind: MediaKind
  let title: String
  let year: Int?
  let overview: String?
  let genres: [String]
  let runtimeMinutes: Int?
  let poster: ArtworkSummary?
  let backdrop: ArtworkSummary?

  var id: UUID { mediaId }

  /// "2019 · 1h 53m · Comedy · Crime".
  var meta: String {
    ([year.map(String.init), MovieNightRules.runtime(runtimeMinutes)].compactMap { $0 }
      + genres.prefix(2)).joined(separator: " · ")
  }
}

struct MovieNightVote: Codable, Equatable, Sendable {
  let mediaId: UUID
  let like: Bool
}

struct MovieNightAward: Codable, Equatable, Sendable {
  let title: String
  let name: String
  let line: String
}

struct MovieNightResult: Codable, Equatable, Sendable {
  let card: MovieNightCard?
  let likes: Int
  let voters: Int
  let isUnanimous: Bool
  let headline: String
  let line: String
  let awards: [MovieNightAward]
}

struct MovieNightState: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let phase: String
  let revision: Int64
  let round: Int
  let deckVersion: Int
  let kinds: String
  let genre: String?
  let genreOptions: [String]
  let members: [MovieNightMember]
  let deck: [MovieNightCard]?
  let yourVotes: [MovieNightVote]
  let result: MovieNightResult?
  let lastAction: String?
  let lastActionBy: String?

  var me: MovieNightMember? { members.first { $0.isYou } }
  var host: MovieNightMember? { members.first { $0.isHost } }
  var voters: [MovieNightMember] { members.filter(\.isVoting) }
}

/// What a screen shows for the night.
enum MovieNightScreen: Equatable, Sendable {
  case intro, lobby, swipe, waiting, match, noMatch
}

enum MovieNightChoice: Equatable, Sendable { case like, nope }

/// The rules that need no screen, so the logic tests can check them.
enum MovieNightRules {
  /// How far a card travels, in points, before letting go counts as a vote.
  static let swipeDistance: Double = 110

  /// The vote for a card let go `offset` points to the side, moving at `velocity` points per second.
  static func choice(offset: Double, velocity: Double = 0, width: Double = 360) -> MovieNightChoice? {
    let limit = min(swipeDistance, max(60, width * 0.3))
    if offset >= limit || (velocity > 600 && offset > 30) { return .like }
    if offset <= -limit || (velocity < -600 && offset < -30) { return .nope }
    return nil
  }

  /// The cards this person has not swiped yet, in deck order.
  static func remaining(
    deck: [MovieNightCard], votes: [MovieNightVote], pending: [UUID: Bool]
  ) -> [MovieNightCard] {
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

  static func screen(_ state: MovieNightState?, remaining: Int) -> MovieNightScreen {
    guard let state else { return .intro }
    switch state.phase {
    case "lobby": return .lobby
    case "match": return .match
    case "no-match": return .noMatch
    default: return state.me?.isVoting == true && remaining > 0 ? .swipe : .waiting
    }
  }

  /// The voters still swiping, slowest first.
  static func slowpokes(_ state: MovieNightState, deckSize: Int) -> [MovieNightMember] {
    state.voters.filter { $0.swiped < deckSize }.sorted { $0.swiped < $1.swiped }
  }
}

/// The requests Movie Night needs; `APIClient` answers them.
protocol MovieNightAPI: Sendable {
  func movieNights() async throws -> [MovieNightSummary]
  func createMovieNight(deviceName: String, voting: Bool) async throws -> MovieNightState
  func joinMovieNight(id: UUID, deviceName: String, voting: Bool) async throws -> MovieNightState
  func movieNight(id: UUID, after: Int64?, deckVersion: Int?, waitMilliseconds: Int) async throws
    -> MovieNightState
  func movieNightSettings(id: UUID, kinds: String, genre: String?) async throws -> MovieNightState
  func dealMovieNight(id: UUID) async throws -> MovieNightState
  func voteMovieNight(id: UUID, mediaID: UUID, like: Bool) async throws -> MovieNightState
  func keepSwiping(id: UUID) async throws -> MovieNightState
  func movieNightRole(id: UUID, voting: Bool) async throws -> MovieNightState
  func leaveMovieNight(id: UUID) async throws
}

/// The night this Mac is in. Swipes count here at once and are sent behind; the
/// deck is kept between polls, which only carry it again when it changed.
@MainActor
final class MovieNightSession: ObservableObject {
  @Published private(set) var state: MovieNightState?
  @Published private(set) var deck: [MovieNightCard] = []
  @Published private(set) var pending: [UUID: Bool] = [:]
  @Published var errorText: String?

  private let api: any MovieNightAPI
  private let deviceName: String
  private var pollTask: Task<Void, Never>?

  init(api: any MovieNightAPI, deviceName: String) {
    self.api = api
    self.deviceName = deviceName
  }

  var remaining: [MovieNightCard] {
    guard let state else { return [] }
    return MovieNightRules.remaining(deck: deck, votes: state.yourVotes, pending: pending)
  }

  var screen: MovieNightScreen { MovieNightRules.screen(state, remaining: remaining.count) }

  func start(voting: Bool = true) async {
    let name = deviceName
    await run { [api] in try await api.createMovieNight(deviceName: name, voting: voting) }
  }

  func join(_ night: MovieNightSummary, voting: Bool = true) async {
    let name = deviceName
    await run { [api] in try await api.joinMovieNight(id: night.id, deviceName: name, voting: voting) }
  }

  func settings(kinds: String, genre: String?) async {
    guard let id = state?.id else { return }
    await run { [api] in try await api.movieNightSettings(id: id, kinds: kinds, genre: genre) }
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
  func vote(_ card: MovieNightCard, like: Bool) {
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

  func receive(_ next: MovieNightState) {
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

  private func run(_ action: @escaping @Sendable () async throws -> MovieNightState) async {
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
          if let failure = error as? APIClientError, failure.httpStatus == 403 || failure.httpStatus == 404 {
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
    if let failure = error as? APIClientError, let text = failure.errorDescription, !text.isEmpty { return text }
    return fallback
  }
}

extension APIClient: MovieNightAPI {}
