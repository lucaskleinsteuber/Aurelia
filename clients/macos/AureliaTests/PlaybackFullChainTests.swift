import AVFoundation
import AppKit
import CryptoKit
import Foundation
@preconcurrency import VLCKit
import XCTest

@testable import Aurelia

/// A required release gate, provisioned by scripts/test-playback-full-chain.sh.
/// This deliberately fails when unconfigured instead of silently skipping playback.
/// All requests and decoding use production implementations; only media/setup are synthetic.
@MainActor
final class PlaybackFullChainTests: XCTestCase {
  func testPackagedPinnedServerRelayAndRealVideoAudio() async {
    await runFullChain(episodeOnly: false)
  }

  /// A quick, real EOF investigation, never a substitute for the release gate.
  func testAutomaticEpisodeHandoffDiagnostic() async {
    await runFullChain(episodeOnly: true)
  }

  private func runFullChain(episodeOnly: Bool) async {
    let evidence = FullChainEvidence()
    var temporaryDirectory: URL?
    var controller: PlaybackController?
    var window: NSWindow?
    var latestPlayer: VLCMediaPlayer?
    defer {
      window?.orderOut(nil)
      window?.close()
      if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
      let attachment = XCTAttachment(data: evidence.json(), uniformTypeIdentifier: "public.json")
      attachment.name = "Full chain playback evidence"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    do {
      evidence.phase = "configuration"
      let configuration = try FullChainConfiguration()
      evidence.requestedSoakSeconds = configuration.soakSeconds
      evidence.formatFilter = episodeOnly ? "episode-handoff" : configuration.formatFilter
      evidence.pauseSeconds = configuration.pauseSeconds
      evidence.clientVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      evidence.clientBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      // A client-container temporary directory can be unreadable to the standalone
      // packaged server. The wrapper provides one explicit owned shared fixture root.
      let root = configuration.mediaRoot
        .appendingPathComponent("Aurelia-FullChain-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      temporaryDirectory = root
      evidence.phase = "synthetic_media_generation"
      let fixtures = try await FullChainSyntheticMedia.generate(
        in: root.appendingPathComponent("Movies"))
      let initialAttributes = try fixtures.map { try Self.attributes($0.url) }

      evidence.phase = "pinned_server_inspection"
      let inspected = try await APIClient.inspect(baseURL: configuration.baseURL)
      try Self.require(
        inspected.publicKeyFingerprint.caseInsensitiveCompare(configuration.fingerprint)
          == .orderedSame,
        "server_pin_does_not_match_owned_certificate")
      try Self.require(
        inspected.info.version == configuration.serverVersion, "wrong_packaged_server_version")
      evidence.serverVersion = inspected.info.version
      evidence.check("owned_certificate_pin_verified")
      let deviceProfile = APIClient.profile(
        authentication: configuration.authentication, inspected: inspected)
      var profile = try await unlockViewingProfile(
        device: deviceProfile, configuration: configuration, evidence: evidence)
      var api = APIClient(profile: profile)
      let setup = FullChainPinnedRequests(profile: profile, evidence: evidence)
      evidence.phase = "synthetic_library_provisioning"
      let body = try JSONEncoder().encode(
        CreateLibraryRequest(
          name: "Full chain synthetic movies",
          path: root.appendingPathComponent("Movies").path, kind: .movies,
          combineExisting: false, requireImportPreview: false))
      let approvalBody = try JSONSerialization.data(
        withJSONObject: [
          "action": "POST /api/v1/libraries",
          "payloadHash": SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
          "password": configuration.password,
        ], options: .sortedKeys)
      let approvalBytes = try await setup.request(
        path: "/api/v1/server/approval", method: "POST",
        body: approvalBody, expected: 200, tag: "library_approval")
      struct Approval: Decodable { let token: String }
      let approval = try JSONDecoder().decode(Approval.self, from: approvalBytes)
      let libraryBytes = try await setup.request(
        path: "/api/v1/libraries", method: "POST", body: body,
        headers: ["X-Aurelia-Approval": approval.token], expected: 201, tag: "create_library")
      let library = try JSONDecoder().decode(LibrarySummary.self, from: libraryBytes)
      let scan = try await api.startLibraryScan(id: library.id)
      let scanDeadline = ContinuousClock.now.advanced(by: .seconds(30))
      while true {
        let current = try await api.scan(id: scan.id)
        if current.state == .completed { break }
        try Self.require(
          current.state != .failed && current.state != .interrupted,
          "synthetic_library_scan_failed")
        try Self.require(ContinuousClock.now < scanDeadline, "synthetic_library_scan_timed_out")
        try await Task.sleep(for: .milliseconds(100))
      }
      let movies = try await api.movies()
      try Self.require(movies.count == fixtures.count, "synthetic_catalog_is_incomplete")
      let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
      let playbackWindow = NSWindow(
        contentRect: view.frame, styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      playbackWindow.isReleasedWhenClosed = false
      playbackWindow.title = "Aurelia synthetic full chain playback"
      playbackWindow.contentView = view
      playbackWindow.center()
      playbackWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      window = playbackWindow
      let engine = VLCPlaybackEngine(playerFactory: {
        let player = VLCMediaPlayer(options: VLCPlaybackEngine.defaultPlayerOptions)
        latestPlayer = player
        return player
      })
      var preferences = PlaybackPreferences.defaultValue
      preferences.preventSleepDuringPlayback = false
      preferences.automaticallyPlayNextEpisode = false
      preferences.automaticResume = false
      preferences.defaultVolume = 0.15

      for (index, fixture) in fixtures.enumerated() {
        if episodeOnly { continue }
        if let selected = configuration.formatFilter, fixture.name != selected { continue }
        evidence.phase = "\(fixture.name)_catalog"
        guard
          let movie = movies.first(where: {
            $0.title == "Full Chain \(fixture.name)" && $0.availability == .available
          })
        else {
          throw FullChainFailure.failed("synthetic_\(fixture.name)_movie_missing")
        }
        evidence.phase = "\(fixture.name)_http_ranges"
        try await verifyRanges(api: api, mediaID: movie.id, fixture: fixture, evidence: evidence)
        evidence.phase = "\(fixture.name)_first_video_audio"
        let outboxStorage = root.appendingPathComponent("progress-\(index).json")
        let outbox = PlaybackProgressOutbox(storageURL: outboxStorage)
        try Self.require(!outbox.storageFailed, "isolated_progress_storage_unavailable")
        var observedClient = FullChainObservedClient(profile: profile, evidence: evidence)
        let playbackProfile = profile
        var playback = PlaybackController(
          client: observedClient,
          presentation: PlaybackPresentation(
            mediaId: movie.id, title: "Synthetic \(fixture.name)", subtitle: nil),
          engine: engine, preferences: preferences,
          relayFactory: { url, fingerprint in
            try LoopbackStreamRelay(
              sourceURL: url, publicKeyFingerprint: fingerprint,
              authorizationToken: playbackProfile.token)
          }, progressOutbox: outbox)
        controller = playback
        playback.attachVideoView(view)
        await playback.start()
        try await waitForOutput(playback, player: { latestPlayer }, evidence: evidence)
        try Self.require(
          observedClient.firstTicketLifetime >= 330 && observedClient.firstTicketLifetime <= 365,
          "isolated_short_ticket_policy_is_missing")
        try Self.require(
          abs(playback.durationMilliseconds - fixture.durationMilliseconds) <= 1_500,
          "synthetic_duration_incorrect")
        evidence.check("\(fixture.name)_real_video_and_audio_output")

        for target: Int64 in [5_000, 40_000, 12_000, 48_000, 18_000] {
          evidence.phase = "\(fixture.name)_seek"
          playback.seek(to: target)
          try await waitUntil(playback, evidence: evidence, seconds: 15) {
            playback.isPlaying && playback.currentTimeMilliseconds >= target + 400
              && playback.currentTimeMilliseconds <= target + 4_000
          }
        }
        // Rapid seek churn must not turn cancellation of a prior read into an outage.
        for target: Int64 in [2_000, 35_000, 6_000, 44_000, 9_000] { playback.seek(to: target) }
        try await waitUntil(playback, evidence: evidence, seconds: 15) {
          playback.isPlaying && (9_400...13_000).contains(playback.currentTimeMilliseconds)
        }
        evidence.check("\(fixture.name)_forward_backward_and_rapid_seek")

        evidence.phase = "\(fixture.name)_pause"
        playback.togglePlayback()
        try await waitUntil(playback, evidence: evidence, seconds: 5) { !playback.isPlaying }
        let pausePosition = playback.currentTimeMilliseconds
        // MP4 pauses longer than the configured normal request timeout. A suspended
        // URLSession task itself has disabled timers; resume still must preserve state.
        let pause = fixture.name == "MP4" ? configuration.pauseSeconds : 2
        try await Task.sleep(for: .seconds(pause))
        try Self.require(
          abs(playback.currentTimeMilliseconds - pausePosition) <= 500,
          "intentional_pause_changed_position")
        try Self.require(
          playback.errorMessage == nil && playback.recoveryMessage == nil,
          "intentional_pause_reported_outage")
        playback.seek(to: 25_000)
        try await Task.sleep(for: .milliseconds(300))
        try Self.require(!playback.isPlaying, "paused_seek_started_playback")
        evidence.phase = "\(fixture.name)_pause_resume"
        playback.togglePlayback()
        try await waitUntil(playback, evidence: evidence, seconds: 15) {
          playback.isPlaying && (25_500...30_000).contains(playback.currentTimeMilliseconds)
        }
        try await waitForOutput(playback, player: { latestPlayer }, evidence: evidence)
        evidence.check("\(fixture.name)_pause_seek_and_resume")

        do {
          evidence.phase = "\(fixture.name)_continuous_baseline"
          let continuousPlayer = latestPlayer
          let started = ContinuousClock.now
          let seconds = fixture.name == "MP4" ? configuration.soakSeconds : 120
          let deadline = started.advanced(by: .seconds(seconds))
          var lastPosition = playback.currentTimeMilliseconds
          var lastMovement = ContinuousClock.now
          var lastSeek = ContinuousClock.now
          var lastSeekTarget: Int64 = 25_000
          var lastOutputCheck = ContinuousClock.now
          var lastDisplayed = latestPlayer?.media?.statistics.displayedPictures ?? 0
          var lastPlayedAudio = latestPlayer?.media?.statistics.playedAudioBuffers ?? 0
          var samples = 0
          while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            evidence.captureContinuous(
              player: latestPlayer, controller: playback,
              elapsedMilliseconds: Int64(Self.seconds(started.duration(to: .now)) * 1_000),
              lastSeekAgeMilliseconds: Int64(Self.seconds(lastSeek.duration(to: .now)) * 1_000),
              lastSeekTargetMilliseconds: lastSeekTarget,
              successfulTicketCount: observedClient.sourceCount)
            try Self.require(
              playback.errorMessage == nil && playback.recoveryMessage == nil,
              "continuous_baseline_reported_playback_failure")
            let position = playback.currentTimeMilliseconds
            if position > lastPosition + 250 {
              lastMovement = ContinuousClock.now
              lastPosition = position
            }
            try Self.require(
              lastMovement.duration(to: .now) < .seconds(15),
              "continuous_baseline_stopped_advancing")
            if lastOutputCheck.duration(to: .now) >= .seconds(5) {
              let displayed = latestPlayer?.media?.statistics.displayedPictures ?? 0
              let audio = latestPlayer?.media?.statistics.playedAudioBuffers ?? 0
              try Self.require(
                displayed > lastDisplayed && audio > lastPlayedAudio,
                "continuous_baseline_video_or_audio_output_stopped")
              lastDisplayed = displayed
              lastPlayedAudio = audio
              lastOutputCheck = .now
            }
            if position > 50_000 || lastSeek.duration(to: .now) > .seconds(20) {
              playback.seek(to: 5_000)
              lastSeek = .now
              lastSeekTarget = 5_000
              lastMovement = .now
              lastPosition = 5_000
              evidence.captureContinuous(
                player: latestPlayer, controller: playback,
                elapsedMilliseconds: Int64(Self.seconds(started.duration(to: .now)) * 1_000),
                lastSeekAgeMilliseconds: 0, lastSeekTargetMilliseconds: lastSeekTarget,
                successfulTicketCount: observedClient.sourceCount)
            }
            samples += 1
            if samples.isMultiple(of: 60) {
              print(
                "Full chain playback output: format=\(fixture.name); elapsed=\(Int(Self.seconds(started.duration(to: .now))))s; position=\(position)ms; video=\(lastDisplayed); audio=\(lastPlayedAudio)"
              )
            }
          }
          let elapsed = Self.seconds(started.duration(to: .now))
          evidence.baselineSeconds[fixture.name] = elapsed
          try Self.require(
            latestPlayer === continuousPlayer,
            "decoder_reloaded_during_continuous_baseline")
          evidence.capture(controller: playback, label: evidence.phase)
          evidence.check("\(fixture.name)_at_least_120_seconds_real_video_audio")
          if fixture.name == "MP4" {
            evidence.actualSoakSeconds = elapsed
            evidence.soakSamples = samples
            try Self.require(
              observedClient.sourceCount >= 2
                && observedClient.latestExpiry > observedClient.firstExpiry,
              "real_client_ticket_renewal_not_observed")
            evidence.renewedTickets = observedClient.sourceCount - 1
            evidence.check("real_client_renewed_server_issued_ticket")
            evidence.check("MP4_real_api_https_relay_vlc_soak")
          }
        }
        if fixture.name == "MP4" {
          let resumed = try await verifyServerInterruptions(
            playback, client: observedClient, api: api, configuration: configuration,
            device: deviceProfile, view: view, engine: engine, preferences: preferences,
            outbox: outbox,
            player: { latestPlayer }, evidence: evidence)
          playback = resumed.playback
          observedClient = resumed.client
          api = resumed.api
          profile = resumed.profile
          controller = playback
        }
        if fixture.name == "MKV" {
          try await verifyOwnedSourceInterruption(
            playback, client: observedClient, folder: root.appendingPathComponent("Movies"),
            player: { latestPlayer }, evidence: evidence)
        }
        evidence.phase = "\(fixture.name)_shutdown_progress"
        // The production progress policy deliberately resets the first ten
        // seconds and marks a 64-second fixture complete from 30 seconds onward.
        // A wall-clock soak can end on either side after its repeated seeks.
        // Choose a meaningful unfinished position instead of depending on that
        // unrelated endpoint, then require the real asynchronous save to arrive.
        playback.seek(to: 15_000)
        try await waitUntil(playback, evidence: evidence, seconds: 15) {
          playback.isPlaying && (15_400...19_000).contains(playback.currentTimeMilliseconds)
        }
        let progressBeforeShutdown = try await api.playbackProgress(mediaId: movie.id)
        evidence.captureProgress(
          outbox: outbox, storage: outboxStorage, profile: profile, mediaID: movie.id,
          server: progressBeforeShutdown, label: "\(fixture.name)_before_shutdown")
        evidence.capture(player: latestPlayer, label: fixture.name)
        await playback.shutdown()
        try Self.require(!playback.isPlaying, "shutdown_kept_playback_running")
        // The production durable queue uses bounded retry delays up to60s.
        // Waiting must observe that real policy, not manually clear attempts,
        // resolve conflicts or overwrite the server's concurrency revision.
        let progressDeadline = ContinuousClock.now.advanced(by: .seconds(65))
        var progress = try await api.playbackProgress(mediaId: movie.id)
        evidence.captureProgress(
          outbox: outbox, storage: outboxStorage, profile: profile, mediaID: movie.id,
          server: progress, label: "\(fixture.name)_after_shutdown")
        while !((progress.revision ?? 0) > (progressBeforeShutdown.revision ?? 0)
          && !progress.isCompleted && (10_001...29_999).contains(progress.positionMilliseconds))
          && ContinuousClock.now < progressDeadline
        {
          try await Task.sleep(for: .milliseconds(100))
          progress = try await api.playbackProgress(mediaId: movie.id)
        }
        evidence.captureProgress(
          outbox: outbox, storage: outboxStorage, profile: profile, mediaID: movie.id,
          server: progress, label: "\(fixture.name)_progress_wait_complete")
        try Self.require(
          !outbox.storageFailed && outbox.state(media: movie.id, profile: profile) != .conflict
            && (progress.revision ?? 0) > (progressBeforeShutdown.revision ?? 0)
            && !progress.isCompleted && (10_001...29_999).contains(progress.positionMilliseconds),
          "real_progress_missing_or_marked_finished")
        evidence.check("\(fixture.name)_real_progress_saved")
        controller = nil
      }
      if episodeOnly || configuration.formatFilter == nil {
        try await verifyAutomaticEpisodeHandoff(
          api: api, profile: profile, configuration: configuration, fixtures: fixtures,
          root: root, view: view, evidence: evidence)
      }
      evidence.phase = "fixture_integrity"
      for (index, fixture) in fixtures.enumerated() {
        try Self.require(
          try Self.attributes(fixture.url) == initialAttributes[index], "synthetic_fixture_changed")
      }
      evidence.check("generated_fixture_sizes_and_modification_dates_unchanged")
      evidence.phase = "complete"
      evidence.testSucceeded = true
      evidence.passed =
        !episodeOnly && configuration.formatFilter == nil && configuration.soakSeconds >= 1_800
        && evidence.actualSoakSeconds >= 1_800 && evidence.clientConfiguration == "Release"
      if let selected = evidence.formatFilter {
        print(
          "Full chain diagnostic subset succeeded: format=\(selected); required_full_gate_complete=false"
        )
      } else if evidence.passed {
        print(
          "Full chain playback passed: formats=AVI,MP4,MKV; real_video_audio=true; soak=\(Int(evidence.actualSoakSeconds))s"
        )
      } else {
        print(
          "Full chain diagnostic all-format suite succeeded: formats=AVI,MP4,MKV; real_video_audio=true; soak=\(Int(evidence.actualSoakSeconds))s; required_full_gate_complete=false"
        )
      }
    } catch {
      evidence.capture(player: latestPlayer, label: "failure_before_shutdown")
      if let controller {
        // Capture before shutdown changes phase/state or records cleanup failures.
        evidence.capture(controller: controller, label: "failure_before_shutdown")
        await controller.shutdown(saveProgress: false)
      }
      evidence.failure = Self.redacted(error)
      XCTFail("Full chain playback failed at \(evidence.phase): \(evidence.failure ?? "unknown")")
    }
  }

  private func verifyAutomaticEpisodeHandoff(
    api: APIClient, profile: StoredServerProfile, configuration: FullChainConfiguration,
    fixtures: [FullChainSyntheticMedia.Fixture], root: URL, view: NSView,
    evidence: FullChainEvidence
  ) async throws {
    evidence.phase = "series_generated_episode_provisioning"
    guard let generated = fixtures.first(where: { $0.name == "MP4" }),
      generated.url.standardizedFileURL.path.hasPrefix(root.path + "/Movies/")
    else { throw FullChainFailure.failed("owned_generated_episode_source_missing") }
    let seriesRoot = root.appendingPathComponent("Series")
    let seasonFolder = seriesRoot.appendingPathComponent("Full Chain Episodes/Season 1")
    try FileManager.default.createDirectory(
      at: seasonFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // Only copies a fixture generated inside this exact run, never personal media.
    for number in 1...2 {
      try FileManager.default.copyItem(
        at: generated.url,
        to: seasonFolder.appendingPathComponent(
          "Full Chain Episodes - S01E0\(number) - Synthetic Episode \(number).mp4"))
    }
    let setup = FullChainPinnedRequests(profile: profile, evidence: evidence)
    // The mandatory soak outlasts the ten-minute administration unlock.
    // Request a fresh unlock instead of granting a permanent test exemption.
    _ = try await api.unlockManagement(password: configuration.password)
    let body = try JSONEncoder().encode(
      CreateLibraryRequest(
        name: "Full chain synthetic episodes", path: seriesRoot.path, kind: .tvShows,
        combineExisting: false, requireImportPreview: false))
    let approvalBody = try JSONSerialization.data(
      withJSONObject: [
        "action": "POST /api/v1/libraries",
        "payloadHash": SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
        "password": configuration.password,
      ], options: .sortedKeys)
    struct Approval: Decodable { let token: String }
    let approval = try JSONDecoder().decode(
      Approval.self,
      from: try await setup.request(
        path: "/api/v1/server/approval", method: "POST", body: approvalBody,
        expected: 200, tag: "series_library_approval"))
    let library = try JSONDecoder().decode(
      LibrarySummary.self,
      from: try await setup.request(
        path: "/api/v1/libraries", method: "POST", body: body,
        headers: ["X-Aurelia-Approval": approval.token], expected: 201,
        tag: "create_series_library"))
    let scan = try await api.startLibraryScan(id: library.id)
    let scanDeadline = ContinuousClock.now.advanced(by: .seconds(30))
    while true {
      let current = try await api.scan(id: scan.id)
      if current.state == .completed { break }
      try Self.require(
        current.state != .failed && current.state != .interrupted,
        "synthetic_series_scan_failed")
      try Self.require(ContinuousClock.now < scanDeadline, "synthetic_series_scan_timed_out")
      try await Task.sleep(for: .milliseconds(100))
    }
    let series = try await api.series()
    try Self.require(series.count == 1, "synthetic_series_catalog_is_incomplete")
    let detail = try await api.series(id: series[0].id)
    let episodes = detail.seasons.sorted { $0.number < $1.number }
      .flatMap { $0.episodes.sorted { $0.episodeNumber < $1.episodeNumber } }
    try Self.require(
      episodes.count == 2 && episodes.map(\.seasonNumber) == [1, 1]
        && episodes.map(\.episodeNumber) == [1, 2]
        && episodes.allSatisfy { $0.availability == .available },
      "synthetic_series_episode_assignments_incorrect")
    let first = episodes[0]
    let second = episodes[1]
    let plan = try await api.playbackPlan(mediaId: series[0].id)
    try Self.require(
      plan.target?.id == first.id && plan.queue.map(\.id) == [second.id]
        && plan.action == .play,
      "packaged_series_playback_plan_incorrect")
    guard let presentation = plan.presentation else {
      throw FullChainFailure.failed("packaged_series_playback_plan_unavailable")
    }
    evidence.check("packaged_series_playback_plan_and_queue")
    var latestPlayer: VLCMediaPlayer?
    let engine = VLCPlaybackEngine(playerFactory: {
      let player = VLCMediaPlayer(options: VLCPlaybackEngine.defaultPlayerOptions)
      latestPlayer = player
      return player
    })
    var preferences = PlaybackPreferences.defaultValue
    preferences.preventSleepDuringPlayback = false
    preferences.automaticallyPlayNextEpisode = true
    preferences.automaticResume = true
    preferences.defaultVolume = 0.15
    let outbox = PlaybackProgressOutbox(
      storageURL: root.appendingPathComponent("series-progress.json"))
    try Self.require(!outbox.storageFailed, "isolated_series_progress_storage_unavailable")
    let client = FullChainObservedClient(profile: profile, evidence: evidence)
    func makeController() -> PlaybackController {
      let controller = PlaybackController(
        client: client, presentation: presentation, engine: engine, preferences: preferences,
        relayFactory: { url, fingerprint in
          try LoopbackStreamRelay(
            sourceURL: url, publicKeyFingerprint: fingerprint,
            authorizationToken: profile.token)
        }, progressOutbox: outbox)
      let ended = engine.onEnded
      engine.onEnded = {
        evidence.capture(player: latestPlayer, label: "series_actual_native_eof_before_controller")
        ended?()
      }
      return controller
    }
    var playback = makeController()
    do {
      evidence.phase = "series_real_unfinished_progress"
      playback.attachVideoView(view)
      await playback.start()
      try await waitForOutput(playback, player: { latestPlayer }, evidence: evidence)
      playback.seek(to: 15_000)
      try await waitUntil(playback, evidence: evidence, seconds: 15) {
        playback.isPlaying && (15_400...19_000).contains(playback.currentTimeMilliseconds)
      }
      await playback.shutdown()
      let saveDeadline = ContinuousClock.now.advanced(by: .seconds(65))
      var saved = try await api.playbackProgress(mediaId: first.id)
      while (saved.isCompleted || !(10_001...29_999).contains(saved.positionMilliseconds))
        && ContinuousClock.now < saveDeadline
      {
        try await Task.sleep(for: .milliseconds(100))
        saved = try await api.playbackProgress(mediaId: first.id)
      }
      try Self.require(
        !saved.isCompleted && (10_001...29_999).contains(saved.positionMilliseconds)
          && (saved.revision ?? 0) > 0, "synthetic_episode_unfinished_progress_missing")
      let resumePlan = try await api.playbackPlan(mediaId: series[0].id)
      try Self.require(
        resumePlan.target?.id == first.id && resumePlan.queue.map(\.id) == [second.id]
          && resumePlan.action == .resume,
        "packaged_series_resume_plan_incorrect")
      evidence.check("packaged_series_resume_plan_from_actual_progress")
      evidence.phase = "series_resume_from_actual_saved_progress"
      playback = makeController()
      playback.attachVideoView(view)
      await playback.start()
      try await waitUntil(playback, evidence: evidence, seconds: 30) {
        playback.isPlaying && playback.presentation.mediaId == first.id
          && playback.currentTimeMilliseconds >= saved.positionMilliseconds + 400
          && playback.currentTimeMilliseconds <= saved.positionMilliseconds + 6_000
      }
      try await waitForOutput(playback, player: { latestPlayer }, evidence: evidence)
      evidence.check("series_real_saved_progress_automatic_resume")
      let firstPlayer = latestPlayer
      evidence.phase = "series_natural_decoder_eof_and_automatic_next_episode"
      playback.seek(to: 58_000)
      try await waitUntil(playback, evidence: evidence, seconds: 15) {
        playback.presentation.mediaId == first.id && playback.isPlaying
          && (58_400...62_000).contains(playback.currentTimeMilliseconds)
      }
      // No onEnded injection, manual next command or presentation mutation:
      // let the real decoder reach EOF and the production controller advance.
      try await waitUntil(playback, evidence: evidence, seconds: 30) {
        playback.presentation.mediaId == second.id && playback.isPlaying
          && (500...15_000).contains(playback.currentTimeMilliseconds)
      }
      try await waitForOutput(playback, player: { latestPlayer }, evidence: evidence)
      try Self.require(
        latestPlayer !== firstPlayer && playback.presentation.queue.isEmpty
          && playback.diagnostics.events.filter { $0.kind == .ended }.count == 1
          && playback.diagnostics.events.filter { $0.kind == .nextEpisode }.count == 1,
        "natural_eof_handoff_or_queue_consumption_missing")
      evidence.capture(controller: playback, label: evidence.phase)
      evidence.capture(player: latestPlayer, label: "series_second_episode_actual_output")
      let completionDeadline = ContinuousClock.now.advanced(by: .seconds(65))
      var completed = try await api.playbackProgress(mediaId: first.id)
      while !completed.isCompleted && ContinuousClock.now < completionDeadline {
        try await Task.sleep(for: .milliseconds(100))
        completed = try await api.playbackProgress(mediaId: first.id)
      }
      try Self.require(
        completed.isCompleted && completed.durationMilliseconds == generated.durationMilliseconds
          && (completed.revision ?? 0) > (saved.revision ?? 0)
          && client.completedProgressWrites > 0 && client.lastCompletedMediaID == first.id
          && outbox.state(media: first.id, profile: profile) != .conflict,
        "real_finished_episode_progress_not_saved")
      evidence.check("series_real_decoder_eof_automatic_next_video_audio_and_completion")
      await playback.shutdown()
    } catch {
      evidence.capture(controller: playback, label: "series_handoff_failure_before_shutdown")
      evidence.capture(player: latestPlayer, label: "series_handoff_failure_output")
      await playback.shutdown(saveProgress: false)
      throw error
    }
  }

  private func verifyRanges(
    api: APIClient, mediaID: UUID, fixture: FullChainSyntheticMedia.Fixture,
    evidence: FullChainEvidence
  ) async throws {
    let source = try await api.createPlayback(mediaId: mediaID)
    try Self.require(source.contentType == fixture.contentType, "content_type_mismatch")
    let direct = FullChainPinnedRequests(profile: api.profile, evidence: evidence)
    _ = try await direct.request(
      path: source.streamPath, method: "HEAD", expected: 200,
      tag: "\(fixture.name)_pinned_server_HEAD")
    _ = try await direct.request(
      path: source.streamPath, method: "GET",
      headers: ["Range": "bytes=0-63"], expected: 206, tag: "\(fixture.name)_pinned_server_range")
    let relay = try LoopbackStreamRelay(
      sourceURL: api.streamURL(path: source.streamPath),
      publicKeyFingerprint: api.profile.publicKeyFingerprint, authorizationToken: api.profile.token)
    let local = try await relay.start()
    defer { relay.stop() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let fixtureBytes = try Data(contentsOf: fixture.url)
    try Self.require(source.contentLength == fixtureBytes.count, "content_length_mismatch")
    var head = URLRequest(url: local)
    head.httpMethod = "HEAD"
    let (headBytes, headResponse) = try await session.data(for: head)
    evidence.http(tag: "\(fixture.name)_relay_HEAD", response: headResponse, bytes: headBytes.count)
    try Self.require(
      (headResponse as? HTTPURLResponse)?.statusCode == 200 && headBytes.isEmpty,
      "relay_head_failed")
    for (range, expected) in [
      ("bytes=0-63", Data(fixtureBytes.prefix(64))),
      ("bytes=4096-4159", Data(fixtureBytes[4_096..<4_160])),
      ("bytes=-64", Data(fixtureBytes.suffix(64))),
      ("bytes=\(fixtureBytes.count - 64)-", Data(fixtureBytes.suffix(64))),
    ] {
      var request = URLRequest(url: local)
      request.setValue(range, forHTTPHeaderField: "Range")
      let (bytes, response) = try await session.data(for: request)
      evidence.http(tag: "\(fixture.name)_relay_range", response: response, bytes: bytes.count)
      try Self.require(
        (response as? HTTPURLResponse)?.statusCode == 206 && bytes == expected,
        "relay_range_body_or_status_incorrect")
    }
    var first = URLRequest(url: local)
    first.setValue("bytes=0-63", forHTTPHeaderField: "Range")
    var second = URLRequest(url: local)
    second.setValue("bytes=4096-4159", forHTTPHeaderField: "Range")
    async let firstRequest = session.data(for: first)
    async let secondRequest = session.data(for: second)
    let (firstResult, secondResult) = try await (firstRequest, secondRequest)
    evidence.http(
      tag: "\(fixture.name)_relay_parallel_first", response: firstResult.1,
      bytes: firstResult.0.count)
    evidence.http(
      tag: "\(fixture.name)_relay_parallel_second", response: secondResult.1,
      bytes: secondResult.0.count)
    try Self.require(
      firstResult.0 == Data(fixtureBytes.prefix(64))
        && secondResult.0 == Data(fixtureBytes[4_096..<4_160]), "relay_parallel_ranges_incorrect")
    var invalid = URLRequest(url: local)
    invalid.setValue("bytes=\(fixtureBytes.count + 100)-", forHTTPHeaderField: "Range")
    let (invalidBytes, invalidResponse) = try await session.data(for: invalid)
    evidence.http(
      tag: "\(fixture.name)_relay_unsatisfied", response: invalidResponse, bytes: invalidBytes.count
    )
    try Self.require(
      (invalidResponse as? HTTPURLResponse)?.statusCode == 416, "relay_416_incorrect")
    relay.stop()
    try await api.revokePlayback(id: source.id)
    evidence.check("\(fixture.name)_real_https_head_closed_open_suffix_and_416_ranges")
  }

  private func waitForOutput(
    _ playback: PlaybackController, player: () -> VLCMediaPlayer?,
    evidence: FullChainEvidence
  ) async throws {
    // Retain zero/missing counters too; advancing time alone is not output.
    defer { evidence.capture(player: player(), label: evidence.phase) }
    try await waitUntil(playback, evidence: evidence, seconds: 20) {
      guard playback.isPlaying, playback.currentTimeMilliseconds >= 500,
        let statistics = player()?.media?.statistics
      else { return false }
      return statistics.decodedVideo > 0 && statistics.displayedPictures > 0
        && statistics.decodedAudio > 0 && statistics.playedAudioBuffers > 0
    }
  }

  private func unlockViewingProfile(
    device: StoredServerProfile, configuration: FullChainConfiguration, evidence: FullChainEvidence
  ) async throws -> StoredServerProfile {
    let paired = APIClient(profile: device)
    guard let owner = device.user else {
      throw FullChainFailure.failed("owned_device_has_no_owner_identity")
    }
    let picker = try await paired.watchingProfiles()
    if picker.managementSetupRequired {
      try await paired.initializeProfiles(password: configuration.password, pin: "1234")
    }
    let unlocked = try await paired.unlockProfile(id: owner.id, pin: "1234")
    try Self.require(unlocked.user.id == owner.id, "unlocked_wrong_viewing_profile")
    let viewing = StoredServerProfile(
      serverId: device.serverId, name: device.name, baseURL: device.baseURL,
      publicKeyFingerprint: device.publicKeyFingerprint, token: unlocked.token,
      sessionId: unlocked.sessionId, expiresAt: unlocked.expiresAt, user: unlocked.user,
      viewingSession: true)
    _ = try await APIClient(profile: viewing).unlockManagement(password: configuration.password)
    evidence.check("real_pin_unlock_and_separate_management_authority")
    return viewing
  }

  private func verifyServerInterruptions(
    _ initialPlayback: PlaybackController, client initialClient: FullChainObservedClient,
    api initialAPI: APIClient, configuration: FullChainConfiguration, device: StoredServerProfile,
    view: NSView, engine: VLCPlaybackEngine, preferences: PlaybackPreferences,
    outbox: PlaybackProgressOutbox, player: () -> VLCMediaPlayer?,
    evidence: FullChainEvidence
  ) async throws -> (
    playback: PlaybackController, client: FullChainObservedClient, api: APIClient,
    profile: StoredServerProfile
  ) {
    let control = FullChainServerControl(url: configuration.controlURL, evidence: evidence)
    var playback = initialPlayback
    var client = initialClient
    var api = initialAPI
    var profile = initialAPI.profile
    let presentation = initialPlayback.presentation

    func unlockAndResume() async throws {
      await playback.shutdown(saveProgress: false)
      let unlocked = try await unlockViewingProfile(
        device: device, configuration: configuration, evidence: evidence)
      profile = unlocked
      api = APIClient(profile: unlocked)
      client = FullChainObservedClient(profile: unlocked, evidence: evidence)
      var resumedPreferences = preferences
      resumedPreferences.automaticResume = true
      playback = PlaybackController(
        client: client, presentation: presentation, engine: engine, preferences: resumedPreferences,
        relayFactory: { url, fingerprint in
          try LoopbackStreamRelay(
            sourceURL: url, publicKeyFingerprint: fingerprint, authorizationToken: unlocked.token)
        }, progressOutbox: outbox)
      playback.attachVideoView(view)
      await playback.start()
    }
    do {
      evidence.phase = "MP4_owned_server_restart"
      playback.seek(to: 20_000)
      try await waitUntil(playback, evidence: evidence, seconds: 15) {
        playback.isPlaying && (20_500...24_000).contains(playback.currentTimeMilliseconds)
      }
      let resumePosition = playback.currentTimeMilliseconds
      playback.pause()
      await outbox.flush()
      try Self.require(
        (10_001...29_999).contains(
          try await api.playbackProgress(mediaId: presentation.mediaId).positionMilliseconds),
        "pre_outage_actual_progress_not_saved")
      playback.play()
      let priorFailures = client.failedAuthorizations
      try await control.command("stop", expectRunning: false)
      // A short fixture may already be buffered. A real explicit retry forces
      // fresh production API/transport I/O; no fake engine callback is injected.
      await playback.retry()
      try await waitUntil(playback, evidence: evidence, seconds: 20) {
        client.failedAuthorizations >= priorFailures + 2
      }
      try Self.require(
        client.lastFailure?.cause == .connectionInterrupted,
        "owned_server_stop_did_not_produce_real_connection_error")
      evidence.capture(controller: playback, label: "server_down_repeated_real_failures")
      try await control.command("restart", expectRunning: true)
      try await waitForSamePinnedServer(api: api, evidence: evidence)
      try await waitUntil(playback, evidence: evidence, seconds: 45, allowTerminalFailure: true) {
        playback.errorMessage != nil && !playback.isPreparing && playback.recoveryMessage == nil
      }
      try Self.require(
        client.lastFailure?.httpStatus == 401,
        "server_restart_did_not_end_volatile_viewing_session")
      let expiredAttempts = client.authorizationAttempts
      try await Task.sleep(for: .seconds(3))
      try Self.require(
        client.authorizationAttempts == expiredAttempts && !playback.isPlaying,
        "expired_profile_kept_retrying_without_pin")
      evidence.capture(controller: playback, label: "server_restart_requires_fresh_pin")
      try await unlockAndResume()
      try await waitForOutput(playback, player: player, evidence: evidence)
      try Self.require(
        (resumePosition - 2_000...resumePosition + 12_000).contains(
          playback.currentTimeMilliseconds),
        "fresh_pin_resume_lost_actual_progress")
      evidence.check("owned_server_restart_same_pin_requires_pin_then_resumes_real_output")

      evidence.phase = "MP4_persistent_server_outage_retry_budget"
      let attemptsBeforeOutage = client.authorizationAttempts
      try await control.command("stop", expectRunning: false)
      await playback.retry()
      try await waitUntil(
        playback, evidence: evidence, seconds: 140, allowTerminalFailure: true
      ) {
        playback.errorMessage != nil && playback.recoveryMessage == nil && !playback.isPreparing
      }
      let stoppedAttempts = client.authorizationAttempts
      try Self.require(
        stoppedAttempts >= attemptsBeforeOutage + 3,
        "persistent_outage_did_not_exercise_repeated_real_retries")
      try Self.require(
        playback.diagnostics.events.contains(where: { $0.kind == .recoveryExhausted }),
        "persistent_outage_did_not_exhaust_bounded_recovery")
      try await Task.sleep(for: .seconds(6))
      try Self.require(
        !playback.isPlaying && client.authorizationAttempts == stoppedAttempts,
        "persistent_outage_kept_reconnecting_after_terminal_state")
      evidence.capture(controller: playback, label: "persistent_outage_terminal_no_more_requests")
      evidence.check("persistent_real_outage_stops_with_no_infinite_reconnect")
      try await control.command("restart", expectRunning: true)
      try await waitForSamePinnedServer(api: api, evidence: evidence)
      try await unlockAndResume()
      let progress = try await api.playbackProgress(mediaId: playback.presentation.mediaId)
      try Self.require(!progress.isCompleted, "server_outage_marked_media_finished")
      evidence.phase = "MP4_fresh_pin_after_terminal_outage"
      try await waitUntil(playback, evidence: evidence, seconds: 30) {
        playback.isPlaying && playback.currentTimeMilliseconds >= progress.positionMilliseconds
          && playback.currentTimeMilliseconds <= progress.positionMilliseconds + 12_000
      }
      try await waitForOutput(playback, player: player, evidence: evidence)
      evidence.check("fresh_pin_after_real_terminal_outage_resumes_unfinished_media")
      return (playback, client, api, profile)
    } catch {
      evidence.capture(controller: playback, label: "server_interruption_failure_before_restore")
      await playback.shutdown(saveProgress: false)
      try? await control.command("restart", expectRunning: true)
      throw error
    }
  }

  private func waitForSamePinnedServer(api: APIClient, evidence: FullChainEvidence) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while ContinuousClock.now < deadline {
      do {
        let info = try await api.serverInfo()
        try Self.require(info.serverId == api.profile.serverId, "server_restart_changed_identity")
        evidence.check("server_restart_preserved_identity_and_production_tls_pin")
        return
      } catch let error as FullChainFailure {
        throw error
      } catch {
        evidence.networkFailure(tag: "pinned_restart_readiness", error: error)
        try await Task.sleep(for: .milliseconds(200))
      }
    }
    throw FullChainFailure.failed("same_pin_server_restart_timed_out")
  }

  private func verifyOwnedSourceInterruption(
    _ playback: PlaybackController, client: FullChainObservedClient, folder: URL,
    player: () -> VLCMediaPlayer?, evidence: FullChainEvidence
  ) async throws {
    evidence.phase = "MKV_owned_synthetic_source_offline"
    playback.seek(to: 20_000)
    try await waitUntil(playback, evidence: evidence, seconds: 15) {
      playback.isPlaying && (20_500...24_000).contains(playback.currentTimeMilliseconds)
    }
    let resumePosition = playback.currentTimeMilliseconds
    let priorFailures = client.failedAuthorizations
    let offline = folder.deletingLastPathComponent().appendingPathComponent("Movies-offline")
    // Only this test's newly generated directory is renamed, never a user library.
    try FileManager.default.moveItem(at: folder, to: offline)
    do {
      await playback.retry()
      try await waitUntil(playback, evidence: evidence, seconds: 20) {
        client.failedAuthorizations >= priorFailures + 2
      }
      try Self.require(
        client.lastFailure?.httpStatus == 503
          && client.lastFailure?.problemCode == "media_unavailable",
        "owned_source_offline_did_not_produce_typed_real_503")
      evidence.capture(controller: playback, label: "synthetic_source_offline_real_503_retries")
      try FileManager.default.moveItem(at: offline, to: folder)
      try await waitUntil(playback, evidence: evidence, seconds: 45) {
        playback.isPlaying && playback.recoveryMessage == nil
          && playback.currentTimeMilliseconds >= resumePosition + 400
          && playback.currentTimeMilliseconds <= resumePosition + 12_000
      }
      try await waitForOutput(playback, player: player, evidence: evidence)
      evidence.capture(controller: playback, label: "synthetic_source_restored_real_output")
      evidence.check("owned_synthetic_source_503_repeated_retries_restore_and_resume")
    } catch {
      evidence.capture(controller: playback, label: "source_interruption_failure_before_restore")
      if FileManager.default.fileExists(atPath: offline.path) {
        try? FileManager.default.moveItem(at: offline, to: folder)
      }
      throw error
    }
  }

  private func waitUntil(
    _ playback: PlaybackController, evidence: FullChainEvidence,
    seconds: Double, allowTerminalFailure: Bool = false, predicate: () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !predicate() {
      if !allowTerminalFailure && playback.errorMessage != nil {
        evidence.capture(controller: playback, label: "controller_reported_failure")
        throw FullChainFailure.failed("controller_reported_failure")
      }
      guard ContinuousClock.now < deadline else {
        evidence.capture(controller: playback, label: "phase_timed_out")
        throw FullChainFailure.failed("phase_timed_out")
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private static func attributes(_ url: URL) throws -> [String: String] {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return [
      "size": String(describing: attributes[.size] ?? ""),
      "modified": String(describing: attributes[.modificationDate] ?? ""),
    ]
  }
  private static func require(_ condition: Bool, _ code: String) throws {
    if !condition { throw FullChainFailure.failed(code) }
  }
  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
  private static func redacted(_ error: Error) -> String {
    if case FullChainFailure.failed(let code) = error { return code }
    if case FullChainSyntheticMedia.GenerationError.failed(let code) = error { return code }
    if let api = error as? APIClientError {
      return "api_status_\(api.httpStatus ?? 0)_code_\(api.problemCode ?? "none")"
    }
    let value = error as NSError
    let allowed = [NSURLErrorDomain, NSCocoaErrorDomain, AVFoundationErrorDomain]
    return "\(allowed.contains(value.domain) ? value.domain : "other")_\(value.code)"
  }
}

private enum FullChainFailure: Error { case failed(String) }

@MainActor
private struct FullChainConfiguration {
  let baseURL: URL
  let fingerprint: String
  let authentication: AuthenticationResponse
  let password: String
  let serverVersion: String
  let soakSeconds: Double
  let pauseSeconds: Double
  let controlURL: URL
  let mediaRoot: URL
  let formatFilter: String?
  init() throws {
    let environment = ProcessInfo.processInfo.environment
    // TestRuns is deliberately not an allowed native-helper preflight root.
    // The requested-but-inactive guard rejects ordinary app startup before
    // saved profiles/preferences/registered hosts can be used in Release too.
    guard NativePreflightIsolation.isRequested, !NativePreflightIsolation.isActive,
      let address = environment["AURELIA_FULL_CHAIN_SERVER_URL"],
      let url = URL(string: address), url.scheme == "https", url.host == "127.0.0.1",
      let port = url.port, port >= 1_024,
      let fingerprint = environment["AURELIA_FULL_CHAIN_FINGERPRINT"], fingerprint.count == 64,
      let owner = environment["AURELIA_FULL_CHAIN_OWNER_AUTH"],
      let bytes = owner.data(using: .utf8),
      let password = environment["AURELIA_FULL_CHAIN_PASSWORD"],
      let version = environment["AURELIA_FULL_CHAIN_SERVER_VERSION"],
      let controlAddress = environment["AURELIA_FULL_CHAIN_CONTROL_URL"],
      let controlURL = URL(string: controlAddress), controlURL.scheme == "http",
      controlURL.host == "127.0.0.1", let controlPort = controlURL.port,
      controlPort >= 1_024, controlURL.path.dropFirst().count == 64,
      controlURL.path.dropFirst().allSatisfy({ $0.isHexDigit }),
      let mediaPath = environment["AURELIA_FULL_CHAIN_MEDIA_ROOT"],
      mediaPath.hasPrefix("/"),
      mediaPath.contains("/Library/Caches/Aurelia/TestRuns/full-chain-"),
      mediaPath.hasSuffix("/Fixtures")
    else { throw FullChainFailure.failed("required_isolated_full_chain_configuration_missing") }
    self.baseURL = url
    self.fingerprint = fingerprint
    self.authentication = try JSONDecoder().decode(AuthenticationResponse.self, from: bytes)
    self.password = password
    self.serverVersion = version
    self.controlURL = controlURL
    self.mediaRoot = URL(fileURLWithPath: mediaPath, isDirectory: true).standardizedFileURL
    guard self.mediaRoot.path == mediaPath else {
      throw FullChainFailure.failed("owned_media_root_is_not_canonical")
    }
    self.soakSeconds = min(
      max(Double(environment["AURELIA_FULL_CHAIN_SOAK_SECONDS"] ?? "180") ?? 180, 120), 7_200)
    self.pauseSeconds = min(
      max(Double(environment["AURELIA_FULL_CHAIN_PAUSE_SECONDS"] ?? "35") ?? 35, 31), 120)
    self.formatFilter = environment["AURELIA_FULL_CHAIN_FORMAT_FILTER"]
    if let formatFilter, !["AVI", "MP4", "MKV"].contains(formatFilter) {
      throw FullChainFailure.failed("invalid_diagnostic_format_filter")
    }
  }
}

/// Observation only: every operation delegates to the production API client and
/// retains only successful ticket counts/expiry, never ticket URLs or credentials.
@MainActor
private final class FullChainObservedClient: PlaybackClientProtocol {
  private let production: APIPlaybackClient
  private let evidence: FullChainEvidence
  var profile: StoredServerProfile { production.profile }
  var requiresProgressRevision: Bool { production.requiresProgressRevision }
  private(set) var sourceCount = 0
  private(set) var authorizationAttempts = 0
  private(set) var failedAuthorizations = 0
  private(set) var completedProgressWrites = 0
  private(set) var lastCompletedMediaID: UUID?
  private(set) var lastFailure: PlaybackFailureContext?
  private(set) var firstTicketLifetime: TimeInterval = 0
  private(set) var firstExpiry = Date.distantPast
  private(set) var latestExpiry = Date.distantPast
  init(profile: StoredServerProfile, evidence: FullChainEvidence) {
    production = APIPlaybackClient(profile: profile)
    self.evidence = evidence
  }
  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
    authorizationAttempts += 1
    let result: PlaybackSourceResponse
    do { result = try await production.createPlayback(mediaId: mediaId) } catch {
      failedAuthorizations += 1
      lastFailure = PlaybackFailureContext(error: error, phase: .ticketAuthorization)
      evidence.authorizationFailure(context: lastFailure!, attempt: authorizationAttempts)
      throw error
    }
    guard let expiry = TicketRenewalPolicy.expiration(result.expiresAt) else {
      throw FullChainFailure.failed("server_ticket_expiry_invalid")
    }
    if sourceCount == 0 {
      firstExpiry = expiry
      firstTicketLifetime = expiry.timeIntervalSinceNow
    }
    latestExpiry = expiry
    sourceCount += 1
    return result
  }
  func playbackProgress(mediaId: UUID) async throws -> PlaybackProgressResponse {
    try await production.playbackProgress(mediaId: mediaId)
  }
  func updatePlaybackProgress(
    mediaId: UUID, positionMilliseconds: Int64,
    durationMilliseconds: Int64, isFinished: Bool
  ) async throws -> PlaybackProgressResponse {
    let result = try await production.updatePlaybackProgress(
      mediaId: mediaId, positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds, isFinished: isFinished)
    if isFinished {
      completedProgressWrites += 1
      lastCompletedMediaID = mediaId
    }
    return result
  }
  func updatePlaybackProgress(
    mediaId: UUID, positionMilliseconds: Int64,
    durationMilliseconds: Int64, isFinished: Bool, expectedRevision: Int64,
    clientMutationId: UUID
  ) async throws -> PlaybackProgressResponse {
    let result = try await production.updatePlaybackProgress(
      mediaId: mediaId, positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds, isFinished: isFinished,
      expectedRevision: expectedRevision, clientMutationId: clientMutationId)
    if isFinished {
      completedProgressWrites += 1
      lastCompletedMediaID = mediaId
    }
    return result
  }
  func revokePlayback(id: UUID) async throws { try await production.revokePlayback(id: id) }
  func streamURL(path: String) throws -> URL { try production.streamURL(path: path) }
}

@MainActor
private final class FullChainPinnedRequests {
  let profile: StoredServerProfile
  let evidence: FullChainEvidence
  init(profile: StoredServerProfile, evidence: FullChainEvidence) {
    self.profile = profile
    self.evidence = evidence
  }
  func request(
    path: String, method: String, body: Data? = nil, headers: [String: String] = [:],
    expected: Int, tag: String
  ) async throws -> Data {
    let delegate = TLSTrustDelegate(
      mode: .pinned(profile.publicKeyFingerprint),
      allowedHost: profile.baseURL.host ?? "")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 30
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: profile.baseURL.appendingPathComponent(String(path.dropFirst())))
    request.httpMethod = method
    request.httpBody = body
    request.setValue("Bearer \(profile.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let data: Data
    let response: URLResponse
    do { (data, response) = try await session.data(for: request) } catch {
      evidence.networkFailure(tag: tag, error: error)
      throw error
    }
    evidence.http(tag: tag, response: response, bytes: data.count)
    guard (response as? HTTPURLResponse)?.statusCode == expected else {
      let problem = evidence.setupProblem(tag: tag, data: data)
      throw FullChainFailure.failed(
        "\(tag)_http_\((response as? HTTPURLResponse)?.statusCode ?? 0)_\(problem)")
    }
    return data
  }
}

/// Private test supervisor, separate from production HTTP routes. It exposes
/// no arbitrary command, PID, path, credential or certificate mutation.
@MainActor
private final class FullChainServerControl {
  private let url: URL
  private let evidence: FullChainEvidence
  init(url: URL, evidence: FullChainEvidence) {
    self.url = url
    self.evidence = evidence
  }
  func command(_ action: String, expectRunning: Bool) async throws {
    guard ["stop", "restart"].contains(action) else {
      throw FullChainFailure.failed("invalid_owned_server_control_action")
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 12
    configuration.timeoutIntervalForResource = 15
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url.appendingPathComponent(action))
    request.httpMethod = "POST"
    let (bytes, response) = try await session.data(for: request)
    struct State: Decodable {
      let running: Bool
      let restarts: Int
      let forcedShutdown: Bool
    }
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let state = try? JSONDecoder().decode(State.self, from: bytes),
      state.running == expectRunning, !state.forcedShutdown
    else { throw FullChainFailure.failed("owned_server_control_failed_or_forced_shutdown") }
    evidence.check("owned_server_\(action)_acknowledged")
  }
}

@MainActor
private final class FullChainEvidence {
  var phase = "unconfigured" {
    didSet { print("Full chain playback phase: \(phase)") }
  }
  var passed = false
  var testSucceeded = false
  var formatFilter: String?
  var failure: String?
  var clientVersion: String?
  var clientBuild: String?
  var clientConfiguration: String {
    #if DEBUG
      "Debug"
    #else
      "Release"
    #endif
  }
  var serverVersion: String?
  var requestedSoakSeconds: Double = 0
  var actualSoakSeconds: Double = 0
  var pauseSeconds: Double = 0
  var soakSamples = 0
  var renewedTickets = 0
  var baselineSeconds: [String: Double] = [:]
  var positionMilliseconds: Int64 = 0
  var durationMilliseconds: Int64 = 0
  private var checks: [String] = []
  private var responses: [[String: Any]] = []
  private var outputs: [[String: Any]] = []
  private var continuousSamples: [[String: Any]] = []
  private var failures: [[String: Any]] = []
  private var controllerSnapshots: [[String: Any]] = []
  private var authorizationFailures: [[String: Any]] = []
  private var setupProblems: [[String: String]] = []
  private var progressSnapshots: [[String: Any]] = []
  func check(_ code: String) { checks.append(code) }
  func setupProblem(tag: String, data: Data) -> String {
    // Never retain arbitrary error messages, body data, media paths or credentials.
    let allowed: Set<String> = [
      "invalid_library_path", "unreadable_library_path", "invalid_library_name",
      "invalid_library_kind", "overlapping_library_path", "approval_required",
      "invalid_approval", "owner_required", "owner_session_revoked", "device_session_revoked",
      "invalid_session", "access_denied", "invalid_server_data",
      "server_storage_unavailable", "rate_limited", "request_too_large",
    ]
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let raw = object?["code"] as? String
    let code = raw.flatMap { allowed.contains($0) ? $0 : nil } ?? "unknown_problem"
    setupProblems.append(["phase": tag, "code": code])
    return code
  }
  func http(tag: String, response: URLResponse, bytes: Int) {
    let http = response as? HTTPURLResponse
    responses.append([
      "check": tag, "status": http?.statusCode ?? 0, "bytes": bytes,
      "contentLength": http?.value(forHTTPHeaderField: "Content-Length") ?? "none",
      "contentRange": http?.value(forHTTPHeaderField: "Content-Range") ?? "none",
    ])
  }
  func capture(player: VLCMediaPlayer?, label: String) {
    // A progressing clock alone is not proof of video. Keep zero counters and
    // presence flags on failures, before cleanup clears the current media.
    let stats = player?.media?.statistics
    outputs.append([
      "phase": label, "playerPresent": player != nil,
      "playerState": player.map { Int($0.state.rawValue) } ?? -1,
      "normalizedPosition": player.map { Double($0.position) } ?? -1,
      "remainingMilliseconds": player?.remainingTime?.value?.int64Value ?? -1,
      "mediaPresent": player?.media != nil, "statisticsPresent": stats != nil,
      "isPlaying": player?.isPlaying ?? false,
      "decodedVideo": stats?.decodedVideo ?? 0,
      "displayedPictures": stats?.displayedPictures ?? 0,
      "decodedAudio": stats?.decodedAudio ?? 0,
      "playedAudioBuffers": stats?.playedAudioBuffers ?? 0,
      "lostAudioBuffers": stats?.lostAudioBuffers ?? 0,
      "positionMilliseconds": player?.time.value?.int64Value ?? 0,
      "durationMilliseconds": player?.media?.length.value?.int64Value ?? 0,
    ])
    if outputs.count > 100 { outputs.removeFirst(outputs.count - 100) }
  }
  func captureContinuous(
    player: VLCMediaPlayer?, controller: PlaybackController,
    elapsedMilliseconds: Int64, lastSeekAgeMilliseconds: Int64,
    lastSeekTargetMilliseconds: Int64, successfulTicketCount: Int
  ) {
    // Keep a numeric/boolean ring before recovery clears the decoder's media.
    // No source URLs, identities, titles or arbitrary decoder text are retained.
    let stats = player?.media?.statistics
    let normalizedPosition = Double(player?.position ?? -1)
    let observedPosition =
      Mirror(reflecting: controller).children
      .first { $0.label == "observedPosition" }?.value as? Int64
    let lastMovementAt =
      Mirror(reflecting: controller).children
      .first { $0.label == "lastMovementAt" }?.value as? Date
    var sample: [String: Any] = [
      "phase": phase, "elapsedMilliseconds": elapsedMilliseconds,
      "lastSeekAgeMilliseconds": lastSeekAgeMilliseconds,
      "lastSeekTargetMilliseconds": lastSeekTargetMilliseconds,
      "successfulTicketCount": successfulTicketCount,
      "playerPresent": player != nil, "mediaPresent": player?.media != nil,
      "statisticsPresent": stats != nil,
      "playerState": player.map { Int($0.state.rawValue) } ?? -1,
      "playerIsPlaying": player?.isPlaying ?? false,
      "playerPositionMilliseconds": player?.time.value?.int64Value ?? -1,
      "playerNormalizedPosition":
        player != nil && normalizedPosition.isFinite ? min(1, max(0, normalizedPosition)) : -1,
      "playerRemainingMilliseconds": player?.remainingTime?.value?.int64Value ?? -1,
      "playerIsSeekable": player?.isSeekable ?? false,
      "controllerPositionMilliseconds": controller.currentTimeMilliseconds,
      "controllerDurationMilliseconds": controller.durationMilliseconds,
      "controllerIsPlaying": controller.isPlaying,
      "controllerIsPreparing": controller.isPreparing,
      "hasRecoveryMessage": controller.recoveryMessage != nil,
      "hasTerminalError": controller.errorMessage != nil,
      "decodedVideo": stats?.decodedVideo ?? 0,
      "displayedPictures": stats?.displayedPictures ?? 0,
      "decodedAudio": stats?.decodedAudio ?? 0,
      "playedAudioBuffers": stats?.playedAudioBuffers ?? 0,
      "lostAudioBuffers": stats?.lostAudioBuffers ?? 0,
    ]
    // Reflect only these two named numeric watchdog values. Never export a
    // controller mirror, identities, source objects or unrelated private state.
    if let observedPosition { sample["observedPositionMilliseconds"] = observedPosition }
    if let lastMovementAt {
      let now = Date(timeIntervalSince1970: ProcessInfo.processInfo.systemUptime)
      let age = now.timeIntervalSince(lastMovementAt) * 1_000
      if age.isFinite {
        sample["lastMovementAgeMilliseconds"] = min(120_000, max(0, age))
      }
    }
    continuousSamples.append(sample)
    if continuousSamples.count > 100 {
      continuousSamples.removeFirst(continuousSamples.count - 100)
    }
  }
  func networkFailure(tag: String, error: Error) {
    let value = error as NSError
    let domain =
      [NSURLErrorDomain, NSCocoaErrorDomain].contains(value.domain) ? value.domain : "other"
    failures.append(["phase": tag, "domain": domain, "code": value.code])
    if failures.count > 100 { failures.removeFirst(failures.count - 100) }
  }
  func authorizationFailure(context: PlaybackFailureContext, attempt: Int) {
    // This context is already whitelisted and bounded by production diagnostics.
    authorizationFailures.append([
      "phase": phase, "attempt": attempt, "cause": context.cause.rawValue,
      "diagnosticPhase": context.phase.rawValue, "httpStatus": context.httpStatus ?? 0,
      "urlErrorCode": context.urlErrorCode ?? 0, "problemCode": context.problemCode ?? "none",
      "localReason": context.localReason ?? "none",
    ])
    if authorizationFailures.count > 100 {
      authorizationFailures.removeFirst(authorizationFailures.count - 100)
    }
  }
  func capture(controller: PlaybackController, label: String) {
    positionMilliseconds = controller.currentTimeMilliseconds
    durationMilliseconds = controller.durationMilliseconds
    let exported = (try? controller.diagnostics.export()) ?? Data()
    let document = (try? JSONSerialization.jsonObject(with: exported)) as? [String: Any]
    controllerSnapshots.append([
      "phase": label, "positionMilliseconds": positionMilliseconds,
      "durationMilliseconds": durationMilliseconds, "isPlaying": controller.isPlaying,
      "isPreparing": controller.isPreparing, "hasTerminalError": controller.errorMessage != nil,
      "hasRecoveryMessage": controller.recoveryMessage != nil,
      "closedDiagnosticExport": document ?? [:],
    ])
    if controllerSnapshots.count > 20 {
      controllerSnapshots.removeFirst(controllerSnapshots.count - 20)
    }
  }
  func captureProgress(
    outbox: PlaybackProgressOutbox, storage: URL, profile: StoredServerProfile, mediaID: UUID,
    server: PlaybackProgressResponse, label: String
  ) {
    // This is the explicit synthetic queue under the granted owned fixture
    // root. Retain only closed state/numeric observations, never scope IDs,
    // mutations, filenames, profiles, credentials or the serialized queue.
    var document: [String: Any] = [
      "phase": label, "storageFailed": outbox.storageFailed,
      "capacityReached": outbox.capacityReached,
      "pendingCount": outbox.pendingCount(profile: profile),
      "state": outbox.state(media: mediaID, profile: profile)?.rawValue ?? "none",
      "serverRevision": server.revision ?? 0,
      "serverPositionMilliseconds": server.positionMilliseconds,
      "serverDurationMilliseconds": server.durationMilliseconds,
      "serverIsCompleted": server.isCompleted, "ownedStorageSnapshotAvailable": false,
    ]
    if let bytes = try? Data(contentsOf: storage),
      bytes.count <= PlaybackProgressOutbox.maximumFileBytes,
      let entries = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]]
    {
      document["ownedStorageSnapshotAvailable"] = true
      if let entry = entries.first(where: {
        ($0["media"] as? String)?.caseInsensitiveCompare(mediaID.uuidString) == .orderedSame
      }) {
        if let attempts = entry["attempts"] as? Int, (0...6).contains(attempts) {
          document["retryAttempts"] = attempts
        }
        if let referenceSeconds = entry["nextAttempt"] as? Double {
          let delay = Date(timeIntervalSinceReferenceDate: referenceSeconds).timeIntervalSinceNow
          if delay.isFinite { document["nextAttemptDelaySeconds"] = min(60, max(-120, delay)) }
        }
        if let mutation = entry["mutation"] as? [String: Any],
          let revision = mutation["expectedRevision"] as? Int64, revision >= 0
        {
          document["inFlightExpectedRevision"] = revision
        }
        if let pending = entry["pending"] as? [String: Any] {
          if let position = pending["position"] as? Int64, position >= 0 {
            document["pendingPositionMilliseconds"] = position
          }
          if let finished = pending["finished"] as? Bool { document["pendingFinished"] = finished }
        }
      }
    }
    progressSnapshots.append(document)
    if progressSnapshots.count > 20 { progressSnapshots.removeFirst(progressSnapshots.count - 20) }
  }
  func json() -> Data {
    let document: [String: Any] = [
      "formatVersion": 4, "passed": passed, "testSucceeded": testSucceeded,
      "allFormatSuiteSucceeded": testSucceeded && formatFilter == nil,
      "diagnosticSubsetSucceeded": testSucceeded && !passed,
      "requiredFullGateComplete": passed, "formatFilter": formatFilter ?? "all",
      "requiredMinimumReleaseSoakSeconds": 1_800,
      "phase": phase,
      "failure": failure ?? "none", "clientVersion": clientVersion ?? "unknown",
      "clientConfiguration": clientConfiguration,
      "clientBuild": clientBuild ?? "unknown", "serverVersion": serverVersion ?? "unknown",
      "requestedSoakSeconds": requestedSoakSeconds, "actualSoakSeconds": actualSoakSeconds,
      "pauseSeconds": pauseSeconds, "soakSamples": soakSamples, "renewedTickets": renewedTickets,
      "baselineSecondsByFormat": baselineSeconds,
      "isolatedTicketLifetimeSeconds": 360, "checks": checks,
      "httpResponses": responses, "outputSamples": outputs, "networkFailures": failures,
      "continuousSamples": continuousSamples,
      "authorizationFailures": authorizationFailures, "controllerSnapshots": controllerSnapshots,
      "setupProblems": setupProblems,
      "progressSnapshots": progressSnapshots,
      "positionMilliseconds": positionMilliseconds, "durationMilliseconds": durationMilliseconds,
      "methodology":
        "Owned synthetic fixtures and credentials. Production API, SPKI-pinned HTTPS packaged server, loopback relay and normal VLC video/audio outputs. Ordinary app startup is explicitly rejected before saved profiles or registered hosts are accessed. The same-identity signed test host keeps its sandbox and every original entitlement, plus an exact test-folder grant simulating user-selected folder access. No personal media. No dummy outputs or mock network.",
      "fixtureProfiles": [
        "AVI: uncompressed DIB video and mono 44100 Hz 16-bit PCM, 64 seconds",
        "MP4: H.264 video and AAC audio, moov at end, 64 seconds",
        "MKV: complete MJPEG frames and mono PCM with seek cues, 64 seconds",
      ],
      "limitations": [
        "An optional single-format diagnostic run cannot certify the mandatory all-format gate.",
        "An all-format soak shorter than 1800 seconds is diagnostic only, even when every test case succeeds.",
        "A Debug test-host run is diagnostic only, even with all formats and a 1800-second soak.",
        "Human hearing and picture quality are not automatically verified.",
        "Renewal uses a real 360-second ticket issued only by the isolated Testing server, not natural 12-hour expiry.",
        "No physical external storage or separate physical LAN device is used.",
        "Outages stop the owned server and rename the generated source folder, then force a fresh real retry because short fixtures can be buffered; this is not physical network or drive removal.",
        "HEVC, VP9, subtitles and multiple audio tracks are not covered.",
      ],
    ]
    return
      (try? JSONSerialization.data(
        withJSONObject: document, options: [.prettyPrinted, .sortedKeys])) ?? Data()
  }
}
