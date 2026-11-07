import Combine
import Foundation

/// How a player follows a Watch Together party: where the shared picture is now, and which few
/// steps bring this player there. Small differences are left alone so playback never stutters.
enum WatchTogetherFollower {
  /// Players further apart than this jump to the shared moment.
  static let driftTolerance: Int64 = 1_500
  /// While paused or waiting, players line up more closely.
  static let stillTolerance: Int64 = 500

  enum Step: Equatable { case play, pause, seek(Int64) }

  static func shouldPlay(_ state: WatchPartyState) -> Bool { state.isPlaying && !state.isWaiting }

  /// The shared position at `serverNow`: it runs on only while the party plays and nobody waits.
  static func position(_ state: WatchPartyState, serverNow: Date) -> Int64 {
    guard shouldPlay(state), let updated = WatchTogetherClock.date(state.updatedAt) else {
      return state.positionMilliseconds
    }
    return state.positionMilliseconds + max(0, Int64(serverNow.timeIntervalSince(updated) * 1_000))
  }

  static func steps(
    _ state: WatchPartyState, serverNow: Date, localPosition: Int64, localPlaying: Bool
  ) -> [Step] {
    var steps: [Step] = []
    let target = position(state, serverNow: serverNow)
    let playing = shouldPlay(state)
    let tolerance = playing ? driftTolerance : stillTolerance
    if abs(localPosition - target) > tolerance { steps.append(.seek(target)) }
    if playing != localPlaying { steps.append(playing ? .play : .pause) }
    return steps
  }
}

/// Server times and this Mac's clock: the offset is measured from each answer, assuming the
/// answer was written halfway through the request.
enum WatchTogetherClock {
  static func offset(serverTime: String, sent: Date, received: Date) -> TimeInterval? {
    guard let server = date(serverTime) else { return nil }
    let middle = sent.addingTimeInterval(received.timeIntervalSince(sent) / 2)
    return server.timeIntervalSince(middle)
  }

  /// Reads "2026-11-07T20:00:00.1234567+00:00"; fractions longer than milliseconds are cut.
  static func date(_ text: String) -> Date? {
    var value = text
    if let dot = value.firstIndex(of: "."),
      let end = value[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
    {
      let digits = value[value.index(after: dot)..<end]
      let trimmed = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
      value.replaceSubrange(dot..<end, with: "." + trimmed)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = value.contains(".")
      ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    return formatter.date(from: value)
  }
}

/// What the player tells a Watch Together session that someone did here.
enum PlaybackUserAction: Equatable {
  case play(Int64)
  case pause(Int64)
  case seek(Int64)
}

/// The party this Mac is in: it asks the server for changes, makes the attached player follow
/// them and sends what happens here. Remote steps are applied with `applyingRemote` set, so they
/// are not sent back as this player's own actions.
@MainActor
final class WatchTogetherSession: ObservableObject {
  @Published private(set) var state: WatchPartyState?
  @Published private(set) var notice: String?
  @Published private(set) var errorText: String?

  private let client: APIClient
  /// Opens another title when the party moves on, such as to the next episode.
  var openTitle: (@MainActor (UUID, String) -> Void)?
  private weak var player: PlaybackController?
  private var observers: Set<AnyCancellable> = []
  private var pollTask: Task<Void, Never>?
  private var noticeTask: Task<Void, Never>?
  private var offset: TimeInterval = 0
  private var ownRevisions: Set<Int64> = []
  private var applyingRemote = false
  private var reportedReady = false
  /// Set while this Mac opens the party's new title, so closing the old player keeps the party.
  private(set) var isChangingTitle = false
  private let deviceName = Host.current().localizedName ?? "Mac"

  init(client: APIClient) {
    self.client = client
  }

  var partyId: UUID? { state?.id }

  func start(mediaId: UUID, position: Int64, playing: Bool) async -> Bool {
    await run {
      try await self.client.createWatchParty(
        CreateWatchPartyRequest(
          mediaId: mediaId, positionMilliseconds: position, isPlaying: playing,
          deviceName: self.deviceName))
    }
  }

  func join(_ party: WatchPartySummary) async -> Bool {
    await run {
      try await self.client.joinWatchParty(
        id: party.id, JoinWatchPartyRequest(deviceName: self.deviceName))
    }
  }

  func leave() async {
    pollTask?.cancel()
    pollTask = nil
    detach()
    if let id = partyId { try? await client.leaveWatchParty(id: id) }
    state = nil
  }

  /// The player now showing the party's title.
  func attach(_ controller: PlaybackController) {
    detach()
    player = controller
    isChangingTitle = false
    reportedReady = false
    controller.userActionObserver = { [weak self] action in self?.send(action) }
    controller.$isPreparing.removeDuplicates().sink { [weak self] preparing in
      Task { @MainActor in self?.preparingChanged(preparing) }
    }.store(in: &observers)
    controller.$presentation.map(\.mediaId).removeDuplicates().dropFirst().sink {
      [weak self] mediaId in
      Task { @MainActor in self?.titleChanged(mediaId) }
    }.store(in: &observers)
    if let state { apply(state) }
  }

  func detach() {
    player?.userActionObserver = nil
    player = nil
    observers.removeAll()
  }

  /// Turns the party's state into steps for the player.
  func apply(_ state: WatchPartyState) {
    guard let player else { return }
    if state.mediaId != player.presentation.mediaId {
      guard !isChangingTitle else { return }
      isChangingTitle = true
      openTitle?(state.mediaId, state.title)
      return
    }
    // A player still loading follows once it is ready.
    guard !player.isPreparing || player.isPlaying else { return }
    let steps = WatchTogetherFollower.steps(
      state, serverNow: Date().addingTimeInterval(offset),
      localPosition: player.currentTimeMilliseconds, localPlaying: player.isPlaying)
    applyingRemote = true
    defer { applyingRemote = false }
    for step in steps {
      switch step {
      case .seek(let position): player.seek(to: position)
      case .play: player.play()
      case .pause: player.pause()
      }
    }
  }

  private func run(_ action: @escaping @MainActor () async throws -> WatchPartyState) async -> Bool
  {
    do {
      let sent = Date()
      let next = try await action()
      receive(next, sent: sent, own: true)
      errorText = nil
      startPolling()
      return true
    } catch {
      errorText = error.localizedDescription
      return false
    }
  }

  private func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      var failures = 0
      while !Task.isCancelled {
        guard let self, let id = self.partyId else { return }
        let sent = Date()
        do {
          let next = try await self.client.watchParty(
            id: id, after: self.state?.revision, waitMilliseconds: 20_000)
          failures = 0
          self.receive(next, sent: sent, own: false)
        } catch is CancellationError {
          return
        } catch let failure as APIClientError
          where failure.httpStatus == 404 || failure.httpStatus == 403
        {
          self.errorText = "The Watch Together party has ended."
          self.state = nil
          self.detach()
          self.pollTask = nil
          return
        } catch {
          failures += 1
          if failures >= 6 {
            self.errorText = "Lost the Watch Together party."
            self.state = nil
            self.pollTask = nil
            return
          }
          try? await Task.sleep(for: .seconds(2))
        }
      }
    }
  }

