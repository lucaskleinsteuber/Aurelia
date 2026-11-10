import CoreFoundation
import Foundation

enum AppUpdateSource {
  // The owner requested the main repository for the next anonymous Mac update test.
  static let publicTestRepository = "lucaskleinsteuber/Aurelia"
  static let legacyPublicTestRepository = "lucaskleinsteuber/Aurelia-Update-Test"
  static let publicTestKey = "AureliaPublicUpdateTestEnabled"

  static func retirePublicTest(in defaults: UserDefaults) {
    guard defaults.bool(forKey: publicTestKey) else { return }
    defaults.removeObject(forKey: publicTestKey)
    defaults.removeObject(forKey: AppUpdatePreferences.checkKey(publicTestRepository))
    defaults.removeObject(forKey: AppUpdateCatalogCache.key(publicTestRepository))
  }

  static func auditsAnonymousRequest(_ request: URLRequest) -> Bool {
    guard request.value(forHTTPHeaderField: "Authorization") == nil,
      let path = request.url?.path
    else { return false }
    return [publicTestRepository, legacyPublicTestRepository].contains {
      path.hasPrefix("/repos/\($0)/")
    }
  }
}

/// One validated response and its validator are saved together, scoped to their repository.
struct AppUpdateCatalogCache: Codable, Sendable {
  let data: Data
  let etag: String

  /// Stable and beta answers come from different GitHub addresses, so each has its own entry.
  static func key(_ repository: String, beta: Bool = false) -> String {
    beta ? "AureliaUpdateCatalog.beta.v1.\(repository)" : "AureliaUpdateCatalog.v1.\(repository)"
  }

  static func load(repository: String, beta: Bool = false, defaults: UserDefaults) -> Self? {
    guard let bytes = defaults.data(forKey: key(repository, beta: beta)),
      bytes.count <= 3 * 1_024 * 1_024,
      let value = try? JSONDecoder().decode(Self.self, from: bytes),
      !value.etag.isEmpty, value.etag.utf8.count <= 1_024,
      (try? AppUpdateLogic.release(in: value.data, beta: beta, repository: repository)) != nil
    else { return nil }
    return value
  }

  static func save(_ value: Self?, repository: String, beta: Bool = false, defaults: UserDefaults) {
    if let value, let bytes = try? JSONEncoder().encode(value) {
      defaults.set(bytes, forKey: key(repository, beta: beta))
    } else {
      defaults.removeObject(forKey: key(repository, beta: beta))
    }
  }
}

/// A GitHub release of this app that is newer than the one running.
/// Told how many bytes of the disk image arrived and how many are expected (nil: unknown).
typealias AppUpdateProgressHandler = @Sendable (_ received: Int64, _ expected: Int64?) -> Void

/// How far an update download is, for the "Updating Aurelia" window and Settings › Updates.
struct AppUpdateProgress: Equatable, Sendable {
  let received: Int64
  let expected: Int64?

  /// 0…1, or nil when the size is unknown and the bar can only show that something happens.
  var fraction: Double? {
    guard let expected, expected > 0 else { return nil }
    return min(1, max(0, Double(received) / Double(expected)))
  }

  /// "34.2 MB of 120.5 MB", or only what arrived when the size is unknown.
  var text: String {
    let arrived = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
    guard let expected, expected > 0 else { return arrived }
    return "\(arrived) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
  }

  /// Whether a new amount is worth showing: every half percent (every megabyte without a size)
  /// and always the last byte, so a fast download doesn't flood the main thread.
  static func shouldReport(received: Int64, lastReported: Int64, expected: Int64?) -> Bool {
    guard received > lastReported else { return false }
    if let expected, expected > 0 {
      return received >= expected || received - lastReported >= max(expected / 200, 65_536)
    }
    return received - lastReported >= 1_048_576
  }
}

