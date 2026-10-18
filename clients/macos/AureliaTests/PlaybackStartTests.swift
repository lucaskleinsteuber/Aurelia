import Foundation
import Testing
import VLCKit

@testable import Aurelia

@MainActor
struct PlaybackStartTests {
  /// A synthetic, silent 60 s video played without a window: opening at the resume position
  /// starts the clock there instead of at the beginning.
  @Test(.timeLimit(.minutes(1))) func vlcOpensDirectlyAtTheResumePosition() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AureliaStart-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("steps.mp4")
    try await ScrubPreviewTests.writeVideo(
      levels: [20, 90, 160, 235, 120, 60], secondsPerLevel: 10, to: video)

    let engine = VLCPlaybackEngine(playerFactory: {
      VLCPlaybackEngine.makePlayer(
        nightMode: false, extraOptions: ["--vout=dummy", "--aout=dummy", "--no-audio"])
    })
    #expect(engine.opensAtStartPosition)
    var firstClock: Int64?
    engine.onUpdate = {
      if firstClock == nil, engine.currentTimeMilliseconds > 0 {
        firstClock = engine.currentTimeMilliseconds
      }
    }
    let started = Date()
    engine.load(url: video, startAt: 40_000)
    engine.play()
    while firstClock == nil, Date().timeIntervalSince(started) < 20 {
      try await Task.sleep(for: .milliseconds(10))
    }
    engine.stop()
    let clock = try #require(firstClock)
    print("First clock \(clock) ms after \(Date().timeIntervalSince(started)) s")
    #expect(clock >= 39_000 && clock <= 43_000, "first clock \(clock)")
  }
}
