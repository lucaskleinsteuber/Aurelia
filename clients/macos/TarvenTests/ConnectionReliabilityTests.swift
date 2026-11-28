import AppKit
import Foundation
import Security
import Testing

@testable import Tarven

@MainActor
struct ConnectionReliabilityTests {
  @Test
  func legacyKeychainMigrationCannotResurrectDisconnectedProfile() throws {
    let currentService = "Tarven.tests.current.\(UUID().uuidString)"
    let legacyService = "Tarven.tests.legacy.\(UUID().uuidString)"
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

  @Test func tarvenRestsOnlyWhenNothingPlaysAndNobodyUsedTheMac() throws {
    let suite = "TarvenRestTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(TarvenRest.isEnabled(defaults: defaults))
    #expect(TarvenRest.minutes(defaults: defaults) == 15)
    defaults.set(7, forKey: TarvenRest.minutesKey)
    #expect(TarvenRest.minutes(defaults: defaults) == 15, "Only offered choices count.")
    defaults.set(30, forKey: TarvenRest.minutesKey)
    #expect(TarvenRest.minutes(defaults: defaults) == 30)

    func rests(
      enabled: Bool = true, idle: TimeInterval = 15 * 60, playing: Bool = false,
      elsewhere: Bool = true, powerSaving: Bool = true
    ) -> Bool {
      TarvenRest.shouldRest(
        enabled: enabled, minutes: 15, secondsWithoutInput: idle, playing: playing,
        connectedElsewhere: elsewhere, serverPowerSavingEnabled: powerSaving)
    }
    #expect(rests())
    #expect(!rests(idle: 14 * 60))
    #expect(!rests(playing: true), "A title playing through the night is still watched.")
    #expect(!rests(enabled: false))
    #expect(!rests(elsewhere: false), "A server on this Mac is not left alone.")
    #expect(!rests(powerSaving: false), "A server with power saving off never rests.")
  }

  @Test func onlyUsingTarvenItselfCountsAsUse() {
    let now = Date()
    let left = now.addingTimeInterval(-20 * 60)
    #expect(
      TarvenRest.secondsWithoutUse(
        isActive: true, secondsWithoutInput: 40, lastActive: left, now: now) == 40,
      "In front, the last input went to Tarven.")
    #expect(
      TarvenRest.secondsWithoutUse(
        isActive: true, secondsWithoutInput: 20 * 60, lastActive: now.addingTimeInterval(-3),
        now: now) == 3,
      "Just focusing Tarven resets idle time even before any new key or mouse input.")
    #expect(
      TarvenRest.secondsWithoutUse(
        isActive: false, secondsWithoutInput: 2, lastActive: left, now: now) == 20 * 60,
      "Typing in another app does not keep the server awake.")
    #expect(
      TarvenRest.secondsWithoutUse(
        isActive: false, secondsWithoutInput: 2, lastActive: now.addingTimeInterval(5), now: now)
        == 0)
  }

  @Test @MainActor func leavingTarvenIsNotedFromAnyThread() async throws {
    let clock = TarvenUseClock.shared
    let before = clock.lastActive
    try await Task.sleep(for: .milliseconds(20))
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        NotificationCenter.default.post(
          name: NSApplication.didResignActiveNotification, object: nil)
        continuation.resume()
      }
    }
    for _ in 0..<100 where clock.lastActive == before {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(clock.lastActive > before)
  }

  @Test func restingClosesThePlayerAndStaysQuiet() async {
    let profile = syntheticProfile().changingPowerSaving(true)
    let model = AppModel(store: FailingDisconnectStore(profile: profile), initialProfile: profile)
    guard model.operatingMode != .host else { return }
    model.startRemoteDeviceService()
    #expect(model.hasActiveRemoteDeviceTasks)
    await model.enterRest()
    #expect(model.isResting)
    #expect(!model.hasActiveRemoteDeviceTasks)
    #expect(model.playback == nil)
    #expect(model.connectionStatus == nil)
    // Nothing a view might trigger meanwhile reaches the server.
    await model.refreshFromUI()
    await model.refreshHome()
    await model.reloadWatchingProfiles()
    model.startRemoteDeviceService()
    #expect(!model.hasActiveRemoteDeviceTasks)
    #expect(model.errorMessage == nil)
    #expect(model.isResting)
  }

  @Test func serverWithoutPowerSavingOrLoopbackNeverRestsAndActivationLeavesRest() async throws {
    let suite = "TarvenRestPolicyTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    // Default profile has powerSavingEnabled == false: never rests.
    let defaultProfile = syntheticProfile()
    #expect(!defaultProfile.powerSavingEnabled)
    let defaultModel = AppModel(
      store: FailingDisconnectStore(profile: defaultProfile), initialProfile: defaultProfile)
    defaultModel.restDefaults = defaults
    defaultModel.secondsWithoutUse = { 30 * 60 }
    await defaultModel.start()
    #expect(!defaultModel.shouldRest())
    await defaultModel.enterRest()
    #expect(!defaultModel.isResting)

    // Loopback servers never rest even if powerSavingEnabled == true.
    for address in [
      "https://127.0.0.1:43111", "https://localhost:43111", "https://[::1]:43111",
    ] {
      let url = try #require(URL(string: address))
      #expect(AppModel.isLoopbackHost(url))
      let loopback = syntheticProfile().changingAddress(url).changingPowerSaving(true)
      let loopModel = AppModel(
        store: FailingDisconnectStore(profile: loopback), initialProfile: loopback)
      loopModel.restDefaults = defaults
      loopModel.secondsWithoutUse = { 30 * 60 }
      await loopModel.start()
      #expect(!loopModel.shouldRest())
      await loopModel.enterRest()
      #expect(!loopModel.isResting)
    }

    // Remote server with powerSavingEnabled == true rests when idle, and leaves rest automatically
    // when Tarven becomes active or when server power saving is turned off.
    let remote = syntheticProfile().changingPowerSaving(true)
    let model = AppModel(store: InMemoryServerProfileStore(profile: remote), initialProfile: remote)
    model.restDefaults = defaults
    model.serverWakeUp.probe = { _ in true }
    model.secondsWithoutUse = { 30 * 60 }
    await model.start()
    guard model.operatingMode != .host else { return }
    #expect(model.shouldRest())
    await model.enterRest()
    #expect(model.isResting)

    await model.setApplicationActive(true)
    #expect(!model.isResting)

    // Notification-driven activation also leaves rest automatically.
    await model.enterRest()
    #expect(model.isResting)
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    for _ in 0..<100 where model.isResting {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isResting)

    // Turning power saving off on the server prevents resting and leaves rest if active.
    await model.enterRest()
    #expect(model.isResting)
    model.noteServerPowerSettings(
      ServerPowerSettings(
        available: true, mode: "off", idleMinutes: 15, awakeFrom: nil, awakeUntil: nil))
    #expect(!model.serverPowerSavingEnabled)
    for _ in 0..<100 where model.isResting {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isResting)
  }

  @Test func systemSleepStopsRemoteDeviceTasks() async {
    let profile = syntheticProfile()
    let model = AppModel(store: FailingDisconnectStore(profile: profile), initialProfile: profile)
    model.startRemoteDeviceService()
    #expect(model.hasActiveRemoteDeviceTasks)
    await model.systemWillSleep()
    #expect(!model.hasActiveRemoteDeviceTasks)
  }

  @Test func aSignInKeptInTheLoginKeychainMovesToTheDataProtectionKeychain() throws {
    let service = "Tarven.tests.move.\(UUID().uuidString)"
    let profile = syntheticProfile()
    // The login keychain alone: without the flag set to false, macOS also finds the new copy.
    let legacy: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "active-server", kSecUseDataProtectionKeychain as String: false,
    ]
    var add = legacy
    add[kSecValueData as String] = try JSONEncoder().encode(profile)
    #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
    let store = KeychainServerStore(service: service)
    defer {
      try? store.delete()
      SecItemDelete(legacy as CFDictionary)
    }
    #expect(try store.load() == profile)
    if TarvenKeychain.usesDataProtection {
      #expect(SecItemCopyMatching(legacy as CFDictionary, nil) == errSecItemNotFound)
    }
    #expect(try store.load() == profile)
    try store.delete()
    #expect(try store.load() == nil)
  }

  @Test func viewingCredentialCannotReplacePersistedDeviceCredential() throws {
    let store = KeychainServerStore(service: "Tarven.tests.device-only.\(UUID().uuidString)")
    defer { try? store.delete() }
    let device = syntheticProfile()
    try store.save(device)
    let viewing = StoredServerProfile(
      serverId: device.serverId, name: device.name, baseURL: device.baseURL,
      publicKeyFingerprint: device.publicKeyFingerprint, token: "synthetic-viewing-token",
      sessionId: UUID(),
      expiresAt: device.expiresAt, user: device.user, locallyManaged: device.locallyManaged,
      viewingSession: true)
    #expect(throws: KeychainServerStore.StoreError.self) { try store.save(viewing) }
    #expect(try store.load() == device)
    #expect(viewing.changingAddress(URL(string: "https://other.fixture.invalid")!).isViewingSession)
    #expect(viewing.retainingLocalHosting().isViewingSession)
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
      if model.synchronizationErrorMessage != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.synchronizationErrorMessage == error.localizedDescription)
    await model.disconnect()
    #expect(model.errorMessage == nil)
    #expect(model.synchronizationErrorMessage == nil)
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

