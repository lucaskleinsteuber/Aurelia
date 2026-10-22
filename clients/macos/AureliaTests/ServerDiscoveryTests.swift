import Foundation
import Testing

@testable import Aurelia

@MainActor
struct ServerDiscoveryTests {
  @Test func serviceDisplayNameDoesNotDetermineAddressOrPort() throws {
    let description = BonjourServiceDescription(
      name: "Movies 🎬 12345678", type: "_aurelia._tcp.", domain: "local.",
      displayName: "Movies 🎬", serverId: UUID())
    let server = try #require(
      description.resolved(
        host: "actual-computer.local.", port: 54321,
        numericHosts: ["192.168.10.15", "fe80::42%en0"]))
    #expect(server.baseURL.host == "actual-computer.local.")
    #expect(server.baseURL.port == 54321)
    #expect(server.name == "Movies 🎬")
    #expect(server.addresses.count == 3)
    #expect(server.addresses.allSatisfy { $0.scheme == "https" && $0.port == 54321 })
    #expect(server.addresses.contains { $0.absoluteString.contains("fe80::42%25en0") })
    #expect(description.resolved(host: "actual.local", port: 0, numericHosts: []) == nil)
  }

  @Test func advertisementsOnDifferentInterfacesAndLegacyTypeFormOneServer() throws {
    let serverID = UUID()
    let first = BonjourServiceDescription(
      name: "Server", type: "_aurelia._tcp.", domain: "local.",
      displayName: "Library", serverId: serverID)
    let legacy = BonjourServiceDescription(
      name: "Server", type: "_aurelia-home._tcp.", domain: "local.",
      displayName: "Library", serverId: serverID)
    let servers = BonjourBrowser.merged([
      try #require(first.resolved(host: "mac.local.", port: 43111, numericHosts: ["10.0.0.5"])),
      try #require(legacy.resolved(host: "mac.local.", port: 43111, numericHosts: ["fd00::5"])),
    ])
    #expect(servers.count == 1)
    #expect(servers.first?.serverId == serverID)
    #expect(servers.first?.addresses.count == 3)
  }

  @Test func reconnectIntervalsAreBoundedAndOnlyTransportErrorsRediscover() {
    #expect(
      (0...6).map { ServerReconnectPolicy.delay(attempt: $0, jitter: 1) } == [
        3, 6, 12, 30, 30, 30, 30,
      ])
    #expect(ServerReconnectPolicy.delay(attempt: 100, jitter: 1.1) == 30)
    #expect(ServerReconnectPolicy.isConnectivityFailure(URLError(.networkConnectionLost)))
    #expect(!ServerReconnectPolicy.isConnectivityFailure(URLError(.cancelled)))
    #expect(!ServerReconnectPolicy.isConnectivityFailure(APIClientError.serverIdentityMismatch))
    #expect(
      !ServerReconnectPolicy.isConnectivityFailure(
        APIClientError.httpFailure(status: 503, retryAfter: nil, code: nil, message: nil)))
  }

  @Test func relocationRequiresBothIdentityAndPublicKey() async throws {
    let stored = profile()
    let address = URL(string: "https://new-address.local:43111")!
    let browser = SyntheticDiscovery(servers: [discovered(stored, address)])
    var inspectedAddresses: [URL] = []
    let coordinator = ServerReconnectCoordinator(
      browser: browser,
      inspect: { url in
        inspectedAddresses.append(url)
        if url == stored.baseURL { throw URLError(.cannotConnectToHost) }
        return inspected(stored, at: url)
      }, delay: { _ in })
    let result = try await coordinator.reconnect(stored)
    #expect(result.baseURL == address)
    #expect(inspectedAddresses == [stored.baseURL, address])
    #expect(browser.stops == 2)
  }

  @Test func reconnectingWakesTheSleepingServerBeforeEachAttempt() async throws {
    let stored = profile()
    var wakes: [UUID] = []
    var attempts = 0
    let coordinator = ServerReconnectCoordinator(
      browser: SyntheticDiscovery(servers: []),
      inspect: { url in
        attempts += 1
        if attempts < 2 { throw URLError(.cannotConnectToHost) }
        return inspected(stored, at: url)
      }, delay: { _ in }, wake: { serverId, _ in wakes.append(serverId) })
    _ = try await coordinator.reconnect(stored)
    #expect(wakes == [stored.serverId, stored.serverId])
  }

  @Test func wakeAddressesAreRememberedPerServerAndFormMagicPackets() throws {
    let suite = "AureliaWakeOnLanTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let serverId = UUID()
    var info = ServerInfoResponse(
      serverId: serverId, name: "Linux", version: "1.8.2", isSetup: true, lanAccessEnabled: true,
      lanHttpsPort: 43111, publicKeyFingerprint: nil, displayFingerprint: nil)
    info.wakeOnLanAddresses = ["02:00:5E:10:00:01", "not-an-address", "00:00:00:00:00:00"]
    WakeOnLan.remember(info, defaults: defaults)
    #expect(
      WakeOnLan.addresses(for: serverId, defaults: defaults) == [
        [0x02, 0x00, 0x5E, 0x10, 0x00, 0x01]
      ])
    #expect(WakeOnLan.addresses(for: UUID(), defaults: defaults).isEmpty)
    #expect(WakeOnLan.hardwareAddress("02-00-5e-10-00-01") != nil)
    #expect(WakeOnLan.hardwareAddress("02:00:5e:10:00") == nil)
    let packet = WakeOnLan.magicPacket([0x02, 0x00, 0x5E, 0x10, 0x00, 0x01])
    #expect(packet.count == 102)
    #expect(packet.prefix(6).allSatisfy { $0 == 0xFF })
    #expect(Array(packet[96..<102]) == [0x02, 0x00, 0x5E, 0x10, 0x00, 0x01])
  }

  @Test func closingTheWindowQuitsUnlessTurnedOff() throws {
    let suite = "AureliaWindowCloseTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(WindowClosePreference.quits(defaults: defaults))
    defaults.set(false, forKey: WindowClosePreference.quitsKey)
    #expect(!WindowClosePreference.quits(defaults: defaults))
  }

  @Test(arguments: [true, false])
  func contradictoryIdentityCannotBeSelected(replaceID: Bool) async throws {
    let stored = profile()
    let browser = SyntheticDiscovery(servers: [])
    let coordinator = ServerReconnectCoordinator(
      browser: browser,
      inspect: { url in
        inspected(
          stored, at: url, serverID: replaceID ? UUID() : stored.serverId,
          fingerprint: replaceID ? stored.publicKeyFingerprint : "different-key")
      }, delay: { _ in })
    do {
      _ = try await coordinator.reconnect(stored)
      Issue.record("An identity mismatch must be visible instead of replacing the saved trust.")
    } catch {
      #expect(error as? APIClientError == .serverIdentityMismatch)
    }
  }

  @Test func cancelledResolutionCannotCompleteWithLateAnswer() async throws {
    let stored = profile()
    let pending = PendingInspection()
    let coordinator = ServerReconnectCoordinator(
      browser: SyntheticDiscovery(servers: []), inspect: pending.inspect, delay: { _ in })
    let request = Task { try await coordinator.reconnect(stored) }
    await pending.waitUntilStarted()
    coordinator.cancel()
    pending.complete(inspected(stored, at: stored.baseURL))
    do {
      _ = try await request.value
      Issue.record("The abandoned connection must not be reopened by a late response.")
    } catch { #expect(error is CancellationError) }
  }

  @Test func disconnectRetiresAnInFlightAutomaticRelocation() async throws {
    let stored = profile()
    let store = InMemoryServerProfileStore()
    try store.save(stored)
    let pending = PendingInspection()
    let coordinator = ServerReconnectCoordinator(
      browser: SyntheticDiscovery(servers: []), inspect: pending.inspect, delay: { _ in })
    let controller = LibrarySyncController(fetchChanges: { _, _, _, _ in
      throw URLError(.networkConnectionLost)
    })
    let model = AppModel(
      store: store, initialProfile: stored, syncController: controller,
      profileSelectionEnabled: false, reconnectCoordinator: coordinator)
    await model.start()
    await model.setApplicationActive(true)
    await pending.waitUntilStarted()
    await model.disconnect()
    pending.complete(inspected(stored, at: URL(string: "https://replacement.local:43111")!))
    for _ in 0..<100 { await Task.yield() }
    #expect(model.profile == nil)
    #expect(try store.load() == nil)
    #expect(model.errorMessage == nil)
    await controller.stop()
  }

  @Test func explicitDeviceRevocationShowsPairingWithoutDeletingSavedCredential() async throws {
    let device = profile()
    let viewing = StoredServerProfile(
      serverId: device.serverId, name: device.name, baseURL: device.baseURL,
      publicKeyFingerprint: device.publicKeyFingerprint, token: "synthetic-viewing-token",
      sessionId: UUID(), expiresAt: device.expiresAt, viewingSession: true)
    let store = InMemoryServerProfileStore()
    try store.save(device)
    let controller = LibrarySyncController(fetchChanges: { _, _, _, _ in
      throw APIClientError.httpFailure(
        status: 403, retryAfter: nil, code: "device_session_revoked", message: "Device revoked.")
    })
    let model = AppModel(
      store: store, initialProfile: viewing, syncController: controller,
      profileSelectionEnabled: true)
    await model.start()
    await model.setApplicationActive(true)
    for _ in 0..<1000 {
      if model.profile == nil { break }
      await Task.yield()
    }
    #expect(model.profile == nil)
    #expect(model.errorMessage?.contains("Pair it with your server again") == true)
    #expect(try store.load() == device)
    await controller.stop()
  }

  private func profile() -> StoredServerProfile {
    StoredServerProfile(
      serverId: UUID(), name: "Synthetic Server",
      baseURL: URL(string: "https://old-address.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "synthetic-device-token",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
  }

  private func discovered(_ profile: StoredServerProfile, _ address: URL) -> DiscoveredServer {
    DiscoveredServer(
      id: profile.serverId.uuidString, name: profile.name, serverId: profile.serverId,
      baseURL: address)
  }

  private func inspected(
    _ profile: StoredServerProfile, at address: URL, serverID: UUID? = nil,
    fingerprint: String? = nil
  ) -> InspectedServer {
    InspectedServer(
      baseURL: address,
      info: ServerInfoResponse(
        serverId: serverID ?? profile.serverId, name: profile.name, version: "1.5.5",
        isSetup: true, lanAccessEnabled: true, lanHttpsPort: 43111,
        publicKeyFingerprint: fingerprint ?? profile.publicKeyFingerprint, displayFingerprint: nil),
      publicKeyFingerprint: fingerprint ?? profile.publicKeyFingerprint)
  }
}

@MainActor
private final class SyntheticDiscovery: ServerDiscovery {
  let servers: [DiscoveredServer]
  var stops = 0
  init(servers: [DiscoveredServer]) { self.servers = servers }
  func start() {}
  func stop() { stops += 1 }
}

@MainActor
private final class PendingInspection {
  private var pending: CheckedContinuation<InspectedServer, Error>?
  func inspect(_ address: URL) async throws -> InspectedServer {
    try await withCheckedThrowingContinuation { pending = $0 }
  }
  func waitUntilStarted() async {
    for _ in 0..<1000 {
      if pending != nil { return }
      await Task.yield()
    }
    Issue.record("The synthetic inspection did not start.")
  }
  func complete(_ result: InspectedServer) {
    pending?.resume(returning: result)
    pending = nil
  }
}
