import Foundation

/// What changed in this version, from the changelog built into the app (as in the Linux app).
enum ReleaseNotes {
  /// The bullets of "## Mac <version> …" in a Keep a Changelog file, without the section
  /// headings and Markdown marks. Empty when the version has no section.
  static func changes(in changelog: String?, version: String, product: String = "Mac")
    -> [String]
  {
    guard let changelog, !changelog.isEmpty else { return [] }
    let lines = changelog.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.hasPrefix("## \(product) \(version) ") })
    else { return [] }
    var changes: [String] = []
    for line in lines[(start + 1)...] {
      if line.hasPrefix("## ") { break }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("- ") else { continue }
      changes.append(
        String(trimmed.dropFirst(2)).replacingOccurrences(of: "**", with: "")
          .replacingOccurrences(of: "`", with: ""))
    }
    return changes
  }

  /// This app's changes, read once from the CHANGELOG.md in its bundle.
  static let current: [String] = {
    let file = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
    let text = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    return changes(in: text, version: version)
  }()
}
