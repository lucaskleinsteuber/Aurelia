import Foundation
import Testing

@Suite("iOS scoped preference journal and immediate resume")
struct IOSProgressJournalTests {
  private let scope = IOSProgressScope(
    serverID: UUID(), profileID: UUID(), fingerprint: String(repeating: "C", count: 64))
  private let mediaID = UUID()
  private let snapshot = IOSProgressSnapshot(position: 42_000, duration: 100_000, finished: false)

  @Test func defaultsJournalSurvivesANewStoreAndOutboxInstance() async throws {
    let suite = "Aurelia-TV-Journal-Test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = IOSProgressOutbox(journal: IOSDefaultsProgressJournal(defaults: defaults))
    #expect(
      await first.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7))
    let data = try #require(defaults.data(forKey: IOSDefaultsProgressJournal.key))
    #expect(data.count <= 256 * 1_024)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("https"))
    #expect(!json.contains("profileToken"))
    #expect(!json.contains("streamPath"))
    let restarted = IOSProgressOutbox(
      journal: IOSDefaultsProgressJournal(defaults: try #require(UserDefaults(suiteName: suite))))
    #expect(await restarted.latestPendingSnapshot(scope: scope, mediaID: mediaID) == snapshot)
  }

  @Test func defaultsRestartReplaysTheExactUncertainMutation() async throws {
    let suite = "Aurelia-TV-Journal-Test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = IOSProgressOutbox(journal: IOSDefaultsProgressJournal(defaults: defaults))
    let interrupted = IOSJournalClient(mode: .hold)
    await first.activate(scope: scope, client: interrupted)
    #expect(
      await first.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7))
    let original = try await interrupted.waitForAttempt()
    await first.deactivate()
    let restarted = IOSProgressOutbox(
      journal: IOSDefaultsProgressJournal(defaults: try #require(UserDefaults(suiteName: suite))))
    let available = IOSJournalClient(mode: .accept)
    await restarted.activate(scope: scope, client: available)
    #expect(try await available.waitForAttempt() == original)
    #expect(await restarted.flush(scope: scope, mediaID: mediaID) == .saved)
    await restarted.deactivate()
    await interrupted.completeHeld()
  }

  @Test func acknowledgementWriteFailureRetainsTheOriginalIdempotentMutation() async throws {
    // Enqueue and dispatch are durable. Persisting the acknowledgement fails.
    let store = IOSJournalTestStore(failOnWrite: 3)
    let outbox = IOSProgressOutbox(journal: store)
    let client = IOSJournalClient(mode: .accept)
    await outbox.activate(scope: scope, client: client)
    #expect(
      await outbox.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7))
    let original = try await client.waitForAttempt()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await outbox.storageFailed), ContinuousClock.now < deadline { await Task.yield() }
    #expect(await outbox.storageFailed)
    #expect(await outbox.pendingMutation(scope: scope, mediaID: mediaID) == original)
    await outbox.deactivate()
    let restarted = IOSProgressOutbox(journal: store)
    let retry = IOSJournalClient(mode: .accept)
    await restarted.activate(scope: scope, client: retry)
    #expect(try await retry.waitForAttempt() == original)
    #expect(await restarted.flush(scope: scope, mediaID: mediaID) == .saved)
    await restarted.deactivate()
  }

  @Test func immediateResumeReadsNewestSampleWhileOlderMutationIsUncertain() async throws {
    let outbox = IOSProgressOutbox()
    let client = IOSJournalClient(mode: .hold)
    await outbox.activate(scope: scope, client: client)
    #expect(
      await outbox.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7))
    let mutation = try await client.waitForAttempt()
    let newest = IOSProgressSnapshot(position: 15_000, duration: 100_000, finished: false)
    #expect(
      await outbox.enqueue(scope: scope, mediaID: mediaID, snapshot: newest, baselineRevision: 7))
    #expect(await outbox.latestPendingSnapshot(scope: scope, mediaID: mediaID) == newest)
    #expect(await outbox.pendingMutation(scope: scope, mediaID: mediaID) == mutation)
    #expect(await outbox.flush(scope: scope, mediaID: mediaID, timeout: .zero) == .pending)
    await outbox.deactivate()
    await client.completeHeld()
  }

  @Test func scopedSnapshotsNeverExposeAnotherProfileOrIdentity() async {
    let outbox = IOSProgressOutbox()
    let otherProfile = IOSProgressScope(
      serverID: scope.serverID, profileID: UUID(), fingerprint: scope.fingerprint)
    let otherIdentity = IOSProgressScope(
      serverID: scope.serverID, profileID: scope.profileID,
      fingerprint: String(repeating: "D", count: 64))
    #expect(
      await outbox.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7))
    #expect(await outbox.pendingSnapshots(scope: scope) == [mediaID: snapshot])
    #expect(await outbox.pendingSnapshots(scope: otherProfile).isEmpty)
    #expect(await outbox.latestPendingSnapshot(scope: otherIdentity, mediaID: mediaID) == nil)
  }

  @Test func restoredBackgroundConflictIsSilentButStorageFailureNeedsAttention() async throws {
    let store = IOSJournalTestStore()
    let first = IOSProgressOutbox(journal: store)
    #expect(
      await first.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7))
    let restored = IOSProgressOutbox(journal: store)
    let stream = await restored.changes(scope: scope)
    await restored.activate(scope: scope, client: IOSJournalClient(mode: .conflict))
    #expect(await restored.flush(scope: scope, mediaID: mediaID) == .conflict)
    var changes = stream.makeAsyncIterator()
    let conflict = try #require(await changes.next())
    #expect(conflict.state == .conflict && !conflict.requiresUserAttention)
    #expect(await restored.pendingSnapshots(scope: scope).isEmpty)
    let server = IOSPlaybackProgress(
      mediaId: mediaID, positionMilliseconds: 81_000, durationMilliseconds: 100_000,
      isCompleted: false, lastPlayedAt: nil, updatedAt: nil, revision: 9, lastMutationId: nil)
    #expect(await restored.resumePosition(scope: scope, server: server) == 81_000)
    #expect(
      IOSProgressOutboxChange(
        reason: .storageFailure, scope: scope, mediaID: mediaID, snapshot: nil,
        progress: nil, state: nil, storageFailed: true
      ).requiresUserAttention)
    await restored.deactivate()
  }

  @Test func aConflictKeepsTheServerPositionAndLeavesNothingStuck() async throws {
    let store = IOSJournalTestStore()
    let client = IOSJournalClient(mode: .conflict)
    let first = IOSProgressOutbox(journal: store)
    await first.activate(scope: scope, client: client)
    #expect(
      await first.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7))
    #expect(await first.flush(scope: scope, mediaID: mediaID) == .conflict)
    #expect(await first.latestPendingSnapshot(scope: scope, mediaID: mediaID) == nil)
    #expect(await first.pendingSnapshots(scope: scope).isEmpty)
    await first.deactivate()
    // The rejected sample is not kept, so after a restart the title saves normally again.
    let restarted = IOSProgressOutbox(journal: store)
    #expect(await restarted.state(scope: scope, mediaID: mediaID) == nil)
    await restarted.activate(scope: scope, client: client)
    #expect(await restarted.flush(scope: scope, mediaID: mediaID) == .saved)
    #expect(await client.attemptCount == 1)
    await restarted.deactivate()
  }

  @Test func aConflictKeptByAnOlderBuildIsSettledOnActivation() async throws {
    let scopeJSON = try JSONEncoder().encode(scope)
    let entry = """
      {"scope":\(String(decoding: scopeJSON, as: UTF8.self)),"mediaID":"\(mediaID.uuidString)",\
      "latest":{"id":"\(UUID().uuidString)","position":42000,"duration":100000,"finished":false},\
      "revision":7,"state":"conflict"}
      """
    let store = IOSJournalTestStore(
      data: Data("{\"version\":1,\"legacyImported\":true,\"entries\":[\(entry)]}".utf8))
    let outbox = IOSProgressOutbox(journal: store)
    #expect(await outbox.state(scope: scope, mediaID: mediaID) == .conflict)
    let client = IOSJournalClient(mode: .accept)
    await outbox.activate(scope: scope, client: client)
    #expect(await outbox.state(scope: scope, mediaID: mediaID) == nil)
    #expect(await outbox.count(scope: scope) == 0)
    #expect(await client.attemptCount == 0)
    #expect(
      await outbox.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 9))
    #expect(try await client.waitForAttempt().expectedRevision == 9)
    await outbox.deactivate()
  }

  @Test func flushDeadlineDoesNotWaitForAnUncancellableTransport() async throws {
    let outbox = IOSProgressOutbox()
    let client = IOSJournalClient(mode: .hold)
    await outbox.activate(scope: scope, client: client)
    #expect(
      await outbox.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7))
    _ = try await client.waitForAttempt()
    let start = ContinuousClock.now
    // Callers cannot accidentally turn this into a long network wait.
    #expect(await outbox.flush(scope: scope, mediaID: mediaID, timeout: .seconds(20)) == .pending)
    #expect(start.duration(to: .now) < .seconds(3))
    await outbox.deactivate()
    await client.completeHeld()
  }

  @Test func flushCancellationStopsObservationWithoutDroppingTheJournal() async throws {
    let outbox = IOSProgressOutbox()
    let client = IOSJournalClient(mode: .hold)
    await outbox.activate(scope: scope, client: client)
    #expect(
      await outbox.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7))
    _ = try await client.waitForAttempt()
    let observation = Task { await outbox.flush(scope: scope, mediaID: mediaID) }
    observation.cancel()
    #expect(await observation.value == .cancelled)
    #expect(await outbox.latestPendingSnapshot(scope: scope, mediaID: mediaID) == snapshot)
    await outbox.deactivate()
    await client.completeHeld()
  }

  @Test func profileChangeInvalidatesAFlushAndPreservesTheOldSnapshot() async throws {
    let outbox = IOSProgressOutbox()
    let client = IOSJournalClient(mode: .hold)
    await outbox.activate(scope: scope, client: client)
    #expect(
      await outbox.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7))
    _ = try await client.waitForAttempt()
    let observation = Task { await outbox.flush(scope: scope, mediaID: mediaID) }
    await Task.yield()
    await outbox.deactivate()
    #expect(await observation.value == .inactive)
    #expect(await outbox.latestPendingSnapshot(scope: scope, mediaID: mediaID) == snapshot)
    await client.completeHeld()
  }

  @Test func scopedChangesDeliverEnqueueAndAcknowledgement() async throws {
    let outbox = IOSProgressOutbox()
    let client = IOSJournalClient(mode: .accept)
    let changes = await outbox.changes(scope: scope)
    let reader = Task { () -> [IOSProgressOutboxChange] in
      var events: [IOSProgressOutboxChange] = []
      for await change in changes {
        events.append(change)
        if change.reason == .acknowledged { break }
      }
      return events
    }
    await outbox.activate(scope: scope, client: client)
    #expect(
      await outbox.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7))
    #expect(await outbox.flush(scope: scope, mediaID: mediaID) == .saved)
    let events = await reader.value
    #expect(events.count == 2)
    #expect(events.first?.reason == .enqueued)
    #expect(events.first?.snapshot == snapshot)
    #expect(events.last?.progress?.revision == 8)
    #expect(events.last?.progress?.positionMilliseconds == snapshot.position)
    #expect(events.last?.snapshot == nil)
    #expect(events.allSatisfy { $0.scope == scope && $0.mediaID == mediaID })
    await outbox.deactivate()
  }

  @Test func writeFailureIsReportedAndDoesNotSendAnUndurableMutation() async throws {
    let store = IOSJournalTestStore(failWrites: true)
    let outbox = IOSProgressOutbox(journal: store)
    let client = IOSJournalClient(mode: .accept)
    await outbox.activate(scope: scope, client: client)
    #expect(
      !(await outbox.enqueue(
        scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7)))
    #expect(await outbox.storageFailed)
    #expect(await outbox.flush(scope: scope, mediaID: mediaID) == .storageFailure)
    #expect(await client.attemptCount == 0)
    #expect(try store.read() == nil)
    store.setFailWrites(false)
    #expect(
      await outbox.enqueue(scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7))
    #expect(await outbox.flush(scope: scope, mediaID: mediaID) == .saved)
    #expect(await client.attemptCount == 1)
    await outbox.deactivate()
  }

  @Test func capacityFailureNeverDeletesOtherTitles() async throws {
    let store = IOSJournalTestStore()
    let outbox = IOSProgressOutbox(journal: store)
    for _ in 0..<IOSProgressOutbox.capacity {
      #expect(
        await outbox.enqueue(scope: scope, mediaID: UUID(), snapshot: snapshot, baselineRevision: 7)
      )
    }
    let before = try store.read()
    #expect(
      !(await outbox.enqueue(
        scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7)))
    #expect(await outbox.storageFailed)
    #expect(await outbox.count(scope: scope) == IOSProgressOutbox.capacity)
    #expect(try store.read() == before)
    #expect((before?.count ?? .max) <= IOSProgressOutbox.maximumBytes)
  }

  @Test(arguments: [Data(), Data("invalid journal".utf8)])
  func unreadableDestinationIsPreserved(_ bytes: Data) async throws {
    let store = IOSJournalTestStore(data: bytes)
    let outbox = IOSProgressOutbox(journal: store)
    #expect(await outbox.storageFailed)
    #expect(
      !(await outbox.enqueue(
        scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7)))
    #expect(try store.read() == bytes)
  }

  @Test func nonDataPreferenceIsPreserved() async throws {
    let suite = "Aurelia-TV-Journal-Test-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("unreadable journal", forKey: IOSDefaultsProgressJournal.key)
    let outbox = IOSProgressOutbox(journal: IOSDefaultsProgressJournal(defaults: defaults))
    #expect(await outbox.storageFailed)
    #expect(
      !(await outbox.enqueue(
        scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7)))
    #expect(defaults.string(forKey: IOSDefaultsProgressJournal.key) == "unreadable journal")
  }

  @Test func readableLegacyArrayMigratesBeforeTheSourceIsRemoved() async throws {
    let file = try makeLegacyFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = IOSJournalTestStore()
    let outbox = IOSProgressOutbox(journal: store, legacyStorageURL: file)
    #expect(!(await outbox.storageFailed))
    #expect(await outbox.latestPendingSnapshot(scope: scope, mediaID: mediaID) == snapshot)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let restored = IOSProgressOutbox(journal: store)
    #expect(await restored.latestPendingSnapshot(scope: scope, mediaID: mediaID) == snapshot)
  }

  @Test func failedLegacyMigrationPreservesItsExactSourceAndDestination() async throws {
    let file = try makeLegacyFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let source = try Data(contentsOf: file)
    let store = IOSJournalTestStore(failWrites: true)
    let outbox = IOSProgressOutbox(journal: store, legacyStorageURL: file)
    #expect(await outbox.storageFailed)
    #expect(try Data(contentsOf: file) == source)
    #expect(try store.read() == nil)
    #expect(
      !(await outbox.enqueue(
        scope: scope, mediaID: mediaID, snapshot: snapshot, baselineRevision: 7)))
    #expect(try Data(contentsOf: file) == source)
  }

  @Test func unreadableLegacyDoesNotCreateOrOverwriteTheDestination() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Aurelia-Journal-\(UUID())")
    let source = Data()
    try source.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let store = IOSJournalTestStore()
    let outbox = IOSProgressOutbox(journal: store, legacyStorageURL: file)
    #expect(await outbox.storageFailed)
    #expect(try Data(contentsOf: file) == source)
    #expect(try store.read() == nil)
  }

  private func makeLegacyFile() throws -> URL {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Aurelia-Journal-Legacy-\(UUID())", isDirectory: true
    ).appendingPathComponent("outbox.json")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let oldEntries: [[String: Any]] = [
      [
        "scope": [
          "serverID": scope.serverID.uuidString, "profileID": scope.profileID.uuidString,
          "fingerprint": scope.fingerprint,
        ],
        "mediaID": mediaID.uuidString,
        "latest": [
          "id": snapshot.id.uuidString, "position": snapshot.position,
          "duration": snapshot.duration, "finished": snapshot.finished,
        ],
        "revision": 7,
        "state": "pending",
      ]
    ]
    try JSONSerialization.data(withJSONObject: oldEntries).write(to: file)
    return file
  }
}

