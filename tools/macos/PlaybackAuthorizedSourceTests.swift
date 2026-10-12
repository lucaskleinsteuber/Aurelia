import AppKit
import Foundation
@preconcurrency import VLCKit
import XCTest

@testable import Aurelia

/// Overlay only into an owned source snapshot. The server has exactly one
/// offline-provisioned source, never scans its directory, and never connects to
/// the personal server. No controller/outbox/progress writer is instantiated.
@MainActor
final class PlaybackAuthorizedSourceTests: XCTestCase {
  func testExactAuthorizedSourceThroughSixMinutesFortyFiveWithoutProgressWrites() async {
    var engine: VLCPlaybackEngine?
    var relay: LoopbackStreamRelay?
    var api: APIClient?
    var ticketID: UUID?
    var window: NSWindow?
    var phase = "configuration"
    var passed = false
    var samples: [[String: Any]] = []
    var failures: [[String: Any]] = []
    var progressUnchanged = false
    var headStatus = 0
    var version = "unknown"
    let started = ContinuousClock.now
    // This deadline begins before authorization. It bounds actual source reads,
    // not compilation/setup time, and is stricter than the approved ten minutes.
    let deadline = started.advanced(by: .seconds(570))
    defer {
      engine?.stop()
      relay?.stop()
      window?.orderOut(nil)
      window?.close()
      let elapsed = started.duration(to: .now).components
      let document: [String: Any] = [
        "formatVersion": 1, "passed": passed, "phase": phase, "version": version,
        "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
        "requiredPositionMilliseconds": 405_000, "targetPositionMilliseconds": 430_000,
        "maximumSourceReadWallSeconds": 570,
        "pinnedHeadStatus": headStatus, "samples": samples, "failureContexts": failures,
        "ownedProgressSnapshotUnchanged": progressUnchanged,
        "progressWriterInstantiated": false, "sourceDirectoryScan": false,
        "scope":
          "One explicitly authorized original source, played in place via production authorization, pinned HTTPS, real loopback relay and normal VLC video/audio outputs.",
        "limitations": [
          "No personal server/catalog/progress is read or written; the test uses a disposable account/database.",
          "This bounded transport/decoder check deliberately bypasses PlaybackController to prevent all progress writes.",
          "Controller recovery/progress and other formats are covered by the separate synthetic full-chain gate.",
          "Output counters do not replace a human picture/hearing check; no screenshot/audio capture or content analysis is performed.",
        ],
      ]
      let data =
        (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])) ?? Data()
      let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
      attachment.name = "Bounded authorized source playback evidence"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    do {
      let environment = ProcessInfo.processInfo.environment
      guard environment["AURELIA_SOURCE_EVIDENCE_OWNED_STATE"] == "YES",
        environment["AURELIA_SOURCE_EVIDENCE_AUTHORIZATION"] == "BREAKING_BAD_S01E01_10_MINUTES",
        NativePreflightIsolation.isRequested, !NativePreflightIsolation.isActive,
        let address = environment["AURELIA_SOURCE_EVIDENCE_SERVER_URL"],
        let url = URL(string: address), url.scheme == "https", url.host == "127.0.0.1",
        let port = url.port, port >= 1_024,
        let pin = environment["AURELIA_SOURCE_EVIDENCE_FINGERPRINT"], pin.count == 64,
        pin.allSatisfy(\.isHexDigit),
        let authentication = environment["AURELIA_SOURCE_EVIDENCE_AUTH"]?.data(using: .utf8),
        let expectedVersion = environment["AURELIA_SOURCE_EVIDENCE_SERVER_VERSION"],
        let expectedBytesString = environment["AURELIA_SOURCE_EVIDENCE_SOURCE_BYTES"],
        let expectedBytes = Int64(expectedBytesString), expectedBytes > 0,
        let mediaID = UUID(uuidString: environment["AURELIA_SOURCE_EVIDENCE_MEDIA_ID"] ?? "")
      else { throw Failure.code("missing_bounded_authorized_configuration") }
      phase = "owned_server_pin"
      let inspected = try await APIClient.inspect(baseURL: url)
      try require(
        inspected.publicKeyFingerprint.caseInsensitiveCompare(pin) == .orderedSame
          && inspected.info.name == "Aurelia Authorized Playback Evidence"
          && inspected.info.version == expectedVersion, "wrong_owned_server_or_pin")
      version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "unknown"
      try require(version == expectedVersion, "client_server_version_mismatch")
      let profile = APIClient.profile(
        authentication: try JSONDecoder().decode(AuthenticationResponse.self, from: authentication),
        inspected: inspected)
      let client = APIClient(profile: profile)
      api = client
      let movies = try await client.movies()
      try require(
        movies.count == 1 && movies[0].id == mediaID
          && movies[0].title == "Authorized playback evidence",
        "catalog_not_exact_authorized_source")
      let progressBefore = try await client.playbackProgress(mediaId: mediaID)
      try require(
        progressBefore.positionMilliseconds == 0 && progressBefore.durationMilliseconds == 0
          && !progressBefore.isCompleted && progressBefore.lastPlayedAt == nil
          && progressBefore.updatedAt == nil && (progressBefore.revision ?? 0) == 0,
        "owned_progress_not_empty")

      phase = "production_ticket_authorization"
      let source = try await client.createPlayback(mediaId: mediaID)
      ticketID = source.id
      try require(
        source.contentLength == expectedBytes && source.progress == progressBefore,
        "authorized_source_metadata_mismatch")
      let streamURL = try client.streamURL(path: source.streamPath)
      phase = "pinned_head"
      let trust = TLSTrustDelegate(mode: .pinned(pin), allowedHost: "127.0.0.1")
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 10
      configuration.timeoutIntervalForResource = 15
      let session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
      defer { session.invalidateAndCancel() }
      var request = URLRequest(url: streamURL)
      request.httpMethod = "HEAD"
      request.setValue("Bearer \(profile.token)", forHTTPHeaderField: "Authorization")
      let (headBytes, response) = try await session.data(for: request)
      headStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
      try require(
        headStatus == 200 && headBytes.isEmpty && response.expectedContentLength == expectedBytes,
        "pinned_head_failed")

      phase = "relay_startup"
      let streamRelay = try LoopbackStreamRelay(
        sourceURL: streamURL, publicKeyFingerprint: pin, authorizationToken: profile.token)
      relay = streamRelay
      var transportFailure: PlaybackStreamFailure?
      streamRelay.setFailureHandler { transportFailure = $0 }
      let localURL = try await streamRelay.start()
      let view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
      let outputWindow = NSWindow(
        contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
      outputWindow.isReleasedWhenClosed = false
      outputWindow.title = "Aurelia bounded authorized playback evidence"
      outputWindow.contentView = view
      outputWindow.makeKeyAndOrderFront(nil)
      window = outputWindow
      var activePlayer: VLCMediaPlayer?
      let playback = VLCPlaybackEngine(playerFactory: {
        let player = VLCMediaPlayer(options: VLCPlaybackEngine.defaultPlayerOptions)
        activePlayer = player
        return player
      })
      engine = playback
      var engineReportedError = false
      var engineEnded = false
      playback.onError = { _ in engineReportedError = true }
      playback.onEnded = { engineEnded = true }
      playback.volume = 0.05
      playback.playbackRate = 1
      playback.attach(to: view)
      playback.load(url: localURL)
      playback.play()
      phase = "first_audio_video_movement"
      let startupDeadline = ContinuousClock.now.advanced(by: .seconds(30))
      while true {
        if let transportFailure {
          failures.append(Self.safeTransportContext(transportFailure))
          throw Failure.code("relay_reported_startup_failure")
        }
        try require(!engineReportedError && !engineEnded, "engine_reported_startup_failure")
        let statistics = activePlayer?.media?.statistics
        if playback.isPlaying && playback.currentTimeMilliseconds >= 500
          && (statistics?.decodedVideo ?? 0) > 0 && (statistics?.displayedPictures ?? 0) > 0
          && (statistics?.decodedAudio ?? 0) > 0 && (statistics?.playedAudioBuffers ?? 0) > 0
        {
          break
        }
        try require(ContinuousClock.now < startupDeadline, "first_movement_timed_out")
        try await Task.sleep(for: .milliseconds(200))
      }
      try require(
        playback.durationMilliseconds > 430_000 && playback.currentTimeMilliseconds < 5_000,
        "source_too_short_or_did_not_start_at_beginning")
      phase = "continuous_playback_through_6m45s"
      var lastTime = playback.currentTimeMilliseconds
      var lastMovement = ContinuousClock.now
      var lastOutputCheck = ContinuousClock.now
      var lastVideo = activePlayer?.media?.statistics.displayedPictures ?? 0
      var lastAudio = activePlayer?.media?.statistics.playedAudioBuffers ?? 0
      while playback.currentTimeMilliseconds < 430_000 {
        try require(ContinuousClock.now < deadline, "bounded_read_deadline_reached")
        if let transportFailure {
          failures.append(Self.safeTransportContext(transportFailure))
          throw Failure.code("relay_reported_playback_failure")
        }
        try require(!engineReportedError && !engineEnded, "engine_reported_playback_failure")
        let time = playback.currentTimeMilliseconds
        if time > lastTime + 250 {
          lastMovement = .now
          lastTime = time
        }
        try require(lastMovement.duration(to: .now) < .seconds(15), "playback_stopped_advancing")
        if lastOutputCheck.duration(to: .now) >= .seconds(5) {
          let video = activePlayer?.media?.statistics.displayedPictures ?? 0
          let audio = activePlayer?.media?.statistics.playedAudioBuffers ?? 0
          try require(video > lastVideo && audio > lastAudio, "audio_video_output_stopped")
          lastVideo = video
          lastAudio = audio
          lastOutputCheck = .now
          if samples.count < 120 {
            samples.append([
              "positionMilliseconds": time, "durationMilliseconds": playback.durationMilliseconds,
              "displayedPictures": video, "playedAudioBuffers": audio,
            ])
          }
        }
        try await Task.sleep(for: .milliseconds(250))
      }
      samples.append([
        "positionMilliseconds": playback.currentTimeMilliseconds,
        "durationMilliseconds": playback.durationMilliseconds,
        "displayedPictures": activePlayer?.media?.statistics.displayedPictures ?? 0,
        "playedAudioBuffers": activePlayer?.media?.statistics.playedAudioBuffers ?? 0,
      ])
      // Stop all source reads before any further API operation.
      playback.stop()
      streamRelay.stop()
      phase = "unchanged_owned_progress"
      try await client.revokePlayback(id: source.id)
      ticketID = nil
      progressUnchanged = try await client.playbackProgress(mediaId: mediaID) == progressBefore
      try require(progressUnchanged, "unexpected_owned_progress_write")
      phase = "complete"
      passed = true
    } catch {
      engine?.stop()
      relay?.stop()
      if let api, let ticketID { try? await api.revokePlayback(id: ticketID) }
      if let failure = error as? Failure {
        failures.append(["testCode": failure.code])
        XCTFail("Bounded authorized playback failed at \(phase): \(failure.code)")
      } else {
        let context = PlaybackFailureContext(error: error, phase: .ticketAuthorization)
        failures.append(Self.safeContext(context))
        XCTFail("Bounded authorized playback failed at \(phase); closed error context attached.")
      }
    }
  }

