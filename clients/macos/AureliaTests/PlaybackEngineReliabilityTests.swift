import AppKit
import Foundation
import Testing
@preconcurrency import VLCKit

@testable import Aurelia

@Suite(.serialized)
@MainActor
struct PlaybackEngineReliabilityTests {
  @Test
  func reloadKeepsVideoSurfaceAndRequestedPlaybackSettings() async throws {
    var players: [VLCMediaPlayer] = []
    let engine = VLCPlaybackEngine(playerFactory: {
      let player = Self.testPlayer()
      players.append(player)
      return player
    })
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    engine.attach(to: view)
    engine.volume = 0.35
    engine.isMuted = true
    engine.playbackRate = 1.5
    engine.load(url: URL(string: "http://127.0.0.1:1/synthetic-first.avi")!)
    let firstPlayer = try #require(players.last)
    #expect(firstPlayer.drawable as? NSView === view)

    engine.stop()
    #expect(firstPlayer.drawable == nil)
    #expect(firstPlayer.media == nil)
    engine.load(url: URL(string: "http://127.0.0.1:1/synthetic-next.avi")!)
    let nextPlayer = try #require(players.last)
    #expect(nextPlayer !== firstPlayer)
    #expect(nextPlayer.drawable as? NSView === view)
    #expect(engine.volume == 0.35)
    #expect(engine.isMuted)
    #expect(engine.playbackRate == 1.5)
    engine.stop()
  }

  @Test
  func notificationsFromRetiredInputDoNotUpdateReplacement() async throws {
    var players: [VLCMediaPlayer] = []
    let engine = VLCPlaybackEngine(playerFactory: {
      let player = Self.testPlayer()
      players.append(player)
      return player
    })
    engine.load(url: URL(string: "http://127.0.0.1:1/synthetic-first.avi")!)
    let firstPlayer = try #require(players.last)
    var updates = 0
    var terminalEvents = 0
    engine.onUpdate = { updates += 1 }
    engine.onEnded = { terminalEvents += 1 }
    engine.onError = { _ in terminalEvents += 1 }
    engine.stop()
    engine.load(url: URL(string: "http://127.0.0.1:1/synthetic-next.avi")!)
    NotificationCenter.default.post(
      name: Notification.Name(rawValue: VLCMediaPlayerTimeChanged), object: firstPlayer)
    NotificationCenter.default.post(
      name: Notification.Name(rawValue: VLCMediaPlayerStateChanged), object: firstPlayer)
    for _ in 0..<8 { await Task.yield() }
    #expect(updates == 0)
    #expect(terminalEvents == 0)
    engine.stop()
  }

