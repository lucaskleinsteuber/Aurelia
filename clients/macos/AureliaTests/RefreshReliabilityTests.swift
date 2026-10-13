import Foundation
import Testing

@testable import Aurelia

@MainActor
struct RefreshReliabilityTests {
  @Test func startupActivationCannotStartSyncOrSupersedeInitialSnapshot() async throws {
    let requests = StartupRequestCounter()
    let controller = LibrarySyncController(fetchChanges: { _, _, _, _ in
      await requests.record()
      throw CancellationError()
    })
    let model = AppModel(
      store: InMemoryServerProfileStore(), initialProfile: syntheticProfile(),
      syncController: controller)
    #expect(model.isStarting)
    await model.setApplicationActive(true)
    await model.refreshHome()
    try await Task.sleep(for: .milliseconds(30))
    #expect(await requests.count == 0)
    #expect(model.errorMessage == nil)
    #expect(model.home == nil)
    await controller.stop()
  }

  @Test(arguments: [false, true])
  func failedSnapshotIsRedeliveredBeforeCursorAcknowledgement(reset: Bool) async throws {
    let probe = AcknowledgementProbe(reset: reset)
    let controller = LibrarySyncController(
      fetchChanges: { _, cursor, _, _ in try await probe.fetch(after: cursor) },
      delay: { _ in try await Task.sleep(for: .milliseconds(1)) })
    await controller.start(profile: syntheticProfile()) { _ in try await probe.apply() }
    try await wait { await probe.cursors.contains(7) }
    await controller.stop()
    #expect(await probe.cursors.prefix(2) == [0, 0])
    #expect(await probe.applications == 2)
  }

  @Test func authorizationFailureWhileApplyingStopsRatherThanAcknowledging() async throws {
    let probe = AcknowledgementProbe(denied: true)
    let controller = LibrarySyncController(
      fetchChanges: { _, cursor, _, _ in try await probe.fetch(after: cursor) },
      delay: { _ in try await Task.sleep(for: .milliseconds(1)) })
    let profile = syntheticProfile()
    await controller.start(
      profile: profile, onFailure: { _ in await probe.reportFailure() },
      onChanges: { _ in try await probe.apply() })
    try await wait { await probe.failures == 1 }
    #expect(await probe.cursors == [0])
    await controller.stop()
  }

  @Test func supersededSnapshotIsRedeliveredWithoutPublishingServerFailure() async throws {
    let probe = AcknowledgementProbe(superseded: true)
    let controller = LibrarySyncController(
      fetchChanges: { _, cursor, _, _ in try await probe.fetch(after: cursor) },
      delay: { _ in try await Task.sleep(for: .milliseconds(1)) })
    await controller.start(
      profile: syntheticProfile(), onFailure: { _ in await probe.reportFailure() },
      onChanges: { _ in try await probe.apply() })
    try await wait { await probe.cursors.contains(7) }
    await controller.stop()
    #expect(await probe.cursors.prefix(2) == [0, 0])
    #expect(await probe.applications == 2)
    #expect(await probe.failures == 0)
  }

  @Test func disappearingSnapshotIsRedeliveredRatherThanDisablingSync() async throws {
    let probe = AcknowledgementProbe(missingSnapshot: true)
    let controller = LibrarySyncController(
      fetchChanges: { _, cursor, _, _ in try await probe.fetch(after: cursor) },
      delay: { _ in try await Task.sleep(for: .milliseconds(1)) })
    await controller.start(profile: syntheticProfile()) { _ in try await probe.apply() }
    try await wait { await probe.cursors.contains(7) }
    #expect(await probe.cursors.prefix(2) == [0, 0])
    #expect(await probe.applications == 2)
    await controller.stop()
  }

  @Test func userStateLoadsOnlyHomeAndAffectedCards() {
    let id = UUID()
    let plan = SyncRefreshPlan(change(areas: [.userState], ids: [id, id]))
    #expect(!plan.fullCatalog)
    #expect(!plan.collections)
    #expect(plan.home)
    #expect(plan.mediaIDs == [id])
    #expect(!SyncRefreshPlan(change(areas: [.metadata], ids: [id])).fullCatalog)
    #expect(SyncRefreshPlan(change(areas: [.collections])).collections)
  }

