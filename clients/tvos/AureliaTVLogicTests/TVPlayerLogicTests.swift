import Foundation
import Testing

@Suite("TV player policy and durable progress")
struct TVPlayerLogicTests {
  private let scope = TVProgressScope(
    serverID: UUID(), profileID: UUID(), fingerprint: String(repeating: "A", count: 64))
  private let mediaID = UUID()

  @Test func resumeDoesNotResumeCompletedTitles() {
    #expect(TVPlayerPolicy.resumePosition(progress(position: 45_000, completed: false)) == 45_000)
    #expect(TVPlayerPolicy.resumePosition(progress(position: 45_000, completed: true)) == 0)
  }

  @Test func seekingIsBoundedAndOverflowSafe() {
    #expect(TVPlayerPolicy.seekPosition(current: 5_000, offset: -10_000, duration: 60_000) == 0)
    #expect(
      TVPlayerPolicy.seekPosition(current: 58_000, offset: 10_000, duration: 60_000) == 59_500)
    #expect(TVPlayerPolicy.seekPosition(current: .max - 10, offset: 20, duration: 60_000) == 59_500)
    #expect(TVPlayerPolicy.seekPosition(current: 20_000, offset: -10_000, duration: 0) == 10_000)
  }

  @Test func earlyEOFAndErrorsNeverFinishATitle() {
    #expect(
      !TVPlayerPolicy.isNaturalCompletion(
        position: 25_000, duration: 120_000, observedPlayback: true, transportFailed: false))
    #expect(
      !TVPlayerPolicy.isNaturalCompletion(
        position: 119_000, duration: 120_000, observedPlayback: true, transportFailed: true))
    #expect(
      !TVPlayerPolicy.isNaturalCompletion(
        position: 119_000, duration: 120_000, observedPlayback: false, transportFailed: false))
    #expect(
      !TVPlayerPolicy.isNaturalCompletion(
        position: 119_000, duration: 0, observedPlayback: true, transportFailed: false))
    #expect(
      TVPlayerPolicy.isNaturalCompletion(
        position: 119_500, duration: 120_000, observedPlayback: true, transportFailed: false))
  }

  @Test func controlsRemainWhilePausedBusyOrChoosingATrack() {
    #expect(
      TVPlayerPolicy.mayHideControls(
        playing: true, menuOpen: false, interacting: false, loading: false, hasError: false))
    #expect(
      !TVPlayerPolicy.mayHideControls(
        playing: false, menuOpen: false, interacting: false, loading: false, hasError: false))
    #expect(
      !TVPlayerPolicy.mayHideControls(
        playing: true, menuOpen: true, interacting: false, loading: false, hasError: false))
    #expect(
      !TVPlayerPolicy.mayHideControls(
        playing: true, menuOpen: false, interacting: true, loading: false, hasError: false))
    #expect(
      !TVPlayerPolicy.mayHideControls(
        playing: true, menuOpen: false, interacting: false, loading: true, hasError: false))
    #expect(
      !TVPlayerPolicy.mayHideControls(
        playing: true, menuOpen: false, interacting: false, loading: false, hasError: true))
  }

  @Test func recoveryIsBoundedAndTicketRenewalPrecedesExpiry() {
    var budget = TVPlaybackRecoveryBudget()
    #expect(budget.takeAttempt() == 1)
    #expect(budget.takeAttempt() == 3)
    #expect(budget.takeAttempt() == nil)
    #expect(budget.attempts == 2)
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(TVPlayerPolicy.renewalDelay(expiresAt: now.addingTimeInterval(300), now: now) == 240)
    #expect(TVPlayerPolicy.renewalDelay(expiresAt: now.addingTimeInterval(-5), now: now) == 1)
    #expect(TVPlayerPolicy.expiry("2026-10-16T12:30:00.123Z") != nil)
    #expect(TVPlayerPolicy.expiry("2026-10-16T12:30:00Z") != nil)
    #expect(TVPlayerPolicy.expiry("invalid") == nil)
  }

  @Test func relayAllowsOnlyExactSecretRouteAndSingleByteRange() throws {
    let request = try TVRelayRequest.parse(
      Data(
        "GET /stream/secret HTTP/1.1\r\nHost: 127.0.0.1:12345\r\nRange: bytes=10-20\r\n\r\n".utf8),
      secret: "secret")
    #expect(request.method == "GET")
    #expect(request.range == "bytes=10-20")
    let head = try TVRelayRequest.parse(
      Data("HEAD /stream/secret HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=-500\r\n\r\n".utf8),
      secret: "secret")
    #expect(head.method == "HEAD")
  }

  @Test(arguments: [
    "GET /stream/wrong HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
    "GET /stream/secret?token=value HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
    "POST /stream/secret HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
    "GET /stream/secret HTTP/1.1\r\nHost: localhost\r\n\r\n",
    "GET /stream/secret HTTP/1.1\r\nHost: 127.0.0.1:0\r\n\r\n",
    "GET /stream/secret HTTP/1.1\r\nHost: 127.0.0.1\r\nHost: 127.0.0.1\r\n\r\n",
    "GET /stream/secret HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-1,4-5\r\n\r\n",
    "GET /stream/secret HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=20-10\r\n\r\n",
    "GET /stream/secret HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=-0\r\n\r\n",
    "GET /stream/secret HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=１-２\r\n\r\n",
    "GET /stream/secret HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 1\r\n\r\n",
    "GET /stream/secret HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n",
  ])
  func relayRejectsInvalidRequests(_ request: String) {
    #expect(throws: TVRelayRequestError.self) {
      try TVRelayRequest.parse(Data(request.utf8), secret: "secret")
    }
  }

  @Test func persistedProgressContainsNoCredentialsOrMediaLocations() async throws {
    let file = storageURL()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let outbox = TVProgressOutbox(storageURL: file)
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 42_000, duration: 100_000, finished: false),
        baselineRevision: 7))
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains(mediaID.uuidString))
    #expect(!text.contains("token"))
    #expect(!text.contains("https"))
    #expect(!text.contains("streamPath"))
    let restored = TVProgressOutbox(storageURL: file)
    #expect(await restored.count(scope: scope) == 1)
  }

  @Test func lostResponseReplaysExactlyThePersistedMutationAfterRestart() async throws {
    let file = storageURL()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let first = TVProgressOutbox(storageURL: file)
    let disconnected = TVPlayerFakeProgressClient(mode: .hold)
    await first.activate(scope: scope, client: disconnected)
    #expect(
      await first.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 42_000, duration: 100_000, finished: false),
        baselineRevision: 7))
    let original = try await disconnected.attempt(1)
    await first.deactivate()
    let restarted = TVProgressOutbox(storageURL: file)
    let reconnected = TVPlayerFakeProgressClient(mode: .accept)
    await restarted.activate(scope: scope, client: reconnected)
    let repeated = try await reconnected.attempt(1)
    #expect(original == repeated)
    try await eventually { await restarted.count(scope: scope) == 0 }
    await disconnected.completeHeld()
    await restarted.deactivate()
  }

  @Test func aBackwardSeekDoesNotReplaceAnUncertainWrite() async throws {
    let outbox = TVProgressOutbox()
    let client = TVPlayerFakeProgressClient(mode: .hold)
    await outbox.activate(scope: scope, client: client)
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 42_000, duration: 100_000, finished: false),
        baselineRevision: 7))
    let first = try await client.attempt(1)
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 10_000, duration: 100_000, finished: false),
        baselineRevision: 7))
    #expect(await outbox.pendingMutation(scope: scope, mediaID: mediaID) == first)
    await client.completeHeld()
    let next = try await client.attempt(2)
    #expect(next.snapshot.position == 10_000)
    #expect(next.expectedRevision == 8)
    #expect(next.mutationID != first.mutationID)
    await outbox.deactivate()
    await client.completeHeld()
  }

  @Test func acceptedWritesAdvanceTheNextBaselineRevision() async throws {
    let outbox = TVProgressOutbox()
    let client = TVPlayerFakeProgressClient(mode: .accept)
    await outbox.activate(scope: scope, client: client)
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 10_000, duration: 100_000, finished: false),
        baselineRevision: 7))
    _ = try await client.attempt(1)
    try await eventually { await outbox.count(scope: scope) == 0 }
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 20_000, duration: 100_000, finished: false),
        baselineRevision: 7))
    let second = try await client.attempt(2)
    #expect(second.expectedRevision == 8)
    await outbox.deactivate()
  }

  @Test func aConflictStopsTheOpenPlayerUntilTheTitleIsOpenedAgain() async throws {
    let outbox = TVProgressOutbox()
    let client = TVPlayerFakeProgressClient(mode: .conflict)
    await outbox.activate(scope: scope, client: client)
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 10_000, duration: 100_000, finished: false),
        baselineRevision: 7))
    _ = try await client.attempt(1)
    try await eventually { await outbox.state(scope: scope, mediaID: mediaID) == .conflict }
    // The still open player must not overwrite the other device's newer position.
    #expect(
      !(await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 20_000, duration: 100_000, finished: false),
        baselineRevision: 8)))
    await outbox.activate(scope: scope, client: client)
    #expect(await outbox.state(scope: scope, mediaID: mediaID) == .conflict)
    #expect(await client.attemptCount == 1)
    // Opening the title again starts from the server's position, and saving works again.
    await outbox.noteBaseline(
      scope: scope,
      progress: TVPlaybackProgress(
        mediaId: mediaID, positionMilliseconds: 50_000, durationMilliseconds: 100_000,
        isCompleted: false, lastPlayedAt: nil, updatedAt: nil, revision: 12, lastMutationId: nil))
    #expect(await outbox.state(scope: scope, mediaID: mediaID) == nil)
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 51_000, duration: 100_000, finished: false),
        baselineRevision: 12))
    let next = try await client.attempt(2)
    #expect(next.expectedRevision == 12)
    await outbox.deactivate()
  }

  @Test func leavingAndReturningToTheAppKeepsItsOwnLatestRevision() async throws {
    let outbox = TVProgressOutbox()
    let client = TVPlayerFakeProgressClient(mode: .accept)
    await outbox.activate(scope: scope, client: client)
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 10_000, duration: 100_000, finished: false),
        baselineRevision: 7))
    _ = try await client.attempt(1)
    try await eventually { await outbox.count(scope: scope) == 0 }
    // Home button and back: the app deactivates and activates progress saving again.
    await outbox.deactivate()
    await outbox.activate(scope: scope, client: client)
    // The player still holds its baseline from when it opened (7); the next write must expect
    // this Apple TV's own write (8), not conflict with it.
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 25_000, duration: 100_000, finished: false),
        baselineRevision: 7))
    let second = try await client.attempt(2)
    #expect(second.expectedRevision == 8)
    await outbox.deactivate()
  }

  @Test func aLateReplyAfterProfileChangeDoesNotConsumeTheOldProfilesEntry() async throws {
    let outbox = TVProgressOutbox()
    let oldClient = TVPlayerFakeProgressClient(mode: .hold)
    await outbox.activate(scope: scope, client: oldClient)
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 10_000, duration: 100_000, finished: false),
        baselineRevision: 7))
    _ = try await oldClient.attempt(1)
    let other = TVProgressScope(
      serverID: scope.serverID, profileID: UUID(), fingerprint: scope.fingerprint)
    let newClient = TVPlayerFakeProgressClient(mode: .accept)
    await outbox.activate(scope: other, client: newClient)
    await oldClient.completeHeld()
    #expect(await outbox.count(scope: scope) == 1)
    #expect(await outbox.count(scope: other) == 0)
    #expect(await newClient.attemptCount == 0)
    await outbox.deactivate()
  }

  @Test func oldPlayerCannotReplaceTheNewerSessionsSample() async throws {
    let outbox = TVProgressOutbox()
    let client = TVPlayerFakeProgressClient(mode: .accept)
    let oldSession = UUID()
    let currentSession = UUID()
    await outbox.activate(scope: scope, client: client, sessionID: currentSession)
    #expect(
      !(await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 10_000, duration: 100_000, finished: false),
        baselineRevision: 7,
        sessionID: oldSession)))
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 20_000, duration: 100_000, finished: false),
        baselineRevision: 7,
        sessionID: currentSession))
    let mutation = try await client.attempt(1)
    #expect(mutation.snapshot.position == 20_000)
    try await eventually { await outbox.count(scope: scope) == 0 }
    await outbox.deactivate()
  }

  @Test func deactivatedOutboxRetainsTheFinalSnapshotWithoutSending() async {
    let outbox = TVProgressOutbox()
    let client = TVPlayerFakeProgressClient(mode: .accept)
    let session = UUID()
    await outbox.activate(scope: scope, client: client, sessionID: session)
    await outbox.deactivate()
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 20_000, duration: 100_000, finished: false),
        baselineRevision: 7,
        sessionID: session))
    #expect(await outbox.count(scope: scope) == 1)
    #expect(await client.attemptCount == 0)
  }

  @Test func invalidRequestsDoNotRetryForever() async throws {
    let outbox = TVProgressOutbox()
    let client = TVPlayerFakeProgressClient(mode: .invalidRequest)
    await outbox.activate(scope: scope, client: client)
    #expect(
      await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 10_000, duration: 100_000, finished: false),
        baselineRevision: 7))
    _ = try await client.attempt(1)
    try await eventually { await outbox.state(scope: scope, mediaID: mediaID) == .unavailable }
    await outbox.activate(scope: scope, client: client)
    #expect(await outbox.state(scope: scope, mediaID: mediaID) == .unavailable)
    #expect(await client.attemptCount == 1)
    await outbox.deactivate()
  }

  @Test func unreadableQueueIsPreservedAndNeverOverwritten() async throws {
    let file = storageURL()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data("not a saved queue".utf8)
    try bytes.write(to: file)
    let outbox = TVProgressOutbox(storageURL: file)
    #expect(await outbox.storageFailed)
    #expect(
      !(await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 10_000, duration: 100_000, finished: false),
        baselineRevision: 7)))
    #expect(try Data(contentsOf: file) == bytes)
  }

  @Test func invalidSnapshotsDoNotEnterTheQueue() async {
    let outbox = TVProgressOutbox()
    #expect(
      !(await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: -1, duration: 100_000, finished: false),
        baselineRevision: 7)))
    #expect(
      !(await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 100_001, duration: 100_000, finished: false),
        baselineRevision: 7)))
    #expect(
      !(await outbox.enqueue(
        scope: scope, mediaID: mediaID,
        snapshot: TVProgressSnapshot(position: 0, duration: 0, finished: false), baselineRevision: 7
      )))
    #expect(await outbox.count(scope: scope) == 0)
  }

  private func progress(position: Int64, completed: Bool) -> TVPlaybackProgress {
    TVPlaybackProgress(
      mediaId: mediaID, positionMilliseconds: position, durationMilliseconds: 100_000,
      isCompleted: completed, lastPlayedAt: nil, updatedAt: nil, revision: 7, lastMutationId: nil)
  }

  private func storageURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "Aurelia-TV-Logic-\(UUID().uuidString)", isDirectory: true
    )
    .appendingPathComponent("outbox.json")
  }

  private func eventually(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
    #expect(await condition())
  }
}

