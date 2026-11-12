import Foundation

/// A private note at a moment or over a range of a title (as on the Mac, the browser and Linux).
struct IOSSceneNote: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  var startMilliseconds: Int64
  var endMilliseconds: Int64?
  var text: String
  let revision: Int64
}

/// Revision zero creates a note with a new id from this device; a positive one updates it.
struct IOSSaveSceneNote: Codable, Equatable, Sendable {
  let startMilliseconds: Int64
  let endMilliseconds: Int64?
  let text: String
  let revision: Int64
}

enum IOSSceneNotePolicy {
  static let maximumLength = 2_000
  /// A note without an end shows for this long from its moment.
  static let momentMilliseconds: Int64 = 6_000

  /// The note to show at `position`: the first whose moment or range contains it.
  static func cue(_ notes: [IOSSceneNote], position: Int64) -> IOSSceneNote? {
    notes.sorted { $0.startMilliseconds < $1.startMilliseconds }.first { note in
      !note.text.isEmpty && position >= note.startMilliseconds
        && position <= (note.endMilliseconds ?? note.startMilliseconds + momentMilliseconds)
    }
  }

  /// The note's text trimmed and within its limit, or nil when nothing is left.
  static func cleaned(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(maximumLength))
  }

  /// "12:04" or "12:04–13:10".
  static func label(_ note: IOSSceneNote) -> String {
    let start = IOSPlayerPolicy.timeLabel(milliseconds: note.startMilliseconds)
    guard let end = note.endMilliseconds, end > note.startMilliseconds else { return start }
    return "\(start)–\(IOSPlayerPolicy.timeLabel(milliseconds: end))"
  }
}
