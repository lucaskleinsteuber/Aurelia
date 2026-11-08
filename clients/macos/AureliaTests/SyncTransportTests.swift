import Foundation
import Testing

@testable import Aurelia

struct SyncTransportTests {
  @Test
  func httpFailuresRetainStatusAndRetryAfterWithoutLosingSafeMessages() throws {
    let rate = APIClient.responseError(status: 429, retryAfter: "60", data: Data())
    #expect(rate.httpStatus == 429)
    #expect(rate.retryDelay == 60)
    #expect(rate.isRetryableTransient)
    let denied = APIClient.responseError(status: 401, retryAfter: nil, data: Data())
    #expect(denied.isAuthenticationFailure)
    let forbidden = APIClient.responseError(status: 403, retryAfter: nil, data: Data())
    #expect(forbidden.errorDescription?.contains("did not allow") == true)
    let conflict = APIClient.responseError(
      status: 409, retryAfter: nil,
      data: Data(#"{"code":"catalog_changed","message":"Reload the library."}"#.utf8))
    #expect(conflict.problemCode == "catalog_changed")
    #expect(conflict.errorDescription == "Reload the library.")
    #expect(!conflict.isRetryableTransient)
    #expect(
      APIClient.responseError(status: 500, retryAfter: nil, data: Data()).isRetryableTransient)
    #expect(APIClient.responseError(status: 404, retryAfter: nil, data: Data()).httpStatus == 404)
    #expect(
      APIClient.responseError(status: 503, retryAfter: "99999", data: Data()).retryDelay == 300)
  }

  @Test
  func revisionConflictRestartsWholePaginationButNeverPublishesPartialResults() async throws {
    let probe = PageProbe()
    let result: [MovieSummary] = try await APIClient.loadPages { offset, revision in
      await probe.fetch(offset: offset, revision: revision)
    }
    #expect(result.map(\.title) == ["A", "B", "C"])
    #expect(Set(result.map(\.id)).count == 3)
    #expect(await probe.attempt == 2)
  }

  @Test
  func repeatedConflictsHaveOnlyTwoRestarts() async throws {
    let probe = PageProbe(alwaysConflict: true)
    do {
      let _: [MovieSummary] = try await APIClient.loadPages { offset, revision in
        await probe.fetch(offset: offset, revision: revision)
      }
      Issue.record("A partial changing catalog must not be returned as a completed load.")
    } catch let error as APIClientError {
      #expect(error.problemCode == "catalog_changed")
    }
    #expect(await probe.attempt == 3)
  }

  @Test
  func temporaryInvalidResponseRetriesAndTrue404DoesNot() async throws {
    let probe = SyncProbe()
    let controller = LibrarySyncController(
      fetchChanges: { _, _, _, _ in
        try await probe.fetch()
      }, delay: { _ in try await Task.sleep(for: .milliseconds(1)) })
    await controller.start(profile: profile()) { _ in await probe.received() }
    try await wait { await probe.updates == 1 }
    await controller.stop()
    #expect(await probe.calls >= 2)

    let missing = SyncProbe(missing: true)
    let oldController = LibrarySyncController(
      fetchChanges: { _, _, _, _ in
        try await missing.fetch()
      }, delay: { _ in try await Task.sleep(for: .milliseconds(1)) })
    await oldController.start(profile: profile()) { _ in await missing.received() }
    try await wait { await missing.calls == 1 }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await missing.calls == 1)
    await oldController.stop()
  }

  @Test
  func legacyChangingTotalsCannotDriveUnboundedPagination() async throws {
    let probe = LegacyPageProbe()
    do {
      let _: [MovieSummary] = try await APIClient.loadPages { offset, _ in
        await probe.fetch(offset: offset)
      }
      Issue.record("Legacy totals changing during loading must not publish partial results.")
    } catch let error as APIClientError {
      #expect(error.problemCode == "catalog_changed")
    }
    #expect(await probe.calls == 6)
  }

  @Test
  func foregroundRestartReportsAuthenticationFailure() async throws {
    let probe = FailureProbe()
    let controller = LibrarySyncController(fetchChanges: { _, _, _, _ in
      throw APIClientError.httpFailure(status: 401, retryAfter: nil, code: nil, message: nil)
    })
    await controller.setForeground(false, profile: nil) { _ in }
    await controller.setForeground(
      true, profile: profile(),
      onFailure: { _ in await probe.received() }, onChanges: { _ in })
    try await wait { await probe.calls == 1 }
    await controller.stop()
  }

  @Test
  func delayedOldRunStopCannotCancelNewRunOnTheSameSession() async throws {
    let probe = RunProbe()
    let controller = LibrarySyncController(fetchChanges: { _, _, _, _ in
      try await probe.fetch()
    })
    let session = profile()
    let oldRun = UUID()
    let newRun = UUID()
    await controller.start(profile: session, runID: oldRun) { _ in }
    try await wait { await probe.calls == 1 }
    await controller.start(profile: session, runID: newRun) { _ in }
    try await wait {
      let calls = await probe.calls
      let cancellations = await probe.cancellations
      return calls == 2 && cancellations == 1
    }
    await controller.stop(runID: oldRun)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await probe.cancellations == 1)
    await controller.stop(runID: newRun)
    try await wait { await probe.cancellations == 2 }
    #expect(await probe.calls == 2)
  }

  @Test
  func oldSessionCursorCacheIsBounded() async throws {
    let probe = SessionProbe()
    let first = profile()
    let controller = LibrarySyncController(
      fetchChanges: { profile, cursor, _, _ in
        try await probe.fetch(profile: profile, cursor: cursor)
      }, delay: { _ in try await Task.sleep(for: .milliseconds(1)) })
    for index in 0..<17 {
      let current =
        index == 0
        ? first
        : StoredServerProfile(
          serverId: first.serverId, name: first.name, baseURL: first.baseURL,
          publicKeyFingerprint: first.publicKeyFingerprint, token: "synthetic-\(index)",
          sessionId: UUID(), expiresAt: first.expiresAt)
      await controller.start(profile: current) { _ in }
      // Seeing the first fetch is not proof its callback/cursor was committed.
      // A second fetch at the committed cursor is the acknowledgement barrier.
      try await wait { await probe.calls.contains { $0.0 == current.sessionId && $0.1 == 50 } }
    }
    let previous = await probe.calls.count
    await controller.start(profile: first) { _ in }
    try await wait {
      await probe.calls.dropFirst(previous).contains { $0.0 == first.sessionId }
    }
    await controller.stop()
    // A cancelled previous fetch may still enter the probe actor. Assert the
    // restarted session's first request, not an unrelated global array index.
    #expect(await probe.calls.dropFirst(previous).first { $0.0 == first.sessionId }?.1 == 0)
  }

  @Test
  func switchingSessionsOnSameServerStartsWithIndependentCursor() async throws {
    let probe = SessionProbe()
    let first = profile()
    let second = StoredServerProfile(
      serverId: first.serverId, name: first.name, baseURL: first.baseURL,
      publicKeyFingerprint: first.publicKeyFingerprint, token: "second-test-only",
      sessionId: UUID(), expiresAt: first.expiresAt)
    let controller = LibrarySyncController(fetchChanges: { profile, cursor, _, _ in
      try await probe.fetch(profile: profile, cursor: cursor)
    })
    await controller.start(profile: first) { _ in }
    try await wait { await probe.calls.count >= 1 }
    await controller.start(profile: second) { _ in }
    try await wait { await probe.calls.count >= 2 }
    await controller.stop()
    let calls = await probe.calls
    #expect(calls[0].1 == 0)
    #expect(calls[1].1 == 0)
  }

  private func profile() -> StoredServerProfile {
    StoredServerProfile(
      serverId: UUID(), name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
  }

  private func wait(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw APIClientError.invalidResponse
  }
}

