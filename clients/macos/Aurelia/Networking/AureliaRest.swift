import AppKit
import CoreGraphics
import Foundation

/// After a while in which nobody used Aurelia and nothing played, Aurelia lets go of its server:
/// no requests, no reconnecting and no Wake-on-LAN, so a server that saves power can sleep even
/// while Aurelia stays open. Using Aurelia again connects, and wakes the server. Working in other
/// apps on this Mac does not count as using Aurelia.
enum AureliaRest {
  static let enabledKey = "AureliaRestsWhenUnused"
  static let minutesKey = "AureliaRestMinutes"
  static let defaultMinutes = 15
  static let minuteChoices = [5, 10, 15, 30, 60]

  static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: enabledKey) as? Bool ?? true
  }

  static func minutes(defaults: UserDefaults = .standard) -> Int {
    let stored = defaults.integer(forKey: minutesKey)
    return minuteChoices.contains(stored) ? stored : defaultMinutes
  }

  /// Rest only when connected to a server elsewhere: a server on this Mac stops with the app anyway.
  static func shouldRest(
    enabled: Bool, minutes: Int, secondsWithoutInput: TimeInterval, playing: Bool,
    connectedElsewhere: Bool
  ) -> Bool {
    enabled && connectedElsewhere && !playing && secondsWithoutInput >= TimeInterval(minutes * 60)
  }

  /// Time since someone used Aurelia. While Aurelia is the active app, keyboard, mouse and
  /// trackpad go to it, so that is the time since the last input; while another app is in
  /// front, it is the time since Aurelia was last in front.
  static func secondsWithoutUse(
    isActive: Bool, secondsWithoutInput: TimeInterval, lastActive: Date, now: Date
  ) -> TimeInterval {
    isActive ? secondsWithoutInput : max(0, now.timeIntervalSince(lastActive))
  }

  /// Time since the last keyboard, mouse or trackpad use on this Mac, in any app.
  static var secondsWithoutInput: TimeInterval {
    guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
  }
}

/// Remembers when Aurelia was last the active app. AppKit posts the notification on the main
/// thread and the observer runs on the main queue.
@MainActor
final class AureliaUseClock {
  static let shared = AureliaUseClock()
  private(set) var lastActive = Date()

  private init() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { AureliaUseClock.shared.lastActive = Date() }
    }
  }

  var secondsWithoutUse: TimeInterval {
    AureliaRest.secondsWithoutUse(
      isActive: NSApplication.shared.isActive,
      secondsWithoutInput: AureliaRest.secondsWithoutInput, lastActive: lastActive, now: Date())
  }
}