struct PinnedHostMatchingTests {
  @Test func aPinnedHostMatchesHoweverItsAddressIsWritten() {
    #expect(TLSTrustDelegate.sameHost("Tarven.local", "tarven.local"))
    #expect(TLSTrustDelegate.sameHost("fe80::1%en0", "[fe80::1%25en0]"))
    #expect(TLSTrustDelegate.sameHost("[fd00::5]", "fd00::5"))
    #expect(!TLSTrustDelegate.sameHost("fd00::5", "fd00::6"))
    #expect(!TLSTrustDelegate.sameHost("", ""))
  }

  @Test func unknownSyncChangeAreasDecodeTolerantlyAndTriggerFullRefresh() throws {
    let payload = Data(
      """
      {"cursor":12,"resetRequired":false,"changedAreas":["catalog","futureArea"],"changedMediaIds":[]}
      """.utf8)
    let response = try JSONDecoder().decode(SyncChangesResponse.self, from: payload)
    #expect(response.changedAreas == [.catalog, .unknown])
    let onlyFuture = SyncChangesResponse(
      cursor: 13, resetRequired: false, changedAreas: [.unknown], changedMediaIds: [])
    let plan = SyncRefreshPlan(onlyFuture)
    #expect(plan.fullCatalog)
    #expect(plan.collections)
    #expect(plan.home)
  }

