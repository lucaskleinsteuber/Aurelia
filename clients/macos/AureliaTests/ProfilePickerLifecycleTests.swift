import Foundation
import SwiftUI
import Testing

@testable import Aurelia

@MainActor
struct ProfilePickerLifecycleTests {
  @Test(arguments: ["1234", "12345678"])
  func enterCompatiblePINUsesOneRequestUntilTheFirstFinishes(pin: String) async throws {
    let pending = PendingProfileUnlock()
    let model = makeModel(unlocker: pending.unlock)
    let selection = choice()
    let request = Task { await model.selectWatchingProfile(selection, pin: pin) }
    try await pending.waitForRequest()
    #expect(model.isSelectingProfile)
    #expect(pending.pins == [pin])
    #expect(!(await model.selectWatchingProfile(selection, pin: pin)))
    #expect(pending.pins == [pin])
    model.cancelWatchingProfileSelection()
    pending.complete(.failure(CancellationError()))
    #expect(!(await request.value))
    #expect(!model.isSelectingProfile)
    #expect(model.profileSelectionError == nil)
  }

  @Test(arguments: ["", "123", "123456789", "12ab", "١٢٣٤"])
  func invalidPINNeverStartsARequest(pin: String) async {
    var requests = 0
    let model = makeModel(unlocker: { _, _, _ in
      requests += 1
      throw APIClientError.invalidResponse
    })
    #expect(!(await model.selectWatchingProfile(choice(), pin: pin)))
    #expect(requests == 0)
    #expect(!model.isSelectingProfile)
  }

  @Test func cancelledNoncooperativeSuccessCannotOpenTheProfileAndEndsItsSession() async throws {
    let pending = PendingProfileUnlock()
    var ended: [StoredServerProfile] = []
    var cleanupWasCancelled = true
    let model = makeModel(
      unlocker: pending.unlock,
      ender: {
        cleanupWasCancelled = Task.isCancelled
        ended.append($0)
      })
    let device = model.profile
    let selection = choice()
    let response = session(selection)
    let request = Task { await model.selectWatchingProfile(selection, pin: "1234") }
    try await pending.waitForRequest()
    request.cancel()
    model.cancelWatchingProfileSelection()
    pending.complete(.success(response))
    #expect(!(await request.value))
    #expect(model.profile == device)
    #expect(model.requiresProfileSelection)
    #expect(!model.isSelectingProfile)
    #expect(model.profileSelectionError == nil)
    #expect(ended.count == 1)
    #expect(ended.first?.sessionId == response.sessionId)
    #expect(ended.first?.token == response.token)
    #expect(!cleanupWasCancelled)
  }

  @Test func returningToSelectionInvalidatesAnUncancelledLateFailure() async throws {
    let pending = PendingProfileUnlock()
    let model = makeModel(unlocker: pending.unlock)
    let device = model.profile
    let request = Task { await model.selectWatchingProfile(choice(), pin: "1234") }
    try await pending.waitForRequest()
    model.cancelWatchingProfileSelection()
    pending.complete(.failure(APIClientError.invalidResponse))
    #expect(!(await request.value))
    #expect(model.profile == device)
    #expect(model.profileSelectionError == nil)
    #expect(model.visibleErrorMessage == nil)
  }

  @Test func profileUnlockErrorIsLocalAndClearsBeforeTheNextAttempt() async throws {
    let pending = PendingProfileUnlock()
    let model = makeModel(unlocker: pending.unlock)
    model.errorMessage = "A separate existing failure."
    let first = Task { await model.selectWatchingProfile(choice(), pin: "1234") }
    try await pending.waitForRequest()
    pending.complete(.failure(APIClientError.invalidResponse))
    #expect(!(await first.value))
    #expect(model.profileSelectionError == APIClientError.invalidResponse.localizedDescription)
    #expect(model.errorMessage == "A separate existing failure.")
    let second = Task { await model.selectWatchingProfile(choice(), pin: "12345678") }
    try await pending.waitForRequest()
    #expect(model.profileSelectionError == nil)
    model.cancelWatchingProfileSelection()
    pending.complete(.failure(CancellationError()))
    #expect(!(await second.value))
    #expect(model.errorMessage == "A separate existing failure.")
  }