struct AppRelease: Equatable, Sendable {
  let tag: String
  let version: String
  let build: Int
  let diskImageName: String
  let diskImageURL: URL
  let checksumsURL: URL
  let pageURL: URL?
  let downloadBytes: Int64?
  /// A GitHub pre-release, offered only to Macs that turned on beta updates.
  let isBeta: Bool

  init(
    tag: String, version: String, build: Int, diskImageName: String, diskImageURL: URL,
    checksumsURL: URL, pageURL: URL?, downloadBytes: Int64? = nil, isBeta: Bool = false
  ) {
    self.tag = tag
    self.version = version
    self.build = build
    self.diskImageName = diskImageName
    self.diskImageURL = diskImageURL
    self.checksumsURL = checksumsURL
    self.pageURL = pageURL
    self.downloadBytes = downloadBytes
    self.isBeta = isBeta
  }
}

/// Local update choices; callers inject a private defaults suite in tests.
enum AppUpdatePreferences {
  static let automaticChecksKey = "AureliaAutomaticUpdateChecks"
  static let skippedVersionsKey = "AureliaSkippedUpdateVersions"
  static let lastCheckKey = "AureliaLastUpdateCheck"
  static let latestETagKey = "AureliaUpdateLatestETag"
  /// Off by default: only the owner's test Macs see pre-releases.
  static let betaUpdatesKey = "AureliaBetaUpdates"
  static let checkInterval: TimeInterval = 24 * 3_600

  static func betaUpdates(in defaults: UserDefaults) -> Bool {
    defaults.bool(forKey: betaUpdatesKey)
  }

  static func checksAutomatically(in defaults: UserDefaults) -> Bool {
    defaults.object(forKey: automaticChecksKey) == nil || defaults.bool(forKey: automaticChecksKey)
  }

  static func backgroundCheckIsDue(
    in defaults: UserDefaults, now: Date = Date(), repository: String? = nil
  ) -> Bool {
    guard checksAutomatically(in: defaults) else { return false }
    let last = defaults.object(forKey: checkKey(repository)) as? Date ?? .distantPast
    return now.timeIntervalSince(last) >= checkInterval
  }

  static func checkKey(_ repository: String?) -> String {
    repository.map { "\(lastCheckKey).\($0)" } ?? lastCheckKey
  }

  static func shouldOffer(
    version: String, userInitiated: Bool, defaults: UserDefaults
  ) -> Bool {
    userInitiated
      || (checksAutomatically(in: defaults)
        && !(defaults.stringArray(forKey: skippedVersionsKey) ?? []).contains(version))
  }

  static func skip(version: String, in defaults: UserDefaults) {
    var versions = defaults.stringArray(forKey: skippedVersionsKey) ?? []
    guard !versions.contains(version) else { return }
    versions.append(version)
    defaults.set(versions, forKey: skippedVersionsKey)
  }
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

  /// The architecture this app was built for, as the disk images name it: arm64 for Apple
  /// silicon, x64 for Intel. Each Mac takes only the image made for it.
  static var architecture: String {
    #if arch(arm64)
      "arm64"
    #else
      "x64"
    #endif
  }

  /// The disk image publish-release.sh attaches for a tag and this Mac's architecture.
  static func diskImageName(tag: String, architecture: String = architecture) -> String {
    "Aurelia-\(tag)-macOS-\(architecture).dmg"
  }

  /// A release is newer when its build number is higher; build numbers only ever rise.
  static func isNewer(build: Int, than currentBuild: Int) -> Bool { build > currentBuild }

