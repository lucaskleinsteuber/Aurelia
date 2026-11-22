import Foundation

enum ServerReconnectPolicy {
  static func delay(attempt: Int, jitter: Double = Double.random(in: 0.9...1.1)) -> TimeInterval {
    let intervals: [Double] = [3, 6, 12, 30]
    return min(
      30, intervals[min(max(attempt, 0), intervals.count - 1)] * min(max(jitter, 0.9), 1.1))
  }

  static func isConnectivityFailure(_ error: Error) -> Bool {
    guard let error = error as? URLError else { return false }
    return [
      .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
      .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed,
    ]
    .contains(error.code)
  }

  /// The server answered that it moved to another computer; Aurelia looks for it there.
  static func isMoved(_ error: Error) -> Bool {
    (error as? APIClientError)?.problemCode == "server_moved"
  }

  static func validate(_ inspected: InspectedServer, for stored: StoredServerProfile) throws {
    guard inspected.info.serverId == stored.serverId,
      inspected.publicKeyFingerprint.caseInsensitiveCompare(stored.publicKeyFingerprint)
        == .orderedSame
    else { throw APIClientError.serverIdentityMismatch }
  }
}

@MainActor
protocol ServerDiscovery: AnyObject {
  var servers: [DiscoveredServer] { get }
  func start()
  func stop()
}

extension BonjourBrowser: ServerDiscovery {}

/// Owns one cancellable attempt. Discovery is never allowed to select a new identity.
@MainActor
final class ServerReconnectCoordinator {
  typealias Inspector = @MainActor (URL) async throws -> InspectedServer
  typealias Delay = @MainActor (TimeInterval) async throws -> Void
  typealias Waker = @MainActor (UUID, URL) -> Void
  private let browser: any ServerDiscovery
  private let inspect: Inspector
  private let delay: Delay
  private let wake: Waker
  private var generation = UUID()

  init(
    browser: any ServerDiscovery = BonjourBrowser(),
    // A server on the home network answers within moments; a sleeping one never does.
    inspect: @escaping Inspector = { try await APIClient.inspect(baseURL: $0, timeout: 4) },
    delay: @escaping Delay = { try await Task.sleep(for: .seconds($0)) },
    wake: @escaping Waker = { serverId, address in
      if WakeOnLan.userIsPresent { WakeOnLan.wake(serverId: serverId, lastKnown: address) }
    }
  ) {
    self.browser = browser
    self.inspect = inspect
    self.delay = delay
    self.wake = wake
  }

  func cancel() {
    generation = UUID()
    browser.stop()
  }

  /// Looks for the server until it answers. With `wakes` it also sends a wake packet before each
  /// attempt; Aurelia's background search passes false, so only an explicit wake starts it.
  func reconnect(_ stored: StoredServerProfile, wakes: Bool = true) async throws -> InspectedServer
  {
    cancel()
    let run = generation
    browser.start()
    defer { if generation == run { browser.stop() } }
    var attempt = 0
    while generation == run {
      // A server that sleeps when nobody watches wakes within seconds of this packet, sent
      // only while someone uses Aurelia.
      if wakes { wake(stored.serverId, stored.baseURL) }
      try await delay(ServerReconnectPolicy.delay(attempt: attempt))
      try Task.checkCancellation()
      guard generation == run else { throw CancellationError() }
      // The saved address gets the same identity validation as every discovered address.
      let discovered = browser.servers.filter { $0.serverId == stored.serverId }.flatMap(
        \.addresses)
      var seen = Set<URL>()
      var addresses = Array(
        ([stored.baseURL] + discovered).filter { seen.insert($0).inserted }.prefix(16))
      var savedAddressError: Error?
      var index = 0
      while index < addresses.count {
        let address = addresses[index]
        index += 1
        do {
          let result = try await inspect(address)
          try Task.checkCancellation()
          guard generation == run else { throw CancellationError() }
          try ServerReconnectPolicy.validate(result, for: stored)
          // A server that moved still answers at its old address: follow it to the new one.
          if let moved = result.info.moved {
            let next = moved.followable(for: stored.serverId, tried: seen)
            seen.formUnion(next)
            addresses += next
            continue
          }
          // Return immediately on the first verified match so spoofed or failing Bonjour entries
          // cannot disrupt or abort a working connection.
          return result
        } catch {
          try Task.checkCancellation()
          guard generation == run else { throw CancellationError() }
          // Only surface an identity mismatch or non-connectivity failure from the paired saved
          // address itself (and only if no other candidate matches); untrusted LAN announcements
          // with wrong identities or broken TLS must never abort reconnection.
          if address == stored.baseURL,
            error as? APIClientError == .serverIdentityMismatch
              || !ServerReconnectPolicy.isConnectivityFailure(error)
          {
            savedAddressError = error
          }
        }
      }
      if let savedAddressError { throw savedAddressError }
      attempt = min(attempt + 1, 3)
    }
    throw CancellationError()
  }
}
