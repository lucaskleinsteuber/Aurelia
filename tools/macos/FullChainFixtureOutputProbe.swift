import AppKit
import Darwin
import Foundation
@preconcurrency import VLCKit

/// A local decoder probe, not a replacement for the mandatory signed full-chain
/// gate. Generates new test patterns only, then uses normal video/audio outputs.
/// Compile together with FullChainSyntheticMedia.swift and the pinned VLCKit.
@main
@MainActor
enum FullChainFixtureOutputProbe {
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    Task { @MainActor in await run() }
    application.run()
  }

  private static func run() async {
    var player: VLCMediaPlayer?
    var window: NSWindow?
    var eofObservation: EOFObservation?
    var samples: [[String: Any]] = []
    var phase = "configuration"
    var failure = "none"
    var passed = false
    let format = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "MKV"
    do {
      guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3,
        ["AVI", "MP4", "MKV"].contains(format)
      else { throw Failure.code("invalid_probe_arguments") }
      let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
      let parent = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Aurelia/TestRuns", isDirectory: true)
      guard root.deletingLastPathComponent() == parent,
        root.lastPathComponent.hasPrefix("playback-evidence-mkv-probe-"),
        root.resolvingSymlinksInPath() == root,
        (try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory
          == true,
        (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
      else { throw Failure.code("invalid_owned_probe_root") }
      phase = "synthetic_generation"
      let fixtures = try await FullChainSyntheticMedia.generate(
        in: root.appendingPathComponent("Fixtures", isDirectory: true))
      guard let fixture = fixtures.first(where: { $0.name == format }) else {
        throw Failure.code("generated_fixture_missing")
      }
      let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
      let outputWindow = NSWindow(
        contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
      outputWindow.isReleasedWhenClosed = false
      outputWindow.contentView = view
      outputWindow.title = "Aurelia generated fixture decoder probe"
      outputWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      window = outputWindow
      let outputPlayer = VLCMediaPlayer(options: [
        "--no-video-title-show", "--network-caching=1000", "--no-metadata-network-access",
        "--no-play-and-pause",
      ])
      outputPlayer.drawable = view
      outputPlayer.audio?.volume = 5
      outputPlayer.media = VLCMedia(url: fixture.url)
      player = outputPlayer
      phase = "first_real_video_audio"
      outputPlayer.play()
      try await wait(seconds: 20) {
        outputPlayer.isPlaying && (outputPlayer.time.value?.int64Value ?? 0) >= 500
          && hasOutput(outputPlayer)
      }
      samples.append(snapshot(outputPlayer, phase: phase))
      guard abs((outputPlayer.media?.length.value?.int64Value ?? 0) - 64_000) <= 1_500 else {
        throw Failure.code("incorrect_generated_duration")
      }
      phase = "continued_real_video_audio"
      let before = outputPlayer.media?.statistics
      try await Task.sleep(for: .seconds(5))
      samples.append(snapshot(outputPlayer, phase: phase))
      guard let after = outputPlayer.media?.statistics, let before,
        after.displayedPictures > before.displayedPictures,
        after.playedAudioBuffers > before.playedAudioBuffers
      else { throw Failure.code("video_or_audio_output_did_not_increase") }
      for target: Int32 in [40_000, 12_000, 48_000] {
        phase = "seek_\(target)"
        outputPlayer.time = VLCTime(int: target)
        try await wait(seconds: 15) {
          let time = outputPlayer.time.value?.int64Value ?? 0
          return outputPlayer.isPlaying && time >= Int64(target) + 400
            && time <= Int64(target) + 4_000 && hasOutput(outputPlayer)
        }
        samples.append(snapshot(outputPlayer, phase: phase))
      }
      phase = "seek_58000_for_natural_eof"
      let observation = EOFObservation(player: outputPlayer)
      eofObservation = observation
      outputPlayer.time = VLCTime(int: 58_000)
      try await wait(seconds: 15) {
        let time = outputPlayer.time.value?.int64Value ?? 0
        return outputPlayer.isPlaying && (58_400...62_000).contains(time)
          && hasOutput(outputPlayer)
      }
      observation.capture(event: "seek_acknowledged", player: outputPlayer)
      samples.append(snapshot(outputPlayer, phase: phase))
      phase = "actual_natural_eof"
      try await wait(seconds: 20) {
        observation.capture(event: "bounded_eof_poll", player: outputPlayer)
        return observation.endedSnapshot != nil
      }
      samples.append(snapshot(outputPlayer, phase: phase))
      phase = "complete"
      passed = true
    } catch {
      if let player { samples.append(snapshot(player, phase: "failure_before_stop")) }
      failure = (error as? Failure)?.code ?? "probe_generation_or_runtime_failure"
    }
    eofObservation?.stop()
    player?.stop()
    window?.orderOut(nil)
    window?.close()
    let document: [String: Any] = [
      "formatVersion": 2, "passed": passed, "format": format, "phase": phase,
      "failure": failure, "outputSamples": samples,
      "naturalEOF": eofObservation?.document ?? [:],
      "scope":
        "Newly generated synthetic fixture, pinned VLCKit, normal local window/audio outputs.",
      "requiredFullGateComplete": false,
      "limitations": [
        "Local decoder probe only; no signed app, server, TLS, relay or personal media."
      ],
    ]
    if let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) {
      try? FileHandle.standardOutput.write(contentsOf: data)
      try? FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
    }
    Darwin.exit(passed ? 0 : 1)
  }

  private static func hasOutput(_ player: VLCMediaPlayer) -> Bool {
    guard let stats = player.media?.statistics else { return false }
    return stats.decodedVideo > 0 && stats.displayedPictures > 0
      && stats.decodedAudio > 0 && stats.playedAudioBuffers > 0
  }

  private static func snapshot(_ player: VLCMediaPlayer, phase: String) -> [String: Any] {
    let stats = player.media?.statistics
    let normalizedPosition = Double(player.position)
    return [
      "phase": phase, "statisticsPresent": stats != nil, "isPlaying": player.isPlaying,
      "playerState": Int(player.state.rawValue),
      "normalizedPosition":
        normalizedPosition.isFinite ? min(1, max(0, normalizedPosition)) : -1,
      "positionMilliseconds": player.time.value?.int64Value ?? 0,
      "remainingMilliseconds": player.remainingTime?.value?.int64Value ?? 0,
      "durationMilliseconds": player.media?.length.value?.int64Value ?? 0,
      "decodedVideo": stats?.decodedVideo ?? 0, "displayedPictures": stats?.displayedPictures ?? 0,
      "decodedAudio": stats?.decodedAudio ?? 0,
      "playedAudioBuffers": stats?.playedAudioBuffers ?? 0,
      "lostAudioBuffers": stats?.lostAudioBuffers ?? 0,
    ]
  }

  private static func wait(seconds: Int, until predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !predicate() {
      guard ContinuousClock.now < deadline else { throw Failure.code("real_output_timed_out") }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  @MainActor
  private final class EOFObservation {
    private weak var player: VLCMediaPlayer?
    private var tokens: [NSObjectProtocol] = []
    private var events: [[String: Any]] = []
    private let started = ContinuousClock.now
    private var maximumClockMilliseconds: Int64 = 0
    private var maximumNormalizedPosition: Double = 0
    private(set) var endedSnapshot: [String: Any]?

    init(player: VLCMediaPlayer) {
      self.player = player
      for (name, event) in [
        (VLCMediaPlayerTimeChanged, "time_changed"),
        (VLCMediaPlayerStateChanged, "state_changed"),
      ] {
        tokens.append(
          NotificationCenter.default.addObserver(
            forName: Notification.Name(rawValue: name), object: player, queue: .main
          ) { [weak self] _ in
            MainActor.assumeIsolated {
              guard let self, let player = self.player else { return }
              self.capture(event: event, player: player)
            }
          })
      }
      capture(event: "before_eof_seek", player: player)
    }

    func capture(event: String, player: VLCMediaPlayer) {
      let state = player.state
      let clock = player.time.value?.int64Value ?? 0
      maximumClockMilliseconds = max(maximumClockMilliseconds, clock)
      let normalizedPosition = Double(player.position)
      if normalizedPosition.isFinite {
        maximumNormalizedPosition = max(
          maximumNormalizedPosition, min(1, max(0, normalizedPosition)))
      }
      let elapsed = started.duration(to: .now).components
      var sample = FullChainFixtureOutputProbe.snapshot(player, phase: event)
      sample["elapsedMilliseconds"] =
        Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
      sample["maximumClockMilliseconds"] = maximumClockMilliseconds
      sample["maximumNormalizedPosition"] = maximumNormalizedPosition
      events.append(sample)
      if events.count > 64 { events.removeFirst(events.count - 64) }
      if state == .ended, endedSnapshot == nil { endedSnapshot = sample }
    }

    func stop() {
      for token in tokens { NotificationCenter.default.removeObserver(token) }
      tokens.removeAll()
    }

    var document: [String: Any] {
      [
        "actualEndedStateObserved": endedSnapshot != nil,
        "endedSnapshot": endedSnapshot ?? [:], "last64StateAndClockEvents": events,
        "maximumClockMilliseconds": maximumClockMilliseconds,
        "maximumNormalizedPosition": maximumNormalizedPosition,
        "scope": "Public cached VLC properties and state/time notifications only.",
      ]
    }
  }

  private enum Failure: Error {
    case code(String)
    var code: String {
      switch self {
      case .code(let value): value
      }
    }
  }
}
