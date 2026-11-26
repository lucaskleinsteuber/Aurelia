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

  /// Keep the Mac awake only while the user asked for it and the server process is actually active.
  /// Once the server stops for being unused (.idle) or stops/fails, the Mac must be allowed to sleep.
  static func shouldPreventIdleSleep(
    settingEnabled: Bool,
    isShuttingDown: Bool,
    isProcessRunning: Bool,
    isIdle: Bool
  ) -> Bool {
    settingEnabled && !isShuttingDown && isProcessRunning && !isIdle
  }
}
