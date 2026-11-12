import Combine
import Foundation

@MainActor final class MetadataSearchController: ObservableObject {
  @Published private(set) var candidates: [MetadataCandidateSummary] = []
  @Published private(set) var isSearching = false
  @Published private(set) var errorMessage: String?
  private var generation = UUID()

  func invalidate() {
    generation = UUID()
    candidates = []
    errorMessage = nil
    isSearching = false
  }

  func search(
    query: String,
    debounce: Duration = .milliseconds(350),
    operation: (String) async throws -> [MetadataCandidateSummary]
  ) async {
    invalidate()
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    let request = generation
    isSearching = true
    defer { if generation == request { isSearching = false } }
    do {
      try await Task.sleep(for: debounce)
      try Task.checkCancellation()
      let result = try await operation(normalized)
      try Task.checkCancellation()
      guard generation == request else { return }
      candidates = result
    } catch {
      guard generation == request, !Task.isCancelled else { return }
      if error is CancellationError { return }
      errorMessage = error.localizedDescription
    }
  }
}

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

enum CatalogPlaybackLogic {
  static func presentation(
    for item: CatalogItemSummary, intent: PlaybackStartIntent = .play
  ) -> PlaybackPresentation? {
    guard item.isPlayable else { return nil }
    return PlaybackPresentation(
      mediaId: item.id, title: item.title, subtitle: subtitle(for: item), startIntent: intent,
      artwork: artwork(for: item))
  }

  static func previousEpisodes(in detail: CatalogDetailPresentation, before mediaID: UUID)
    -> [PlaybackQueueItem]
  {
    let episodes = detail.seasons.filter { $0.number > 0 }.sorted { $0.number < $1.number }
      .flatMap { $0.episodes.sorted { $0.episodeNumber < $1.episodeNumber } }.map(\.item)
    guard let index = episodes.firstIndex(where: { $0.id == mediaID }) else { return [] }
    return episodes.prefix(index).filter(\.isPlayable).map {
      PlaybackQueueItem(
        mediaId: $0.id, title: $0.title, subtitle: subtitle(for: $0), artwork: artwork(for: $0))
    }
  }

  /// The series response is already access-filtered; never invent previous items outside it.
  static func previousEpisodes(in series: SeriesDetailResponse, before mediaID: UUID)
    -> [PlaybackQueueItem]
  {
    let episodes = series.seasons.filter { $0.number > 0 }.sorted { $0.number < $1.number }
      .flatMap { $0.episodes.sorted { $0.episodeNumber < $1.episodeNumber } }
    guard let index = episodes.firstIndex(where: { $0.id == mediaID }) else { return [] }
    return episodes.prefix(index).filter { $0.availability == .available }.map {
      PlaybackQueueItem(
        mediaId: $0.id, title: $0.title,
        subtitle: "\(series.title) · Season \($0.seasonNumber) · Episode \($0.episodeNumber)")
    }
  }

  static func artwork(for item: CatalogItemSummary) -> ArtworkSummary? {
    item.poster ?? item.backdrop
  }

