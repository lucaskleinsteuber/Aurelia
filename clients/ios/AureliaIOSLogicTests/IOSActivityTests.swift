import Foundation
import Testing

struct IOSActivityTests {
  @Test func watchTimeReadsLikeSpokenDurations() {
    #expect(IOSWatchTime.text(seconds: 0) == "0 min")
    #expect(IOSWatchTime.text(seconds: 20) == "Under 1 min")
    #expect(IOSWatchTime.text(hours: 0.75) == "45 min")
    #expect(IOSWatchTime.text(hours: 2 + 5.0 / 60) == "2 h 5 min")
    #expect(IOSWatchTime.text(hours: 3) == "3 h")
    #expect(IOSWatchTime.text(hours: 24) == "1 day")
    #expect(IOSWatchTime.text(hours: 76) == "3 days 4 h")
    #expect(IOSWatchTime.text(hours: .nan) == "0 min")
  }

  @Test func isoWeeksStartOnMonday() throws {
    let start = try #require(IOSWatchTime.weekStart("2026-W43"))
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = .current
    let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: start)
    #expect(parts.year == 2026 && parts.month == 10 && parts.day == 19 && parts.weekday == 2)
    #expect(IOSWatchTime.weekStart("2026-43") == nil)
  }

  @Test func historyIsGroupedByDayInServerOrder() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-31T18:00:00Z"))
    let items = [
      entry("2026-10-31T17:00:00Z"), entry("2026-10-31T09:00:00Z"),
      entry("2026-10-30T22:00:00Z"), entry("2026-10-20T12:00:00Z"), entry("not a date"),
    ]
    let days = IOSWatchTime.days(items, now: now, calendar: calendar)
    #expect(days.map(\.title).prefix(2) == ["Today", "Yesterday"])
    #expect(days.map(\.items.count) == [2, 1, 1, 1])
    #expect(days.last?.title == "Earlier")
  }

  @Test func statisticsFromOlderServersDecodeWithoutOptionalFields() throws {
    let stats = try JSONDecoder().decode(
      IOSUserStatistics.self, from: Data(#"{"totalHoursWatched":1.5}"#.utf8))
    #expect(stats.totalHoursWatched == 1.5 && stats.hoursByWeek == nil)
    let named = try JSONDecoder().decode(
      IOSNamedCount.self, from: Data(#"{"name":"Drama","count":3}"#.utf8))
    #expect(named.hours == nil)
  }

  @Test func historyProgressIsBounded() {
    #expect(entry("2026-10-31T17:00:00Z", position: 9_000, duration: 6_000).fraction == 1)
    #expect(entry("2026-10-31T17:00:00Z", position: 3_000, duration: 6_000).fraction == 0.5)
    #expect(entry("2026-10-31T17:00:00Z", position: 3_000, duration: 0).fraction == 0)
  }

  private func entry(_ watchedAt: String, position: Int64 = 0, duration: Int64 = 1)
    -> IOSWatchHistoryItem
  {
    IOSWatchHistoryItem(
      id: UUID(), mediaId: UUID(), title: "Synthetic", eyebrow: nil, year: 2026, kind: "movie",
      poster: nil, watchedAt: watchedAt, positionMilliseconds: position,
      durationMilliseconds: duration, secondsWatched: 60, isCompleted: false)
  }
}
