import Foundation

/// One title in the profile's watch history, newest first.
struct IOSWatchHistoryItem: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let title: String
  /// "Series · S1E2" for episodes, the year for movies.
  let eyebrow: String?
  let year: Int?
  let kind: String
  let poster: IOSArtwork?
  let watchedAt: String
  let positionMilliseconds: Int64
  let durationMilliseconds: Int64
  let secondsWatched: Int64
  let isCompleted: Bool

  var watchedDate: Date? { IOSServerDate.parse(watchedAt) }
  var fraction: Double {
    if isCompleted { return 1 }
    guard durationMilliseconds > 0 else { return 0 }
    return min(1, Double(positionMilliseconds) / Double(durationMilliseconds))
  }
}

struct IOSWatchHistoryPage: Codable, Equatable, Sendable {
  let items: [IOSWatchHistoryItem]
  let offset: Int
  let limit: Int
  let total: Int
}

struct IOSPeriodHours: Codable, Equatable, Sendable {
  let period: String
  let hours: Double
}

struct IOSNamedCount: Codable, Equatable, Sendable {
  let name: String
  let count: Int
  /// Watch time in hours; older servers send only the count.
  let hours: Double?
}

struct IOSUserStatistics: Codable, Equatable, Sendable {
  let totalHoursWatched: Double
  let hoursPast7Days: Double?
  let hoursPast30Days: Double?
  let hoursByWeek: [IOSPeriodHours]?
  let topGenres: [IOSNamedCount]?
  let topTitles: [IOSNamedCount]?
  let currentStreakDays: Int?
  let longestStreakDays: Int?
  let busiestWeekday: String?
  let completionRate: Double?
  let yearsAvailable: [Int]?
}

struct IOSYearInReview: Codable, Equatable, Sendable {
  let year: Int
  let totalHoursWatched: Double?
  let titlesWatched: Int?
  let moviesWatched: Int?
  let episodesWatched: Int?
  let topGenre: String?
  let topTitle: String?
  let busiestDay: String?
}

/// Watch time as people say it: "45 min", "2 h 5 min" or "3 days 4 h", never "0.8 h".
/// The same wording as the Mac app's Activity settings.
enum IOSWatchTime {
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
    return sameYear ? date.formatted(style) : date.formatted(style.year())
  }

  /// History entries grouped by the day they were watched, in the order received.
  static func days(
    _ items: [IOSWatchHistoryItem], now: Date = Date(), calendar: Calendar = .current
  )
    -> [(title: String, items: [IOSWatchHistoryItem])]
  {
    var result: [(title: String, items: [IOSWatchHistoryItem])] = []
    for item in items {
      let title =
        item.watchedDate.map { dayTitle(for: $0, now: now, calendar: calendar) } ?? "Earlier"
      if result.last?.title == title {
        result[result.count - 1].items.append(item)
      } else {
        result.append((title, [item]))
      }
    }
    return result
  }
}