private final class IOSJournalTestStore: IOSProgressJournalStore, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  private var failWrites: Bool
  private let failOnWrite: Int?
  private var writes = 0

  init(data: Data? = nil, failWrites: Bool = false, failOnWrite: Int? = nil) {
    self.data = data
    self.failWrites = failWrites
    self.failOnWrite = failOnWrite
  }

  func read() throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return data
  }

  func write(_ data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    writes += 1
    guard !failWrites, writes != failOnWrite else { throw CocoaError(.fileWriteOutOfSpace) }
    self.data = data
  }

  func setFailWrites(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    failWrites = value
  }
}

private actor IOSJournalClient: IOSProgressClient {
  enum Mode { case accept, hold, conflict }
  private let mode: Mode
  private var attempts: [IOSProgressMutation] = []
  private var held: [(IOSProgressMutation, CheckedContinuation<IOSPlaybackProgress, Error>)] = []

  init(mode: Mode) { self.mode = mode }
  var attemptCount: Int { attempts.count }

  func readProgress(mediaID: UUID) async throws -> IOSPlaybackProgress {
    result(mediaID: mediaID, position: 0, duration: 100_000, revision: 7, mutationID: nil)
  }

  func sendProgress(_ mutation: IOSProgressMutation) async throws -> IOSPlaybackProgress {
    attempts.append(mutation)
    switch mode {
    case .accept: return result(mutation)
    case .hold:
      return try await withCheckedThrowingContinuation { held.append((mutation, $0)) }
    case .conflict:
      throw IOSCoreError.server(
        status: 409, code: "playback_progress_conflict", message: nil, retryAfter: nil)
    }
  }

  func waitForAttempt() async throws -> IOSProgressMutation {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while attempts.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
    return try #require(attempts.first)
  }

  func completeHeld() {
    let replies = held
    held.removeAll()
    for (mutation, continuation) in replies { continuation.resume(returning: result(mutation)) }
  }

  private func result(_ mutation: IOSProgressMutation) -> IOSPlaybackProgress {
    result(
      mediaID: mutation.mediaID, position: mutation.snapshot.position,
      duration: mutation.snapshot.duration,
      revision: mutation.expectedRevision + 1, mutationID: mutation.mutationID)
  }

  private func result(
    mediaID: UUID, position: Int64, duration: Int64, revision: Int64, mutationID: UUID?
  ) -> IOSPlaybackProgress {
    IOSPlaybackProgress(
      mediaId: mediaID, positionMilliseconds: position, durationMilliseconds: duration,
      isCompleted: false, lastPlayedAt: nil, updatedAt: nil, revision: revision,
      lastMutationId: mutationID)
  }
}
