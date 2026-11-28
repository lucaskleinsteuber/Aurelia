import Foundation
import Testing

/// Guards source-level layout and formatting invariants across all iPhone and iPad views so
/// Slide Over (320 pt), Split View, small iPhones, and accessibility Dynamic Type never regress.
@Suite("iOS View Layout & Formatting Conventions")
struct IOSViewLayoutConventionsTests {
  private static var iosSourceRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("TarvenIOS", isDirectory: true)
  }

  private static func swiftFiles(in relativeSubdirectory: String) throws -> [URL] {
    let directory = iosSourceRoot.appendingPathComponent(relativeSubdirectory, isDirectory: true)
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    var urls: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      urls.append(url)
    }
    return urls.sorted { $0.path < $1.path }
  }

  @Test func viewsAlwaysUseSizeClassAdaptiveDesignTokensInsteadOfIdiomGlobals() throws {
    let files = try Self.swiftFiles(in: "Views") + Self.swiftFiles(in: "Playback")
    #expect(!files.isEmpty)

    // Matching bare `IOSDesign.margin` (not followed by `(for:`), etc., outside IOSDesign.swift.
    let nonAdaptivePattern = try Regex(
      #"IOSDesign\.(margin|posterWidth|landscapeWidth|shelfSpacing|gridColumns)(?!\s*\()"#)

    var violations: [String] = []
    for file in files where file.lastPathComponent != "IOSDesign.swift" {
      let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
      for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        if line.contains(nonAdaptivePattern) {
          violations.append("\(file.lastPathComponent):\(index + 1): \(trimmed)")
        }
      }
    }
    #expect(
      violations.isEmpty,
      "Use sizeClass-adaptive IOSDesign methods so iPad Slide Over/Split View stay compact: \(violations)"
    )
  }

  @Test func viewsNeverSizeLayoutsFromMainScreenBounds() throws {
    let files = try Self.swiftFiles(in: "Views") + Self.swiftFiles(in: "Playback")
    var violations: [String] = []
    for file in files {
      let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
      for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        if line.contains("UIScreen.main") {
          violations.append("\(file.lastPathComponent):\(index + 1): \(trimmed)")
        }
      }
    }
    #expect(
      violations.isEmpty,
      "Views must read container geometry or size classes instead of UIScreen.main: \(violations)")
  }

  @Test func sharedButtonStyleKeepsTouchTargetMinimumsAndWrapsAtLargeTextSizes() throws {
    let designURL = Self.iosSourceRoot
      .appendingPathComponent("Views", isDirectory: true)
      .appendingPathComponent("IOSDesign.swift")
    let designSource = try String(contentsOf: designURL, encoding: .utf8)
    #expect(designSource.contains("minHeight: kind == .icon ? nil : (kind == .row ? 44 : 48)"))
    #expect(designSource.contains("typeSize.isAccessibilitySize || typeSize >= .xLarge"))
  }
}
