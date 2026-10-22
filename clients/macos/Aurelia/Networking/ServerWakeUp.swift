import Foundation

enum ServerConnectionStatus: Equatable {
  case connecting
  case waking(since: Date)
  case loading
}

/// Opening Aurelia while its server sleeps: instead of failing a request after a long timeout and
/// showing an error, Aurelia checks quickly whether the server answers, wakes it with Wake-on-LAN
/// and waits until it is up, so the first screen is the library or the profiles.
@MainActor
struct ServerWakeUp {
  typealias Probe = @MainActor (URL) async -> Bool
  typealias Waker = @MainActor (UUID, URL) -> Void
  typealias Delay = @MainActor (TimeInterval) async throws -> Void

  /// True when something answers at the address, even with an error: only silence means asleep.
  /// A server that power saving stopped drops the first connection while it starts again.
  var probe: Probe = { address in
    do {
      _ = try await APIClient.inspect(baseURL: address, timeout: 3)
      return true
    } catch let error as URLError where error.code == .secureConnectionFailed {
      return false
    } catch {
      return !ServerReconnectPolicy.isConnectivityFailure(error)
    }
  }
  var canWake: @MainActor (UUID) -> Bool = { !WakeOnLan.addresses(for: $0).isEmpty }
  var wake: Waker = { WakeOnLan.wake(serverId: $0, lastKnown: $1) }
  var delay: Delay = { try await Task.sleep(for: .seconds($0)) }
  var now: @MainActor () -> Date = { Date() }
  /// A PC resuming from standby answers within seconds; a cold start can take a minute or two.
  var limit: TimeInterval = 120
  /// A server that only stopped Aurelia starts it again by itself within seconds.
  var startLimit: TimeInterval = 20
  var pollInterval: TimeInterval = 2
  var wakeInterval: TimeInterval = 10

  /// Returns whether the server answers. `onWaking` runs once when it has to be woken.
  func run(serverId: UUID, address: URL, onWaking: @MainActor () -> Void) async -> Bool {
    // Stop Waiting cancels the wait; a probe cut short says nothing about the server.
    if await probe(address) { return !Task.isCancelled }
    if Task.isCancelled { return false }
    let wakes = canWake(serverId)
    if wakes { onWaking() }
    let started = now()
    var lastWake: Date?
    while now().timeIntervalSince(started) < (wakes ? limit : startLimit) {
      if wakes, lastWake.map({ now().timeIntervalSince($0) >= wakeInterval }) ?? true {
        wake(serverId, address)
        lastWake = now()
      }
      do { try await delay(pollInterval) } catch { return false }
      if await probe(address) { return !Task.isCancelled }
      if Task.isCancelled { return false }
    }
    return false
  }
}