  static func isNewer(_ release: AppRelease, version: String, build: Int) -> Bool {
    guard release.build > build, let current = parseTag("\(version)-\(max(1, build))") else {
      return false
    }
    return release.version.compare(current.version, options: .numeric) != .orderedAscending
  }

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
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AppUpdateError.invalidRelease
    }
    return try validatedRelease(object, allowsBeta: false, repository: repository)
  }

  /// The beta channel reads GitHub's release list: the Mac release with the highest build,
  /// pre-releases included. Linux and server releases in the same list have other tags and are
  /// passed over.
  static func newestRelease(fromList data: Data, repository: String? = nil) throws -> AppRelease {
    guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw AppUpdateError.invalidRelease
    }
    let releases = list.compactMap {
      try? validatedRelease($0, allowsBeta: true, repository: repository)
    }
    guard let newest = releases.max(by: { $0.build < $1.build }) else {
      throw AppUpdateError.invalidRelease
    }
    return newest
  }

  static func release(in data: Data, beta: Bool, repository: String? = nil) throws -> AppRelease {
    beta
      ? try newestRelease(fromList: data, repository: repository)
      : try validatedRelease(fromLatest: data, repository: repository)
  }

  private static func validatedRelease(
    _ object: [String: Any], allowsBeta: Bool, repository: String?
  ) throws -> AppRelease {
    let isBeta = object["prerelease"] as? Bool == true
    guard
      let tag = object["tag_name"] as? String,
      object["draft"] as? Bool != true,
      allowsBeta || !isBeta,
      let assets = object["assets"] as? [[String: Any]]
    else { throw AppUpdateError.invalidRelease }
    guard let parsed = parseTag(tag) else { throw AppUpdateError.invalidTag }
    let imageName = diskImageName(tag: tag)
    func assetURL(_ name: String) throws -> URL {
      guard let asset = assets.first(where: { $0["name"] as? String == name }) else {
        throw (name == imageName ? AppUpdateError.noDiskImage : AppUpdateError.noChecksum)
      }
      // The API address works for public and private repositories (with the token); the public
      // download link only works while the repository is public.
      if let apiStr = asset["url"] as? String,
        let apiURL = URL(string: apiStr),
        isAssetURL(apiURL, repository: repository)
      {
        return apiURL
      }
      if let publicStr = asset["browser_download_url"] as? String,
        let publicURL = URL(string: publicStr),
        isPublicAssetURL(publicURL, repository: repository)
      {
        return publicURL
      }
      throw AppUpdateError.invalidURL
    }
    let image = try assetURL(imageName)
    let imageAsset = assets.first { $0["name"] as? String == imageName }
    let bytes = downloadBytes(from: imageAsset?["size"])
    let sums = try assetURL("SHA256SUMS")
    let page = (object["html_url"] as? String).flatMap(URL.init(string:))
    return AppRelease(
      tag: tag, version: parsed.version, build: parsed.build, diskImageName: imageName,
      diskImageURL: image, checksumsURL: sums,
      pageURL: page.flatMap { isReleasePageURL($0, repository: repository) ? $0 : nil },
      downloadBytes: bytes, isBeta: isBeta)
  }

  static func downloadSizeText(_ bytes: Int64?) -> String {
    guard let bytes, bytes >= 0 else { return "Download size unavailable." }
    return "Download size: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
  }

  private static func downloadBytes(from value: Any?) -> Int64? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      let bytes = Int64(number.stringValue), bytes >= 0
    else { return nil }
    return bytes
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

  static func isPublicAssetURL(_ url: URL, repository: String? = nil) -> Bool {
    guard isHTTPS(url), url.host?.lowercased() == "github.com", url.query == nil else {
      return false
    }
    let parts = url.path.split(separator: "/")
    guard parts.count == 6, parts[2] == "releases", parts[3] == "download",
      !parts[0].isEmpty, !parts[1].isEmpty, !parts[4].isEmpty, !parts[5].isEmpty
    else { return false }
    return repository == nil || "\(parts[0])/\(parts[1])".lowercased() == repository?.lowercased()
  }

  static func isAnyAssetURL(_ url: URL, repository: String? = nil) -> Bool {
    isAssetURL(url, repository: repository) || isPublicAssetURL(url, repository: repository)
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
      isAnyAssetURL(url)
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
