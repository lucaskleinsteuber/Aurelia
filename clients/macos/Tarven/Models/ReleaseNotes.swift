import Foundation

/// What changed in this version, from the changelog built into the app (as in the Linux app).
enum ReleaseNotes {
  /// The bullets of a matching "## Mac <version> …" or "## [… Mac <version> …](…)" heading in a
  /// Keep a Changelog file, without the section headings and Markdown marks. Empty when the
  /// version has no section.
  static func changes(in changelog: String?, version: String, product: String = "Mac")
    -> [String]
  {
    guard let changelog, !changelog.isEmpty, !version.isEmpty else { return [] }
    let lines = changelog.components(separatedBy: "\n")
    guard
      let start = lines.firstIndex(where: {
        matchesHeading($0, product: product, version: version)
      })
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

  /// Matches headings such as "## Mac 2.0.0 (153)", "## [Mac 1.30.0 (142) Beta](…)" and
  /// "## [Server 2.12.0 (161), Mac 2.12.1 (170), …](…)" without matching a prefix like "1.34".
  static func matchesHeading(_ line: String, product: String, version: String) -> Bool {
    guard line.hasPrefix("## "), !product.isEmpty, !version.isEmpty else { return false }
    let heading = headingTitle(from: String(line.dropFirst(3)))
    let needle = "\(product) \(version)"
    var searchStart = heading.startIndex
    while let range = heading.range(of: needle, range: searchStart..<heading.endIndex) {
      let validBefore: Bool =
        if range.lowerBound == heading.startIndex {
          true
        } else {
          isLeadingBoundary(heading[heading.index(before: range.lowerBound)])
        }
      let validAfter: Bool =
        if range.upperBound == heading.endIndex {
          true
        } else {
          isTrailingBoundary(heading[range.upperBound])
        }
      if validBefore && validAfter { return true }
      searchStart = range.upperBound
    }
    return false
  }

  private static func headingTitle(from raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
      return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
    }
    return trimmed
  }

  private static func isLeadingBoundary(_ character: Character) -> Bool {
    character.isWhitespace || character == "," || character == "[" || character == "("
  }

  private static func isTrailingBoundary(_ character: Character) -> Bool {
    character.isWhitespace || character == "(" || character == "," || character == "]"
      || character == "-" || character == "–"
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
