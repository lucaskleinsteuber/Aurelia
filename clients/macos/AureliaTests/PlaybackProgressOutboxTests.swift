import AppKit
import Foundation
import Testing

@testable import Aurelia

@MainActor
struct PlaybackProgressOutboxTests {
  @Test
  func progressContractsRemainCompatibleAndGuardZeroRevisionExplicitly() throws {
    let legacy = """
      {"mediaId":"00000000-0000-0000-0000-000000000001","positionMilliseconds":0,
       "durationMilliseconds":0,"isCompleted":false,"lastPlayedAt":null,"updatedAt":null}
      """
    let decoded = try JSONDecoder().decode(PlaybackProgressResponse.self, from: Data(legacy.utf8))
    #expect(decoded.revision == nil)
    #expect(decoded.lastMutationId == nil)
    let id = UUID()
    let request = UpdatePlaybackProgressRequest(
      positionMilliseconds: 20_000, durationMilliseconds: 100_000, isFinished: false,
      expectedRevision: 0, enforceRevision: true, clientMutationId: id)
    let fields = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(fields["expectedRevision"] as? Int == 0)
    #expect(fields["enforceRevision"] as? Bool == true)
    #expect(fields["clientMutationId"] as? String == id.uuidString)
  }

  @Test
  func newerSnapshotsCoalesceWithoutLosingAnIntentionalBackwardsSeek() async throws {
    let client = OutboxTestClient()
    client.holdWrites = true
    let outbox = PlaybackProgressOutbox()
    outbox.activate(client: client)
    outbox.noteBaseline(client.progress, profile: client.profile)
    #expect(enqueue(outbox, client, 50_000))
    try await waitUntil { client.writes.count == 1 }
    for position in 50_001...50_100 { #expect(enqueue(outbox, client, Int64(position))) }
    #expect(enqueue(outbox, client, 10_000))
    #expect(client.writes.count == 1)
    client.holdWrites = false
    client.releaseWrite()
    try await waitUntil { outbox.pendingCount(profile: client.profile) == 0 }
    #expect(client.writes.map(\.position) == [50_000, 10_000])
    #expect(client.writes.map(\.revision) == [0, 1])
    outbox.deactivate()
  }

  @Test
  func uncertainAppliedWriteRetainsItsMutationIDAcrossRestart() async throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let client = OutboxTestClient()
    client.loseAcknowledgement = true
    let first = PlaybackProgressOutbox(storageURL: file, sleep: { _ in throw CancellationError() })
    first.activate(client: client)
    first.noteBaseline(client.progress, profile: client.profile)
    #expect(enqueue(first, client, 32_000))
    try await waitUntil { first.state(media: client.media, profile: client.profile) == .retrying }
    first.deactivate()
    let mutation = try #require(client.writes.first?.id)
    let restored = PlaybackProgressOutbox(
      storageURL: file, clock: { Date().addingTimeInterval(120) })
    #expect(!restored.storageFailed)
    restored.activate(client: client)
    try await waitUntil { restored.pendingCount(profile: client.profile) == 0 }
    #expect(client.writes.count == 2)
    #expect(client.writes.last?.id == mutation)
    #expect(client.revision == 1)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    let persisted = String(decoding: try Data(contentsOf: file), as: UTF8.self)
    #expect(!persisted.contains(client.profile.token))
    #expect(!persisted.contains(client.profile.baseURL.absoluteString))
    restored.deactivate()
  }

  @Test
  func aLaterPositionFromAnotherDeviceIsNeverOverwritten() async throws {
    let client = OutboxTestClient()
    let outbox = PlaybackProgressOutbox()
    outbox.activate(client: client)
    outbox.noteBaseline(client.progress, profile: client.profile)
    // Another device saved after this Mac's sample was taken.
    client.revision = 8
    client.serverUpdatedAt = "2099-01-01T00:00:00Z"
    #expect(enqueue(outbox, client, 70_000))
    try await waitUntil { outbox.pendingCount(profile: client.profile) == 0 }
    #expect(outbox.state(media: client.media, profile: client.profile) == nil)
    #expect(client.writes.count == 1)
    #expect(client.revision == 8)
    // Watching on, this Mac saves again on the server's revision.
    client.serverUpdatedAt = nil
    #expect(enqueue(outbox, client, 75_000))
    try await waitUntil { outbox.pendingCount(profile: client.profile) == 0 }
    #expect(client.writes.last?.revision == 8)
    #expect(client.revision == 9)
    outbox.deactivate()
  }

