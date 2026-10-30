import Foundation

public enum IOSScrubPreviewPlan {
  public static let minimumInterval: Int64 = 10_000
  public static let maximumFrames = 720
  public static let standInReach: Int64 = 4
  public static let endMargin: Int64 = 3_000

  public static func interval(for duration: Int64) -> Int64 {
    let spread = (max(0, duration) + Int64(maximumFrames) - 1) / Int64(maximumFrames)
    return max(minimumInterval, (spread + 999) / 1_000 * 1_000)
  }

  public static func bucket(for milliseconds: Int64, interval: Int64) -> Int64 {
    max(0, milliseconds) / interval * interval
  }

  public static func order(duration: Int64, interval: Int64) -> [Int64] {
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

  public static func snapshotPosition(bucket: Int64, interval: Int64, duration: Int64) -> Int64 {
    max(0, min(bucket + interval / 2, duration - endMargin))
  }

  public static func nearest(to bucket: Int64, interval: Int64, prepared: (Int64) -> Bool) -> Int64?
  {
    if prepared(bucket) { return bucket }
    for steps in 1...standInReach {
      for candidate in [bucket - steps * interval, bucket + steps * interval]
      where candidate >= 0 && prepared(candidate) {
        return candidate
      }
    }
    return nil
  }
}
