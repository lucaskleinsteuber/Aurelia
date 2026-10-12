import AppKit
import Foundation
@preconcurrency import VLCKit
import XCTest

@testable import Aurelia

/// Overlay only into an external source archive of 1.4.0 or 1.4.1. This file is
/// intentionally outside the active test target and never changes production code.
/// Both runs use the same generated source files/IDs and matching archived
/// production server/client versions, with separate owned databases/certificates.
@MainActor
final class PlaybackHistoricalBaselineTests: XCTestCase {
  func testPinnedSyntheticStartupAndControls() async {
    var controller: PlaybackController?
    var window: NSWindow?
    var samples: [[String: Any]] = []
    var phase = "configuration"
    var version = "unknown"
    var passed = false
    var failures: [[String: Any]] = []
    var httpSamples: [[String: Any]] = []
    var diagnostics: [String: Any] = [:]
    var formatOutcomes: [String: String] = [:]
    var serverVersion = "unknown"
    defer {
      window?.orderOut(nil)
      window?.close()
      let document: [String: Any] = [
        "formatVersion": 1, "passed": passed, "phase": phase,
        "clientVersion": version, "serverVersion": serverVersion, "samples": samples,
        "failureContexts": failures, "httpSamples": httpSamples,
        "closedControllerDiagnostics": diagnostics,
        "formatOutcomes": formatOutcomes,
        "scope": "Owned synthetic catalog; real pinned HTTPS, relay and normal VLC outputs.",
        "limitations": [
          "No personal media or installed app changes.",
          "Not a human picture/hearing check or an active-stream outage test.",
        ],
      ]
      let data =
        (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
        ?? Data()
      let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
      attachment.name = "Historical synthetic playback baseline"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    do {
      let environment = ProcessInfo.processInfo.environment
      guard environment["AURELIA_BASELINE_OWNED_TEST_STATE"] == "YES",
        environment["AURELIA_UI_TEST_MODE"] != nil,
        NativePreflightIsolation.isRequested, !NativePreflightIsolation.isActive,
        let address = environment["AURELIA_BASELINE_SERVER_URL"],
        let url = URL(string: address), url.scheme == "https", url.host == "127.0.0.1",
        let port = url.port, port >= 1_024,
        let pin = environment["AURELIA_BASELINE_FINGERPRINT"], pin.count == 64,
        pin.allSatisfy(\.isHexDigit),
        let authentication = environment["AURELIA_BASELINE_AUTH"]?.data(using: .utf8),
        let fixtureBytes = environment["AURELIA_BASELINE_FIXTURES"]?.data(using: .utf8),
        let rootPath = environment["AURELIA_BASELINE_RUN_ROOT"],
        rootPath.hasPrefix("/"), rootPath.contains("/Library/Caches/Aurelia/TestRuns/"),
        let expectedServerVersion = environment["AURELIA_BASELINE_EXPECTED_SERVER_VERSION"]
      else { throw Failure.code("missing_owned_baseline_configuration") }
      version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "unknown"
      #if AURELIA_BASELINE_REVISIONED_PROGRESS
        try require(version == "1.4.1", "wrong_revisioned_client_version")
      #else
        try require(version == "1.4.0", "wrong_legacy_client_version")
      #endif
      let root = URL(fileURLWithPath: rootPath, isDirectory: true)
      try require(root.resolvingSymlinksInPath().path == root.path, "noncanonical_run_root")
      let fixtures = try JSONDecoder().decode([Fixture].self, from: fixtureBytes)
      try require(
        Set(fixtures.map(\.format)) == Set(["AVI", "MP4", "MKV"])
          && fixtures.count == 3, "wrong_synthetic_fixture_set")
      phase = "owned_server_pin"
      let inspected = try await APIClient.inspect(baseURL: url)
      try require(
        inspected.publicKeyFingerprint.caseInsensitiveCompare(pin) == .orderedSame
          && inspected.info.name == "Aurelia Historical Baseline"
          && inspected.info.version == expectedServerVersion
          && inspected.info.version == version, "wrong_owned_server_or_pin")
      serverVersion = inspected.info.version
      let profile = APIClient.profile(
        authentication: try JSONDecoder().decode(AuthenticationResponse.self, from: authentication),
        inspected: inspected)
      let api = APIClient(profile: profile)
      let movies = try await api.movies()
      try require(
        movies.count == 3
          && fixtures.allSatisfy { fixture in
            movies.contains {
              $0.id == fixture.mediaId && $0.title == "Full Chain \(fixture.format)"
            }
          }, "catalog_not_the_exact_owned_synthetic_set")

      let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
      let outputWindow = NSWindow(
        contentRect: view.frame, styleMask: [.titled],
        backing: .buffered, defer: false)
      outputWindow.isReleasedWhenClosed = false
      outputWindow.title = "Aurelia historical synthetic playback baseline"
      outputWindow.contentView = view
      outputWindow.makeKeyAndOrderFront(nil)
      window = outputWindow
      var preferences = PlaybackPreferences.defaultValue
      preferences.automaticResume = false
      preferences.automaticallyPlayNextEpisode = false
      preferences.preventSleepDuringPlayback = false
      preferences.defaultVolume = 0.05
      for fixture in fixtures {
        do {
          phase = "\(fixture.format)_pinned_http_probe"
          let source = try await api.createPlayback(mediaId: fixture.mediaId)
          do {
            let trust = TLSTrustDelegate(mode: .pinned(pin), allowedHost: "127.0.0.1")
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 10
            sessionConfiguration.timeoutIntervalForResource = 15
            let session = URLSession(
              configuration: sessionConfiguration, delegate: trust, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            for method in ["HEAD", "GET"] {
              var request = URLRequest(url: try api.streamURL(path: source.streamPath))
              request.httpMethod = method
              request.setValue("Bearer \(profile.token)", forHTTPHeaderField: "Authorization")
              if method == "GET" { request.setValue("bytes=0-63", forHTTPHeaderField: "Range") }
              let (bytes, response) = try await session.data(for: request)
              let status = (response as? HTTPURLResponse)?.statusCode ?? 0
              httpSamples.append([
                "format": fixture.format, "method": method, "status": status,
                "bytes": bytes.count, "authorizedContentLength": source.contentLength,
              ])
              try require(
                status == (method == "HEAD" ? 200 : 206)
                  && bytes.count == (method == "HEAD" ? 0 : 64), "pinned_http_probe_failed")
            }
            try await api.revokePlayback(id: source.id)
          } catch {
            try? await api.revokePlayback(id: source.id)
            throw error
          }
          phase = "\(fixture.format)_startup"
          var player: VLCMediaPlayer?
          let engine = VLCPlaybackEngine(playerFactory: {
            let created = VLCMediaPlayer(options: VLCPlaybackEngine.defaultPlayerOptions)
            player = created
            return created
          })
          let client = APIPlaybackClient(profile: profile)
          let presentation = PlaybackPresentation(
            mediaId: fixture.mediaId,
            title: "Synthetic \(fixture.format)", subtitle: nil)
          let relay: (URL, String) throws -> any PlaybackRelayProtocol = { source, fingerprint in
            try LoopbackStreamRelay(
              sourceURL: source, publicKeyFingerprint: fingerprint,
              authorizationToken: profile.token)
          }
          #if AURELIA_BASELINE_REVISIONED_PROGRESS
            let playback = PlaybackController(
              client: client, presentation: presentation,
              engine: engine, preferences: preferences, relayFactory: relay,
              progressOutbox: PlaybackProgressOutbox(
                storageURL: root.appendingPathComponent("baseline-\(fixture.format)-outbox.json")))
          #else
            let playback = PlaybackController(
              client: client, presentation: presentation,
              engine: engine, preferences: preferences, relayFactory: relay)
          #endif
          controller = playback
          playback.attachVideoView(view)
          let started = ContinuousClock.now
          // Keep historical startup inside the same output deadline; awaiting an
          // older non-cooperative preparation operation must not hang this test.
          let startupTask = Task { @MainActor in await playback.start() }
          defer { startupTask.cancel() }
          try await wait(playback, seconds: 20) {
            let stats = player?.media?.statistics
            return playback.isPlaying && playback.currentTimeMilliseconds >= 500
              && (stats?.decodedVideo ?? 0) > 0 && (stats?.displayedPictures ?? 0) > 0
              && (stats?.decodedAudio ?? 0) > 0 && (stats?.playedAudioBuffers ?? 0) > 0
          }
          try require(abs(playback.durationMilliseconds - 64_000) <= 1_500, "wrong_duration")
          let startup = started.duration(to: .now).components
          let startupSeconds = Double(startup.seconds) + Double(startup.attoseconds) / 1e18
          phase = "\(fixture.format)_seek"
          for position: Int64 in [5_000, 40_000, 12_000] {
            playback.seek(to: position)
            try await wait(playback, seconds: 15) {
              playback.isPlaying
                && (position + 400...position + 4_000)
                  .contains(playback.currentTimeMilliseconds)
            }
          }
          phase = "\(fixture.format)_pause_resume"
          playback.togglePlayback()
          try await wait(playback, seconds: 5) { !playback.isPlaying }
          let paused = playback.currentTimeMilliseconds
          try await Task.sleep(for: .seconds(2))
          try require(
            abs(playback.currentTimeMilliseconds - paused) <= 500
              && playback.errorMessage == nil && playback.recoveryMessage == nil, "pause_failed")
          playback.togglePlayback()
          try await wait(playback, seconds: 15) {
            playback.isPlaying && playback.currentTimeMilliseconds >= paused + 400
          }
          phase = "\(fixture.format)_120_second_baseline"
          let minimumSeconds = min(
            max(Double(environment["AURELIA_BASELINE_MINIMUM_SECONDS"] ?? "120") ?? 120, 120), 600)
          let baselineStart = ContinuousClock.now
          let baselineDeadline = baselineStart.advanced(by: .seconds(minimumSeconds))
          var lastTime = playback.currentTimeMilliseconds
          var lastMovement = ContinuousClock.now
          var lastSeek = ContinuousClock.now
          var lastOutputCheck = ContinuousClock.now
          var lastVideo = player?.media?.statistics.displayedPictures ?? 0
          var lastAudio = player?.media?.statistics.playedAudioBuffers ?? 0
          while ContinuousClock.now < baselineDeadline {
            try await Task.sleep(for: .seconds(1))
            try require(
              playback.errorMessage == nil && playback.recoveryMessage == nil,
              "baseline_reported_failure")
            let time = playback.currentTimeMilliseconds
            if time > lastTime + 250 {
              lastMovement = .now
              lastTime = time
            }
            try require(
              lastMovement.duration(to: .now) < .seconds(15), "baseline_stopped_advancing")
            if lastOutputCheck.duration(to: .now) >= .seconds(5) {
              let video = player?.media?.statistics.displayedPictures ?? 0
              let audio = player?.media?.statistics.playedAudioBuffers ?? 0
              try require(video > lastVideo && audio > lastAudio, "baseline_output_stopped")
              lastVideo = video
              lastAudio = audio
              lastOutputCheck = .now
            }
            if time > 50_000 || lastSeek.duration(to: .now) >= .seconds(20) {
              playback.seek(to: 5_000)
              lastTime = 5_000
              lastMovement = .now
              lastSeek = .now
            }
          }
          let elapsed = baselineStart.duration(to: .now).components
          if let stats = player?.media?.statistics {
            samples.append([
              "format": fixture.format, "startupSeconds": startupSeconds,
              "baselineSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
              "positionMilliseconds": playback.currentTimeMilliseconds,
              "durationMilliseconds": playback.durationMilliseconds,
              "decodedVideo": stats.decodedVideo, "displayedPictures": stats.displayedPictures,
              "decodedAudio": stats.decodedAudio, "playedAudioBuffers": stats.playedAudioBuffers,
            ])
          }
          await playback.shutdown(saveProgress: false)
          controller = nil
          formatOutcomes[fixture.format] = "passed"
        } catch {
          #if AURELIA_BASELINE_REVISIONED_PROGRESS
            if let controller, let data = try? controller.diagnostics.export(),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
              diagnostics[fixture.format] = document
            }
          #endif
          var context = Self.safeContext(error)
          context["format"] = fixture.format
          context["phase"] = phase
          let code = Self.failureCode(error)
          context["testCode"] = code
          failures.append(context)
          formatOutcomes[fixture.format] = "failed"
          if let controller { await controller.shutdown(saveProgress: false) }
          controller = nil
          XCTFail("Historical synthetic baseline failed at \(phase): \(code)")
        }
      }
      passed = failures.isEmpty && formatOutcomes.count == 3
      phase = passed ? "complete" : "complete_with_playback_failures"
    } catch {
      #if AURELIA_BASELINE_REVISIONED_PROGRESS
        if let controller, let data = try? controller.diagnostics.export(),
          let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
          diagnostics["configuration"] = document
        }
      #endif
      failures.append(Self.safeContext(error))
      if let controller { await controller.shutdown(saveProgress: false) }
      // Never emit server descriptions, token URLs, titles, paths or credentials.
      XCTFail("Historical synthetic baseline failed at \(phase): \(Self.failureCode(error))")
    }
  }

  private func wait(
    _ playback: PlaybackController, seconds: Double,
    predicate: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !predicate() {
      try require(playback.errorMessage == nil, "controller_reported_failure")
      try require(ContinuousClock.now < deadline, "phase_timed_out")
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func require(_ condition: Bool, _ code: String) throws {
    if !condition { throw Failure.code(code) }
  }

  private static func safeContext(_ error: Error) -> [String: Any] {
    let allowed = [
      "media_unavailable", "media_file_unavailable", "media_not_found",
      "media_not_playable", "invalid_session", "access_denied", "approval_required",
    ]
    if let api = error as? APIClientError {
      return [
        "httpStatus": api.httpStatus ?? 0,
        "problemCode": allowed.contains(api.problemCode ?? "") ? api.problemCode! : "none",
      ]
    }
    let value = error as NSError
    return [
      "domain": value.domain == NSURLErrorDomain ? NSURLErrorDomain : "other", "code": value.code,
    ]
  }

  private static func failureCode(_ error: Error) -> String {
    if case Failure.code(let value) = error { return value }
    return "operation_failed_\((error as NSError).code)"
  }

  private struct Fixture: Decodable {
    let format: String
    let mediaId: UUID
  }
  private enum Failure: Error { case code(String) }
}