  @Test
  func syntheticVideoDecodesAfterReloadAndRetainsTerminalPosition() async throws {
    let fixture = FileManager.default.temporaryDirectory
      .appendingPathComponent("Aurelia-Engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let url = fixture.appendingPathComponent("synthetic.avi")
    try Self.syntheticAVI().write(to: url)
    var players: [VLCMediaPlayer] = []
    let engine = VLCPlaybackEngine(playerFactory: {
      let player = Self.testPlayer()
      players.append(player)
      return player
    })
    defer { engine.stop() }
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    engine.attach(to: view)
    var errors: [String] = []
    var ends = 0
    var endedPosition: Int64 = 0
    var endedDuration: Int64 = 0
    var observations: [String] = []
    let diagnostics = {
      let player = players.last
      return "state=\(String(describing: player?.state)), playing=\(engine.isPlaying), "
        + "rawTime=\(player?.time.value?.int64Value ?? -1), cachedTime=\(engine.currentTimeMilliseconds), "
        + "duration=\(engine.durationMilliseconds), ends=\(ends), errors=\(errors), "
        + "events=\(observations.suffix(12))"
    }
    engine.onUpdate = {
      observations.append(
        "\(String(describing: players.last?.state))@\(engine.currentTimeMilliseconds)")
    }
    engine.onError = { errors.append($0) }
    engine.onEnded = {
      ends += 1
      endedPosition = engine.currentTimeMilliseconds
      endedDuration = engine.durationMilliseconds
    }

    engine.load(url: url)
    engine.play()
    try await Self.waitUntil("first decode", diagnostics: diagnostics) {
      engine.isPlaying && engine.currentTimeMilliseconds >= 500
    }
    engine.pause()
    try await Self.waitUntil("pause", diagnostics: diagnostics) { !engine.isPlaying }
    let pausedPosition = engine.currentTimeMilliseconds
    try await Task.sleep(for: .milliseconds(150))
    #expect(abs(engine.currentTimeMilliseconds - pausedPosition) <= 150)
    engine.seek(to: 1_500)
    engine.play()
    try await Self.waitUntil("seek and resume", diagnostics: diagnostics) {
      engine.isPlaying && engine.currentTimeMilliseconds >= 1_800
    }
    let retired = try #require(players.last)
    engine.stop()
    engine.load(url: url)
    #expect(players.last?.drawable as? NSView === view)
    #expect(players.last !== retired)
    engine.play()
    try await Self.waitUntil("reloaded natural EOF", diagnostics: diagnostics) {
      ends == 1 || !errors.isEmpty
    }
    print("Synthetic VLC terminal evidence: \(diagnostics())")
    #expect(errors.isEmpty)
    #expect(ends == 1)
    #expect(endedDuration == 3_000)
    #expect(endedPosition >= endedDuration - 1_000)
    #expect(engine.currentTimeMilliseconds == endedPosition)
    #expect(engine.durationMilliseconds == endedDuration)
    for _ in 0..<5 {
      NotificationCenter.default.post(
        name: Notification.Name(rawValue: VLCMediaPlayerStateChanged), object: players.last)
    }
    for _ in 0..<8 { await Task.yield() }
    #expect(ends == 1)
  }

  @Test
  func realEngineCompletesEpisodeAndAdvancesControllerQueue() async throws {
    let fixture = FileManager.default.temporaryDirectory
      .appendingPathComponent("Aurelia-Queue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let url = fixture.appendingPathComponent("synthetic.avi")
    try Self.syntheticAVI().write(to: url)
    let firstID = UUID()
    let nextID = UUID()
    let client = SyntheticPlaybackClient(url: url, nextID: nextID)
    var players: [VLCMediaPlayer] = []
    let engine = VLCPlaybackEngine(playerFactory: {
      let player = Self.testPlayer()
      players.append(player)
      return player
    })
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    var preferences = PlaybackPreferences.defaultValue
    preferences.preventSleepDuringPlayback = false
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: firstID, title: "Synthetic episode 1", subtitle: nil,
        queue: [PlaybackQueueItem(mediaId: nextID, title: "Synthetic episode 2", subtitle: nil)]),
      engine: engine, preferences: preferences,
      relayFactory: { sourceURL, _ in SyntheticPlaybackRelay(url: sourceURL) })
    controller.attachVideoView(view)
    await controller.start()
    do {
      try await Self.waitUntil(
        "real engine to controller automatic next",
        diagnostics: {
          "media=\(controller.presentation.mediaId), playing=\(controller.isPlaying), "
            + "time=\(controller.currentTimeMilliseconds), duration=\(controller.durationMilliseconds), "
            + "state=\(String(describing: players.last?.state)), "
            + "error=\(controller.errorMessage ?? "none"), recovery=\(controller.recoveryMessage ?? "none"), "
            + "created=\(client.createdMediaIDs), updates=\(client.updates)"
        },
        {
          controller.presentation.mediaId == nextID && controller.isPlaying
            && controller.currentTimeMilliseconds >= 1_000
        })
      #expect(client.createdMediaIDs == [firstID, nextID])
      #expect(client.updates.contains { $0.mediaID == firstID && $0.finished })
      #expect(!client.updates.contains { $0.mediaID == nextID && $0.finished })
      #expect(players.count == 3)
      #expect(players.last?.drawable as? NSView === view)
      #expect(controller.errorMessage == nil)
      #expect(controller.recoveryMessage == nil)
      await controller.shutdown()
      #expect(client.updates.last?.mediaID == nextID)
      #expect(client.updates.last?.finished == false)
    } catch {
      await controller.shutdown(saveProgress: false)
      throw error
    }
  }

