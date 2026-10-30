import Foundation

/// Which timeline frames to prepare, in what order, and where each is taken. The frames
/// themselves are decoded live and kept only in memory by `IOSScrubPreviews`.
enum IOSScrubPreviewPlan {
  static let minimumInterval: Int64 = 10_000
  static let maximumFrames = 720
  /// While the exact frame is still on its way, a prepared frame this many steps away stands in.
  static let standInReach: Int64 = 4
  static let endMargin: Int64 = 3_000
  /// The server feature that keeps preview reads apart from playback streams.
  static let serverFeature = "preview-streams-v1"
  /// The server feature for pre-generated scrub preview strips.
  static let serverScrubPreviewsFeature = "scrub-previews-v1"

  static func interval(for duration: Int64) -> Int64 {
    let spread = (max(0, duration) + Int64(maximumFrames) - 1) / Int64(maximumFrames)
    return max(minimumInterval, (spread + 999) / 1_000 * 1_000)
  }

  static func bucket(for milliseconds: Int64, interval: Int64) -> Int64 {
    max(0, milliseconds) / interval * interval
  }

  /// Every step once: first every eighth, then the ones between, so the whole timeline is
  /// roughly covered early on.
  static func order(duration: Int64, interval: Int64) -> [Int64] {
    guard duration > 0, interval > 0 else { return [] }
    let count = Int((duration + interval - 1) / interval)
    var seen = [Bool](repeating: false, count: count)
    var order: [Int64] = []
    order.reserveCapacity(count)
    var step = 8
    while step >= 1 {
      for index in stride(from: 0, to: count, by: step) where !seen[index] {
        seen[index] = true
        order.append(Int64(index) * interval)
      }
      step /= 2
    }
    return order
  }

  /// A step's frame is taken in its middle, but never in the last seconds, where the decoder
  /// finds no frame after the seek.
  static func snapshotPosition(bucket: Int64, interval: Int64, duration: Int64) -> Int64 {
    max(0, min(bucket + interval / 2, duration - endMargin))
  }

  /// The exact step if prepared, else the closest prepared one within reach.
  static func nearest(to bucket: Int64, interval: Int64, prepared: (Int64) -> Bool) -> Int64? {
    if prepared(bucket) { return bucket }
    for steps in 1...standInReach {
      for candidate in [bucket - steps * interval, bucket + steps * interval]
      where candidate >= 0 && prepared(candidate) {
        return candidate
      }
    }
    return nil
  }

  /// Background decoders: several where the server keeps previews apart, else one, because
  /// older servers would count previews as playback streams.
  static func workers(parallel: Bool, cores: Int = ProcessInfo.processInfo.activeProcessorCount)
    -> Int
  {
    parallel ? min(4, max(2, cores - 2)) : 1
  }
}
