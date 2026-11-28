import AppKit
import CoreGraphics
import Foundation

/// After a while in which nobody used Tarven and nothing played, Tarven lets go of its server:
/// no requests, no reconnecting and no Wake-on-LAN, so a server that saves power can sleep even
/// while Tarven stays open. Using Tarven again connects, and wakes the server. Working in other
/// apps on this Mac does not count as using Tarven.
enum TarvenRest {
  static let enabledKey = "TarvenRestsWhenUnused"
  static let minutesKey = "TarvenRestMinutes"
  static let defaultMinutes = 15
  static let minuteChoices = [5, 10, 15, 30, 60]

  static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: enabledKey) as? Bool ?? true
  }

  static func minutes(defaults: UserDefaults = .standard) -> Int {
    let stored = defaults.integer(forKey: minutesKey)
    return minuteChoices.contains(stored) ? stored : defaultMinutes
  }

  /// Loopback addresses run on this Mac and never enter remote power-saving rest.
  static func isLoopbackHost(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "127.0.0.1" || host == "::1" || host == "[::1]" || host == "localhost"
  }

  /// Rest only when connected to a remote non-loopback server whose power saving is enabled.
  static func shouldRest(
    enabled: Bool, minutes: Int, secondsWithoutInput: TimeInterval, playing: Bool,
    connectedElsewhere: Bool, serverPowerSavingEnabled: Bool
  ) -> Bool {
    enabled && connectedElsewhere && serverPowerSavingEnabled && !playing
      && secondsWithoutInput >= TimeInterval(minutes * 60)
  }

  /// Time since someone used Tarven. While Tarven is the active app, keyboard, mouse and
  /// trackpad go to it, bounded by when Tarven was brought to the front so focusing Tarven
  /// never counts as idle; while another app is in front, it is the time since Tarven was last active.
  static func secondsWithoutUse(
    isActive: Bool, secondsWithoutInput: TimeInterval, lastActive: Date, now: Date
  ) -> TimeInterval {
    let sinceActive = max(0, now.timeIntervalSince(lastActive))
    return isActive ? min(secondsWithoutInput, sinceActive) : sinceActive
  }

  /// Time since the last keyboard, mouse or trackpad use on this Mac, in any app.
  static var secondsWithoutInput: TimeInterval {
    guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
  }
}

/// Remembers when Tarven was last brought to the front or left. AppKit posts the notifications on
/// the main thread and the observers run on the main queue.
@MainActor
final class TarvenUseClock {
  static let shared = TarvenUseClock()
  private(set) var lastActive = Date()

  private init() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { TarvenUseClock.shared.lastActive = Date() }
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { TarvenUseClock.shared.lastActive = Date() }
    }
  }

  func noteActive(at date: Date = Date()) {
    lastActive = date
  }

  var secondsWithoutUse: TimeInterval {
    TarvenRest.secondsWithoutUse(
      isActive: NSApplication.shared.isActive,
      secondsWithoutInput: TarvenRest.secondsWithoutInput, lastActive: lastActive, now: Date())
  }
}
