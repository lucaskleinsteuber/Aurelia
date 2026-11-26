import Foundation
import Testing

@testable import Aurelia

@MainActor
struct PlaybackRenewalReliabilityTests {
  @Test
  func transientFailureRetriesAndRecoversWithoutStoppingPlayback() async throws {
    let fixture = RenewalFixture(outcomes: [
      .failure(URLError(.networkConnectionLost)), .success(()),
    ])
    await fixture.controller.start()
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.clock.waitForSleeps(2)
    #expect(fixture.client.calls == 2)
    #expect(fixture.engine.isPlaying)
    #expect(fixture.controller.errorMessage == nil)
    #expect(fixture.controller.noticeMessage != nil)
    fixture.clock.wake()
    try await fixture.clock.waitForSleeps(3)
    #expect(fixture.client.calls == 3)
    #expect(fixture.controller.errorMessage == nil)
    #expect(fixture.controller.noticeMessage == nil)
    #expect(fixture.engine.isPlaying)
    await fixture.controller.shutdown(saveProgress: false)
    fixture.clock.wake()
  }

  @Test(arguments: [
    APIClientError.serverIdentityMismatch,
    APIClientError.serverRejected(code: "invalid_session", message: "Revoked"),
  ])
  func definitiveFailureStopsRelayAndDoesNotRetry(error: APIClientError) async throws {
    let fixture = RenewalFixture(outcomes: [.failure(error)])
    await fixture.controller.start()
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.client.waitForCalls(2)
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.engine.didStop)
    #expect(fixture.relay.didStop)
    #expect(!fixture.controller.isPlaying)
    #expect(fixture.controller.errorMessage != nil)
    #expect(fixture.clock.count == 1)
    await fixture.controller.shutdown(saveProgress: false)
  }

  @Test
  func closingWhileRetrySleepsPreventsAnotherAuthorizationRequest() async throws {
    let fixture = RenewalFixture(outcomes: [.failure(URLError(.timedOut))])
    await fixture.controller.start()
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.clock.waitForSleeps(2)
    await fixture.controller.shutdown(saveProgress: false)
    fixture.clock.wake()
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.client.calls == 2)
    #expect(fixture.engine.didStop)
  }

  @Test
  func rejectedRenewedStreamURLRevokesTheNewTicketAndPreservesTheFailureCause() async throws {
    let fixture = RenewalFixture(outcomes: [.success(())])
    await fixture.controller.start()
    try await fixture.clock.waitForSleeps(1)
    fixture.client.failNextStreamURL = true
    fixture.clock.wake()
    try await fixture.client.waitForCalls(2)
    for _ in 0..<100 { await Task.yield() }
    #expect(fixture.client.revokedIDs.count == 1)
    #expect(fixture.controller.recoveryCause == .invalidStream)
    #expect(!fixture.controller.isPlaying)
    #expect(!fixture.controller.play())
    #expect(fixture.clock.count == 1)
    await fixture.controller.shutdown(saveProgress: false)
    #expect(fixture.client.revokedIDs.count == 2)
  }

  @Test
  func successfulExplicitRetryRestoresControlsAfterAuthorizationDenial() async throws {
    let fixture = RenewalFixture(outcomes: [
      .failure(APIClientError.httpFailure(status: 401, retryAfter: nil, code: nil, message: nil)),
      .failure(APIClientError.httpFailure(status: 401, retryAfter: nil, code: nil, message: nil)),
      .success(()),
    ])
    await fixture.controller.start()
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.client.waitForCalls(2)
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.controller.errorMessage != nil)
    #expect(!fixture.controller.isPlaying)
    fixture.engine.onEnded?()
    fixture.controller.togglePlayback()
    #expect(!fixture.controller.isPlaying)
    #expect(fixture.client.calls == 2)

    await fixture.controller.retry()
    #expect(fixture.client.calls == 3)
    #expect(fixture.controller.errorMessage != nil)
    fixture.engine.onUpdate?()
    fixture.controller.togglePlayback()
    #expect(!fixture.controller.isPlaying)

    await fixture.controller.retry()
    try await fixture.clock.waitForSleeps(2)
    #expect(fixture.client.calls == 4)
    #expect(fixture.controller.errorMessage == nil)
    #expect(!fixture.controller.isPreparing)
    #expect(fixture.controller.isPlaying)
    fixture.controller.togglePlayback()
    #expect(!fixture.controller.isPlaying)
    fixture.controller.togglePlayback()
    #expect(fixture.controller.isPlaying)
    await fixture.controller.shutdown(saveProgress: false)
    fixture.clock.wake()
  }

  @Test
  func anExpiredTicketCannotRetryAfterNetworkRecovery() async throws {
    let fixture = RenewalFixture(outcomes: [.failure(URLError(.timedOut))], lifetime: 2)
    await fixture.controller.start()
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.clock.waitForSleeps(2)
    fixture.clock.now = fixture.clock.now.addingTimeInterval(3)
    fixture.clock.wake()
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.engine.didStop)
    #expect(fixture.client.calls == 2)
    await fixture.controller.shutdown(saveProgress: false)
  }

  @Test
  func renewalPolicyNeverRetriesCertificateTrustOrAuthenticationFailures() {
    #expect(!TicketRenewalPolicy.isTransient(URLError(.serverCertificateUntrusted)))
    #expect(!TicketRenewalPolicy.isTransient(APIClientError.serverIdentityMismatch))
    #expect(
      !TicketRenewalPolicy.isTransient(
        APIClientError.serverRejected(code: "invalid_session", message: "Revoked")))
    #expect(TicketRenewalPolicy.isTransient(URLError(.timedOut)))
  }

  @Test
  func hangingRenewalIsBoundedWithoutStoppingTheCurrentStreamAndRevokesLateTicket() async throws {
    let fixture = RenewalFixture(
      outcomes: [], timing: PlaybackTimingPolicy(ticketTimeout: 0.02))
    await fixture.controller.start()
    try await fixture.clock.waitForSleeps(1)
    fixture.client.holdNextRequest = true
    fixture.clock.wake()
    try await fixture.client.waitForCalls(2)
    for _ in 0..<200 {
      if fixture.clock.count == 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(fixture.clock.count == 2)
    #expect(fixture.engine.isPlaying)
    #expect(fixture.controller.pause())
    fixture.client.releaseRequest()
    for _ in 0..<2_000 {
      if fixture.client.revokedIDs.count == 1 { break }
      await Task.yield()
    }
    #expect(fixture.client.revokedIDs.count == 1)
    #expect(!fixture.engine.isPlaying)
    #expect(
      fixture.controller.diagnostics.events.contains {
        $0.kind == .operationTimedOut && $0.phase == .ticketRenewal
      })
    await fixture.controller.shutdown(saveProgress: false)
    fixture.clock.wake()
  }

  @Test(arguments: [PlaybackStreamFailure.authorizationDenied, .untrustedServer])
  func terminalStreamFailureQuarantinesPendingRenewalAndPreservesItsCause(
    failure: PlaybackStreamFailure
  ) async throws {
    let fixture = RenewalFixture(outcomes: [])
    await fixture.controller.start()
    try await fixture.clock.waitForSleeps(1)
    fixture.client.holdNextRequest = true
    fixture.clock.wake()
    try await fixture.client.waitForCalls(2)
    #expect(fixture.client.pendingRequest != nil)

    fixture.relay.failure?(failure)
    let expectedCause: PlaybackRecoveryCause =
      failure == .untrustedServer ? .serverIdentityMismatch : .accessDenied
    let message = try #require(fixture.controller.errorMessage)
    #expect(fixture.controller.recoveryCause == expectedCause)
    #expect(!fixture.engine.isPlaying)
    #expect(!fixture.controller.play())
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.controller.errorMessage == message)
    #expect(fixture.controller.recoveryCause == expectedCause)

    fixture.client.releaseRequest()
    for _ in 0..<2_000 {
      if fixture.client.revokedIDs.count == 1 { break }
      await Task.yield()
    }
    #expect(fixture.client.revokedIDs.count == 1)
    #expect(fixture.client.calls == 2)
    #expect(fixture.clock.count == 1)
    #expect(fixture.relay.updatedURLs.isEmpty)
    #expect(fixture.engine.playCalls == 1)
    #expect(fixture.controller.errorMessage == message)
    #expect(fixture.controller.recoveryCause == expectedCause)
    #expect(
      !fixture.controller.diagnostics.events.contains {
        $0.kind == .authorizationStopped && $0.cause != expectedCause
      })
    await fixture.controller.shutdown(saveProgress: false)
    #expect(fixture.client.revokedIDs.count == 2)
  }

  @Test(arguments: [PlaybackStreamFailure.authorizationDenied, .untrustedServer])
  func terminalStreamFailureQuarantinesAnUncooperativeRenewalBackoff(
    failure: PlaybackStreamFailure
  ) async throws {
    let fixture = RenewalFixture(outcomes: [.failure(URLError(.networkConnectionLost))])
    await fixture.controller.start()
    try await fixture.clock.waitForSleeps(1)
    fixture.clock.wake()
    try await fixture.clock.waitForSleeps(2)
    fixture.relay.failure?(failure)
    let expectedCause: PlaybackRecoveryCause =
      failure == .untrustedServer ? .serverIdentityMismatch : .accessDenied
    let message = try #require(fixture.controller.errorMessage)
    fixture.clock.now.addTimeInterval(7_200)
    // This test clock deliberately ignores cancellation: the late wake must
    // not turn the original trust/access failure into an expired-ticket error.
    fixture.clock.wake()
    for _ in 0..<100 { await Task.yield() }
    #expect(fixture.controller.errorMessage == message)
    #expect(fixture.controller.recoveryCause == expectedCause)
    #expect(fixture.client.calls == 2)
    #expect(fixture.clock.count == 2)
    #expect(!fixture.controller.isPlaying)
    #expect(
      !fixture.controller.diagnostics.events.contains {
        $0.kind == .authorizationStopped && $0.cause != expectedCause
      })
    await fixture.controller.shutdown(saveProgress: false)
  }

  @Test func nonFatalDialogueBoostUsesNoticeAndAudioReopenReattachesSidecars() async throws {
    let fixture = RenewalFixture(outcomes: [])
    fixture.client.sidecarTracks = [
      try JSONDecoder().decode(
        LiveSubtitleTrack.self,
        from: Data(
          #"{"index":7,"codec":"srt","language":"en","title":"English","isDefault":false,"isForced":false,"supported":true,"isSidecar":true,"isSdh":false}"#
            .utf8))
    ]
    await fixture.controller.start()
    for _ in 0..<50 where fixture.engine.addedSubtitleSlaves.isEmpty {
      await Task.yield()
    }
    #expect(fixture.engine.addedSubtitleSlaves.count == 1)

    // Dialogue Boost unavailable shows a non-fatal notice without setting errorMessage.
    fixture.engine.dialogueBoostResult = .unavailable
    #expect(!fixture.controller.setDialogueBoost(.standard))
    #expect(fixture.controller.errorMessage == nil)
    #expect(fixture.controller.noticeMessage?.contains("Dialogue Boost") == true)

    // Audio change reload re-attaches previously discovered sidecar subtitles.
    fixture.engine.currentTimeMilliseconds = 5_000
    fixture.engine.durationMilliseconds = 120_000
    fixture.engine.onUpdate?()
    fixture.controller.reopenForAudioChange()
    #expect(fixture.engine.addedSubtitleSlaves.count == 2)
    #expect(fixture.engine.addedSubtitleSlaves[0] == fixture.engine.addedSubtitleSlaves[1])

    // Remote commands control the active registered player.
    PlaybackShutdownCoordinator.shared.register(fixture.controller)
    defer { PlaybackShutdownCoordinator.shared.unregister(fixture.controller) }
    let app = AppModel(store: InMemoryServerProfileStore())
    app.handleIncomingRemoteCommand(
      RemotePlaybackCommand(
        commandId: UUID(), action: "pause", mediaId: nil, positionSeconds: nil, skipSeconds: nil,
        createdAt: "2026-11-22T00:00:00Z"))
    #expect(!fixture.engine.isPlaying)
    app.handleIncomingRemoteCommand(
      RemotePlaybackCommand(
        commandId: UUID(), action: "resume", mediaId: nil, positionSeconds: nil, skipSeconds: nil,
        createdAt: "2026-11-22T00:00:00Z"))
    #expect(fixture.engine.isPlaying)
    app.handleIncomingRemoteCommand(
      RemotePlaybackCommand(
        commandId: UUID(), action: "seek", mediaId: nil, positionSeconds: 45, skipSeconds: nil,
        createdAt: "2026-11-22T00:00:00Z"))
    #expect(fixture.engine.seekTargets.last == 45_000)
    app.handleIncomingRemoteCommand(
      RemotePlaybackCommand(
        commandId: UUID(), action: "skip", mediaId: nil, positionSeconds: nil, skipSeconds: 15,
        createdAt: "2026-11-22T00:00:00Z"))
    #expect(fixture.engine.seekTargets.last == 60_000)

    await fixture.controller.shutdown(saveProgress: false)
  }
}

