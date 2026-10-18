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