  @Test
  func anOutdatedRevisionIsSentAgainWhenThisMacHasTheLaterPosition() async throws {
    let client = OutboxTestClient()
    let outbox = PlaybackProgressOutbox()
    outbox.activate(client: client)
    outbox.noteBaseline(client.progress, profile: client.profile)
    client.revision = 8
    client.serverUpdatedAt = "2000-01-01T00:00:00Z"
    #expect(enqueue(outbox, client, 100_000))
    try await waitUntil { outbox.pendingCount(profile: client.profile) == 0 }
    #expect(client.writes.count == 2)
    #expect(client.writes.last?.revision == 8)
    #expect(client.writes.last?.position == 100_000)
    #expect(client.revision == 9)
    #expect(outbox.state(media: client.media, profile: client.profile) == nil)
    outbox.deactivate()
  }

  @Test
  func aDeviceSavingTheSameTitleAtOnceEndsInAConflictToResolve() async throws {
    let client = OutboxTestClient()
    let outbox = PlaybackProgressOutbox()
    outbox.activate(client: client)
    outbox.noteBaseline(client.progress, profile: client.profile)
    client.failure = APIClientError.httpFailure(
      status: 409, retryAfter: nil, code: "playback_progress_conflict", message: nil)
    #expect(enqueue(outbox, client, 70_000))
    try await waitUntil { outbox.state(media: client.media, profile: client.profile) == .conflict }
    #expect(client.writes.count == 4)
    client.failure = nil
    try await outbox.resolveConflict(media: client.media, profile: client.profile)
    try await waitUntil { outbox.pendingCount(profile: client.profile) == 0 }
    #expect(client.writes.last?.position == 70_000)
    outbox.deactivate()
  }

  @Test
  func unknownBaselineAdoptsTheServerRevisionOnlyForTheLaterPosition() async throws {
    let client = OutboxTestClient()
    let outbox = PlaybackProgressOutbox()
    outbox.activate(client: client)
    client.revision = 5
    client.serverUpdatedAt = "2099-01-01T00:00:00Z"
    #expect(enqueue(outbox, client, 20_000))
    try await waitUntil { outbox.pendingCount(profile: client.profile) == 0 }
    #expect(client.writes.isEmpty)
    client.serverUpdatedAt = "2000-01-01T00:00:00Z"
    #expect(enqueue(outbox, client, 25_000))
    try await waitUntil { outbox.pendingCount(profile: client.profile) == 0 }
    #expect(client.writes.last?.revision == 5)
    #expect(client.revision == 6)
    outbox.deactivate()
  }

  @Test
  func anAcknowledgementForTheWrongMediaDoesNotEraseTheDraft() async throws {
    let client = OutboxTestClient()
    client.wrongAcknowledgement = true
    var now = Date()
    let outbox = PlaybackProgressOutbox(
      clock: { now }, sleep: { _ in throw CancellationError() })
    outbox.activate(client: client)
    outbox.noteBaseline(client.progress, profile: client.profile)
    #expect(enqueue(outbox, client, 42_000))
    try await waitUntil { outbox.state(media: client.media, profile: client.profile) == .retrying }
    #expect(outbox.pendingCount(profile: client.profile) == 1)
    client.wrongAcknowledgement = false
    now.addTimeInterval(120)
    for _ in 0..<10 { await Task.yield() }
    outbox.activate(client: client)
    try await waitUntil { outbox.pendingCount(profile: client.profile) == 0 }
    #expect(client.writes.first?.id == client.writes.last?.id)
    #expect(client.revision == 1)
    outbox.deactivate()
  }