@MainActor
private final class RenewalFixture {
  let clock = RenewalClock()
  let engine = FakePlaybackEngine()
  let relay = RenewalRelay()
  let client: RenewalClient
  let controller: PlaybackController
  init(
    outcomes: [Result<Void, Error>], lifetime: TimeInterval = 3_600,
    timing: PlaybackTimingPolicy = PlaybackTimingPolicy()
  ) {
    client = RenewalClient(expires: clock.now.addingTimeInterval(lifetime), outcomes: outcomes)
    controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: client.mediaID, title: "Synthetic Playback", subtitle: nil),
      engine: engine, relayFactory: { [relay] _, _ in relay },
      renewalClock: { [clock] in clock.now }, renewalSleep: clock.sleep, timing: timing)
  }
}

@MainActor
private final class RenewalRelay: PlaybackRelayProtocol {
  var didStop = false
  var updatedURLs: [URL] = []
  var failure: (@MainActor @Sendable (PlaybackStreamFailure) -> Void)?

  func start() async throws -> URL {
    URL(string: "http://127.0.0.1:54321/stream/synthetic-renewal")!
  }

  func subtitleURL(index: Int) -> URL? {
    URL(string: "http://127.0.0.1:54321/subtitle/\(index)")
  }

  func updateSourceURL(_ url: URL) { updatedURLs.append(url) }
  func setFailureHandler(
    _ handler: @escaping @MainActor @Sendable (PlaybackStreamFailure) -> Void
  ) {
    failure = handler
  }
  func stop() { didStop = true }
}

