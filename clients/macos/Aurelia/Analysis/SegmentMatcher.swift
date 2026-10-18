import Foundation

/// Finds the longest passage that two fingerprints share, wherever it sits in each of them.
/// This is how an intro is found even when the scene before it has a different length.
enum SegmentMatcher {
  struct Match: Equatable, Sendable {
    /// Seconds from the start of each compared window.
    let firstStart: Double
    let firstEnd: Double
    let secondStart: Double
    let secondEnd: Double

    var length: Double { firstEnd - firstStart }
  }

  /// Bits of 32 that may differ for a frame to count as the same sound.
  static let frameTolerance = 10
  private static let commonValueLimit = 48
  private static let candidateCount = 4

  static func longestCommon(
    _ first: [UInt32], _ second: [UInt32], hopSeconds: Double = AudioFingerprint.hopSeconds,
    minimum: Double, maximum: Double
  ) -> Match? {
    guard !first.isEmpty, !second.isEmpty else { return nil }
    // Offsets at which identical values line up vote for an alignment.
    var positions: [UInt32: [Int32]] = [:]
    for (index, value) in second.enumerated() where value != 0 && value != .max {
      positions[value, default: []].append(Int32(index))
    }
    var votes: [Int: Int] = [:]
    for (index, value) in first.enumerated() {
      guard let list = positions[value], list.count <= commonValueLimit else { continue }
      for position in list { votes[Int(position) - index, default: 0] += 1 }
    }
    let minimumVotes = max(12, Int(minimum / hopSeconds) / 40)
    let candidates = votes.filter { $0.value >= minimumVotes }
      .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
      .prefix(candidateCount)
    var best: Match?
    for (offset, _) in candidates {
      guard let match = run(first, second, offset: offset, hopSeconds: hopSeconds),
        match.length >= minimum, match.length <= maximum
      else { continue }
      if best == nil || match.length > best!.length { best = match }
    }
    return best
  }

  /// The longest stretch at `offset` where most frames agree, tolerating short dropouts.
  private static func run(_ first: [UInt32], _ second: [UInt32], offset: Int, hopSeconds: Double)
    -> Match?
  {
    let start = max(0, -offset)
    let end = min(first.count, second.count - offset)
    guard end - start > 0 else { return nil }
    let window = max(1, Int((1.0 / hopSeconds).rounded()))
    let maximumGap = Int((1.5 / hopSeconds).rounded())
    var matched = [Bool](repeating: false, count: end - start)
    for index in start..<end {
      matched[index - start] =
        (first[index] ^ second[index + offset]).nonzeroBitCount <= frameTolerance
    }
    // A frame belongs to the passage when at least a third of the surrounding second agrees.
    var prefix = [Int](repeating: 0, count: matched.count + 1)
    for index in matched.indices { prefix[index + 1] = prefix[index] + (matched[index] ? 1 : 0) }
    var bestStart = -1
    var bestEnd = -1
    var runStart = -1
    var lastActive = -1
    for index in matched.indices {
      let low = max(0, index - window / 2)
      let high = min(matched.count, index + window / 2 + 1)
      let active = (prefix[high] - prefix[low]) * 3 >= high - low
      guard active else { continue }
      if runStart < 0 || index - lastActive > maximumGap { runStart = index }
      lastActive = index
      if index - runStart > bestEnd - bestStart {
        bestStart = runStart
        bestEnd = index
      }
    }
    guard bestStart >= 0 else { return nil }
    // Trim the smoothing margin to the first and last frames that truly match.
    while bestStart < bestEnd, !matched[bestStart] { bestStart += 1 }
    while bestEnd > bestStart, !matched[bestEnd] { bestEnd -= 1 }
    let firstStart = Double(bestStart + start) * hopSeconds
    let firstEnd = Double(bestEnd + start + 1) * hopSeconds
    return Match(
      firstStart: firstStart, firstEnd: firstEnd,
      secondStart: firstStart + Double(offset) * hopSeconds,
      secondEnd: firstEnd + Double(offset) * hopSeconds)
  }
}

/// Combines comparisons with several neighbouring episodes. The real intro is shared by all of
/// them; a recap clip matches only the episode it came from, so the largest agreeing group wins.
enum SegmentConsensus {
  static func choose(_ candidates: [(start: Double, end: Double)]) -> (start: Double, end: Double)?
  {
    guard !candidates.isEmpty else { return nil }
    var bestGroup: [(start: Double, end: Double)] = []
    for candidate in candidates {
      let group = candidates.filter { overlap($0, candidate) >= 0.5 }
      let longer =
        group.count == bestGroup.count
        && group.map { $0.end - $0.start }.max() ?? 0 > bestGroup.map { $0.end - $0.start }.max()
          ?? 0
      if group.count > bestGroup.count || longer { bestGroup = group }
    }
    let starts = bestGroup.map(\.start).sorted()
    let ends = bestGroup.map(\.end).sorted()
    return (starts[starts.count / 2], ends[ends.count / 2])
  }

  private static func overlap(
    _ first: (start: Double, end: Double), _ second: (start: Double, end: Double)
  ) -> Double {
    let intersection = max(0, min(first.end, second.end) - max(first.start, second.start))
    let shorter = min(first.end - first.start, second.end - second.start)
    return shorter > 0 ? intersection / shorter : 0
  }
}
