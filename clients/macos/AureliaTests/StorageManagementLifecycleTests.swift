import Foundation
import Testing

@testable import Aurelia

@MainActor
struct StorageManagementLifecycleTests {
  @Test func nonAdminCannotExerciseStoragePairingOrDeviceActions() async {
    let model = AppModel(
      store: InMemoryServerProfileStore(), initialProfile: profile(role: .user),
      profileSelectionEnabled: true)
    await exerciseStorageActions(model)
    await model.generatePairingCode()
    await model.revokeSession(id: UUID())
    #expect(model.visibleErrorMessage == nil)
    #expect(model.administrationErrorMessage == nil)
    #expect(model.libraries.isEmpty)
    #expect(model.activeScans.isEmpty)
    #expect(model.pairingCode == nil)
    #expect(model.sessions.isEmpty)
    #expect(!model.isWorking)
  }

  @Test func selectedTitleAdministratorCannotStartStorageActionsEvenWhenUnlocked() async {
    let model = AppModel(
      store: InMemoryServerProfileStore(),
      initialProfile: profile(role: .admin, mode: .selectedTitles),
      profileSelectionEnabled: true, initialManagementExpiry: Date().addingTimeInterval(600))
    #expect(model.canManageMedia)
    #expect(!model.canManageStorage)
    await exerciseStorageActions(model)
    #expect(model.visibleErrorMessage == nil)
    #expect(model.administrationErrorMessage == nil)
    #expect(model.libraries.isEmpty)
    #expect(model.activeScans.isEmpty)
  }

  @Test func retiredMultiStepOperationCannotUseANewlyUnlockedWindow() async throws {
    let pending = PendingStorageStep()
    let model = AppModel(
      store: InMemoryServerProfileStore(), initialProfile: profile(), profileSelectionEnabled: true,
      initialManagementExpiry: Date().addingTimeInterval(600),
      managementUnlocker: { _, _ in Date().addingTimeInterval(600).ISO8601Format() },
      managementLocker: { _ in },
      administrationFetcher: { _ in AppModel.AdministrationSnapshot() })
    let original = model.administrationGeneration
    var secondStepStarted = false
    let operation = Task {
      do {
        _ = try await model.currentAdministration {
          try await pending.wait()
          guard model.isCurrentAdministration(original) else { throw CancellationError() }
          secondStepStarted = true
          return true
        }
        return true
      } catch is CancellationError {
        return false
      } catch {
        Issue.record("A retired operation must fail as cancellation, not an API error.")
        return false
      }
    }
    try await pending.waitForRequest()
    await model.lockManagement()
    #expect(await model.unlockManagement(password: "synthetic-only-server-password"))
    #expect(model.managementUnlocked)
    #expect(model.administrationGeneration != original)
    pending.release()
    #expect(!(await operation.value))
    #expect(!secondStepStarted)
    #expect(model.visibleErrorMessage == nil)
    #expect(model.administrationErrorMessage == nil)
  }

  private func exerciseStorageActions(_ model: AppModel) async {
    #expect(!(await model.createStorageLocations([])))
    #expect(!(await model.addStorageLocations([], combineExisting: true)))
    await model.removeLibrary(id: UUID())
    await model.scanLibrary(id: UUID())
    await model.setMonitoring(libraryID: UUID(), enabled: true)
    await model.cancelScan(id: UUID())
    let discovery = LibraryDiscoverySummary(
      id: UUID(), libraryId: UUID(), relativePath: "Synthetic", detectedTitle: "Synthetic",
      suggestedKind: .automatic, reason: "Synthetic review", decision: nil)
    await model.classifyDiscovery(discovery, as: .movie)
    await model.reviewIgnoredDiscovery(discovery)
    await model.didConfirmImport(
      scan: LibraryScanSummary(
        id: UUID(), libraryId: UUID(), state: .queued, createdAt: "2026-01-01T00:00:00Z",
        startedAt: nil, completedAt: nil, filesDiscovered: 0, filesProcessed: 0, addedFiles: 0,
        updatedFiles: 0, missingFiles: 0, skippedFiles: 0, error: nil, issues: []))
  }

  private func profile(
    role: UserRole = .owner, mode: ProfileAccessMode = .entireLibrary
  ) -> StoredServerProfile {
    StoredServerProfile(
      serverId: UUID(), name: "Synthetic Server", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "synthetic-only-viewing-token", sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z",
      user: UserSummary(
        id: UUID(), username: "Synthetic Profile", role: role, createdAt: "2026-01-01T00:00:00Z",
        accessMode: mode), viewingSession: true)
  }
}

@MainActor
private final class PendingStorageStep {
  private var continuation: CheckedContinuation<Void, Error>?
  func wait() async throws {
    try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func waitForRequest() async throws {
    for _ in 0..<1_000 {
      if continuation != nil { return }
      await Task.yield()
    }
    throw URLError(.timedOut)
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
