import Foundation

enum MediaSegmentSource: String, Codable, Sendable {
  case none, chapters, detected, manual
}

/// Intro and credits times for one title, as stored on the server.
struct MediaSegments: Codable, Equatable, Sendable {
  let mediaId: UUID
  let analyzed: Bool
  let introStartMilliseconds: Int64?
  let introEndMilliseconds: Int64?
  let creditsStartMilliseconds: Int64?
  let source: MediaSegmentSource
  let analysisVersion: Int
}

struct MediaSegmentAnalysisItem: Codable, Equatable, Sendable {
  let mediaId: UUID
  let episodeNumber: Int?
  let needsAnalysis: Bool
}

struct MediaSegmentAnalysisGroup: Codable, Equatable, Sendable {
  let seriesId: UUID?
  let seasonNumber: Int?
  let items: [MediaSegmentAnalysisItem]
}

struct MediaSegmentAnalysisQueue: Codable, Equatable, Sendable {
  let groups: [MediaSegmentAnalysisGroup]
  /// Progress totals; servers before 1.7.4 leave them out.
  var totalTitles: Int?
  var analyzedTitles: Int?
}

/// The parts of a title that can be skipped, in milliseconds.
struct SkipSegments: Equatable, Sendable {
  var introStart: Int64?
  var introEnd: Int64?
  var creditsStart: Int64?

  static let empty = SkipSegments()

  var isEmpty: Bool { introEnd == nil && creditsStart == nil }
}

enum SkipPrompt: Equatable, Sendable {
  case intro(target: Int64)
  case credits(target: Int64)

  var title: String {
    switch self {
    case .intro: "Skip Intro"
    case .credits: "Skip Credits"
    }
  }

  var target: Int64 {
    switch self {
    case .intro(let target), .credits(let target): target
    }
  }
}

enum SkipSegmentLogic {
  private static let introWords = [
    "intro", "opening", "vorspann", "titelsequenz", "title sequence",
  ]
  private static let creditsWords = ["credits", "ending", "abspann", "outro", "end titles"]

  /// Intro and credits from chapter names, when a file carries them.
  static func fromChapters(_ chapters: [PlaybackChapter], duration: Int64) -> SkipSegments {
    guard duration > 0 else { return .empty }
    var result = SkipSegments()
    let ordered = chapters.sorted { $0.timeOffsetMilliseconds < $1.timeOffsetMilliseconds }
    for (index, chapter) in ordered.enumerated() {
      let title = chapter.title.lowercased()
      let start = chapter.timeOffsetMilliseconds
      let end =
        chapter.durationMilliseconds > 0
        ? start + chapter.durationMilliseconds
        : (index + 1 < ordered.count ? ordered[index + 1].timeOffsetMilliseconds : duration)
      if result.introEnd == nil, matches(title, introWords), !title.contains("introduction"),
        start < duration * 35 / 100, end > start, end - start <= 5 * 60_000
      {
        result.introStart = start
        result.introEnd = end
      } else if result.creditsStart == nil, matches(title, creditsWords),
        start > duration * 60 / 100
      {
        result.creditsStart = start
      }
    }
    return result
  }

  /// Disc releases often give the end credits a chapter of their own without naming it. The
  /// final chapter counts as credits only when it is short and lasts about as long in a
  /// neighbouring episode; a story chapter's length varies from episode to episode.
  static func closingChapter(
    _ chapters: [PlaybackChapter], duration: Int64, neighbours: [([PlaybackChapter], Int64)]
  ) -> Int64? {
    func closing(_ chapters: [PlaybackChapter], _ duration: Int64) -> (start: Int64, length: Int64)?
    {
      // A sliver of a few seconds after the credits is ignored.
      guard duration > 0,
        let start = chapters.map(\.timeOffsetMilliseconds)
          .filter({ $0 > duration * 60 / 100 && duration - $0 >= 15_000 }).max()
      else { return nil }
      let length = duration - start
      return (20_000...180_000).contains(length) ? (start, length) : nil
    }
    guard let own = closing(chapters, duration) else { return nil }
    let agrees = neighbours.contains { neighbour in
      guard let other = closing(neighbour.0, neighbour.1) else { return false }
      return abs(other.length - own.length) <= 12_000
    }
    return agrees ? own.start : nil
  }

  /// Server times win; an analyzed title without times has nothing to skip. Otherwise the
  /// file's own chapters are used.
  static func resolve(
    server: MediaSegments?, chapters: [PlaybackChapter], duration: Int64
  ) -> SkipSegments {
    if let server, server.analyzed {
      return SkipSegments(
        introStart: server.introStartMilliseconds, introEnd: server.introEndMilliseconds,
        creditsStart: server.creditsStartMilliseconds)
    }
    return fromChapters(chapters, duration: duration)
  }

  /// The button to show at `position`, if any.
  static func prompt(position: Int64, duration: Int64, segments: SkipSegments) -> SkipPrompt? {
    if let end = segments.introEnd {
      let start = segments.introStart ?? 0
      if position >= max(0, start - 500), position < end - 1_500 {
        return .intro(target: end)
      }
    }
    if let credits = segments.creditsStart, duration > 0, duration - credits >= 5_000,
      position >= credits, position < duration - 2_000
    {
      return .credits(target: max(credits, duration - 500))
    }
    return nil
  }

  private static func matches(_ title: String, _ words: [String]) -> Bool {
    words.contains { title.contains($0) }
  }
}