  @Test
  func syntheticDecoderRecoverySoakKeepsPositionAndSurface() async throws {
    // Short mode runs in the ordinary suite; a dedicated test host can opt in
    // to a 1–2 hour synthetic soak without ever opening personal media.
    let requested =
      Double(ProcessInfo.processInfo.environment["AURELIA_PLAYBACK_SOAK_SECONDS"] ?? "15") ?? 15
    let seconds = min(max(requested, 15), 7_200)
    let fixture = FileManager.default.temporaryDirectory
      .appendingPathComponent("Aurelia-Soak-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let url = fixture.appendingPathComponent("synthetic.avi")
    try Self.syntheticAVI().write(to: url)
    let initialAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let client = SyntheticPlaybackClient(url: url, nextID: UUID())
    var latestPlayer: VLCMediaPlayer?
    let engine = VLCPlaybackEngine(playerFactory: {
      let player = Self.testPlayer()
      latestPlayer = player
      return player
    })
    var preferences = PlaybackPreferences.defaultValue
    preferences.preventSleepDuringPlayback = false
    preferences.automaticallyPlayNextEpisode = false
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(mediaId: UUID(), title: "Synthetic soak", subtitle: nil),
      engine: engine, preferences: preferences,
      relayFactory: { sourceURL, _ in SyntheticPlaybackRelay(url: sourceURL) },
      recoverySleep: { _ in try await Task.sleep(for: .milliseconds(100)) })
    let surface = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    controller.attachVideoView(surface)
    await controller.start()
    let diagnostics = {
      "time=\(controller.currentTimeMilliseconds), playing=\(controller.isPlaying), "
        + "loads=\(client.createdMediaIDs.count), recovery=\(controller.recoveryMessage ?? "none"), "
        + "error=\(controller.errorMessage ?? "none")"
    }
    do {
      try await Self.waitUntil("soak first decode", diagnostics: diagnostics) {
        controller.isPlaying && controller.currentTimeMilliseconds >= 500
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
      var iterations = 0
      var recoveries = 0
      while ContinuousClock.now < deadline {
        controller.seek(to: 500)
        try await Self.waitUntil("soak seek", diagnostics: diagnostics) {
          controller.isPlaying && controller.currentTimeMilliseconds >= 750
        }
        if iterations.isMultiple(of: 3) {
          let loads = client.createdMediaIDs.count
          engine.onError?("Synthetic arbitrary decoder error containing no real data")
          try await Self.waitUntil("soak recovery", diagnostics: diagnostics) {
            client.createdMediaIDs.count > loads && controller.isPlaying
              && controller.currentTimeMilliseconds >= 750
          }
          recoveries += 1
        }
        if iterations.isMultiple(of: 5) {
          controller.togglePlayback()
          try await Self.waitUntil("soak pause", diagnostics: diagnostics) { !controller.isPlaying }
          controller.togglePlayback()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.errorMessage == nil)
        #expect(latestPlayer?.drawable as? NSView === surface)
        iterations += 1
      }
      #expect(iterations >= 6)
      #expect(recoveries >= 2)
      #expect(
        controller.diagnostics.events.contains {
          $0.kind == .recoveryStarted && $0.cause == .decoderError
        })
      #expect(controller.diagnostics.events.count <= PlaybackDiagnostics.capacity)
      await controller.shutdown()
      let finalAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
      #expect(initialAttributes[.size] as? Int == finalAttributes[.size] as? Int)
      #expect(
        initialAttributes[.modificationDate] as? Date == finalAttributes[.modificationDate] as? Date
      )
      print(
        "Synthetic VLC soak evidence: requested=\(seconds)s, iterations=\(iterations), recoveries=\(recoveries)"
      )
    } catch {
      await controller.shutdown(saveProgress: false)
      throw error
    }
  }

  private static func testPlayer() -> VLCMediaPlayer {
    // Exercise the real demuxer/decoder without requiring a visible video
    // window or audio hardware. Surface attachment is asserted separately.
    VLCMediaPlayer(
      options: VLCPlaybackEngine.defaultPlayerOptions + [
        "--vout=dummy", "--aout=dummy", "--no-osd",
      ])
  }

  private static func waitUntil(
    _ phase: String,
    diagnostics: () -> String,
    _ predicate: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !predicate() {
      guard ContinuousClock.now < deadline else {
        Issue.record("Synthetic VLC timeout during \(phase): \(diagnostics())")
        throw CocoaError(.fileReadUnknown)
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  // Tiny uncompressed AVI generated entirely from test-pattern bytes; no user
  // media, codec tool, network download, or binary fixture is used.
  private static func syntheticAVI() -> Data {
    let width: UInt32 = 64
    let height: UInt32 = 48
    let frameCount: UInt32 = 30
    let frameBytes = width * height * 3
    var main = Data()
    for value: UInt32 in [
      100_000, frameBytes * 10, 0, 0x10, frameCount, 0, 1,
      frameBytes, width, height, 0, 0, 0, 0,
    ] { main.append(little(value)) }
    var stream = Data("vidsDIB ".utf8)
    stream.append(little(UInt32(0)))
    stream.append(little(UInt16(0)))
    stream.append(little(UInt16(0)))
    for value: UInt32 in [0, 1, 10, 0, frameCount, frameBytes, .max, 0] {
      stream.append(little(value))
    }
    for value: UInt16 in [0, 0, UInt16(width), UInt16(height)] {
      stream.append(little(value))
    }
    var format = little(UInt32(40))
    format.append(little(width))
    format.append(little(height))
    format.append(little(UInt16(1)))
    format.append(little(UInt16(24)))
    for value: UInt32 in [0, frameBytes, 0, 0, 0, 0] { format.append(little(value)) }
    let streamList = chunk(
      "LIST", Data("strl".utf8) + chunk("strh", stream) + chunk("strf", format))
    let header = chunk("LIST", Data("hdrl".utf8) + chunk("avih", main) + streamList)
    var movie = Data("movi".utf8)
    var index = Data()
    for frame in 0..<frameCount {
      let offset = UInt32(movie.count)
      var pixels = Data(capacity: Int(frameBytes))
      for y in 0..<height {
        for x in 0..<width {
          pixels.append(UInt8((x * 4 + frame * 8) % 256))
          pixels.append(UInt8((y * 5 + frame * 3) % 256))
          pixels.append(UInt8((frame * 8) % 256))
        }
      }
      movie.append(chunk("00db", pixels))
      index.append(Data("00db".utf8))
      index.append(little(UInt32(0x10)))
      index.append(little(offset))
      index.append(little(frameBytes))
    }
    return chunk("RIFF", Data("AVI ".utf8) + header + chunk("LIST", movie) + chunk("idx1", index))
  }

  private static func chunk(_ name: String, _ contents: Data) -> Data {
    var result = Data(name.utf8) + little(UInt32(contents.count)) + contents
    if contents.count % 2 != 0 { result.append(0) }
    return result
  }

  private static func little<T: FixedWidthInteger>(_ value: T) -> Data {
    var encoded = value.littleEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
  }
}

@MainActor
private final class SyntheticPlaybackClient: PlaybackClientProtocol {
  struct Update: CustomStringConvertible {
    let mediaID: UUID
    let finished: Bool
    var description: String { "\(mediaID):finished=\(finished)" }
  }

  let profile = StoredServerProfile(
    serverId: UUID(), name: "Synthetic engine test",
    baseURL: URL(string: "https://server.test:43111")!,
    publicKeyFingerprint: String(repeating: "A", count: 64), token: "synthetic-test-token",
    sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
  let url: URL
  let nextID: UUID
  private(set) var createdMediaIDs: [UUID] = []
  private(set) var updates: [Update] = []

  init(url: URL, nextID: UUID) {
    self.url = url
    self.nextID = nextID
  }

  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
    createdMediaIDs.append(mediaId)
    return PlaybackSourceResponse(
      id: UUID(), mediaId: mediaId, streamPath: "/synthetic.avi",
      contentType: "video/x-msvideo", contentLength: 1,
      expiresAt: "2099-01-01T12:00:00Z",
      progress: progress(mediaID: mediaId, position: mediaId == nextID ? 500 : 0, finished: false))
  }

  func updatePlaybackProgress(
    mediaId: UUID, positionMilliseconds: Int64, durationMilliseconds: Int64, isFinished: Bool
  ) async throws -> PlaybackProgressResponse {
    updates.append(Update(mediaID: mediaId, finished: isFinished))
    return progress(mediaID: mediaId, position: positionMilliseconds, finished: isFinished)
  }

  func revokePlayback(id: UUID) async throws {}
  func streamURL(path: String) throws -> URL { url }

  private func progress(mediaID: UUID, position: Int64, finished: Bool) -> PlaybackProgressResponse
  {
    PlaybackProgressResponse(
      mediaId: mediaID, positionMilliseconds: position, durationMilliseconds: 3_000,
      isCompleted: finished, lastPlayedAt: nil, updatedAt: nil)
  }
}

@MainActor
private final class SyntheticPlaybackRelay: PlaybackRelayProtocol {
  let url: URL
  init(url: URL) { self.url = url }
  func start() async throws -> URL { url }
  func updateSourceURL(_ url: URL) {}
  func stop() {}
}
