import Foundation

struct SceneNote: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let mediaId: UUID
  let startMilliseconds: Int64
  let endMilliseconds: Int64?
  let text: String
  let revision: Int64

  var timeLabel: String {
    let start = SceneNoteTime.format(startMilliseconds)
    return endMilliseconds.map { "\(start)–\(SceneNoteTime.format($0))" } ?? start
  }
}

enum SceneNoteTime {
  static func format(_ milliseconds: Int64) -> String {
    let value = max(0, milliseconds)
    let seconds = value / 1000
    let fraction = value % 1000
    let base =
      seconds >= 3600
      ? String(format: "%lld:%02lld:%02lld", seconds / 3600, (seconds / 60) % 60, seconds % 60)
      : String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    return fraction == 0 ? base : base + String(format: ".%03lld", fraction)
  }

  static func parse(_ text: String) -> Int64? {
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(
      separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return nil }
    var seconds: Int64 = 0
    for (index, part) in parts.enumerated() {
      if index == parts.count - 1 {
        let fields = part.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(fields.count), let whole = integer(fields[0]),
          parts.count == 1 || whole < 60
        else { return nil }
        let fraction = fields.count == 2 ? String(fields[1]) : ""
        guard fraction.count <= 3, fraction.allSatisfy({ $0.isASCII && $0.isNumber }),
          fields.count == 1 || !fraction.isEmpty
        else { return nil }
        let (sum, overflow) = seconds.addingReportingOverflow(whole)
        let (milliseconds, scaleOverflow) = sum.multipliedReportingOverflow(by: 1000)
        guard !overflow, !scaleOverflow else { return nil }
        let subsecond = Int64(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        let (result, finalOverflow) = milliseconds.addingReportingOverflow(subsecond)
        return finalOverflow ? nil : result
      }
      guard let whole = integer(part), index == 0 || whole < 60 else { return nil }
      let (sum, overflow) = seconds.addingReportingOverflow(whole)
      let (next, scaleOverflow) = sum.multipliedReportingOverflow(by: 60)
      guard !overflow, !scaleOverflow else { return nil }
      seconds = next
    }
    return nil
  }

  private static func integer(_ value: Substring) -> Int64? {
    guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return Int64(value)
  }
}

/// Playback-only cue state: seeks never replay skipped notes and no UI controls are touched.
struct SceneNoteCuePolicy {
  private var previous: Int64?
  private var announced: Set<UUID> = []
  private var discontinuous = true

  mutating func seek() { discontinuous = true }
  mutating func reset() { self = Self() }

  mutating func advance(to position: Int64, playing: Bool, preparing: Bool, notes: [SceneNote])
    -> [SceneNote]
  {
    guard playing, !preparing, position >= 0 else {
      if preparing { discontinuous = true }
      return []
    }
    if let previous, position < previous {
      announced.subtract(
        notes.filter { ($0.endMilliseconds ?? $0.startMilliseconds) >= position }.map(\.id))
      discontinuous = true
    }
    let from = previous
    previous = position
    let continuous = !discontinuous && from != nil && position - (from ?? position) <= 5000
    discontinuous = false
    let due = notes.filter { note in
      guard !announced.contains(note.id) else { return false }
      if continuous, let from {
        return note.startMilliseconds > from && note.startMilliseconds <= position
      }
      if let end = note.endMilliseconds {
        return note.startMilliseconds <= position && position < end
      }
      return note.startMilliseconds == position
    }.sorted {
      $0.startMilliseconds == $1.startMilliseconds
        ? $0.id.uuidString < $1.id.uuidString : $0.startMilliseconds < $1.startMilliseconds
    }
    announced.formUnion(due.map(\.id))
    return due
  }
}
