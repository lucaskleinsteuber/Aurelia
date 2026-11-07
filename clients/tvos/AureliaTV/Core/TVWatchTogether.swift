import Foundation

// Watch Together on Apple TV: the same party protocol and following rules as the Mac and Linux
// apps, written for this client (no shared code with the Mac app).

struct TVWatchPartySummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let title: String
  let hostName: String
  let memberCount: Int
  let isPlaying: Bool
}

struct TVWatchPartyMember: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let deviceName: String
  let isBuffering: Bool
  let isHost: Bool
  let isYou: Bool
}

struct TVWatchPartyState: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let title: String
  let isPlaying: Bool
  let isWaiting: Bool
  let positionMilliseconds: Int64
  let updatedAt: String
  let serverTime: String
  let revision: Int64
  let members: [TVWatchPartyMember]
  let lastAction: String?
  let lastActionBy: String?

  var me: TVWatchPartyMember? { members.first { $0.isYou } }

  /// "Mia paused", the last thing someone did, for a short notice in the player.
  var notice: String? {
    guard let lastAction, let lastActionBy else { return nil }
    switch lastAction {
    case "play": return "\(lastActionBy) pressed play"
    case "pause": return "\(lastActionBy) paused"
    case "seek": return "\(lastActionBy) jumped to another moment"
    case "joined": return "\(lastActionBy) joined"
    case "left": return "\(lastActionBy) left"
    case "change": return "\(lastActionBy) started \(title)"
    default: return nil
    }
  }
}

struct TVWatchPartyCommand: Encodable, Equatable, Sendable {
  let action: String
  var positionMilliseconds: Int64? = nil
  var mediaId: UUID? = nil
}

/// Where the shared picture is now and which few steps bring this player there. Small
/// differences are left alone so playback never stutters.
enum TVWatchTogetherFollower {
  static let driftTolerance: Int64 = 1_500
  static let stillTolerance: Int64 = 500

  enum Step: Equatable { case play, pause, seek(Int64) }

  static func shouldPlay(_ state: TVWatchPartyState) -> Bool { state.isPlaying && !state.isWaiting }

  static func position(_ state: TVWatchPartyState, serverNow: Date) -> Int64 {
    guard shouldPlay(state), let updated = TVWatchTogetherClock.date(state.updatedAt) else {
      return state.positionMilliseconds
    }
    return state.positionMilliseconds + max(0, Int64(serverNow.timeIntervalSince(updated) * 1_000))
  }

  static func steps(
    _ state: TVWatchPartyState, serverNow: Date, localPosition: Int64, localPlaying: Bool
  ) -> [Step] {
    var steps: [Step] = []
    let target = position(state, serverNow: serverNow)
    let playing = shouldPlay(state)
    if abs(localPosition - target) > (playing ? driftTolerance : stillTolerance) {
      steps.append(.seek(target))
    }
    if playing != localPlaying { steps.append(playing ? .play : .pause) }
    return steps
  }
}

enum TVWatchTogetherClock {
  static func offset(serverTime: String, sent: Date, received: Date) -> TimeInterval? {
    guard let server = date(serverTime) else { return nil }
    return server.timeIntervalSince(sent.addingTimeInterval(received.timeIntervalSince(sent) / 2))
  }

  /// Reads "2026-11-07T20:00:00.1234567+00:00"; fractions longer than milliseconds are cut.
  static func date(_ text: String) -> Date? {
    var value = text
    if let dot = value.firstIndex(of: "."),
      let end = value[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
    {
      let digits = String(value[value.index(after: dot)..<end].prefix(3))
      value.replaceSubrange(
        dot..<end, with: "." + digits.padding(toLength: 3, withPad: "0", startingAt: 0))
    }
    return TVServerDate.parse(value)
  }
}

/// The player a party drives: the Apple TV player, or a simulated one in tests.
@MainActor
protocol TVWatchTogetherPlayer: AnyObject {
  var watchMediaID: UUID { get }
  var watchPosition: Int64 { get }
  var watchIsPlaying: Bool { get }
  /// True once the title is open and can play, pause and seek.
  var watchIsReady: Bool { get }
  func watchPlay()
  func watchPause()
  func watchSeek(to milliseconds: Int64)
}

/// The party requests Watch Together needs; `TVAPIClient` answers them.
protocol TVWatchTogetherAPI: Sendable {
  func watchParties() async throws -> [TVWatchPartySummary]
  func joinWatchParty(id: UUID, deviceName: String) async throws -> TVWatchPartyState
  func createWatchParty(mediaID: UUID, position: Int64, playing: Bool, deviceName: String)
    async throws -> TVWatchPartyState
  func watchParty(id: UUID, after: Int64?, waitMilliseconds: Int) async throws -> TVWatchPartyState
  func sendWatchPartyCommand(id: UUID, _ command: TVWatchPartyCommand) async throws
    -> TVWatchPartyState
  func leaveWatchParty(id: UUID) async throws
}

/// What someone did on this Apple TV, reported by the player.
enum TVPlaybackUserAction: Equatable, Sendable {
  case play(Int64)
  case pause(Int64)
  case seek(Int64)
}

/// The party this Apple TV is in: it asks the server for changes, makes the attached player
/// follow them and sends what happens here. Remote steps are applied with `applyingRemote` set,
/// so they are not sent back as this player's own actions.
@MainActor
final class TVWatchTogetherSession: ObservableObject {
  @Published private(set) var state: TVWatchPartyState?
  @Published private(set) var notice: String?
  @Published private(set) var errorText: String?