private actor RunProbe {
  private(set) var calls = 0
  private(set) var cancellations = 0
  func fetch() async throws -> SyncChangesResponse {
    calls += 1
    do { try await Task.sleep(for: .seconds(60)) } catch {
      cancellations += 1
      throw error
    }
    return SyncChangesResponse(
      cursor: 0, resetRequired: false, changedAreas: [], changedMediaIds: [])
  }
}

private actor FailureProbe {
  private(set) var calls = 0
  func received() { calls += 1 }
}

private actor LegacyPageProbe {
  private(set) var calls = 0
  func fetch(offset: Int) -> PagedResponse<MovieSummary> {
    calls += 1
    return PagedResponse(
      items: [MovieSummary(id: UUID(), title: "Synthetic", year: nil, availability: .available)],
      offset: offset, limit: 1, total: offset + 2)
  }
}

private actor PageProbe {
  private let ids = [UUID(), UUID(), UUID()]
  private let alwaysConflict: Bool
  private(set) var attempt = 0
  init(alwaysConflict: Bool = false) { self.alwaysConflict = alwaysConflict }
  func fetch(offset: Int, revision: String?) -> PagedResponse<MovieSummary> {
    if offset == 0 { attempt += 1 }
    let conflict = offset > 0 && (attempt == 1 || alwaysConflict)
    let indices = offset == 0 ? [0, 1] : [2]
    return PagedResponse(
      items: indices.map {
        MovieSummary(id: ids[$0], title: ["A", "B", "C"][$0], year: nil, availability: .available)
      },
      offset: offset, limit: 2, total: 3, revision: conflict ? "changed" : "stable")
  }
}

private actor SyncProbe {
  private let missing: Bool
  private(set) var calls = 0
  private(set) var updates = 0
  init(missing: Bool = false) { self.missing = missing }
  func received() { updates += 1 }
  func fetch() async throws -> SyncChangesResponse {
    calls += 1
    if missing {
      throw APIClientError.httpFailure(status: 404, retryAfter: nil, code: nil, message: nil)
    }
    if calls == 1 { throw APIClientError.invalidResponse }
    if calls > 2 { try await Task.sleep(for: .seconds(60)) }
    return SyncChangesResponse(
      cursor: 10, resetRequired: false, changedAreas: [.catalog], changedMediaIds: [],
      generation: "synthetic")
  }
}

private actor SessionProbe {
  private(set) var calls: [(UUID?, Int64)] = []
  func fetch(profile: StoredServerProfile, cursor: Int64) async throws -> SyncChangesResponse {
    calls.append((profile.sessionId, cursor))
    return SyncChangesResponse(
      cursor: 50, resetRequired: false, changedAreas: [.catalog], changedMediaIds: [],
      generation: "synthetic")
  }
}
