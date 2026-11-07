import Foundation
import Testing

/// Watch Together on iPhone and iPad with an invented party, server and player; nothing is played.
@Suite("iOS Watch Together")
@MainActor
struct IOSWatchTogetherTests {
  static let film = UUID(uuidString: "00000000-0000-4000-8000-0000000000f1")!
  static let episode = UUID(uuidString: "00000000-0000-4000-8000-0000000000f2")!
  static let start = IOSWatchTogetherClock.date("2026-11-07T20:00:00+00:00")!

  static func state(
    playing: Bool, position: Int64, waiting: Bool = false, revision: Int64 = 2,
    action: String = "pause", media: UUID = film, buffering: Bool = false
  ) -> IOSWatchPartyState {
    IOSWatchPartyState(
      id: UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!, mediaId: media,
      title: "Invented Film", isPlaying: playing, isWaiting: waiting,
      positionMilliseconds: position, updatedAt: "2026-11-07T20:00:00.0000000+00:00",
      serverTime: "2026-11-07T20:00:00.0000000+00:00", revision: revision,
      members: [
        IOSWatchPartyMember(
          id: UUID(), name: "Living Room", deviceName: "iPad", isBuffering: buffering,
          isHost: false, isYou: true),
        IOSWatchPartyMember(
          id: UUID(), name: "Mia", deviceName: "Mac", isBuffering: false, isHost: true,
          isYou: false),
      ], lastAction: action, lastActionBy: "Mia")
  }

  final class Player: IOSWatchTogetherPlayer {
    var watchMediaID = IOSWatchTogetherTests.film
    var watchPosition: Int64 = 0
    var watchIsPlaying = true
    var watchIsReady = true
    var steps: [String] = []
    func watchPlay() {
      watchIsPlaying = true
      steps.append("play")
    }
    func watchPause() {
      watchIsPlaying = false
      steps.append("pause")
    }
    func watchSeek(to milliseconds: Int64) {
      watchPosition = milliseconds
      steps.append("seek \(milliseconds)")
    }
  }

  final class API: IOSWatchTogetherAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [IOSWatchPartyCommand] = []
    let answer: IOSWatchPartyState
    init(answer: IOSWatchPartyState) { self.answer = answer }
    var commands: [IOSWatchPartyCommand] { lock.withLock { sent } }
    func watchParties() async throws -> [IOSWatchPartySummary] { [] }
    func joinWatchParty(id: UUID, deviceName: String) async throws -> IOSWatchPartyState { answer }
    func createWatchParty(mediaID: UUID, position: Int64, playing: Bool, deviceName: String)
      async throws -> IOSWatchPartyState
    { answer }
    func watchParty(id: UUID, after: Int64?, waitMilliseconds: Int) async throws
      -> IOSWatchPartyState
    {
      try await Task.sleep(for: .seconds(60))
      return answer
    }
    func sendWatchPartyCommand(id: UUID, _ command: IOSWatchPartyCommand) async throws
      -> IOSWatchPartyState
    {
      lock.withLock { sent.append(command) }
      return answer
    }
    func leaveWatchParty(id: UUID) async throws {}
  }

  @Test func serverDatesAndClockOffsetAreRead() throws {
    let date = try #require(IOSWatchTogetherClock.date("2026-11-07T20:00:01.1234567+00:00"))
    #expect(abs(date.timeIntervalSince(Self.start) - 1.123) < 0.001)
    let offset = try #require(
      IOSWatchTogetherClock.offset(
        serverTime: "2026-11-07T20:00:10+00:00", sent: Self.start,
        received: Self.start.addingTimeInterval(2)))
    #expect(offset == 9)
  }

  @Test func smallDriftIsLeftAloneAndLargeDriftJumps() {
    let now = Self.start.addingTimeInterval(10)
    let playing = Self.state(playing: true, position: 0)
    #expect(IOSWatchTogetherFollower.position(playing, serverNow: now) == 10_000)
    #expect(
      IOSWatchTogetherFollower.position(Self.state(playing: true, position: 0, waiting: true), serverNow: now) == 0)
    #expect(
      IOSWatchTogetherFollower.steps(playing, serverNow: now, localPosition: 9_000, localPlaying: true)
        .isEmpty)
    #expect(
      IOSWatchTogetherFollower.steps(
        Self.state(playing: false, position: 42_000), serverNow: now, localPosition: 42_800,
        localPlaying: true) == [.seek(42_000), .pause])
    #expect(Self.state(playing: false, position: 0).notice == "Mia paused")
  }

  @Test func theAttachedPlayerFollowsAndOlderAnswersAreIgnored() async {
    let api = API(answer: Self.state(playing: false, position: 600_000))
    let player = Player()
    player.watchPosition = 1_200_000
    let session = IOSWatchTogetherSession(api: api, deviceName: "iPad", now: { Self.start })
    session.attach(player)
    session.receive(Self.state(playing: false, position: 600_000), sent: Self.start, own: false)
    #expect(player.steps == ["seek 600000", "pause"])
    #expect(session.notice == "Mia paused")
    // An answer for an older revision never undoes the newer one.
    session.receive(
      Self.state(playing: true, position: 1_200_000, revision: 1, action: "started"),
      sent: Self.start, own: true)
    #expect(player.steps == ["seek 600000", "pause"])
    #expect(session.state?.revision == 2)
  }

  @Test func ownActionsAreSentButRemoteStepsAreNot() async throws {
    let api = API(answer: Self.state(playing: true, position: 5_000, revision: 3, action: "seek"))
    let player = Player()
    let session = IOSWatchTogetherSession(api: api, deviceName: "iPad", now: { Self.start })
    #expect(await session.join(IOSWatchPartySummary(
      id: UUID(), mediaId: Self.film, title: "Invented Film", hostName: "Mia", memberCount: 1,
      isPlaying: true)))
    session.attach(player)
    session.userAction(.pause(7_000))
    try await Task.sleep(for: .milliseconds(200))
    let actions = api.commands.map(\.action)
    #expect(actions.contains("ready"))
    #expect(actions.contains("pause"))
    #expect(api.commands.first { $0.action == "pause" }?.positionMilliseconds == 7_000)
    #expect(!actions.contains("seek"))
    await session.leave()
    #expect(session.state == nil)
  }

  @Test func aNewTitleOpensOnceAndTheAppMovingOnChangesTheParty() async throws {
    let api = API(answer: Self.state(playing: true, position: 0, revision: 4, action: "change", media: Self.episode))
    let player = Player()
    let session = IOSWatchTogetherSession(api: api, deviceName: "iPad", now: { Self.start })
    var opened: [UUID] = []
    session.openTitle = { opened.append($0) }
    session.attach(player)
    session.receive(
      Self.state(playing: true, position: 0, revision: 4, action: "change", media: Self.episode),
      sent: Self.start, own: false)
    session.receive(
      Self.state(playing: true, position: 0, revision: 5, action: "ready", media: Self.episode),
      sent: Self.start, own: false)
    #expect(opened == [Self.episode])
    #expect(session.isChangingTitle)
    // The player opened the episode: it follows again and says it is ready.
    player.watchMediaID = Self.episode
    session.playerChanged()
    #expect(!session.isChangingTitle)
    try await Task.sleep(for: .milliseconds(200))
    #expect(api.commands.map(\.action).contains("ready"))
  }
}
