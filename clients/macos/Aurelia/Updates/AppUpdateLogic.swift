import Foundation

/// A GitHub release of this app that is newer than the one running.
struct AppRelease: Equatable, Sendable {
  let tag: String
  let version: String
  let build: Int
  let diskImageName: String
  let diskImageURL: URL
  let checksumsURL: URL
  let pageURL: URL?
}

/// The rules of updating that need no network or user interface: which release is newer, which
/// files belong to it and whether a download matches its published checksum.
enum AppUpdateLogic {
  /// "1.12.1-99" → ("1.12.1", 99): releases are tagged `<version>-<build>` by publish-release.sh.
  static func parseTag(_ tag: String) -> (version: String, build: Int)? {
    let parts = tag.split(separator: "-")
    guard parts.count == 2, let build = Int(parts[1]), build > 0 else { return nil }
    let numbers = parts[0].split(separator: ".")
    guard numbers.count == 3, numbers.allSatisfy({ Int($0) != nil }) else { return nil }
    return (String(parts[0]), build)
  }

  /// The disk image publish-release.sh attaches for a tag.
  static func diskImageName(tag: String) -> String { "Aurelia-\(tag)-macOS-universal.dmg" }

  /// A release is newer when its build number is higher; build numbers only ever rise.
  static func isNewer(build: Int, than currentBuild: Int) -> Bool { build > currentBuild }

  /// The SHA-256 the release's SHA256SUMS lists for a file, in lowercase hex.
  static func checksum(for fileName: String, in sums: String) -> String? {
    for line in sums.split(whereSeparator: \.isNewline) {
      let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
      guard fields.count == 2 else { continue }
      var name = fields[1].trimmingCharacters(in: .whitespaces)
      if name.hasPrefix("*") { name.removeFirst() }
      if name.hasPrefix("./") { name.removeFirst(2) }
      let hash = fields[0].lowercased()
      if name == fileName, hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash }
    }
    return nil
  }

  /// The newest release from GitHub's "latest release" answer, when it carries this app's disk
  /// image and the checksum list.
  static func release(fromLatest data: Data) -> AppRelease? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = object["tag_name"] as? String,
      object["draft"] as? Bool != true,
      let parsed = parseTag(tag),
      let assets = object["assets"] as? [[String: Any]]
    else { return nil }
    let imageName = diskImageName(tag: tag)
    func assetURL(_ name: String) -> URL? {
      assets.first { $0["name"] as? String == name }
        .flatMap { $0["url"] as? String }
        .flatMap(URL.init(string:))
    }
    guard let image = assetURL(imageName), let sums = assetURL("SHA256SUMS") else { return nil }
    return AppRelease(
      tag: tag, version: parsed.version, build: parsed.build, diskImageName: imageName,
      diskImageURL: image, checksumsURL: sums,
      pageURL: (object["html_url"] as? String).flatMap(URL.init(string:)))
  }

  /// "owner/name" of a GitHub repository, or nil for anything else.
  static func isRepository(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2
      && parts.allSatisfy { part in
        !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
      }
  }
}
