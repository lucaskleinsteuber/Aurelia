import Foundation

/// The server's file watch ("file-checks-v1"): whether it runs, how thoroughly and how far it is.
struct IOSFileCheckSettings: Codable, Equatable, Sendable {
  var enabled: Bool
  var depth: String
  var recheckDays: Int
  var canInspect: Bool
  var totalCount: Int
  var checkedCount: Int
  var pendingCount: Int
  var problemCount: Int
  var running: Bool
  var pausedForPlayback: Bool
  var currentTitle: String? = nil
  var currentStep: String? = nil
  var currentFraction: Double? = nil
  var estimatedSecondsRemaining: Int? = nil
  var lastCheckedAt: String? = nil

  /// Share of the files examined, 0 to 1.
  var progress: Double {
    totalCount == 0 ? 1 : Double(max(0, totalCount - pendingCount)) / Double(totalCount)
  }
}

struct IOSUpdateFileCheckSettings: Encodable, Sendable {
  var enabled: Bool
  var depth: String? = nil
  var recheckDays: Int? = nil
}

/// How thoroughly a new or changed file is examined.
enum IOSFileCheckDepth: String, CaseIterable, Identifiable, Sendable {
  case read, container, decode

  var id: String { rawValue }

  var title: String {
    switch self {
    case .read: "Read Every Byte"
    case .container: "Read Every Packet"
    case .decode: "Decode Everything"
    }
  }

  var detail: String {
    switch self {
    case .read: "Finds places the drive can't read and, later, files that changed by themselves. Fast."
    case .container: "Also finds files that are cut off or have damaged packets. Recommended."
    case .decode:
      "Also finds damage inside pictures and sound. Takes about as long as playing them on a small computer."
    }
  }
}

/// A file the watch found a problem in, for Library Health.
struct IOSFileProblem: Codable, Identifiable, Equatable, Sendable {
  let mediaId: UUID
  let title: String
  let kind: String
  let fileName: String
  let libraryName: String
  let state: String
  let errorCount: Int
  let problemAtSeconds: Double?
  let durationSeconds: Double?
  let detail: String?
  let depth: String
  let checkedAt: String
  let ignored: Bool

  var id: UUID { mediaId }
}

/// What a drive with storage locations reports about itself (SMART).
struct IOSDriveHealth: Codable, Identifiable, Equatable, Sendable {
  let name: String
  let libraries: [String]
  let state: String
  let temperatureCelsius: Double?
  let powerOnHours: Int64?
  let badSectors: Int64?
  let detail: String?

  var id: String { name + "\u{1F}" + libraries.joined(separator: "\u{1F}") }
}

struct IOSDriveHealthResponse: Codable, Equatable, Sendable {
  let drives: [IOSDriveHealth]
  let checkedAt: String?
}

/// The words the file watch shows, the same on every app (copied from the Mac app, not shared).
enum IOSFileWatchText {
  static let recheckChoices: [(days: Int, title: String)] = [
    (0, "Never"), (30, "Every 30 Days"), (90, "Every 90 Days"), (180, "Every 180 Days"),
  ]

  /// "Off", "All 120 files examined", "40 of 120 files · 2 problems · paused while someone watches · About 3 h left".
  static func status(_ settings: IOSFileCheckSettings) -> String {
    guard settings.enabled else { return "Off" }
    let total = settings.totalCount
    let problems =
      settings.problemCount > 0
      ? " · \(settings.problemCount) \(settings.problemCount == 1 ? "problem" : "problems")" : ""
    if settings.pendingCount == 0 { return "All \(total) \(total == 1 ? "file" : "files") examined\(problems)" }
    var parts = ["\(max(0, total - settings.pendingCount)) of \(total) files\(problems)"]
    if settings.pausedForPlayback { parts.append("paused while someone watches") }
    if let seconds = settings.estimatedSecondsRemaining, let left = remaining(seconds) { parts.append(left) }
    return parts.joined(separator: " · ")
  }

  /// "Now: Movie · Reading every byte (40 %)", or nil.
  static func current(_ settings: IOSFileCheckSettings) -> String? {
    guard settings.running, let title = settings.currentTitle else { return nil }
    guard let step = settings.currentStep else { return "Now: \(title)" }
    let share = settings.currentFraction.map { " (\(Int(($0 * 100).rounded())) %)" } ?? ""
    return "Now: \(title) · \(step)\(share)"
  }

  /// "About 40 min left", "About 3 h 20 min left", "About 3 days left", or nil.
  static func remaining(_ seconds: Int) -> String? {
    guard seconds > 0 else { return nil }
    let minutes = max(1, Int((Double(seconds) / 60).rounded()))
    if minutes < 60 { return "About \(minutes) min left" }
    let hours = minutes / 60
    if hours >= 48 { return "About \(Int((Double(hours) / 24).rounded())) days left" }
    let rest = minutes % 60
    return "About \(hours) h\(rest > 0 ? " \(rest) min" : "") left"
  }

  static func problemTitle(_ state: String) -> String {
    switch state {
    case "unreadable": "Unreadable"
    case "changedUnexpectedly": "Changed by Itself"
    case "damaged": "Damaged"
    case "notice": "Notice"
    default: "OK"
    }
  }

  static func problemSymbol(_ state: String) -> String {
    switch state {
    case "unreadable": "externaldrive.badge.exclamationmark"
    case "changedUnexpectedly": "doc.badge.ellipsis"
    case "damaged": "exclamationmark.triangle"
    default: "info.circle"
    }
  }

  /// "1:02:10" or "4:05".
  static func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let rest = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
  }

  /// "At about 1:02:10 of 1:45:00 · 3 errors · Movies".
  static func facts(_ problem: IOSFileProblem) -> String {
    var parts: [String] = []
    if let at = problem.problemAtSeconds {
      var text = "At about \(clock(at))"
      if let duration = problem.durationSeconds, duration > 0 { text += " of \(clock(duration))" }
      parts.append(text)
    }
    if problem.errorCount > 1 { parts.append("\(problem.errorCount) errors") }
    if !problem.libraryName.isEmpty { parts.append(problem.libraryName) }
    return parts.joined(separator: " · ")
  }

  static func driveTitle(_ state: String) -> String {
    switch state {
    case "good": "Good"
    case "warning": "Warning"
    case "failing": "Failing"
    default: "Unknown"
    }
  }

  /// "35 °C · 10,000 hours · 12 bad sectors".
  static func driveFacts(_ drive: IOSDriveHealth) -> String {
    var parts: [String] = []
    if let celsius = drive.temperatureCelsius { parts.append("\(Int(celsius.rounded())) °C") }
    let grouped = NumberFormatter()
    grouped.numberStyle = .decimal
    grouped.locale = Locale(identifier: "en_US")
    if let hours = drive.powerOnHours {
      parts.append("\(grouped.string(from: NSNumber(value: hours)) ?? "\(hours)") hours")
    }
    if let bad = drive.badSectors, bad > 0 {
      parts.append("\(grouped.string(from: NSNumber(value: bad)) ?? "\(bad)") bad sectors")
    }
    return parts.joined(separator: " · ")
  }
}
