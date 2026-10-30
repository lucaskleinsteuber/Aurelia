import Foundation

public enum IOSPlayerPolicy {
  public static let progressInterval: TimeInterval = 10
  public static let controlsDelay: TimeInterval = 4

  public static func seekPosition(current: Int64, offset: Int64, duration: Int64) -> Int64 {
    let (sum, overflow) = current.addingReportingOverflow(offset)
    let requested = overflow ? (offset > 0 ? Int64.max : 0) : max(0, sum)
    return duration > 0 ? min(requested, max(0, duration - 500)) : requested
  }

  public static func isNaturalCompletion(
    position: Int64,
    duration: Int64,
    observedPlayback: Bool,
    transportFailed: Bool
  ) -> Bool {
    guard observedPlayback, !transportFailed, duration > 0, position > 0 else { return false }
    let tolerance = max(1_000, min(5_000, duration / 100))
    return position >= duration - tolerance
  }

  public static func formatTime(milliseconds: Int64) -> String {
    let totalSeconds = max(0, Int(milliseconds / 1000))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    } else {
      return String(format: "%d:%02d", minutes, seconds)
    }
  }

  public static func endTimeLabel(
    position: Int64,
    duration: Int64,
    rate: Double = 1.0,
    now: Date = Date()
  ) -> String? {
    guard duration > 0, rate > 0 else { return nil }
    let remaining = Double(max(0, duration - position)) / 1000.0 / rate
    let end = now.addingTimeInterval(remaining)
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return "Ends at \(formatter.string(from: end))"
  }
}
