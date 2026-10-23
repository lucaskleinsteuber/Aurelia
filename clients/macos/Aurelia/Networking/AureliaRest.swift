import CoreGraphics
import Foundation

/// After a while with no keyboard, mouse or trackpad use and nothing playing, Aurelia lets go of
/// its server: no requests, no reconnecting and no Wake-on-LAN, so a server that saves power can
/// sleep even while Aurelia stays open. Using Aurelia again connects, and wakes the server.
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

  /// Time since the last keyboard, mouse or trackpad use on this Mac, in any app.
  static var secondsWithoutInput: TimeInterval {
    guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
  }
}