  @Test
  func authenticationDenialStopsRetriesAndDraftsStayAccountSeparated() async throws {
    let client = OutboxTestClient()
    client.failure = APIClientError.httpFailure(
      status: 401, retryAfter: nil, code: nil, message: nil)
    let outbox = PlaybackProgressOutbox()
    outbox.activate(client: client)
    outbox.noteBaseline(client.progress, profile: client.profile)
    #expect(enqueue(outbox, client, 20_000))
    try await waitUntil {
      outbox.state(media: client.media, profile: client.profile) == .accessDenied
    }
    outbox.activate(client: client)
    outbox.retryAfterReconnect()
    outbox.retryAfterPlaybackAuthorization(media: client.media, profile: client.profile)
    #expect(client.writes.count == 1)
    let other = OutboxTestClient(server: client.profile.serverId)
    outbox.activate(client: other)
    for _ in 0..<20 { await Task.yield() }
    #expect(other.writes.isEmpty)
    #expect(outbox.pendingCount(profile: client.profile) == 1)
    #expect(outbox.pendingCount(profile: other.profile) == 0)
    outbox.deactivate()
  }

  @Test
  func queueIsBoundedAndDoesNotSilentlyEvictUnsentEntries() throws {
    let outbox = PlaybackProgressOutbox()
    let client = OutboxTestClient()
    for _ in 0..<PlaybackProgressOutbox.capacity {
      #expect(
        outbox.enqueue(
          media: UUID(), profile: client.profile, position: 1, duration: 2, finished: false))
    }
    #expect(
      !outbox.enqueue(
        media: UUID(), profile: client.profile, position: 1, duration: 2, finished: false))
    #expect(outbox.pendingCount(profile: client.profile) == PlaybackProgressOutbox.capacity)
    #expect(outbox.capacityReached)
    #expect(!outbox.storageFailed)
  }

  @Test
  func corruptOrSymlinkedQueueIsNotReplacedOrReportedAsDurable() throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let corrupt = Data("not a valid progress queue".utf8)
    try corrupt.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let outbox = PlaybackProgressOutbox(storageURL: file)
    #expect(outbox.storageFailed)
    #expect(!enqueue(outbox, OutboxTestClient(), 20_000))
    #expect(try Data(contentsOf: file) == corrupt)

    let link = file.deletingLastPathComponent().appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    let linked = PlaybackProgressOutbox(storageURL: link)
    #expect(linked.storageFailed)
    #expect(!enqueue(linked, OutboxTestClient(), 20_000))
    #expect(try Data(contentsOf: file) == corrupt)
  }

  @Test
  func temporaryPersistenceFailureCanRecoverWithoutDeletingDrafts() async throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let client = OutboxTestClient()
    let outbox = PlaybackProgressOutbox(storageURL: file)
    outbox.activate(client: client)
    outbox.noteBaseline(client.progress, profile: client.profile)
    // A directory at the owned test destination simulates a failed atomic
    // write, without filling or modifying any real application disk state.
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    #expect(!enqueue(outbox, client, 22_000))
    #expect(outbox.storageFailed)
    #expect(client.writes.isEmpty)
    #expect(outbox.pendingCount(profile: client.profile) == 1)
    try FileManager.default.removeItem(at: file)
    outbox.retryAfterReconnect()
    try await waitUntil { outbox.pendingCount(profile: client.profile) == 0 }
    #expect(!outbox.storageFailed)
    #expect(client.writes.last?.position == 22_000)
    outbox.deactivate()
  }

  @Test
  func retriesAreBoundedAndUseTheSameMutation() async throws {
    let client = OutboxTestClient()
    client.failure = URLError(.networkConnectionLost)
    var time = Date()
    var delays: [TimeInterval] = []
    let outbox = PlaybackProgressOutbox(
      clock: { time },
      sleep: { delay in
        delays.append(delay)
        time.addTimeInterval(delay)
      })
    outbox.activate(client: client)
    outbox.noteBaseline(client.progress, profile: client.profile)
    #expect(enqueue(outbox, client, 15_000))
    try await waitUntil { client.writes.count == 6 }
    for _ in 0..<20 { await Task.yield() }
    #expect(client.writes.count == 6)
    #expect(Set(client.writes.map(\.id)).count == 1)
    #expect(delays.allSatisfy { $0 >= 1 && $0 <= 60 })
    #expect(outbox.pendingCount(profile: client.profile) == 1)
    outbox.deactivate()
  }

  @Test
  func verifiedPlaybackReleasesExhaustedRetriesWithoutReplacingAnUncertainMutation() async throws {
    let client = OutboxTestClient()
    client.loseAcknowledgement = true
    var time = Date()
    let outbox = PlaybackProgressOutbox(
      clock: { time },
      sleep: { delay in
        time.addTimeInterval(delay)
        // The first write was applied before its acknowledgement was lost.
        // Keep its idempotent retry offline until all six attempts are spent.
        client.failure = URLError(.networkConnectionLost)
      })
    outbox.activate(client: client)
    outbox.noteBaseline(client.progress, profile: client.profile)
    #expect(enqueue(outbox, client, 32_000))
    try await waitUntil { client.writes.count == 6 }
    for _ in 0..<20 { await Task.yield() }
    let uncertain = try #require(client.writes.first)
    #expect(client.revision == 1)
    #expect(Set(client.writes.map(\.id)) == [uncertain.id])

    // A newer backwards seek must remain separate from the uncertain write.
    #expect(enqueue(outbox, client, 10_000))
    outbox.activate(client: client)
    for _ in 0..<20 { await Task.yield() }
    #expect(client.writes.count == 6)
    client.failure = nil
    outbox.noteBaseline(client.progress, profile: client.profile)
    outbox.retryAfterPlaybackAuthorization(media: client.media, profile: client.profile)
    try await waitUntil { outbox.pendingCount(profile: client.profile) == 0 }

    #expect(client.writes.count == 8)
    #expect(client.writes[6].id == uncertain.id)
    #expect(client.writes[6].revision == uncertain.revision)
    #expect(client.writes[6].position == 32_000)
    #expect(client.writes[7].id != uncertain.id)
    #expect(client.writes[7].revision == 1)
    #expect(client.writes[7].position == 10_000)
    #expect(client.revision == 2)
    outbox.deactivate()
  }

  @Test
  func playbackAuthorizationCannotReleaseOtherMediaAccountsOrSessions() async throws {
    let client = OutboxTestClient()
    client.failure = URLError(.networkConnectionLost)
    var time = Date()
    let outbox = PlaybackProgressOutbox(
      clock: { time }, sleep: { time.addTimeInterval($0) })
    outbox.activate(client: client)
    outbox.noteBaseline(client.progress, profile: client.profile)
    #expect(enqueue(outbox, client, 20_000))
    try await waitUntil { client.writes.count == 6 }
    for _ in 0..<20 { await Task.yield() }
    client.failure = nil
    let otherAccount = OutboxTestClient(server: client.profile.serverId)
    let otherSession = StoredServerProfile(
      serverId: client.profile.serverId, name: client.profile.name,
      baseURL: client.profile.baseURL, publicKeyFingerprint: client.profile.publicKeyFingerprint,
      token: client.profile.token, sessionId: UUID(), expiresAt: client.profile.expiresAt,
      user: client.profile.user)
    outbox.retryAfterPlaybackAuthorization(media: UUID(), profile: client.profile)
    outbox.retryAfterPlaybackAuthorization(media: client.media, profile: otherAccount.profile)
    outbox.retryAfterPlaybackAuthorization(media: client.media, profile: otherSession)
    for _ in 0..<20 { await Task.yield() }
    #expect(client.writes.count == 6)
    #expect(outbox.pendingCount(profile: client.profile) == 1)
    #expect(outbox.state(media: client.media, profile: client.profile) == .retrying)
    outbox.deactivate()
  }

  @Test
  func playbackAuthorizationDoesNotBypassUnsupportedProgressContracts() async throws {
    let client = OutboxTestClient()
    client.omitRevision = true
    let outbox = PlaybackProgressOutbox()
    outbox.activate(client: client)
    let knownBaseline = PlaybackProgressResponse(
      mediaId: client.media, positionMilliseconds: 0, durationMilliseconds: 120_000,
      isCompleted: false, lastPlayedAt: nil, updatedAt: nil, revision: 0)
    outbox.noteBaseline(knownBaseline, profile: client.profile)
    #expect(enqueue(outbox, client, 20_000))
    try await waitUntil {
      outbox.state(media: client.media, profile: client.profile) == .unsupportedServer
    }
    client.omitRevision = false
    outbox.retryAfterPlaybackAuthorization(media: client.media, profile: client.profile)
    for _ in 0..<20 { await Task.yield() }
    #expect(client.writes.count == 1)
    #expect(outbox.pendingCount(profile: client.profile) == 1)
    #expect(outbox.state(media: client.media, profile: client.profile) == .unsupportedServer)
    outbox.deactivate()
  }

  @Test
  func recoveredPlaybackAuthorizationRestartsItsProgressQueueWithoutAppRefresh() async throws {
    let client = OutboxTestClient()
    let engine = OutboxTestEngine()
    var time = Date()
    let outbox = PlaybackProgressOutbox(
      clock: { time }, sleep: { time.addTimeInterval($0) })
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: client.media, title: "Synthetic video", subtitle: nil),
      engine: engine, relayFactory: { _, _ in OutboxTestRelay() },
      recoverySleep: { _ in }, progressOutbox: outbox)
    await controller.start()
    try await waitUntil { outbox.pendingCount(profile: client.profile) == 0 }
    #expect(client.writes.count == 1)
    client.failure = URLError(.networkConnectionLost)
    controller.seek(to: 45_000)
    try await waitUntil { client.writes.count == 7 }
    for _ in 0..<20 { await Task.yield() }
    let uncertain = client.writes[1]
    #expect(outbox.state(media: client.media, profile: client.profile) == .retrying)

    client.failure = nil
    engine.onError?("Synthetic decoder interruption")
    try await waitUntil {
      controller.isPlaying && outbox.pendingCount(profile: client.profile) == 0
    }
    #expect(client.writes[7].id == uncertain.id)
    #expect(client.writes[7].revision == uncertain.revision)
    #expect(controller.currentTimeMilliseconds == 45_000)
    #expect(!outbox.storageFailed)
    await controller.shutdown(saveProgress: false)
    outbox.deactivate()
  }

  @Test
  func shutdownDoesNotWaitForAnUnresponsiveProgressWrite() async throws {
    let client = OutboxTestClient()
    client.holdWrites = true
    client.holdRevocations = true
    let engine = OutboxTestEngine()
    let relay = OutboxTestRelay()
    let outbox = PlaybackProgressOutbox()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: client.media, title: "Synthetic video", subtitle: nil),
      engine: engine, relayFactory: { _, _ in relay }, progressOutbox: outbox)
    await controller.start()
    controller.seek(to: 30_000)
    try await waitUntil { client.writes.count == 1 }
    let started = Date()
    let shutdown = Task { await controller.shutdown() }
    try await waitUntil { engine.stopped && relay.stopped }
    #expect(Date().timeIntervalSince(started) < 0.2)
    await shutdown.value
    #expect(Date().timeIntervalSince(started) < 1.5)
    #expect(outbox.pendingCount(profile: client.profile) == 1)
    client.holdWrites = false
    client.releaseWrite()
    client.releaseRevocations()
    outbox.deactivate()
  }

  @Test
  func nextEpisodeStartsEvenWhenPreviousProgressAndRevocationAreUnresponsive() async throws {
    let client = OutboxTestClient()
    client.holdWrites = true
    client.holdRevocations = true
    let engine = OutboxTestEngine()
    let outbox = PlaybackProgressOutbox()
    let next = UUID()
    let controller = PlaybackController(
      client: client,
      presentation: PlaybackPresentation(
        mediaId: client.media, title: "Synthetic first", subtitle: nil,
        queue: [PlaybackQueueItem(mediaId: next, title: "Synthetic next", subtitle: nil)]),
      engine: engine, relayFactory: { _, _ in OutboxTestRelay() }, progressOutbox: outbox)
    await controller.start()
    try await waitUntil { client.writes.count == 1 }
    let started = Date()
    engine.currentTimeMilliseconds = engine.durationMilliseconds
    engine.onEnded?()
    let deadline = Date().addingTimeInterval(1.5)
    // The next presentation is published before asynchronous authorization and
    // relay preparation finish. Wait for the actual playback outcome, not just
    // the intermediate title change, without extending the cleanup deadline.
    while (controller.presentation.mediaId != next || !controller.isPlaying) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(controller.presentation.mediaId == next)
    #expect(controller.isPlaying)
    #expect(Date().timeIntervalSince(started) < 1.5)
    await controller.shutdown(saveProgress: false)
    client.holdWrites = false
    client.releaseWrite()
    client.releaseRevocations()
    outbox.deactivate()
  }

  @Test
  func diagnosticsAreBoundedAndContainOnlyTheClosedSafeSchema() throws {
    let diagnostics = PlaybackDiagnostics()
    for index in 0..<1_000 {
      diagnostics.record(
        .recoveryAttempt, cause: .mediaUnavailable, attempt: index, position: 405_000,
        duration: 600_000)
    }
    #expect(diagnostics.events.count == 200)
    let data = try diagnostics.export()
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let events = try #require(object["events"] as? [[String: Any]])
    #expect(events.count == 200)
    #expect(
      Set(events[0].keys) == [
        "timestamp", "kind", "cause", "attempt", "positionMilliseconds", "durationMilliseconds",
      ])
    #expect(
      PlaybackRecoveryCause.classify(
        APIClientError.httpFailure(
          status: 503, retryAfter: nil, code: "media_unavailable", message: "private path"))
        == .mediaUnavailable)
    #expect(
      PlaybackRecoveryCause.classify(URLError(.networkConnectionLost)) == .connectionInterrupted)
    #expect(
      PlaybackRecoveryCause.classify(APIClientError.serverIdentityMismatch)
        == .serverIdentityMismatch)
  }

  private func enqueue(
    _ queue: PlaybackProgressOutbox, _ client: OutboxTestClient, _ position: Int64
  ) -> Bool {
    queue.enqueue(
      media: client.media, profile: client.profile, position: position, duration: 120_000,
      finished: false)
  }

  private func temporaryFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Aurelia-Progress-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory.appendingPathComponent("progress.json")
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      await Task.yield()
    }
    try #require(condition())
  }
}

