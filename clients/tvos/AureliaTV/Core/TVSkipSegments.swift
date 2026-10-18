import Foundation

/// Intro and credits times stored on the server for one title.
struct TVMediaSegments: Decodable, Equatable, Sendable {
  let mediaId: UUID
  let analyzed: Bool
  let introStartMilliseconds: Int64?
  let introEndMilliseconds: Int64?
  let creditsStartMilliseconds: Int64?
}

enum TVSkipPrompt: Equatable, Sendable {
  case intro(target: Int64)
  case credits(target: Int64)

  var target: Int64 {
    switch self {
    case .intro(let target), .credits(let target): target
    }
  }
}

enum TVSkipLogic {
  /// The skip button to offer at `position`, if any.
  static func prompt(position: Int64, duration: Int64, segments: TVMediaSegments?) -> TVSkipPrompt?
  {
    guard let segments, segments.analyzed else { return nil }
    if let end = segments.introEndMilliseconds {
      let start = segments.introStartMilliseconds ?? 0
      if position >= max(0, start - 500), position < end - 1_500 { return .intro(target: end) }
    }
    if let credits = segments.creditsStartMilliseconds, duration > 0,
      duration - credits >= 5_000, position >= credits, position < duration - 2_000
    {
      return .credits(target: max(credits, duration - 500))
    }
    return nil
  }
}