  @Test func resetsStructuralChangesAndOversizedOrLegacyUpdatesUseCompleteSnapshot() {
    for areas: [SyncChangeArea] in [[.catalog], [.libraries], [.metadata], [.userState]] {
      #expect(SyncRefreshPlan(change(areas: areas)).fullCatalog)
    }
    #expect(
      SyncRefreshPlan(change(areas: [.userState], ids: (0..<33).map { _ in UUID() })).fullCatalog)
    #expect(SyncRefreshPlan(change(areas: [], reset: true)).fullCatalog)
  }

  @Test func failedStatusRequestRetainsScanAndLaterCompletionIsConfirmed() async throws {
    let scan = syntheticScan()
    let unavailable = try await ScanPollingBatch.load(scans: [scan]) { _ in
      throw URLError(.networkConnectionLost)
    }
    #expect(unavailable.active == [scan])
    #expect(unavailable.completed.isEmpty)
    #expect(unavailable.unavailable == [scan.id])
    #expect(unavailable.definitiveFailure == nil)
    let complete = syntheticScan(id: scan.id, library: scan.libraryId, state: .completed)
    let recovered = try await ScanPollingBatch.load(scans: unavailable.active) { _ in complete }
    #expect(recovered.active.isEmpty)
    #expect(recovered.completed == [complete])
    #expect(recovered.unavailable.isEmpty)
  }

  @Test func invalidScanIdentityCannotReplaceCachedStatus() async throws {
    let scan = syntheticScan()
    let batch = try await ScanPollingBatch.load(scans: [scan]) { _ in syntheticScan() }
    #expect(batch.active == [scan])
    #expect(batch.unavailable == [scan.id])
  }

  @Test(arguments: [false, true])
  func confirmedCancellationWinsOverDelayedPollWithoutDroppingNewScan(failed: Bool) async throws {
    let cancelled = syntheticScan()
    let added = syntheticScan()
    let batch = try await ScanPollingBatch.load(scans: [cancelled]) { _ in
      if failed { throw URLError(.timedOut) }
      return cancelled
    }
    let reconciled = batch.reconciled(polledIDs: [cancelled.id], current: [added])
    #expect(reconciled.active == [added])
    #expect(reconciled.completed.isEmpty)
    #expect(reconciled.unavailable.isEmpty)
  }

  @Test func accessDenialRetainsOtherScansAndStopsFurtherRequests() async throws {
    let first = syntheticScan()
    let second = syntheticScan()
    var requests = 0
    let batch = try await ScanPollingBatch.load(scans: [first, second]) { _ in
      requests += 1
      throw APIClientError.httpFailure(status: 401, retryAfter: nil, code: nil, message: nil)
    }
    #expect(requests == 1)
    #expect(batch.active == [first, second])
    #expect(batch.completed.isEmpty)
    #expect(batch.definitiveFailure?.isAuthenticationFailure == true)
  }

  @Test func cancellationNeverLooksLikeSuccessfulScanCompletion() async throws {
    do {
      _ = try await ScanPollingBatch.load(scans: [syntheticScan()]) { _ in throw CancellationError()
      }
      Issue.record("Cancelled polling must not publish a completed batch.")
    } catch is CancellationError {}
  }

  @Test func transientHostFailuresNeedConfirmationAndRecoveryIsBounded() {
    var health = HostHealthPolicy()
    #expect(health.failed(at: 0) == .wait(1))
    #expect(health.failed(at: 1) == .wait(2))
    #expect(health.failed(at: 3) == .recover)
    #expect(health.recoveryDelay == 1)
    #expect(health.failed(at: 4, confirmedExit: true) == .recover)
    #expect(health.recoveryDelay == 2)
    #expect(health.failed(at: 5, confirmedExit: true) == .recover)
    #expect(health.failed(at: 6, confirmedExit: true) == .stop)
    health.healthy(at: 10)
    health.healthy(at: 69)
    #expect(health.recoveries == 3)
    health.healthy(at: 70)
    #expect(health.recoveries == 0)
    #expect(health.failed(at: 71) == .wait(1))
  }

  @Test func aHealthyReplyClearsTransientFailureStreak() {
    var health = HostHealthPolicy()
    _ = health.failed(at: 0)
    _ = health.failed(at: 1)
    health.healthy(at: 2)
    #expect(health.failed(at: 3) == .wait(1))
  }

  private func change(areas: [SyncChangeArea], ids: [UUID] = [], reset: Bool = false)
    -> SyncChangesResponse
  {
    SyncChangesResponse(cursor: 1, resetRequired: reset, changedAreas: areas, changedMediaIds: ids)
  }
  private func syntheticProfile() -> StoredServerProfile {
    StoredServerProfile(
      serverId: UUID(), name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
  }
  private func wait(_ predicate: () async -> Bool) async throws {
    for _ in 0..<200 {
      if await predicate() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw URLError(.timedOut)
  }
  private func syntheticScan(
    id: UUID = UUID(), library: UUID = UUID(), state: LibraryScanState = .running
  ) -> LibraryScanSummary {
    LibraryScanSummary(
      id: id, libraryId: library, state: state, createdAt: "2026-01-01T00:00:00Z",
      startedAt: nil, completedAt: nil, filesDiscovered: 10, filesProcessed: 5,
      addedFiles: 5, updatedFiles: 0, missingFiles: 0, skippedFiles: 0, error: nil, issues: [])
  }
}

private actor StartupRequestCounter {
  private(set) var count = 0
  func record() { count += 1 }
}

private actor AcknowledgementProbe {
  let reset: Bool
  let denied: Bool
  let missingSnapshot: Bool
  let superseded: Bool
  private(set) var cursors: [Int64] = []
  private(set) var applications = 0
  private(set) var failures = 0
  init(
    reset: Bool = false, denied: Bool = false, missingSnapshot: Bool = false,
    superseded: Bool = false
  ) {
    self.reset = reset
    self.denied = denied
    self.missingSnapshot = missingSnapshot
    self.superseded = superseded
  }
  func fetch(after: Int64) async throws -> SyncChangesResponse {
    cursors.append(after)
    if after == 7 { try await Task.sleep(for: .seconds(60)) }
    return SyncChangesResponse(
      cursor: 7, resetRequired: reset, changedAreas: reset ? [] : [.userState], changedMediaIds: [])
  }
  func apply() throws {
    applications += 1
    if denied {
      throw APIClientError.httpFailure(status: 401, retryAfter: nil, code: nil, message: nil)
    }
    if applications == 1 {
      if superseded { throw APIClientError.supersededSnapshot }
      if missingSnapshot {
        throw APIClientError.httpFailure(status: 404, retryAfter: nil, code: nil, message: nil)
      }
      throw URLError(.networkConnectionLost)
    }
  }
  func reportFailure() { failures += 1 }
}
