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
    let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
    func number(_ value: Substring) -> Int? {
      guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
        value.count == 1 || value.first != "0"
      else { return nil }
      return Int(value)
    }
    guard parts.count == 2, let build = number(parts[1]), build > 0 else { return nil }
    let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard numbers.count == 3, numbers.allSatisfy({ number($0) != nil }) else { return nil }
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
    try? validatedRelease(fromLatest: data)
  }

  static func validatedRelease(fromLatest data: Data, repository: String? = nil) throws
    -> AppRelease
  {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = object["tag_name"] as? String,
      object["draft"] as? Bool != true,
      object["prerelease"] as? Bool != true,
      let assets = object["assets"] as? [[String: Any]]
    else { throw AppUpdateError.invalidRelease }
    guard let parsed = parseTag(tag) else { throw AppUpdateError.invalidTag }
    let imageName = diskImageName(tag: tag)
    func assetURL(_ name: String) -> URL? {
      assets.first { $0["name"] as? String == name }
        .flatMap { $0["url"] as? String }
        .flatMap(URL.init(string:))
    }
    guard let image = assetURL(imageName) else { throw AppUpdateError.noDiskImage }
    guard let sums = assetURL("SHA256SUMS") else { throw AppUpdateError.noChecksum }
    guard isAssetURL(image, repository: repository), isAssetURL(sums, repository: repository) else {
      throw AppUpdateError.invalidURL
    }
    let page = (object["html_url"] as? String).flatMap(URL.init(string:))
    return AppRelease(
      tag: tag, version: parsed.version, build: parsed.build, diskImageName: imageName,
      diskImageURL: image, checksumsURL: sums,
      pageURL: page.flatMap { isReleasePageURL($0, repository: repository) ? $0 : nil })
  }

  static func isAssetURL(_ url: URL, repository: String? = nil) -> Bool {
    guard isHTTPS(url), url.host?.lowercased() == "api.github.com", url.query == nil else {
      return false
    }
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 7, parts[0].isEmpty, parts[1] == "repos", !parts[2].isEmpty,
      !parts[3].isEmpty, parts[4] == "releases", parts[5] == "assets", !parts[6].isEmpty,
      parts[6].utf8.allSatisfy({ (48...57).contains($0) })
    else { return false }
    return repository == nil || "\(parts[2])/\(parts[3])".lowercased() == repository?.lowercased()
  }

  static func isHTTPS(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
      && (url.port == nil || url.port == 443) && url.fragment == nil
  }

  static func isReleasePageURL(_ url: URL, repository: String?) -> Bool {
    guard isHTTPS(url), url.host?.lowercased() == "github.com", url.query == nil else {
      return false
    }
    let parts = url.path.split(separator: "/")
    guard parts.count == 5, parts[2] == "releases", parts[3] == "tag" else { return false }
    return repository == nil || "\(parts[0])/\(parts[1])".lowercased() == repository?.lowercased()
  }

  /// Redirects never retain a token, cookies or other credentials, including same-host redirects.
  static func redirectedRequest(_ request: URLRequest) -> URLRequest? {
    guard let url = request.url, isHTTPS(url),
      isAssetURL(url)
        || ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(
          url.host?.lowercased() ?? "")
    else { return nil }
    var sanitized = request
    sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
    sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
    sanitized.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
    return sanitized
  }

  static func shouldStopHost(isHosting: Bool, isBackgroundService: Bool, installingUpdate: Bool)
    -> Bool
  {
    isHosting && (!isBackgroundService || installingUpdate)
  }

  /// "owner/name" of a GitHub repository, or nil for anything else.
  static func isRepository(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2
      && parts.allSatisfy { part in
        !part.isEmpty && part != "." && part != ".."
          && part.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
              || [45, 95, 46].contains($0)
          }
      }
  }
}
