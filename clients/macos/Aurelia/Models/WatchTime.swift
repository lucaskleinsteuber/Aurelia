import Foundation

/// Watch time as people say it: "45 min", "2 h 5 min" or "3 days 4 h", never "0.8 h".
enum WatchTime {
  static func text(hours: Double) -> String {
    guard hours.isFinite else { return text(seconds: 0) }
    return text(seconds: Int((max(0, hours) * 3_600).rounded()))
  }

  static func text(seconds: Int) -> String {
    guard seconds > 0 else { return "0 min" }
    guard seconds >= 30 else { return "Under 1 min" }
    let minutes = (seconds + 30) / 60
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if hours < 24 {
      return remainingMinutes == 0 ? "\(hours) h" : "\(hours) h \(remainingMinutes) min"
    }
    let days = hours / 24
    let remainingHours = hours % 24
    let dayText = days == 1 ? "1 day" : "\(days) days"
    return remainingHours == 0 ? dayText : "\(dayText) \(remainingHours) h"
  }

  /// The Monday that starts an ISO week such as "2026-W43", as the server groups weeks.
  static func weekStart(_ period: String) -> Date? {
    let parts = period.split(separator: "-W")
    guard parts.count == 2, let year = Int(parts[0]), let week = Int(parts[1]) else { return nil }
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = .current
    return calendar.date(
      from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year))
  }

  /// "Today", "Yesterday" or the weekday and date, for grouping the watch history.
  static func dayTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current)
    -> String
  {
    if calendar.isDate(date, inSameDayAs: now) { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      return "Yesterday"
    }
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
      .weekday(.wide).day().month(.wide)
    return sameYear
      ? date.formatted(style) : date.formatted(style.year())
  }
}
