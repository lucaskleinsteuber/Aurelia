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
  private let browser: any ServerDiscovery
  private let inspect: Inspector
  private let delay: Delay
  private var generation = UUID()

  init(
    browser: any ServerDiscovery = BonjourBrowser(),
    inspect: @escaping Inspector = { try await APIClient.inspect(baseURL: $0) },
    delay: @escaping Delay = { try await Task.sleep(for: .seconds($0)) }
  ) {
    self.browser = browser
    self.inspect = inspect
    self.delay = delay
  }

  func cancel() {
    generation = UUID()
    browser.stop()
  }

  func reconnect(_ stored: StoredServerProfile) async throws -> InspectedServer {
    cancel()
    let run = generation
    browser.start()
    defer { if generation == run { browser.stop() } }
    var attempt = 0
    while generation == run {
      try await delay(ServerReconnectPolicy.delay(attempt: attempt))
      try Task.checkCancellation()
      guard generation == run else { throw CancellationError() }
      // The saved address gets the same identity validation as every discovered address.
      let discovered = browser.servers.filter { $0.serverId == stored.serverId }.flatMap(
        \.addresses)
      var seen = Set<URL>()
      let addresses = ([stored.baseURL] + discovered).filter { seen.insert($0).inserted }.prefix(16)
      var selected: InspectedServer?
      for address in addresses {
        do {
          let result = try await inspect(address)
          try Task.checkCancellation()
          guard generation == run else { throw CancellationError() }
          try ServerReconnectPolicy.validate(result, for: stored)
          selected = selected ?? result
        } catch {
          try Task.checkCancellation()
          guard generation == run else { throw CancellationError() }
          // An answering server with a different identity requires a visible decision.
          if error as? APIClientError == .serverIdentityMismatch { throw error }
          if !ServerReconnectPolicy.isConnectivityFailure(error) { throw error }
        }
      }
      if let selected { return selected }
      attempt = min(attempt + 1, 3)
    }
    throw CancellationError()
  }
}
