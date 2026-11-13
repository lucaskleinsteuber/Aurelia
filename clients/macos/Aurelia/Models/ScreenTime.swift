import Foundation

// Screen time of children's profiles ("screen-time-v1", docs/SCREEN_TIME.md). The server decides;
// the app shows what it said: no Up Next for the last title, a good-night screen, and the rules
// in the profile editor. Unknown values from a newer server read as the nearest known one.

enum ScreenTimeState: String, Codable, Sendable {
  case open, lastTitle, closed

  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .open
  }
}

enum ScreenTimeReason: String, Codable, Sendable {
  case none, bedtime, limit

  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
  }
}

enum ScreenTimeLockScope: String, Codable, CaseIterable, Sendable {
  case playbackOnly, wholeProfile

  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .playbackOnly
  }

  var title: String { self == .wholeProfile ? "The Whole Profile" : "Playback Only" }
}

enum ScreenTimeEnding: String, Codable, CaseIterable, Sendable {
  case finishTitle, stopNow

  init(from decoder: Decoder) throws {
    self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .finishTitle
  }

  var title: String { self == .stopNow ? "Stop Right Away" : "Let the Title Finish" }
}

struct ScreenTimeStatus: Codable, Equatable, Sendable {
  var state: ScreenTimeState
  var reason: ScreenTimeReason
  var watchedMinutesToday: Int
  var limitMinutes: Int?
  var remainingMinutes: Int?
  var closesAt: String?
  var titleEndsBy: String?
  var opensAt: String?
  var lockScope: ScreenTimeLockScope
  var ending: ScreenTimeEnding
  var oneMoreTitleAvailable: Bool

  /// No new title may start: no Up Next, no suggestions, and the good-night screen at the end.
  var noMoreTitles: Bool { state != .open }
}

struct ScreenTimeDayRule: Codable, Equatable, Sendable {
  var bedtime: String?
  var wakeTime: String
  var dailyLimitMinutes: Int?
}

struct ScreenTimeRules: Codable, Equatable, Sendable {
  var enabled: Bool
  var lockScope: ScreenTimeLockScope
  var ending: ScreenTimeEnding
  var maxOvertimeMinutes: Int
  var schoolNight: ScreenTimeDayRule
  var weekend: ScreenTimeDayRule

  static let `default` = ScreenTimeRules(
    enabled: false, lockScope: .playbackOnly, ending: .finishTitle, maxOvertimeMinutes: 30,
    schoolNight: .init(bedtime: "19:30", wakeTime: "07:00", dailyLimitMinutes: nil),
    weekend: .init(bedtime: "20:30", wakeTime: "08:00", dailyLimitMinutes: nil))
}

struct ScreenTimeToday: Codable, Equatable, Sendable {
  var extraMinutes: Int
  var bedtimeLifted: Bool
  var oneMoreTitle: Bool
  var oneMoreTitleUsed: Bool
}

struct ProfileScreenTime: Codable, Equatable, Sendable {
  var rules: ScreenTimeRules
  var today: ScreenTimeToday
  var status: ScreenTimeStatus?
  var revision: Int64
}

struct ProfileScreenTimeUpdate: Codable, Sendable {
  var rules: ScreenTimeRules
  var revision: Int64
}

struct ScreenTimeGrant: Codable, Equatable, Sendable {
  var addMinutes = 0
  var liftBedtime = false
  var oneMoreTitle = false
}

struct OwnScreenTime: Codable, Sendable {
  var status: ScreenTimeStatus?
}

enum ScreenTimeText {
  static let capability = "screen-time-v1"
  static let codes: Set<String> = [
    "screen_time_bedtime", "screen_time_limit", "profile_screen_time_closed",
  ]
  /// The player asks the server this often while a title plays.
  static let refreshInterval: TimeInterval = 60

  static func isScreenTimeCode(_ code: String?) -> Bool { code.map(codes.contains) ?? false }

  static func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  /// "07:00" in this Mac's clock, or "" without a time.
  static func clock(_ value: String?, timeZone: TimeZone = .current) -> String {
    guard let date = date(value) else { return "" }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
  }

  /// The good-night screen's heading and line.
  static func goodNight(_ status: ScreenTimeStatus?, name: String, timeZone: TimeZone = .current)
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

  /// Good-night heading and server-power detail when playback stops at a sleep timer.
  static func goodNight(sleepTimerStatus: SleepTimerEndedResponse?, name: String)
    -> (title: String, text: String)
  {
    let who = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = who.isEmpty ? "Good night" : "Good night, \(who)"
    guard let status = sleepTimerStatus, status.afterSleepTimer else {
      return (title, "Sleep well.")
    }
    let minutes = max(1, status.minutes)
    let unit = minutes == 1 ? "minute" : "minutes"
    let detail: String? =
      switch status.powerMode {
      case "sleep":
        "The server goes to sleep in about \(minutes) \(unit) unless someone keeps watching."
      case "shutdown":
        "The server turns off in about \(minutes) \(unit) unless someone keeps watching."
      default:
        nil
      }
    return (title, detail.map { "Sleep well. \($0)" } ?? "Sleep well.")
  }

  /// The quiet note while the last title of the day plays.
  static func lastTitleNote(_ status: ScreenTimeStatus?) -> String {
    status?.reason == .limit
      ? "This is the last title for today." : "This is the last episode before bedtime."
  }

  /// "Good night · back at 07:00" for a closed profile in "Who's watching?".
  static func closedLabel(_ until: String?, timeZone: TimeZone = .current) -> String? {
    guard let until else { return nil }
    let opens = clock(until, timeZone: timeZone)
    return opens.isEmpty ? "Good night" : "Good night · back at \(opens)"
  }

  /// "42 of 60 min watched today · Closes at 19:30" for the parents' "Today" line.
  static func todaySummary(_ status: ScreenTimeStatus?, timeZone: TimeZone = .current) -> String {
    guard let status else { return "Screen time is off." }
    let watched =
      status.limitMinutes.map { "\(status.watchedMinutesToday) of \($0) min watched today" }
      ?? "\(status.watchedMinutesToday) min watched today"
    if status.state == .closed {
      let opens = clock(status.opensAt, timeZone: timeZone)
      let why = status.reason == .limit ? "Time is up" : "Bedtime"
      return "\(watched) · \(why)\(opens.isEmpty ? "" : ", opens at \(opens)")"
        + (status.oneMoreTitleAvailable ? " · One more title allowed" : "")
    }
    let closes = clock(status.closesAt, timeZone: timeZone)
    return closes.isEmpty ? watched : "\(watched) · Closes at \(closes)"
  }

  /// "HH:mm" for a time field, nil when it is not a valid time.
  static func time(_ value: String) -> String? {
    let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":")
    guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
      let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour),
      (0..<60).contains(minute)
    else { return nil }
    return String(format: "%02d:%02d", hour, minute)
  }

  /// The first problem in edited rules, or nil when the server will accept them.
  static func problem(_ rules: ScreenTimeRules) -> String? {
    for (label, rule) in [("school-night", rules.schoolNight), ("weekend", rules.weekend)] {
      if let bedtime = rule.bedtime, !bedtime.isEmpty, time(bedtime) == nil {
        return "Enter the \(label) bedtime like 19:30."
      }
      if time(rule.wakeTime) == nil { return "Enter the \(label) wake time like 07:00." }
      if let limit = rule.dailyLimitMinutes, !(5...1440).contains(limit) {
        return "The \(label) daily limit is 5 to 1440 minutes."
      }
    }
    return (0...180).contains(rules.maxOvertimeMinutes)
      ? nil : "A title may run over by 0 to 180 minutes."
  }
}