  @Test func acceptedProfileSnapshotFailureIsVisibleAndRetryStartsSynchronization() async throws {
    let selection = choice()
    let response = session(selection)
    let failure = URLError(.networkConnectionLost)
    var snapshots = 0
    let probe = ProfileSyncRequestProbe()
    let controller = LibrarySyncController(fetchChanges: { _, _, _, _ in
      await probe.record()
      throw CancellationError()
    })
    let model = makeModel(
      unlocker: { _, _, _ in response },
      refresher: { _ in
        snapshots += 1
        if snapshots == 1 { throw failure }
      }, syncController: controller)
    // Unit-test startup selects client mode in memory, independent of saved host preferences.
    await model.start()
    #expect(model.operatingMode == .client)
    #expect(!(await model.selectWatchingProfile(selection, pin: "1234")))
    #expect(model.profile?.isViewingSession == true)
    #expect(model.profile?.sessionId == response.sessionId)
    #expect(model.profileSelectionError == nil)
    #expect(model.visibleErrorMessage == failure.localizedDescription)
    #expect(await probe.count == 0)
    await model.refreshFromUI()
    #expect(snapshots == 2)
    #expect(model.visibleErrorMessage == nil)
    for _ in 0..<1_000 {
      if await probe.count > 0 { break }
      await Task.yield()
    }
    #expect(await probe.count == 1)
    await controller.stop()
  }

  @Test func acceptedOldSessionSnapshotFailureCannotOverwriteAReplacementSession() async throws {
    let selection = choice()
    let response = session(selection)
    let snapshot = PendingProfileSnapshot()
    let controller = LibrarySyncController(fetchChanges: { _, _, _, _ in throw CancellationError() }
    )
    let model = makeModel(
      unlocker: { _, _, _ in response }, refresher: snapshot.refresh, syncController: controller)
    let device = try #require(model.profile)
    let request = Task { await model.selectWatchingProfile(selection, pin: "1234") }
    try await snapshot.waitForRequest()
    let accepted = try #require(model.profile)
    let replacement = StoredServerProfile(
      serverId: accepted.serverId, name: accepted.name, baseURL: accepted.baseURL,
      publicKeyFingerprint: accepted.publicKeyFingerprint, token: "synthetic-only-replacement",
      sessionId: UUID(), expiresAt: accepted.expiresAt, user: accepted.user,
      locallyManaged: accepted.locallyManaged, viewingSession: true)
    try model.acceptConfirmedNetwork(profile: replacement, device: device)
    model.errorMessage = "The replacement session has its own failure."
    snapshot.complete(.failure(URLError(.networkConnectionLost)))
    #expect(!(await request.value))
    #expect(model.profile == replacement)
    #expect(model.profileSelectionError == nil)
    #expect(model.errorMessage == "The replacement session has its own failure.")
    await controller.stop()
  }