  private func receive(_ next: WatchPartyState, sent: Date, own: Bool) {
    if let measured = WatchTogetherClock.offset(
      serverTime: next.serverTime, sent: sent, received: Date())
    {
      offset = measured
    }
    if own { ownRevisions.insert(next.revision) }
    // Answers can arrive out of order; an older state never undoes a newer one.
    if let known = state, known.id == next.id, next.revision < known.revision { return }
    let isNew = next.revision != state?.revision
    state = next
    if isNew, !own, !ownRevisions.contains(next.revision), let text = next.notice {
      show(text)
    }
    if next.me?.isBuffering == true, let player, player.presentation.mediaId == next.mediaId,
      !player.isPreparing
    {
      sendCommand(WatchPartyCommandRequest(action: "ready"))
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

  private func send(_ action: PlaybackUserAction) {
    guard !applyingRemote, state != nil else { return }
    switch action {
    case .play(let position):
      sendCommand(WatchPartyCommandRequest(action: "play", positionMilliseconds: position))
    case .pause(let position):
      sendCommand(WatchPartyCommandRequest(action: "pause", positionMilliseconds: position))
    case .seek(let position):
      sendCommand(WatchPartyCommandRequest(action: "seek", positionMilliseconds: position))
    }
  }

  private func preparingChanged(_ preparing: Bool) {
    guard let state, let player, player.presentation.mediaId == state.mediaId else { return }
    if !preparing {
      if state.me?.isBuffering == true || !reportedReady {
        reportedReady = true
        sendCommand(WatchPartyCommandRequest(action: "ready"))
      }
      apply(state)
    } else if reportedReady, state.me?.isBuffering == false {
      sendCommand(WatchPartyCommandRequest(action: "buffering"))
    }
  }

  /// The player moved on by itself (Up Next, previous or next episode): the party follows.
  private func titleChanged(_ mediaId: UUID) {
    guard let state, mediaId != state.mediaId, !isChangingTitle else { return }
    reportedReady = false
    sendCommand(WatchPartyCommandRequest(action: "change", positionMilliseconds: 0, mediaId: mediaId))
  }

  private func sendCommand(_ request: WatchPartyCommandRequest) {
    guard let id = partyId else { return }
    Task { [weak self] in
      guard let self else { return }
      let sent = Date()
      do {
        let next = try await self.client.sendWatchPartyCommand(id: id, request)
        self.receive(next, sent: sent, own: true)
      } catch {
        self.errorText = error.localizedDescription
      }
    }
  }
}