  static func subtitle(for item: CatalogItemSummary) -> String? {
    guard item.kind == .episode else { return nil }
    let parts = [
      item.parentTitle,
      item.seasonNumber.map { "Season \($0)" },
      item.episodeNumber.map { "Episode \($0)" },
    ].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

/// "Ends at 21:43": when the title finishes if it plays on from `position` at `rate`.
enum PlaybackEndTime {
  static func text(
    position: Int64, duration: Int64, rate: Double, now: Date, locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String? {
    guard duration > 0, rate > 0 else { return nil }
    let remaining = Double(max(0, duration - position)) / 1_000 / rate
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.locale = locale
    style.timeZone = timeZone
    return "Ends at \(now.addingTimeInterval(remaining).formatted(style))"
  }
}

/// "Skip Intro" is offered while the intro plays. Times come from the server; without them
/// nothing is offered.
enum SkipIntroPolicy {
  /// The button appears a second before the intro and leaves two seconds before its end.
  static func showsButton(position: Int64, introStart: Int64, introEnd: Int64) -> Bool {
    guard introEnd > introStart else { return false }
    return position >= introStart - 1_000 && position < introEnd - 2_000
  }

  /// With "Skip intros automatically" the intro is skipped once per episode, and never after the
  /// person moved into it on their own (they want to see it).
  static func skipsAutomatically(
    enabled: Bool, alreadySkipped: Bool, movedIntoIntro: Bool, buttonShown: Bool
  ) -> Bool {
    enabled && buttonShown && !alreadySkipped && !movedIntoIntro
  }
}

/// "Up Next" appears when the credits begin, or without a credits time in the last seconds of an
/// episode-length title, when the next episode will start on its own.
enum UpNextPolicy {
  static let lead: Int64 = 20_000

  /// A credits time is only trusted in the second half of the title and before its end.
  static func credits(_ creditsStart: Int64?, duration: Int64) -> Int64? {
    guard let creditsStart, duration > 0, creditsStart >= duration / 2, creditsStart < duration - 1_000
    else { return nil }
    return creditsStart
  }

  static func shows(
    position: Int64, duration: Int64, hasNext: Bool, autoplay: Bool, stopsAtEnd: Bool,
    dismissed: Bool, lead: Int64 = lead, creditsStart: Int64? = nil
  ) -> Bool {
    guard hasNext, autoplay, !stopsAtEnd, !dismissed, duration >= 300_000, position > 0 else {
      return false
    }
    if let credits = credits(creditsStart, duration: duration), position >= credits { return true }
    return duration - position <= lead
  }

  /// Whether the card shows because the credits began (rather than in the last seconds).
  static func showsForCredits(position: Int64, duration: Int64, creditsStart: Int64?) -> Bool {
    guard let credits = credits(creditsStart, duration: duration) else { return false }
    return position >= credits
  }

  /// Next Episode in the credits counts the episode as watched: while the Up Next card shows, from
  /// the credits on, or in its last tenth. Earlier, skipping on keeps the position, so the
  /// episode can be resumed.
  static func nextFinishesCurrent(
    position: Int64, duration: Int64, upNextShown: Bool, creditsStart: Int64? = nil
  ) -> Bool {
    guard duration > 0, position >= 0 else { return false }
    if let credits = credits(creditsStart, duration: duration), position >= credits { return true }
    return upNextShown || position >= duration - duration / 10
  }

  /// Seconds until the next episode starts: to the end of the title, or, when the card appeared
  /// with the credits at `creditsAnchor`, the countdown from there.
  static func seconds(
    position: Int64, duration: Int64, creditsAnchor: Int64? = nil, lead: Int64 = lead
  ) -> Int {
    let deadline = creditsAnchor.map { min(duration, $0 + lead) } ?? duration
    return Int((max(0, deadline - position) + 999) / 1_000)
  }
}

/// After a movie or a series' last episode the server suggests what to watch next: a card from
/// the credits on (or the last seconds without known credits), without a countdown, and an end
/// screen when the file ends.
enum SuggestionPolicy {
  /// Shorter titles (a short film, an extra) get no suggestions.
  static let minimumDuration: Int64 = 600_000

  /// Suggestions are asked for once the title has no next episode and is half watched.
  static func wantsSuggestions(position: Int64, duration: Int64, hasNext: Bool) -> Bool {
    !hasNext && duration >= minimumDuration && position >= duration / 2
  }

  static func showsCard(
    position: Int64, duration: Int64, hasNext: Bool, hasSuggestion: Bool, dismissed: Bool,
    creditsStart: Int64?, lead: Int64 = UpNextPolicy.lead
  ) -> Bool {
    guard !hasNext, hasSuggestion, !dismissed, duration >= minimumDuration, position > 0 else {
      return false
    }
    if let credits = UpNextPolicy.credits(creditsStart, duration: duration) {
      return position >= credits
    }
    return duration - position <= lead
  }

  /// "Next in the Toy Story Collection · 2010"
  static func caption(_ suggestion: MediaSuggestion) -> String {
    [suggestion.reason, suggestion.item.year.map(String.init)].compactMap { $0 }
      .filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

struct PlaybackUpNext: Equatable {
  let title: String
  let subtitle: String?
  let seconds: Int
  /// The card appeared with the credits: its second button keeps watching them.
  var duringCredits = false
}
