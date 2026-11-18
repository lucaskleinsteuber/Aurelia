import Foundation
@preconcurrency import MediaPlayer
import Testing

/// Picture in Picture, AirPlay and the lock screen: the hand-over to Apple's player, the relay that
/// AirPlay reads from, and the remote command callbacks. No media plays.
@Suite struct IOSSystemPlaybackTests {
  @Test func appleSPlayerReadsTheHLSMasterBelowTheRelay() {
    let stream = URL(string: "http://127.0.0.1:50123/stream/secret")!
    #expect(
      IOSSystemPlayback.hlsURL(for: stream).absoluteString
        == "http://127.0.0.1:50123/stream/secret/hls/master.m3u8")
    let hls = IOSSystemPlayback.hlsURL(for: stream)
    #expect(IOSSystemPlayback.hlsURL(for: hls) == hls)
  }

  @Test func vlcGoesOnASecondBackAndNeverPastTheEnd() {
    #expect(IOSSystemPlayback.returnPosition(65_000, duration: 120_000) == 64_000)
    #expect(IOSSystemPlayback.returnPosition(500, duration: 120_000) == 0)
    #expect(IOSSystemPlayback.returnPosition(130_000, duration: 120_000) == 119_000)
    #expect(IOSSystemPlaybackPhase.vlc.continuesInBackground == false)
    #expect(IOSSystemPlaybackPhase.system(.airPlay).continuesInBackground)
    #expect(
      IOSSystemPlaybackPhase.starting(.pictureInPicture, position: 0, playing: true).reason
        == .pictureInPicture)
  }

  @Test func airPlayReadsFromTheWiFiAddressNeverCellularOrLinkLocal() {
    #expect(
      IOSSystemPlayback.networkAddress(interfaces: [
        ("pdp_ip0", "10.20.30.40"), ("en2", "192.168.2.5"), ("en0", "192.168.178.30"),
      ]) == "192.168.178.30")
    #expect(IOSSystemPlayback.networkAddress(interfaces: [("en0", "169.254.3.4")]) == nil)
    #expect(IOSSystemPlayback.networkAddress(interfaces: [("pdp_ip0", "10.1.2.3")]) == nil)
    #expect(IOSSystemPlayback.isAirPlay(portTypes: ["AirPlay"]))
    #expect(!IOSSystemPlayback.isAirPlay(portTypes: ["Speaker"]))
  }

  @Test func theAirPlayRelayAnswersOnlyHLSOnItsOwnAddress() throws {
    func parse(_ path: String, host: String) throws -> IOSRelayRequest {
      try IOSRelayRequest.parse(
        Data("GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8), secret: "secret",
        host: "192.168.178.30", hlsOnly: true)
    }
    #expect(
      try parse("/stream/secret/hls/master.m3u8", host: "192.168.178.30:50000").hlsPath
        == "hls/master.m3u8")
    #expect(
      try parse("/stream/secret/hls/720p/3.m4s?audio=1", host: "192.168.178.30").hlsPath
        == "hls/720p/3.m4s?audio=1")
    // The original file and its subtitles stay on this device.
    #expect(throws: IOSRelayRequestError.self) {
      try parse("/stream/secret", host: "192.168.178.30:50000")
    }
    #expect(throws: IOSRelayRequestError.self) {
      try parse("/subtitles/secret/2", host: "192.168.178.30:50000")
    }
    // A page that points another name at this address can't read it.
    #expect(throws: IOSRelayRequestError.self) {
      try parse("/stream/secret/hls/master.m3u8", host: "evil.example:50000")
    }
    #expect(throws: IOSRelayRequestError.self) {
      try parse("/stream/other/hls/master.m3u8", host: "192.168.178.30:50000")
    }
  }

  @Test func lockScreenButtonsFollowThePlayer() {
    var state = IOSNowPlayingState(
      isReady: false, isPlaying: false, canSeek: true, hasNext: true, hasPrevious: false)
    #expect(state.enabled.values.allSatisfy { !$0 })
    state.isReady = true
    #expect(state.enabled[.play] == true && state.enabled[.pause] == false)
    #expect(state.enabled[.nextEpisode] == true && state.enabled[.previousEpisode] == false)
    state.isPlaying = true
    state.canSeek = false
    #expect(state.enabled[.pause] == true && state.enabled[.changePosition] == false)
    let info = IOSNowPlayingInfo(
      title: "Invented Show · S1 E3", subtitle: nil, elapsedSeconds: 61, durationSeconds: 1_800,
      isPlaying: false, rate: 1.5)
    #expect(info.values[MPMediaItemPropertyTitle] as? String == "Invented Show · S1 E3")
    #expect(info.values[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    #expect(info.values[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1.5)
    #expect(IOSNowPlayingCallbacks.skipTarget(position: 5_000, duration: 60_000, by: -10_000) == 0)
    #expect(IOSNowPlayingCallbacks.skipTarget(position: 0, duration: 0, by: 10_000) == nil)
  }

  /// MediaPlayer calls command handlers on its own queues; the production handler must answer
  /// there and only act on the main actor.
  @Test func remoteCommandsCalledOffMainActOnTheMainActorOnlyWhenAllowed() async {
    let gate = IOSNowPlayingGate()
    let generation = UUID()
    let received = Received()
    let perform: @MainActor @Sendable (IOSNowPlayingCommand, Double?) -> Void = { command, _ in
      MainActor.preconditionIsolated()
      received.append(command)
    }
    let handler: @Sendable () -> MPRemoteCommandHandlerStatus = {
      IOSNowPlayingCallbacks.respond(
        to: .toggle, position: nil, gate: gate, generation: generation, perform: perform)
    }
    // The production factory builds without an actor check of its own.
    _ = IOSNowPlayingCallbacks.handler(
      for: .toggle, gate: gate, generation: generation, perform: perform)
    let refused = await Self.callOffMain(handler)
    #expect(refused == .noActionableNowPlayingItem)
    gate.update(generation: generation, enabled: [.toggle: true])
    let accepted = await Self.callOffMain(handler)
    #expect(accepted == .success)
    for _ in 0..<50 where received.count == 0 { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(received.count == 1)
    gate.clear()
    let retired = await Self.callOffMain(handler)
    #expect(retired == .noActionableNowPlayingItem)
  }

  private static func callOffMain(
    _ body: @escaping @Sendable () -> MPRemoteCommandHandlerStatus
  ) async -> MPRemoteCommandHandlerStatus {
    let (status, offMain) = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: (body(), !Thread.isMainThread))
      }
    }
    #expect(offMain)
    return status
  }
}

private final class Received: @unchecked Sendable {
  private let lock = NSLock()
  private var commands: [IOSNowPlayingCommand] = []
  var count: Int { lock.withLock { commands.count } }
  func append(_ command: IOSNowPlayingCommand) { lock.withLock { commands.append(command) } }
}