  private static func safeContext(_ context: PlaybackFailureContext) -> [String: Any] {
    var document: [String: Any] = [
      "cause": context.cause.rawValue, "phase": context.phase.rawValue,
    ]
    if let status = context.httpStatus { document["httpStatus"] = status }
    if let code = context.urlErrorCode { document["urlErrorCode"] = code }
    if let code = context.problemCode { document["problemCode"] = code }
    if let reason = context.localReason { document["localReason"] = reason }
    if let bytes = context.bytesTransferred { document["bytesTransferred"] = bytes }
    return document
  }

  private static func safeTransportContext(_ failure: PlaybackStreamFailure) -> [String: Any] {
    switch failure {
    case .detailed(let context): safeContext(context)
    case .interrupted: ["cause": "connectionInterrupted", "phase": "streamTransport"]
    case .unavailable: ["cause": "mediaSourceUnavailable", "phase": "streamTransport"]
    case .authorizationDenied: ["cause": "accessDenied", "phase": "streamTransport"]
    case .untrustedServer: ["cause": "serverIdentityMismatch", "phase": "streamTransport"]
    case .invalidResponse: ["cause": "invalidStream", "phase": "streamTransport"]
    }
  }

  private func require(_ condition: Bool, _ code: String) throws {
    if !condition { throw Failure.code(code) }
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
