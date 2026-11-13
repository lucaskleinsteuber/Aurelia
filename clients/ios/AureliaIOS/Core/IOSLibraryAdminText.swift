import Foundation

/// The words the Library settings use for scans, storage locations and the folder picker.
enum IOSLibraryAdminText {
  /// Why a scan ran.
  static func trigger(_ trigger: String?) -> String? {
    switch trigger {
    case "manual": "Started by hand"
    case "fileChange": "Noticed a change"
    case "startup": "Server started"
    case "scheduled": "Scheduled"
    case "storageReconnected": "Drive came back"
    case "classificationChanged": "After sorting a folder"
    default: nil
    }
  }

  /// What a scan found, leaving out what didn't happen: "120 files · 12 new · 1 missing".
  static func summary(_ scan: IOSLibraryScan) -> String {
    var parts = [
      scan.isActive && scan.filesDiscovered > 0
        ? "\(scan.filesProcessed) of \(scan.filesDiscovered) files"
        : "\(scan.filesDiscovered) \(scan.filesDiscovered == 1 ? "file" : "files")"
    ]
    if scan.addedFiles > 0 { parts.append("\(scan.addedFiles) new") }
    if scan.updatedFiles > 0 { parts.append("\(scan.updatedFiles) changed") }
    if scan.missingFiles > 0 { parts.append("\(scan.missingFiles) missing") }
    if scan.skippedFiles > 0 { parts.append("\(scan.skippedFiles) skipped") }
    return parts.joined(separator: " · ")
  }

  /// A storage location's state in one line: waiting for review, scanning, or how it is.
  static func status(_ library: IOSLibrarySummary, scanning: Bool) -> String {
    if library.importPreviewRequired == true { return "Waiting for your import review" }
    if scanning { return "Scanning…" }
    return "\(library.kindTitle) · \(library.availabilityTitle)"
  }

  /// Scanning and watching wait until the first import was confirmed.
  static func isWaitingForReview(_ library: IOSLibrarySummary) -> Bool {
    library.importPreviewRequired == true
  }

  /// The name a new storage location gets from its folder.
  static func suggestedName(for path: String) -> String {
    let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    let last = (trimmed as NSString).lastPathComponent
    return last.isEmpty || last == "/" ? trimmed : last
  }

  /// A typed folder path, cleaned up; nil when it can't be a folder on the server.
  static func typedPath(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 4096, !trimmed.contains("\0") else { return nil }
    let isWindowsDrive =
      trimmed.count >= 2 && trimmed.dropFirst().first == ":" && trimmed.first?.isLetter == true
    guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || isWindowsDrive else { return nil }
    return trimmed
  }

  /// Offline titles can be listed after a week, a month or three months away.
  static let offlineChoices = [7, 30, 90]
}
