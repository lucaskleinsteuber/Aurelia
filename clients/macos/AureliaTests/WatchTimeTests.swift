import Foundation
import Testing

@testable import Aurelia

struct WatchTimeTests {
  @Test func watchTimeReadsInMinutesHoursAndDays() {
    #expect(WatchTime.text(seconds: 0) == "0 min")
    #expect(WatchTime.text(seconds: 20) == "Under 1 min")
    #expect(WatchTime.text(seconds: 45) == "1 min")
    #expect(WatchTime.text(seconds: 45 * 60) == "45 min")
    #expect(WatchTime.text(seconds: 60 * 60) == "1 h")
    #expect(WatchTime.text(seconds: 125 * 60) == "2 h 5 min")
    #expect(WatchTime.text(seconds: 24 * 3_600) == "1 day")
    #expect(WatchTime.text(seconds: 28 * 3_600 + 50 * 60) == "1 day 4 h")
    #expect(WatchTime.text(seconds: 76 * 3_600) == "3 days 4 h")
  }

  @Test func theLastTwelveWeeksIncludeWeeksWithoutWatching() throws {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 19)))
    let weeks = WatchTime.lastWeeks(
      [PeriodHours(period: "2026-W43", hours: 1.5), PeriodHours(period: "2026-W30", hours: 9)],
      now: now, calendar: calendar)
    #expect(weeks.count == 12)
    #expect(weeks.first?.period == "2026-W33")
    #expect(weeks.last?.period == "2026-W44")
    #expect(weeks.first { $0.period == "2026-W43" }?.hours == 1.5)
    #expect(weeks.filter { $0.hours > 0 }.count == 1, "Older weeks are left out.")
  }

  @Test func hoursFromTheServerBecomeWholeMinutes() {
    #expect(WatchTime.text(hours: 0.5) == "30 min")
    #expect(WatchTime.text(hours: 1.25) == "1 h 15 min")
    #expect(WatchTime.text(hours: 10.0 / 60) == "10 min")
    #expect(WatchTime.text(hours: -1) == "0 min")
    #expect(WatchTime.text(hours: .nan) == "0 min")
  }

  @Test func isoWeeksStartOnTheirMonday() throws {
    let start = try #require(WatchTime.weekStart("2026-W43"))
    let calendar = Calendar(identifier: .gregorian)
    let parts = calendar.dateComponents(in: .current, from: start)
    #expect(parts.year == 2026 && parts.month == 10 && parts.day == 19)
    #expect(calendar.component(.weekday, from: start) == 2)
    #expect(WatchTime.weekStart("October") == nil)
  }

  @Test func historyDaysAreNamedRelativeToToday() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10)))
    let earlierToday = try #require(calendar.date(byAdding: .hour, value: -9, to: now))
    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
    let lastWeek = try #require(calendar.date(byAdding: .day, value: -5, to: now))
    #expect(WatchTime.dayTitle(for: earlierToday, now: now, calendar: calendar) == "Today")
    #expect(WatchTime.dayTitle(for: yesterday, now: now, calendar: calendar) == "Yesterday")
    let older = WatchTime.dayTitle(for: lastWeek, now: now, calendar: calendar)
    #expect(older != "Today" && older != "Yesterday" && !older.contains("2026"))
  }
}
