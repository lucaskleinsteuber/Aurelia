import Foundation

// Screen time of children's profiles ("screen-time-v1", docs/SCREEN_TIME.md), copied from the
// Mac app's rules: the server decides; this app shows no Up Next for the last title, a good-night
// screen, and closed profiles in "Who's watching?". Unknown values from a newer server read as the
// nearest known one.

enum TVScreenTimeState: String, Codable, Sendable {
  case open, lastTitle, closed

  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .open
  }
}

enum TVScreenTimeReason: String, Codable, Sendable {
  case none, bedtime, limit

  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
  }
}

struct TVScreenTimeStatus: Codable, Equatable, Sendable {
  var state: TVScreenTimeState
  var reason: TVScreenTimeReason
  var watchedMinutesToday: Int
  var limitMinutes: Int?
  var opensAt: String?
  /// "playbackOnly" or "wholeProfile": what closes when time is up.
  var lockScope: String
  var oneMoreTitleAvailable: Bool

  /// No new title may start: no Up Next, no suggestions, and the good-night screen at the end.
  var noMoreTitles: Bool { state != .open }
  var closesWholeProfile: Bool { lockScope == "wholeProfile" }
}

struct TVOwnScreenTime: Codable, Sendable {
  var status: TVScreenTimeStatus?
}

enum TVScreenTimeText {
  /// The player asks the server this often while a title plays.
  static let refreshInterval: TimeInterval = 60

  static func refusesTitle(_ code: String?) -> Bool {
    code == "screen_time_bedtime" || code == "screen_time_limit"
  }

  static func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  /// "07:00" in this device's clock, or "" without a time.
  static func clock(_ value: String?, timeZone: TimeZone = .current) -> String {
    guard let date = date(value) else { return "" }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
  }

  /// The good-night screen's heading and line.
  static func goodNight(_ status: TVScreenTimeStatus?, name: String, timeZone: TimeZone = .current)
    -> (title: String, text: String)
  {
    let who = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let opens = clock(status?.opensAt, timeZone: timeZone)
    if status?.reason == .limit {
      return (
        who.isEmpty ? "That's all for today" : "That's all for today, \(who)",
        opens.isEmpty ? "See you tomorrow." : "See you tomorrow at \(opens).")
    }
    return (
      who.isEmpty ? "Good night" : "Good night, \(who)",
      opens.isEmpty ? "Sleep well." : "See you at \(opens).")
  }

  /// The quiet note while the last title of the day plays.
  static func lastTitleNote(_ status: TVScreenTimeStatus?) -> String {
    status?.reason == .limit
      ? "This is the last title for today." : "This is the last episode before bedtime."
  }

  /// "Good night · back at 07:00" for a closed profile in "Who's watching?".
  static func closedLabel(_ until: String?, timeZone: TimeZone = .current) -> String? {
    guard let until else { return nil }
    let opens = clock(until, timeZone: timeZone)
    return opens.isEmpty ? "Good night" : "Good night · back at \(opens)"
  }
}
