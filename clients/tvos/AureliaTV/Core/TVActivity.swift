import Foundation

/// One title in the profile's watch history, newest first.
struct TVWatchHistoryItem: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let title: String
  /// "Series · S1E2" for episodes, the year for movies.
  let eyebrow: String?
  let year: Int?
  let kind: String
  let poster: TVArtwork?
  let watchedAt: String
  let positionMilliseconds: Int64
  let durationMilliseconds: Int64
  let secondsWatched: Int64
  let isCompleted: Bool

  var watchedDate: Date? { TVServerDate.parse(watchedAt) }
  var fraction: Double {
    if isCompleted { return 1 }
    guard durationMilliseconds > 0 else { return 0 }
    return min(1, Double(positionMilliseconds) / Double(durationMilliseconds))
  }
}

struct TVWatchHistoryPage: Codable, Equatable, Sendable {
  let items: [TVWatchHistoryItem]
  let offset: Int
  let limit: Int
  let total: Int
}

struct TVPeriodHours: Codable, Equatable, Sendable {
  let period: String
  let hours: Double
}

struct TVNamedCount: Codable, Equatable, Sendable {
  let name: String
  let count: Int
  /// Watch time in hours; older servers send only the count.
  let hours: Double?
}

struct TVUserStatistics: Codable, Equatable, Sendable {
  let totalHoursWatched: Double
  let hoursPast7Days: Double?
  let hoursPast30Days: Double?
  let hoursByWeek: [TVPeriodHours]?
  let topGenres: [TVNamedCount]?
  let topTitles: [TVNamedCount]?
  let currentStreakDays: Int?
  let longestStreakDays: Int?
  let busiestWeekday: String?
  let completionRate: Double?
  let yearsAvailable: [Int]?
}

struct TVYearInReview: Codable, Equatable, Sendable {
  let year: Int
  let totalHoursWatched: Double?
  let titlesWatched: Int?
  let moviesWatched: Int?
  let episodesWatched: Int?
  let topGenre: String?
  let topTitle: String?
  let busiestDay: String?
}

/// The year as slides, chosen and written by the server; the app only shows them.
struct TVYearWrapped: Codable, Equatable, Sendable {
  let year: Int
  let profileName: String
  let slides: [TVWrappedSlide]
  /// Set for one month's Wrapped.
  var month: Int?
}

struct TVWrappedFact: Codable, Equatable, Sendable {
  let label: String
  let value: String
}

struct TVWrappedSlide: Codable, Equatable, Sendable {
  let kind: String
  let eyebrow: String
  let headline: String
  let bigNumber: String?
  let unit: String?
  let detail: String?
  let quip: String
  let accent: String
  let mediaId: UUID?
  let poster: TVArtwork?
  let posters: [TVArtwork]?
  let facts: [TVWrappedFact]?
}

/// Wrapped's story rules: colors, counting up and moving between slides.
enum TVWrapped {
  static let slideSeconds: Double = 6

  /// The newest month whose Wrapped is ready: last month from the 2nd on, else the one before.
  static func readyMonth(
    today: Date = Date(), calendar: Calendar = .current
  ) -> (year: Int, month: Int, name: String) {
    let back = calendar.component(.day, from: today) >= 2 ? -1 : -2
    let start = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
    let month = calendar.date(byAdding: .month, value: back, to: start)!
    let number = calendar.component(.month, from: month)
    return (calendar.component(.year, from: month), number, monthName(number))
  }

  /// The months of `year` whose Wrapped is ready: every month of a past year, up to the newest
  /// ready month in its year, none later.
  static func readyMonths(year: Int, today: Date = Date(), calendar: Calendar = .current) -> [Int] {
    let ready = readyMonth(today: today, calendar: calendar)
    if year < ready.year { return Array(1...12) }
    if year == ready.year { return Array(1...ready.month) }
    return []
  }

  /// The years that can have a monthly Wrapped: those with viewing activity and the newest ready
  /// month's year, newest first.
  static func wrappedYears(
    activityYears: [Int], today: Date = Date(), calendar: Calendar = .current
  ) -> [Int] {
    let ready = readyMonth(today: today, calendar: calendar).year
    return Array(Set(activityYears.filter { $0 <= ready } + [ready])).sorted(by: >)
  }

  /// Home shows the new month in its first week, from the 2nd to the 8th.
  static func monthIsNew(today: Date = Date(), calendar: Calendar = .current) -> Bool {
    (2...8).contains(calendar.component(.day, from: today))
  }

  /// English month names; the app's text stays English.
  static func monthName(_ month: Int) -> String {
    let names = [
      "January", "February", "March", "April", "May", "June", "July", "August", "September",
      "October", "November", "December",
    ]
    return names[max(0, min(11, month - 1))]
  }

  /// A color field and the ink and sticker on it, as RGB hex.
  struct Accent: Equatable, Sendable {
    let field: UInt32
    let ink: UInt32
    let sticker: UInt32
  }

  static let accents: [String: Accent] = [
    "night": Accent(field: 0x171A3A, ink: 0xF2F0FF, sticker: 0x5B7CFF),
    "ember": Accent(field: 0xFF5A36, ink: 0x1C0600, sticker: 0x1C0600),
    "violet": Accent(field: 0x6A4CFF, ink: 0xFFFFFF, sticker: 0xFFD84D),
    "gold": Accent(field: 0xF6B92B, ink: 0x1E1400, sticker: 0x1E1400),
    "rose": Accent(field: 0xFF4D88, ink: 0x22000F, sticker: 0x22000F),
    "mint": Accent(field: 0x33D39A, ink: 0x00180E, sticker: 0x00180E),
    "ocean": Accent(field: 0x1D8BFF, ink: 0xFFFFFF, sticker: 0x0B1A3A),
    "lime": Accent(field: 0xC4EE34, ink: 0x131A00, sticker: 0x131A00),
  ]

  static func accent(_ name: String) -> Accent { accents[name] ?? accents["night"]! }

  /// The number to count up to, when the big text is a plain number ("143", not "02:47").
  static func countTarget(_ text: String?) -> Int? {
    guard let text, !text.isEmpty, text.count <= 6, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber)
    else { return nil }
    return Int(text)
  }

  /// The number `fraction` (0…1) into the count, easing out so it lands softly.
  static func countValue(_ target: Int, fraction: Double) -> Int {
    let t = min(1, max(0, fraction))
    return Int((Double(target) * (1 - pow(1 - t, 3))).rounded())
  }

  /// The slide after a tap; nil past the last one, which closes the story.
  static func step(from index: Int, count: Int, forward: Bool) -> Int? {
    forward ? (index + 1 < count ? index + 1 : nil) : max(0, index - 1)
  }
}

/// Watch time as people say it: "45 min", "2 h 5 min" or "3 days 4 h", never "0.8 h".
/// The same wording as the Mac app's Activity settings.
enum TVWatchTime {
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
    _ items: [TVWatchHistoryItem], now: Date = Date(), calendar: Calendar = .current
  )
    -> [(title: String, items: [TVWatchHistoryItem])]
  {
    var result: [(title: String, items: [TVWatchHistoryItem])] = []
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
