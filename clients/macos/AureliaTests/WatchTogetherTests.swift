import Foundation
import Testing

@testable import Aurelia

/// Watch Together's following rules with invented party states; nothing is played.
struct WatchTogetherTests {
  private func state(
    playing: Bool, waiting: Bool = false, position: Int64, updatedAt: String = "2026-11-07T20:00:00+00:00"
  ) -> WatchPartyState {
    WatchPartyState(
      id: UUID(), mediaId: UUID(), title: "Invented Film", isPlaying: playing, isWaiting: waiting,
      positionMilliseconds: position, updatedAt: updatedAt, serverTime: updatedAt, revision: 3,
      members: [], lastAction: "pause", lastActionBy: "Mia")
  }

  private let start = WatchTogetherClock.date("2026-11-07T20:00:00+00:00")!

  @Test
  func serverDatesWithLongFractionsAreRead() throws {
    let date = try #require(WatchTogetherClock.date("2026-11-07T20:00:01.1234567+00:00"))
    #expect(abs(date.timeIntervalSince(start) - 1.123) < 0.001)
    #expect(WatchTogetherClock.date("2026-11-07T20:00:02Z")?.timeIntervalSince(start) == 2)
    let offset = try #require(
      WatchTogetherClock.offset(
        serverTime: "2026-11-07T20:00:10+00:00", sent: start, received: start.addingTimeInterval(2)))
    #expect(offset == 9)
  }

  @Test
  func thePositionRunsOnlyWhilePlayingAndNobodyWaits() {
    let later = start.addingTimeInterval(5)
    #expect(WatchTogetherFollower.position(state(playing: true, position: 1_000), serverNow: later) == 6_000)
    #expect(WatchTogetherFollower.position(state(playing: false, position: 1_000), serverNow: later) == 1_000)
    #expect(
      WatchTogetherFollower.position(state(playing: true, waiting: true, position: 1_000), serverNow: later)
        == 1_000)
  }

  @Test
  func smallDriftIsLeftAloneAndLargeDriftJumps() {
    let now = start.addingTimeInterval(10)
    let playing = state(playing: true, position: 0)
    #expect(WatchTogetherFollower.steps(playing, serverNow: now, localPosition: 9_000, localPlaying: true).isEmpty)
    #expect(
      WatchTogetherFollower.steps(playing, serverNow: now, localPosition: 3_000, localPlaying: true)
        == [.seek(10_000)])
    #expect(
      WatchTogetherFollower.steps(playing, serverNow: now, localPosition: 10_000, localPlaying: false)
        == [.play])
    let paused = state(playing: false, position: 42_000)
    #expect(
      WatchTogetherFollower.steps(paused, serverNow: now, localPosition: 42_800, localPlaying: true)
        == [.seek(42_000), .pause])
    #expect(state(playing: false, position: 0).notice == "Mia paused")
  }
}