  private func makeModel(
    unlocker:
      @escaping @MainActor (StoredServerProfile, UUID, String) async throws ->
      ProfileSessionResponse,
    ender: (@MainActor (StoredServerProfile) async throws -> Void)? = nil,
    refresher: (@MainActor (StoredServerProfile) async throws -> Void)? = nil,
    syncController: LibrarySyncController = LibrarySyncController()
  ) -> AppModel {
    AppModel(
      store: InMemoryServerProfileStore(),
      initialProfile: StoredServerProfile(
        serverId: UUID(), name: "Synthetic Server",
        baseURL: URL(string: "https://fixture.invalid")!,
        publicKeyFingerprint: String(repeating: "A", count: 64), token: "synthetic-only-device",
        sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z"),
      syncController: syncController, profileSelectionEnabled: true, profileUnlocker: unlocker,
      profileSessionEnder: ender, profileSnapshotRefresher: refresher)
  }

  private func choice() -> WatchingProfile {
    WatchingProfile(id: UUID(), name: "Synthetic Viewer", role: .user, needsPinSetup: false)
  }

  private func session(_ profile: WatchingProfile) -> ProfileSessionResponse {
    ProfileSessionResponse(
      user: UserSummary(
        id: profile.id, username: profile.name, role: profile.role,
        createdAt: "2026-01-01T00:00:00Z"), sessionId: UUID(), token: "synthetic-only-session",
      expiresAt: "2099-01-01T00:00:00Z")
  }
}

struct ProfilePickerLayoutTests {
  @Test func oneAndTwoProfilesHaveStableCenteredWidths() {
    #expect(CenteredProfileLayout.rowWidth(count: 1) == 140)
    #expect(CenteredProfileLayout.rowWidth(count: 2) == 304)
    #expect(CenteredProfileLayout.columns(availableWidth: 900, count: 1) == 1)
    #expect(CenteredProfileLayout.columns(availableWidth: 900, count: 2) == 2)
    #expect(CenteredProfileLayout.columns(availableWidth: 303, count: 2) == 1)
    #expect(CenteredProfileLayout.columns(availableWidth: 304, count: 2) == 2)
  }

  @Test func wrappedRowsUseAvailableWidthAndTheLastRowsActualCount() {
    #expect(CenteredProfileLayout.columns(availableWidth: 740, count: 7) == 4)
    #expect(CenteredProfileLayout.rowWidth(count: 4) == 632)
    #expect(CenteredProfileLayout.rowWidth(count: 3) == 468)
    #expect(CenteredProfileLayout.columns(availableWidth: 500, count: 7) == 3)
    #expect(CenteredProfileLayout.rowWidth(count: 1) == 140)
  }

  @Test func unconstrainedOrNonfiniteProposalsUseNaturalFiniteWidth() {
    for width: CGFloat? in [nil, .infinity, -.infinity, .nan] {
      #expect(CenteredProfileLayout.measuredWidth(proposed: width, count: 3) == 468)
    }
    #expect(CenteredProfileLayout.columns(availableWidth: .infinity, count: 3) == 3)
    #expect(CenteredProfileLayout.columns(availableWidth: .nan, count: 3) == 3)
    #expect(CenteredProfileLayout.columns(availableWidth: .greatestFiniteMagnitude, count: 3) == 3)
    #expect(CenteredProfileLayout.measuredWidth(proposed: 0, count: 3) == 140)
    #expect(CenteredProfileLayout.columns(availableWidth: 0, count: 3) == 1)
    #expect(CenteredProfileLayout.columns(availableWidth: 0, count: 0) == 1)
  }
}

@MainActor
private final class PendingProfileUnlock {
  private var continuation: CheckedContinuation<ProfileSessionResponse, Error>?
  private(set) var pins: [String] = []

  func unlock(_ profile: StoredServerProfile, _ id: UUID, _ pin: String) async throws
    -> ProfileSessionResponse
  {
    pins.append(pin)
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func waitForRequest() async throws {
    for _ in 0..<1_000 {
      if continuation != nil { return }
      await Task.yield()
    }
    throw URLError(.timedOut)
  }

  func complete(_ result: Result<ProfileSessionResponse, Error>) {
    continuation?.resume(with: result)
    continuation = nil
  }
}

@MainActor
private final class PendingProfileSnapshot {
  private var continuation: CheckedContinuation<Void, Error>?

  func refresh(_ profile: StoredServerProfile) async throws {
    try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func waitForRequest() async throws {
    for _ in 0..<1_000 {
      if continuation != nil { return }
      await Task.yield()
    }
    throw URLError(.timedOut)
  }

  func complete(_ result: Result<Void, Error>) {
    continuation?.resume(with: result)
    continuation = nil
  }
}

private actor ProfileSyncRequestProbe {
  private(set) var count = 0
  func record() { count += 1 }
}