@MainActor
private final class OutboxTestClient: PlaybackClientProtocol {
  struct Write {
    let id: UUID
    let revision: Int64
    let position: Int64
  }
  let profile: StoredServerProfile
  let media = UUID()
  var requiresProgressRevision: Bool { true }
  var revision: Int64 = 0
  var lastMutation: UUID?
  var writes: [Write] = []
  var holdWrites = false
  var holdRevocations = false
  var loseAcknowledgement = false
  var wrongAcknowledgement = false
  var omitRevision = false
  /// When the server's position was saved; nil means the server did not say.
  var serverUpdatedAt: String?
  var failure: Error?
  private var heldWrite: CheckedContinuation<Void, Never>?
  private var heldRevocations: [CheckedContinuation<Void, Never>] = []

  init(server: UUID = UUID()) {
    profile = StoredServerProfile(
      serverId: server, name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "0", count: 64), token: "synthetic-secret-token",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z",
      user: UserSummary(
        id: UUID(), username: "synthetic", role: .user, createdAt: "2026-10-09T00:00:00Z"))
  }

  var progress: PlaybackProgressResponse {
    PlaybackProgressResponse(
      mediaId: media, positionMilliseconds: writes.last?.position ?? 0,
      durationMilliseconds: 120_000,
      isCompleted: false, lastPlayedAt: nil, updatedAt: serverUpdatedAt,
      revision: omitRevision ? nil : revision,
      lastMutationId: lastMutation)
  }

  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
    PlaybackSourceResponse(
      id: UUID(), mediaId: mediaId, streamPath: "/api/v1/streams/synthetic",
      contentType: "video/mp4",
      contentLength: 1, expiresAt: "2099-01-01T00:00:00Z", progress: progress)
  }
  func playbackProgress(mediaId: UUID) async throws -> PlaybackProgressResponse { progress }
  func updatePlaybackProgress(
    mediaId: UUID, positionMilliseconds: Int64, durationMilliseconds: Int64, isFinished: Bool
  ) async throws -> PlaybackProgressResponse {
    throw APIClientError.invalidResponse
  }
  func updatePlaybackProgress(
    mediaId: UUID, positionMilliseconds: Int64, durationMilliseconds: Int64, isFinished: Bool,
    expectedRevision: Int64, clientMutationId: UUID
  ) async throws -> PlaybackProgressResponse {
    writes.append(
      Write(id: clientMutationId, revision: expectedRevision, position: positionMilliseconds))
    if holdWrites { await withCheckedContinuation { heldWrite = $0 } }
    if let failure { throw failure }
    if lastMutation == clientMutationId { return progress }
    guard expectedRevision == revision else {
      throw APIClientError.httpFailure(
        status: 409, retryAfter: nil, code: "playback_progress_conflict", message: nil)
    }
    revision += 1
    lastMutation = clientMutationId
    if loseAcknowledgement {
      loseAcknowledgement = false
      throw URLError(.networkConnectionLost)
    }
    if wrongAcknowledgement {
      return PlaybackProgressResponse(
        mediaId: UUID(), positionMilliseconds: positionMilliseconds,
        durationMilliseconds: durationMilliseconds, isCompleted: isFinished,
        lastPlayedAt: nil, updatedAt: nil, revision: revision, lastMutationId: lastMutation)
    }
    return progress
  }
  func releaseWrite() {
    heldWrite?.resume()
    heldWrite = nil
  }
  func releaseRevocations() {
    for revocation in heldRevocations { revocation.resume() }
    heldRevocations.removeAll()
  }
  func revokePlayback(id: UUID) async throws {
    if holdRevocations { await withCheckedContinuation { heldRevocations.append($0) } }
  }
  func streamURL(path: String) throws -> URL { URL(string: "https://fixture.invalid\(path)")! }
}