  @Test func repeatedSyncDecodeFailuresReportVisibleError() async throws {
    let failures = FailureBox()
    let controller = LibrarySyncController(
      fetchChanges: { _, _, _, _ in throw APIClientError.invalidResponse },
      delay: { _ in try await Task.sleep(for: .milliseconds(1)) })
    let profile = StoredServerProfile(
      serverId: UUID(), name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
    await controller.start(
      profile: profile,
      onFailure: { error in await failures.append(error) },
      onChanges: { _ in })
    for _ in 0..<400 {
      if await failures.count > 0 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    await controller.stop()
    #expect(await failures.first == .invalidResponse)
  }

  @Test func backupUploadResourceTimeoutScalesForLargeFiles() {
    #expect(APIClient.backupUploadResourceTimeout(fileSize: 10 * 1_024 * 1_024) == 600)
    let fourGiB: Int64 = 4 * 1_024 * 1_024 * 1_024
    #expect(APIClient.backupUploadResourceTimeout(fileSize: fourGiB) > 10_000)
  }

  @Test func keychainMigrationPrefersNewerModificationDate() {
    let older = Date(timeIntervalSince1970: 1_700_000_000)
    let newer = Date(timeIntervalSince1970: 1_700_001_000)
    #expect(TarvenKeychain.shouldOverwriteExisting(legacyModified: newer, existingModified: older))
    #expect(
      !TarvenKeychain.shouldOverwriteExisting(legacyModified: older, existingModified: newer))
    #expect(
      !TarvenKeychain.shouldOverwriteExisting(legacyModified: newer, existingModified: newer))
    #expect(TarvenKeychain.shouldOverwriteExisting(legacyModified: newer, existingModified: nil))
    #expect(!TarvenKeychain.shouldOverwriteExisting(legacyModified: nil, existingModified: older))
  }