  private let api: any TVWatchTogetherAPI
  private let deviceName: String
  private let now: @MainActor () -> Date
  /// Opens another title when the party moves on, such as to the next episode.
  var openTitle: (@MainActor (UUID) -> Void)?
  private weak var player: (any TVWatchTogetherPlayer)?
  private var pollTask: Task<Void, Never>?
  private var noticeTask: Task<Void, Never>?
  private var offset: TimeInterval = 0
  private var ownRevisions: Set<Int64> = []
  private var applyingRemote = false
  private var reportedReady = false
  private(set) var isChangingTitle = false

  init(api: any TVWatchTogetherAPI, deviceName: String, now: @escaping @MainActor () -> Date = { Date() }) {
    self.api = api
    self.deviceName = deviceName
    self.now = now
  }

  var partyID: UUID? { state?.id }

  func start(mediaID: UUID, position: Int64, playing: Bool) async -> Bool {
    let name = deviceName
    return await run { [api] in
      try await api.createWatchParty(
        mediaID: mediaID, position: position, playing: playing, deviceName: name)
    }
  }

  func join(_ party: TVWatchPartySummary) async -> Bool {
    let name = deviceName
    return await run { [api] in try await api.joinWatchParty(id: party.id, deviceName: name) }
  }

  func leave() async {
    pollTask?.cancel()
    pollTask = nil
    detach()
    if let id = partyID { try? await api.leaveWatchParty(id: id) }
    state = nil
  }

  func attach(_ next: any TVWatchTogetherPlayer) {
    player = next
    isChangingTitle = false
    reportedReady = false
    playerChanged()
  }

  func detach() { player = nil }

  func isFollowing(_ candidate: any TVWatchTogetherPlayer) -> Bool { player === candidate }

  /// The player says something changed: it became ready, started loading or moved to another title.
  func playerChanged() {
    guard let player, let state else { return }
    if player.watchMediaID != state.mediaId {
      if isChangingTitle { return }
      // The player moved on by itself (Up Next): the party follows.
      if player.watchIsReady || reportedReady {
        reportedReady = false
        send(TVWatchPartyCommand(action: "change", positionMilliseconds: 0, mediaId: player.watchMediaID))
      }
      return
    }
    isChangingTitle = false
    if player.watchIsReady {
      if state.me?.isBuffering == true || !reportedReady {
        reportedReady = true
        send(TVWatchPartyCommand(action: "ready"))
      }
      apply(state)
    } else if reportedReady, state.me?.isBuffering == false {
      send(TVWatchPartyCommand(action: "buffering"))
    }
  }

  /// Something someone did on this Apple TV.
  func userAction(_ action: TVPlaybackUserAction) {
    guard !applyingRemote, state != nil else { return }
    switch action {
    case .play(let position): send(TVWatchPartyCommand(action: "play", positionMilliseconds: position))
    case .pause(let position): send(TVWatchPartyCommand(action: "pause", positionMilliseconds: position))
    case .seek(let position): send(TVWatchPartyCommand(action: "seek", positionMilliseconds: position))
    }
  }

  func apply(_ state: TVWatchPartyState) {
    guard let player else { return }
    if state.mediaId != player.watchMediaID {
      guard !isChangingTitle, let openTitle else { return }
      isChangingTitle = true
      openTitle(state.mediaId)
      return
    }
    guard player.watchIsReady else { return }
    let steps = TVWatchTogetherFollower.steps(
      state, serverNow: now().addingTimeInterval(offset), localPosition: player.watchPosition,
      localPlaying: player.watchIsPlaying)
    applyingRemote = true
    defer { applyingRemote = false }
    for step in steps {
      switch step {
      case .seek(let position): player.watchSeek(to: position)
      case .play: player.watchPlay()
      case .pause: player.watchPause()
      }
    }
  }

