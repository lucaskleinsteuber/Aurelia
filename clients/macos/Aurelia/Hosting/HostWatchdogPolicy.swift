import Foundation

/// The host owns one recovery budget for both process exits and transport hangs.
/// Times are monotonic system uptime, so wall-clock adjustments cannot reset it.
/// Readiness failures (including HTTP 503) are not transport failures.
struct HostWatchdogPolicy: Sendable {
  enum Decision: Equatable { case none, restart, limitReached }

  private(set) var consecutiveFailures = 0
  private(set) var restartDates: [TimeInterval] = []
  private(set) var graceUntil = -TimeInterval.infinity
  private(set) var suspended = false

  mutating func didBecomeReady() { consecutiveFailures = 0 }

  mutating func willSleep() {
    suspended = true
    consecutiveFailures = 0
  }

  mutating func didWake(at now: TimeInterval) {
    suspended = false
    graceUntil = now + 60
    consecutiveFailures = 0
  }

  func mayProbe(at now: TimeInterval, ready: Bool, operationActive: Bool) -> Bool {
    ready && !operationActive && !suspended && now >= graceUntil
  }

  mutating func transportCompleted(receivedHTTPResponse: Bool, at now: TimeInterval) -> Decision {
    guard !suspended, now >= graceUntil else { return .none }
    if receivedHTTPResponse {
      consecutiveFailures = 0
      return .none
    }
    consecutiveFailures += 1
    guard consecutiveFailures >= 3 else { return .none }
    consecutiveFailures = 0
    return requestAutomaticRecovery(at: now)
  }

  mutating func requestAutomaticRecovery(at now: TimeInterval) -> Decision {
    restartDates.removeAll { now - $0 >= 600 }
    guard restartDates.count < 3 else { return .limitReached }
    restartDates.append(now)
    return .restart
  }

  mutating func manualRetry() {
    restartDates.removeAll()
    consecutiveFailures = 0
  }
}