  @Test func requestURLValidationRejectsSchemeDowngradesAndForeignOrigins() throws {
    let base = URL(string: "https://server.local:43111")!
    let valid = try APIClient.validatedRequestURL(baseURL: base, path: "/api/v1/catalog")
    #expect(valid.absoluteString == "https://server.local:43111/api/v1/catalog")

    #expect(throws: APIClientError.invalidAddress) {
      _ = try APIClient.validatedRequestURL(baseURL: base, path: "https://evil.invalid:43111/api")
    }
    #expect(throws: APIClientError.invalidAddress) {
      _ = try APIClient.validatedRequestURL(baseURL: base, path: "//evil.invalid/api")
    }
    #expect(throws: APIClientError.invalidAddress) {
      _ = try APIClient.validatedRequestURL(baseURL: base, path: "https://server.local:8443/api")
    }
    #expect(throws: APIClientError.insecureAddress) {
      _ = try APIClient.validatedRequestURL(baseURL: base, path: "http://server.local:43111/api")
    }

    let loopback = URL(string: "http://127.0.0.1:43110")!
    let allowedLoopback = try APIClient.validatedRequestURL(
      baseURL: loopback, path: "/api/v1/setup/owner", requiresHTTPS: false)
    #expect(allowedLoopback.absoluteString == "http://127.0.0.1:43110/api/v1/setup/owner")
    #expect(throws: APIClientError.insecureAddress) {
      _ = try APIClient.validatedRequestURL(
        baseURL: loopback, path: "/api/v1/catalog", requiresHTTPS: true)
    }
  }

  @Test func inspectValidationDistinguishesLanDisabledFromIdentityMismatch() throws {
    let fingerprint = String(repeating: "A", count: 64)
    let lanOffInfo = ServerInfoResponse(
      serverId: UUID(), name: "Home", version: "2.30.0", isSetup: true,
      lanAccessEnabled: false, lanHttpsPort: 43_111, publicKeyFingerprint: fingerprint,
      displayFingerprint: nil)
    let remote = URL(string: "https://192.168.1.10:43111")!
    #expect(throws: APIClientError.lanAccessDisabled) {
      _ = try APIClient.validateInspection(
        baseURL: remote, info: lanOffInfo, capturedFingerprint: fingerprint)
    }
    #expect(throws: APIClientError.serverIdentityMismatch) {
      _ = try APIClient.validateInspection(
        baseURL: remote, info: lanOffInfo, capturedFingerprint: String(repeating: "B", count: 64))
    }
    let local = URL(string: "https://127.0.0.1:43111")!
    let inspected = try APIClient.validateInspection(
      baseURL: local, info: lanOffInfo, capturedFingerprint: fingerprint)
    #expect(inspected.publicKeyFingerprint == fingerprint)
  }

  @Test func offlineProfileStoreMatchesAllAccountsForServerRegardlessOfPayload() {
    let serverA = UUID()
    let serverB = UUID()
    let accounts = [
      "\(serverA.uuidString).\(UUID().uuidString)",
      "\(serverA.uuidString).corrupt-entry",
      "\(serverB.uuidString).\(UUID().uuidString)",
      "unrelated",
    ]
    let matched = KeychainOfflineProfileStore.matchingAccounts(accounts, serverId: serverA)
    #expect(matched.count == 2)
    #expect(matched.allSatisfy { $0.hasPrefix(serverA.uuidString + ".") })
  }

  @MainActor
  @Test func corruptCachedArtworkIsEvictedSoNextImageLoadRefetches() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("TarvenCorruptArtwork-\(UUID().uuidString)", isDirectory: true)
    let diskCache = ArtworkDiskCache(directory: dir, byteLimit: 1_024 * 1_024)
    defer { try? FileManager.default.removeItem(at: dir) }

    let profile = syntheticProfile()
    let id = UUID()
    let art = ArtworkSummary(
      id: id, kind: .poster, path: "/api/v1/artwork/\(id.uuidString.lowercased())",
      contentType: "image/png", contentLength: 16, revision: 5)
    let variant = ArtworkVariantRequest.artwork(art, width: 640)
    let diskKey = ArtworkDiskCache.key(
      serverID: profile.serverId, profileID: profile.user?.id, path: variant.path, revision: 5)
    diskCache.store(Data("not-a-valid-image".utf8), forKey: diskKey)
    #expect(diskCache.data(forKey: diskKey) != nil)

    var fetchCount = 0
    let loader = ArtworkLoader(diskCache: diskCache) { _, _ in
      fetchCount += 1
      return Data("still-invalid".utf8)
    }
    do {
      _ = try await loader.image(for: art, profile: profile, width: 640)
      Issue.record("Corrupt artwork must fail to decode.")
    } catch let error as APIClientError {
      #expect(error == .invalidResponse)
    }
    #expect(fetchCount == 0)
    for _ in 0..<200 {
      if diskCache.data(forKey: diskKey) == nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(diskCache.data(forKey: diskKey) == nil)
    // Next attempt refetches from server instead of staying stuck on corrupt cached bytes.
    do {
      _ = try await loader.image(for: art, profile: profile, width: 640)
    } catch {}
    #expect(fetchCount == 1)
  }
}

private actor FailureBox {
  private var items: [APIClientError] = []
  func append(_ error: APIClientError) { items.append(error) }
  var count: Int { items.count }
  var first: APIClientError? { items.first }
}