@MainActor
private final class RenewalClock {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  var count = 0
  var pending: CheckedContinuation<Void, Error>?
  func sleep(_ duration: TimeInterval) async throws {
    count += 1
    try await withCheckedThrowingContinuation { pending = $0 }
  }
  func wake() {
    let continuation = pending
    pending = nil
    continuation?.resume()
  }
  func waitForSleeps(_ expected: Int) async throws {
    for _ in 0..<1_000 {
      if count >= expected { return }
      await Task.yield()
    }
    throw URLError(.timedOut)
  }
}

@MainActor
private final class RenewalClient: PlaybackClientProtocol {
  let mediaID = UUID()
  let profile = StoredServerProfile(
    serverId: UUID(), name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
    publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
    sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
  var calls = 0
  let expires: Date
  var outcomes: [Result<Void, Error>]
  var holdNextRequest = false
  var pendingRequest: CheckedContinuation<Void, Never>?
  var revokedIDs: [UUID] = []
  var failNextStreamURL = false
  var sidecarTracks: [LiveSubtitleTrack] = []
  init(expires: Date, outcomes: [Result<Void, Error>]) {
    self.expires = expires
    self.outcomes = outcomes
  }
  func streamSubtitles(ticket: UUID) async throws -> [LiveSubtitleTrack] { sidecarTracks }
  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
    calls += 1
    if holdNextRequest {
      holdNextRequest = false
      await withCheckedContinuation { pendingRequest = $0 }
    }
    if calls > 1, !outcomes.isEmpty { try outcomes.removeFirst().get() }
    return PlaybackSourceResponse(
      id: UUID(), mediaId: mediaID, streamPath: "/api/v1/streams/synthetic-ticket",
      contentType: "video/mp4", contentLength: 100,
      expiresAt: ISO8601DateFormatter().string(from: expires),
      progress: PlaybackProgressResponse(
        mediaId: mediaID, positionMilliseconds: 0, durationMilliseconds: 120_000,
        isCompleted: false, lastPlayedAt: nil, updatedAt: nil))
  }
  func updatePlaybackProgress(
    mediaId: UUID, positionMilliseconds: Int64, durationMilliseconds: Int64, isFinished: Bool
  ) async throws -> PlaybackProgressResponse {
    PlaybackProgressResponse(
      mediaId: mediaId, positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds,
      isCompleted: isFinished, lastPlayedAt: nil, updatedAt: nil)
  }
  func revokePlayback(id: UUID) async throws { revokedIDs.append(id) }
  func releaseRequest() {
    let continuation = pendingRequest
    pendingRequest = nil
    continuation?.resume()
  }
  func streamURL(path: String) throws -> URL {
    if failNextStreamURL {
      failNextStreamURL = false
      throw APIClientError.invalidResponse
    }
    return URL(string: path, relativeTo: profile.baseURL)!.absoluteURL
  }
  func waitForCalls(_ expected: Int) async throws {
    for _ in 0..<1_000 {
      if calls >= expected { return }
      await Task.yield()
    }
    throw URLError(.timedOut)
  }
}