@MainActor
private final class OutboxTestRelay: PlaybackRelayProtocol {
  var stopped = false
  func start() async throws -> URL { URL(string: "http://127.0.0.1:12345/synthetic")! }
  func updateSourceURL(_ url: URL) {}
  func stop() { stopped = true }
}

@MainActor
private final class OutboxTestEngine: PlaybackEngine {
  var onUpdate: (() -> Void)?
  var onEnded: (() -> Void)?
  var onError: ((String) -> Void)?
  var isPlaying = false
  var currentTimeMilliseconds: Int64 = 0
  var durationMilliseconds: Int64 = 120_000
  var volume = 1.0
  var isMuted = false
  var playbackRate = 1.0
  var audioTracks: [PlaybackTrack] = []
  var subtitleTracks: [PlaybackTrack] = []
  var selectedAudioTrackID: Int32?
  var selectedSubtitleTrackID: Int32?
  var chapters: [PlaybackChapter] = []
  var currentChapterIndex: Int32?
  var stopped = false
  func attach(to view: NSView) {}
  func load(url: URL) {}
  func play() {
    isPlaying = true
    onUpdate?()
  }
  func pause() {
    isPlaying = false
    onUpdate?()
  }
  func stop() {
    isPlaying = false
    stopped = true
  }
  func seek(to milliseconds: Int64) { currentTimeMilliseconds = milliseconds }
  func selectAudioTrack(id: Int32) {}
  func selectSubtitleTrack(id: Int32?) {}
  func selectChapter(index: Int32) {}
}