private actor TVPlayerFakeProgressClient: TVProgressClient {
  enum Mode { case hold, accept, conflict, invalidRequest }
  let mode: Mode
  private var sent: [TVProgressMutation] = []
  private var held: [(TVProgressMutation, CheckedContinuation<TVPlaybackProgress, Error>)] = []

  init(mode: Mode) { self.mode = mode }
  var attemptCount: Int { sent.count }

  func readProgress(mediaID: UUID) async throws -> TVPlaybackProgress {
    TVPlaybackProgress(
      mediaId: mediaID, positionMilliseconds: 0, durationMilliseconds: 100_000,
      isCompleted: false, lastPlayedAt: nil, updatedAt: nil, revision: 7, lastMutationId: nil)
  }

  func sendProgress(_ mutation: TVProgressMutation) async throws -> TVPlaybackProgress {
    sent.append(mutation)
    switch mode {
    case .accept: return result(mutation)
    case .conflict:
      throw TVCoreError.server(
        status: 409, code: "playback_progress_conflict", message: nil, retryAfter: nil)
    case .invalidRequest:
      throw TVCoreError.server(
        status: 400, code: "invalid_playback_progress", message: nil, retryAfter: nil)
    case .hold:
      return try await withCheckedThrowingContinuation { held.append((mutation, $0)) }
    }
  }

  func attempt(_ count: Int) async throws -> TVProgressMutation {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while sent.count < count, ContinuousClock.now < deadline { await Task.yield() }
    guard sent.count >= count else { throw TVPlayerTestError.requestNotSent }
    return sent[count - 1]
  }

  func completeHeld() {
    let current = held
    held.removeAll()
    for (mutation, continuation) in current { continuation.resume(returning: result(mutation)) }
  }

  private func result(_ mutation: TVProgressMutation) -> TVPlaybackProgress {
    TVPlaybackProgress(
      mediaId: mutation.mediaID, positionMilliseconds: mutation.snapshot.position,
      durationMilliseconds: mutation.snapshot.duration, isCompleted: mutation.snapshot.finished,
      lastPlayedAt: nil, updatedAt: nil, revision: mutation.expectedRevision + 1,
      lastMutationId: mutation.mutationID)
  }
}

private enum TVPlayerTestError: Error { case requestNotSent }
