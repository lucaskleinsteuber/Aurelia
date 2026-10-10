import Foundation
import Testing

@testable import Aurelia

@MainActor
struct ConnectionReliabilityTests {
  @Test
  func legacyKeychainMigrationCannotResurrectDisconnectedProfile() throws {
    let currentService = "Aurelia.tests.current.\(UUID().uuidString)"
    let legacyService = "Aurelia.tests.legacy.\(UUID().uuidString)"
    let legacy = KeychainServerStore(service: legacyService)
    let current = KeychainServerStore(service: currentService, migrationService: legacyService)
    defer { try? current.delete() }
    let profile = syntheticProfile()
    try legacy.save(profile)
    #expect(try current.load() == profile)
    #expect(try legacy.load() == nil)
    try current.delete()
    #expect(try current.load() == nil)

    // Disconnect also retires an unmigrated fallback.
    try legacy.save(profile)
    try current.delete()
    #expect(try current.load() == nil)
  }

  @Test
  func failedSecureDisconnectRetainsConnectionAndReportsFailure() async {
    let profile = syntheticProfile()
    let model = AppModel(store: FailingDisconnectStore(profile: profile), initialProfile: profile)
    await model.disconnect()
    #expect(model.profile == profile)
    #expect(model.errorMessage?.contains("could not be removed securely") == true)
  }

  @Test(arguments: [
    APIClientError.serverIdentityMismatch,
    APIClientError.httpFailure(status: 401, retryAfter: nil, code: nil, message: nil),
    APIClientError.httpFailure(
      status: 422, retryAfter: nil, code: "sync_unavailable", message: "Synchronization stopped."),
  ])
  func definitiveSyncFailureIsVisibleAfterForegroundRestart(error: APIClientError) async throws {
    let controller = LibrarySyncController(fetchChanges: { _, _, _, _ in throw error })
    let model = AppModel(
      store: InMemoryServerProfileStore(), initialProfile: syntheticProfile(),
      syncController: controller)
    await model.start()
    await model.setApplicationActive(false)
    await model.setApplicationActive(true)
    for _ in 0..<200 {
      if model.errorMessage != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.errorMessage == error.localizedDescription)
    await model.disconnect()
    #expect(model.errorMessage == nil)
  }

  @Test
  func delayedAdministrationCannotRepopulateAfterDisconnect() async throws {
    let pending = PendingAdministration()
    let model = AppModel(
      store: InMemoryServerProfileStore(), initialProfile: syntheticProfile(),
      administrationFetcher: pending.fetch)
    let request = Task { await model.reloadAdministration() }
    try await pending.waitForRequest()
    await model.disconnect()
    pending.complete(.success(AppModel.AdministrationSnapshot(libraries: [library()])))
    await request.value
    #expect(model.profile == nil)
    #expect(model.libraries.isEmpty)
    #expect(model.sessions.isEmpty)
    #expect(model.errorMessage == nil)
  }

  @Test
  func delayedAdministrationFailureCannotRestoreAnErrorAfterDisconnect() async throws {
    let pending = PendingAdministration()
    let model = AppModel(
      store: InMemoryServerProfileStore(), initialProfile: syntheticProfile(),
      administrationFetcher: pending.fetch)
    let request = Task { await model.reloadAdministration() }
    try await pending.waitForRequest()
    await model.disconnect()
    pending.complete(.failure(URLError(.timedOut)))
    await request.value
    #expect(model.errorMessage == nil)
  }

  @Test(arguments: [false, true])
  func obsoleteArtworkCompletionCannotFinishReplacement(clearAll: Bool) async throws {
    let fetcher = PendingArtwork()
    let loader = ArtworkLoader(fetcher: fetcher.fetch)
    let profile = syntheticProfile()
    let artwork = artwork()
    let old = Task { try await loader.data(for: artwork, profile: profile) }
    try await fetcher.waitForRequests(1)
    if clearAll { loader.removeAll() } else { old.cancel() }
    do {
      _ = try await old.value
      Issue.record("Cancelled subscribers must finish with cancellation.")
    } catch {
      #expect(error is CancellationError)
    }
    let replacement = Task { try await loader.data(for: artwork, profile: profile) }
    try await fetcher.waitForRequests(2)
    fetcher.complete(0, with: Data([1]))
    for _ in 0..<20 { await Task.yield() }
    fetcher.complete(1, with: Data([2]))
    #expect(try await replacement.value == Data([2]))
    #expect(try await loader.data(for: artwork, profile: profile) == Data([2]))
  }

  @Test
  func artworkCacheIsNotSharedBetweenSessionsOnOneServer() async throws {
    var requests = 0
    let loader = ArtworkLoader { _, _ in
      requests += 1
      return Data([UInt8(requests)])
    }
    let first = syntheticProfile()
    let second = syntheticProfile(serverID: first.serverId)
    #expect(try await loader.data(for: artwork(), profile: first) == Data([1]))
    #expect(try await loader.data(for: artwork(), profile: second) == Data([2]))
  }

  private func artwork() -> ArtworkSummary {
    let id = UUID(uuidString: "10000000-0000-0000-0000-000000000099")!
    return ArtworkSummary(
      id: id, kind: .poster, path: "/api/v1/artwork/\(id.uuidString.lowercased())",
      contentType: "image/jpeg", contentLength: 1)
  }

  private func library() -> LibrarySummary {
    LibrarySummary(
      id: UUID(), name: "Synthetic Library", path: "/synthetic-only", kind: .automatic,
      availability: .available, createdAt: "2026-01-01T00:00:00Z", lastScanStartedAt: nil,
      lastScanCompletedAt: nil, lastError: nil)
  }
}

private func syntheticProfile(serverID: UUID = UUID()) -> StoredServerProfile {
  StoredServerProfile(
    serverId: serverID, name: "Synthetic Server", baseURL: URL(string: "https://fixture.invalid")!,
    publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
    sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z",
    user: UserSummary(
      id: UUID(), username: "synthetic", role: .owner, createdAt: "2026-01-01T00:00:00Z"))
}

private struct FailingDisconnectStore: ServerProfileStore {
  let profile: StoredServerProfile
  func load() throws -> StoredServerProfile? { profile }
  func save(_ profile: StoredServerProfile) throws {}
  func delete() throws { throw KeychainServerStore.StoreError.unexpectedStatus(-1) }
}

@MainActor
private final class PendingAdministration {
  var pending: CheckedContinuation<AppModel.AdministrationSnapshot, Error>?
  func fetch(_ profile: StoredServerProfile) async throws -> AppModel.AdministrationSnapshot {
    try await withCheckedThrowingContinuation { pending = $0 }
  }
  func waitForRequest() async throws {
    for _ in 0..<1_000 {
      if pending != nil { return }
      await Task.yield()
    }
    throw URLError(.timedOut)
  }
  func complete(_ result: Result<AppModel.AdministrationSnapshot, Error>) {
    pending?.resume(with: result)
    pending = nil
  }
}

@MainActor
private final class PendingArtwork {
  var pending: [Int: CheckedContinuation<Data, Error>] = [:]
  var count = 0
  func fetch(_ artwork: ArtworkSummary, _ profile: StoredServerProfile) async throws -> Data {
    let index = count
    count += 1
    return try await withCheckedThrowingContinuation { pending[index] = $0 }
  }
  func waitForRequests(_ expected: Int) async throws {
    for _ in 0..<1_000 {
      if count >= expected { return }
      await Task.yield()
    }
    throw URLError(.timedOut)
  }
  func complete(_ index: Int, with data: Data) {
    pending.removeValue(forKey: index)?.resume(returning: data)
  }
}