  private func run(_ action: @escaping @Sendable () async throws -> TVWatchPartyState) async -> Bool {
    do {
      let sent = now()
      let next = try await action()
      receive(next, sent: sent, own: true)
      errorText = nil
      startPolling()
      return true
    } catch {
      errorText = "Watch Together isn't available right now."
      return false
    }
  }

  private func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      var failures = 0
      while !Task.isCancelled {
        guard let self, let id = self.partyID else { return }
        let sent = self.now()
        do {
          let next = try await self.api.watchParty(
            id: id, after: self.state?.revision, waitMilliseconds: 15_000)
          failures = 0
          self.receive(next, sent: sent, own: false)
        } catch is CancellationError {
          return
        } catch TVCoreError.server(let status, _, _, _) where status == 403 || status == 404 {
          self.ended("The Watch Together party has ended.")
          return
        } catch {
          if Task.isCancelled { return }
          failures += 1
          if failures >= 6 {
            self.ended("Lost the Watch Together party.")
            return
          }
          try? await Task.sleep(for: .seconds(2))
        }
      }
    }
  }

  private func ended(_ message: String) {
    errorText = message
    state = nil
    pollTask = nil
    detach()
  }

  func receive(_ next: TVWatchPartyState, sent: Date, own: Bool) {
    if let measured = TVWatchTogetherClock.offset(serverTime: next.serverTime, sent: sent, received: now()) {
      offset = measured
    }
    if own { ownRevisions.insert(next.revision) }
    // Answers can arrive out of order; an older state never undoes a newer one.
    if let known = state, known.id == next.id, next.revision < known.revision { return }
    let isNew = next.revision != state?.revision
    state = next
    if isNew, !own, !ownRevisions.contains(next.revision), let text = next.notice { show(text) }
    if next.me?.isBuffering == true, let player, player.watchMediaID == next.mediaId,
      player.watchIsReady
    {
      send(TVWatchPartyCommand(action: "ready"))
    }
    apply(next)
  }

  private func show(_ text: String) {
    notice = text
    noticeTask?.cancel()
    noticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      self?.notice = nil
    }
  }

  private func send(_ command: TVWatchPartyCommand) {
    guard let id = partyID else { return }
    let sent = now()
    Task { [weak self, api] in
      do {
        let next = try await api.sendWatchPartyCommand(id: id, command)
        self?.receive(next, sent: sent, own: true)
      } catch {
        self?.errorText = "Watch Together couldn't send that."
      }
    }
  }
}

extension TVAPIClient: TVWatchTogetherAPI {
  func watchParties() async throws -> [TVWatchPartySummary] {
    try await getWatchTogether("/api/v1/watch-together")
  }

  func joinWatchParty(id: UUID, deviceName: String) async throws -> TVWatchPartyState {
    struct Body: Encodable { let deviceName: String }
    return try await postWatchTogether(
      "/api/v1/watch-together/\(id.uuidString.lowercased())/join", Body(deviceName: deviceName))
  }

  func createWatchParty(mediaID: UUID, position: Int64, playing: Bool, deviceName: String)
    async throws -> TVWatchPartyState
  {
    struct Body: Encodable {
      let mediaId: UUID
      let positionMilliseconds: Int64
      let isPlaying: Bool
      let deviceName: String
    }
    return try await postWatchTogether(
      "/api/v1/watch-together",
      Body(mediaId: mediaID, positionMilliseconds: position, isPlaying: playing, deviceName: deviceName))
  }

  func watchParty(id: UUID, after: Int64?, waitMilliseconds: Int) async throws -> TVWatchPartyState {
    let query =
      after.map { [URLQueryItem(name: "after", value: String($0)), URLQueryItem(name: "waitMs", value: String(waitMilliseconds))] } ?? []
    return try await getWatchTogether("/api/v1/watch-together/\(id.uuidString.lowercased())", query: query)
  }

  func sendWatchPartyCommand(id: UUID, _ command: TVWatchPartyCommand) async throws
    -> TVWatchPartyState
  {
    try await postWatchTogether(
      "/api/v1/watch-together/\(id.uuidString.lowercased())/commands", command)
  }

  func leaveWatchParty(id: UUID) async throws {
    try await deleteWatchTogether("/api/v1/watch-together/\(id.uuidString.lowercased())/members/me")
  }
}
