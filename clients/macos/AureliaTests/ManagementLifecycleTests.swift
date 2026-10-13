import Foundation
import Testing

@testable import Aurelia

@MainActor
struct ManagementLifecycleTests {
  @Test func lockedAdministrationDoesNotFetchOrPublishAGlobalFailure() async {
    var requests = 0
    let model = AppModel(
      store: InMemoryServerProfileStore(), initialProfile: profile(), profileSelectionEnabled: true,
      administrationFetcher: { _ in
        requests += 1
        throw APIClientError.invalidResponse
      })
    await model.reloadAdministration()
    #expect(requests == 0)
    #expect(model.visibleErrorMessage == nil)
    #expect(model.administrationErrorMessage == nil)
  }

  @Test(arguments: [false, true])
  func retiredAdministrationCannotRepopulateStateOrErrors(failed: Bool) async throws {
    let pending = PendingManagementSnapshot()
    let model = AppModel(
      store: InMemoryServerProfileStore(), initialProfile: profile(), profileSelectionEnabled: true,
      initialManagementExpiry: Date().addingTimeInterval(600), managementLocker: { _ in },
      administrationFetcher: pending.fetch)
    let request = Task { await model.reloadAdministration() }
    try await pending.waitForRequest()
    let oldGeneration = model.administrationGeneration
    await model.lockManagement()
    if failed {
      pending.complete(.failure(APIClientError.invalidResponse))
    } else {
      pending.complete(.success(AppModel.AdministrationSnapshot(libraries: [library()])))
    }
    await request.value
    #expect(model.administrationGeneration != oldGeneration)
    #expect(!model.managementUnlocked)
    #expect(model.libraries.isEmpty)
    #expect(model.visibleErrorMessage == nil)
    #expect(model.administrationErrorMessage == nil)
  }

  @Test func managementLockIsAnExpectedLocalStateNotALostViewingSession() async {
    let active = profile()
    let model = AppModel(
      store: InMemoryServerProfileStore(), initialProfile: active, profileSelectionEnabled: true,
      initialManagementExpiry: Date().addingTimeInterval(600),
      administrationFetcher: { _ in
        throw APIClientError.httpFailure(
          status: 403, retryAfter: nil, code: "management_locked", message: "Unlock management.")
      })
    await model.reloadAdministration()
    #expect(model.profile == active)
    #expect(!model.managementUnlocked)
    #expect(model.visibleErrorMessage == nil)
    #expect(model.administrationErrorMessage == nil)
  }

  @Test func malformedAdministrationResponseIsLocalButCertificateMismatchRemainsGlobal() async {
    for failure in [APIClientError.invalidResponse, .serverIdentityMismatch] {
      let model = AppModel(
        store: InMemoryServerProfileStore(), initialProfile: profile(),
        profileSelectionEnabled: true,
        initialManagementExpiry: Date().addingTimeInterval(600),
        administrationFetcher: { _ in throw failure })
      await model.reloadAdministration()
      if failure == .serverIdentityMismatch {
        #expect(model.visibleErrorMessage == failure.localizedDescription)
      } else {
        #expect(model.visibleErrorMessage == nil)
        #expect(model.administrationErrorMessage == failure.localizedDescription)
      }
    }
  }

  @Test func successfulUnlockCannotEraseAnUnrelatedError() async {
    let model = AppModel(
      store: InMemoryServerProfileStore(), initialProfile: profile(), profileSelectionEnabled: true,
      managementUnlocker: { _, _ in Date().addingTimeInterval(600).ISO8601Format() },
      administrationFetcher: { _ in AppModel.AdministrationSnapshot() })
    model.errorMessage = APIClientError.serverIdentityMismatch.localizedDescription
    #expect(await model.unlockManagement(password: "synthetic-only-server-password"))
    #expect(model.errorMessage == APIClientError.serverIdentityMismatch.localizedDescription)
    #expect(model.administrationErrorMessage == nil)
  }

  private func profile() -> StoredServerProfile {
    StoredServerProfile(
      serverId: UUID(), name: "Synthetic Server", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "synthetic-only-viewing-token",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z",
      user: UserSummary(
        id: UUID(), username: "Owner", role: .owner, createdAt: "2026-01-01T00:00:00Z"),
      viewingSession: true)
  }
  private func library() -> LibrarySummary {
    LibrarySummary(
      id: UUID(), name: "Synthetic", path: "/synthetic-only", kind: .automatic,
      availability: .available, createdAt: "2026-01-01T00:00:00Z", lastScanStartedAt: nil,
      lastScanCompletedAt: nil, lastError: nil)
  }
}

@MainActor
private final class PendingManagementSnapshot {
  private var continuation: CheckedContinuation<AppModel.AdministrationSnapshot, Error>?
  func fetch(_ profile: StoredServerProfile) async throws -> AppModel.AdministrationSnapshot {
    try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func waitForRequest() async throws {
    for _ in 0..<1_000 {
      if continuation != nil { return }
      await Task.yield()
    }
    throw URLError(.timedOut)
  }
  func complete(_ result: Result<AppModel.AdministrationSnapshot, Error>) {
    continuation?.resume(with: result)
    continuation = nil
  }
}
