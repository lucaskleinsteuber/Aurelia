import AppKit
import SwiftUI
import Testing

@testable import Aurelia

/// Lays out Settings › Activity with invented data in an offscreen window. With
/// AURELIA_ACTIVITY_RENDER=1 it also prints both pages as base64 PNG lines to the test log, since
/// the sandboxed test host may not write outside its container.
@MainActor
struct ActivityRenderTests {
  @Test func activityPagesLayOutWithSyntheticData() async throws {
    let model = AppModel(store: InMemoryServerProfileStore())
    let pages: [(name: String, view: AnyView)] = [
      ("statistics", AnyView(ActivityStatisticsView(stats: Self.statistics, review: Self.review))),
      ("history", AnyView(ActivityHistoryView(items: Self.history, total: 12))),
    ]
    for page in pages {
      let host = NSHostingView(
        rootView: page.view.environmentObject(model)
          .padding(24).frame(width: 680, alignment: .topLeading)
          .background(AureliaDesign.canvas).environment(\.colorScheme, .dark))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 680, height: 600), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.contentView = host
      defer { window.orderOut(nil) }
      try await Task.sleep(for: .milliseconds(600))
      let size = host.fittingSize
      #expect(size.height > 400, "\(page.name) laid out only \(size.height) points")
      guard ProcessInfo.processInfo.environment["AURELIA_ACTIVITY_RENDER"] == "1" else { continue }
      host.setFrameSize(NSSize(width: 680, height: size.height))
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      print("AURELIA-ACTIVITY-RENDER \(page.name) \(png.base64EncodedString())")
    }
  }

  private static let statistics = UserStatistics(
    totalHoursWatched: 76.4, hoursPast7Days: 5.75, hoursPast30Days: 21.2,
    hoursByWeek: (32...43).map { week in
      PeriodHours(period: "2026-W\(week)", hours: Double((week * 37) % 9) * 0.75 + 0.4)
    },
    hoursByMonth: [],
    topGenres: [
      NamedCount(name: "Drama", count: 40, hours: 31.5),
      NamedCount(name: "Crime", count: 28, hours: 22.25),
      NamedCount(name: "Comedy", count: 12, hours: 8.1),
      NamedCount(name: "Documentary", count: 3, hours: 0.6),
    ],
    topTitles: [
      NamedCount(name: "Synthetic Series", count: 30, hours: 24.4),
      NamedCount(name: "Invented Movie", count: 2, hours: 2.3),
      NamedCount(name: "Placeholder Show", count: 9, hours: 1.2),
    ],
    currentStreakDays: 4, longestStreakDays: 12, busiestWeekday: "Sunday",
    busiestTimeOfDay: "Evening (18:00–23:00)", completionRate: 68.4,
    yearsAvailable: [2026, 2025])

  private static let review = YearInReview(
    year: 2026, totalHoursWatched: 54.2, titlesWatched: 61, moviesWatched: 9, episodesWatched: 52,
    topGenre: "Drama", topTitle: "Synthetic Series", busiestDay: "2026-03-14",
    busiestDayHours: 5.5)

  private static let history: [WatchHistoryItem] = (0..<6).map { index in
    let watched = Date().addingTimeInterval(Double(-index) * 9 * 3_600)
    return WatchHistoryItem(
      id: UUID(), mediaId: UUID(), title: index % 2 == 0 ? "Synthetic Series" : "Invented Movie",
      eyebrow: index % 2 == 0 ? "Season 1 · Episode \(index + 1)" : "2024", year: 2024,
      kind: index % 2 == 0 ? "episode" : "movie", poster: nil,
      watchedAt: ISO8601DateFormatter().string(from: watched),
      positionMilliseconds: Int64(600_000 * (index + 1)), durationMilliseconds: 3_000_000,
      secondsWatched: Int64([2_520, 40, 3_000, 900, 7_380, 1_260][index]),
      isCompleted: index == 2)
  }
}
