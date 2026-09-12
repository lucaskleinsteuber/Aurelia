import Foundation

struct HomeGenreRow: Identifiable, Equatable, Sendable {
  let title: String
  let items: [CatalogItemSummary]

  var id: String { title }
}

enum HomePresentationLogic {
  static func genreRows(
    from items: [CatalogItemSummary],
    limit: Int = 3
  ) -> [HomeGenreRow] {
    guard limit > 0 else { return [] }
    var grouped: [String: [CatalogItemSummary]] = [:]
    for item in items {
      for genre in Set(item.genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
      where !genre.isEmpty {
        grouped[genre, default: []].append(item)
      }
    }
    return grouped.keys
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
      .prefix(limit)
      .map { HomeGenreRow(title: $0, items: grouped[$0] ?? []) }
  }
}

enum HomeRefreshPolicy {
  static func delay(
    until recommendationChangesAt: String,
    now: Date = Date()
  ) -> TimeInterval? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard
      let date = fractional.date(from: recommendationChangesAt)
        ?? ISO8601DateFormatter().date(from: recommendationChangesAt)
    else { return nil }
    return max(date.timeIntervalSince(now), 0.25)
  }
}
