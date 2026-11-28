import CryptoKit
import Foundation
import OSLog

enum AppUpdateError: Error, Equatable, LocalizedError, Sendable {
  case github(Int)
  case rateLimited, notModified, privateRepository
  case invalidRelease, invalidTag, noDiskImage, noMacRelease, noChecksum, checksumMismatch, noFolder
  case unsigned, badSignature
  case invalidURL, invalidResponse, tooLarge, emptyDownload, incompleteDownload, notNewer
  case timedOut, connectionLost, diskFull, writeFailed

  var errorDescription: String? { message }

  var message: String {
    switch self {
    case .rateLimited:
      "GitHub’s rate limit was reached. Try again later."
    case .notModified:
      "GitHub returned no release information. Try again."
    case .privateRepository:
      "The public release feed is unavailable (404)."
    case .github(let status) where status == 401 || status == 403:
      "GitHub denied access (\(status)). Try again later."
    case .github(404):
      "GitHub has no release for this repository yet."
    case .github(let status): "GitHub answered with an error (\(status)). Try again later."
    case .invalidRelease: "GitHub returned an invalid release description. Try again later."
    case .invalidTag: "The newest release has an invalid version tag. It wasn't installed."
    case .noDiskImage: "The newest release has no Mac disk image."
    case .noMacRelease:
      "No Mac release was found in the recent GitHub release list. Try again later or check the release page."
    case .noChecksum: "The newest release has no checksum for its disk image."
    case .checksumMismatch:
      "The downloaded disk image doesn't match its published checksum, so it wasn't installed."
    case .unsigned:
      "The newest release isn't signed, so it wasn't installed. Download it from the release page if you trust it."
    case .badSignature: "The release signature isn't valid, so the update wasn't installed."
    case .noFolder: "Tarven couldn't prepare a folder for the download."
    case .invalidURL: "The release contains an unexpected download address. It wasn't installed."
    case .invalidResponse: "GitHub returned an unexpected download response. Try again later."
    case .tooLarge: "The download exceeds Tarven's size limit. It wasn't installed."
    case .emptyDownload: "GitHub returned an empty download. Try again later."
    case .incompleteDownload: "The download ended before it was complete. Try again."
    case .notNewer: "This release is not newer than the installed app."
    case .timedOut: "The update download timed out. Check the internet connection, then try again."
    case .connectionLost:
      "The update download was interrupted. Check the internet connection and try again."
    case .diskFull:
      "There isn't enough free disk space for the update. Free some space and try again."
    case .writeFailed: "Tarven couldn't save the update. Check the download folder and try again."
    }
  }

  static func classify(_ error: Error) -> AppUpdateError {
    if let error = error as? AppUpdateError { return error }
    let failure = error as NSError
    if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteOutOfSpaceError)
      || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOSPC))
    {
      return .diskFull
    }
    if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? Error,
      classify(underlying) == .diskFull
    {
      return .diskFull
    }
    if failure.domain == NSURLErrorDomain {
      return failure.code == URLError.timedOut.rawValue ? .timedOut : .connectionLost
    }
    return .writeFailed
  }
}

struct AppUpdateTransfer: Sendable {
  let data: Data
  let sha256: String
  let etag: String?
  let linkHeader: String?

  init(data: Data, sha256: String, etag: String? = nil, linkHeader: String? = nil) {
    self.data = data
    self.sha256 = sha256
    self.etag = etag
    self.linkHeader = linkHeader
  }
}

/// The production transport and deterministic test transports share the same bounded contract.
protocol AppUpdateTransport: Sendable {
  func transfer(_ request: URLRequest, maximumBytes: Int64, destination: URL?) async throws
    -> AppUpdateTransfer
  /// The same, telling `progress` how much arrived; transports without progress just transfer.
  func transfer(
    _ request: URLRequest, maximumBytes: Int64, destination: URL?,
    progress: AppUpdateProgressHandler?
  ) async throws -> AppUpdateTransfer
}

extension AppUpdateTransport {
  func transfer(
    _ request: URLRequest, maximumBytes: Int64, destination: URL?,
    progress: AppUpdateProgressHandler?
  ) async throws -> AppUpdateTransfer {
    try await transfer(request, maximumBytes: maximumBytes, destination: destination)
  }
}

/// Holds at most one network chunk for a disk image; small JSON/checksum responses stay in memory.
/// This separate accumulator also permits testing write failures without filling a real disk.
struct AppUpdateTransferAccumulator {
  private let maximumBytes: Int64
  private let expectedBytes: Int64?
  private let write: ((Data) throws -> Void)?
  private var data = Data()
  private var digest = SHA256()
  private var count: Int64 = 0
  private var prefix = Data()
  private let etag: String?
  private let linkHeader: String?
  private let progress: AppUpdateProgressHandler?
  private var reported: Int64 = 0

  init(
    response: URLResponse, maximumBytes: Int64, write: ((Data) throws -> Void)? = nil,
    progress: AppUpdateProgressHandler? = nil
  ) throws {
    guard let http = response as? HTTPURLResponse else { throw AppUpdateError.invalidResponse }
    if http.statusCode == 304 { throw AppUpdateError.notModified }
    if http.statusCode == 429
      || (http.statusCode == 403 && http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0")
    {
      throw AppUpdateError.rateLimited
    }
    guard http.statusCode == 200 else { throw AppUpdateError.github(http.statusCode) }
    let type = (response.mimeType ?? "").lowercased()
    guard !type.contains("html") else { throw AppUpdateError.invalidResponse }
    guard response.expectedContentLength <= maximumBytes else { throw AppUpdateError.tooLarge }
    self.maximumBytes = maximumBytes
    let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
    expectedBytes =
      response.expectedContentLength >= 0 && (encoding == nil || encoding == "identity")
      ? response.expectedContentLength : nil
    self.write = write
    self.progress = progress
    self.etag = http.value(forHTTPHeaderField: "ETag")
    self.linkHeader = http.value(forHTTPHeaderField: "Link")
  }

  mutating func consume(_ chunk: Data) throws {
    guard Int64(chunk.count) <= maximumBytes - count else { throw AppUpdateError.tooLarge }
    count += Int64(chunk.count)
    if prefix.count < 512 {
      prefix.append(chunk.prefix(512 - prefix.count))
      let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      .lowercased()
      guard !text.hasPrefix("<!doctype html"), !text.hasPrefix("<html") else {
        throw AppUpdateError.invalidResponse
      }
    }
    digest.update(data: chunk)
    if let write { try write(chunk) } else { data.append(chunk) }
    if let progress,
      AppUpdateProgress.shouldReport(
        received: count, lastReported: reported, expected: expectedBytes)
    {
      reported = count
      progress(count, expectedBytes)
    }
  }

  mutating func finish() throws -> AppUpdateTransfer {
    guard count > 0 else { throw AppUpdateError.emptyDownload }
    guard expectedBytes == nil || expectedBytes == count else {
      throw AppUpdateError.incompleteDownload
    }
    return AppUpdateTransfer(
      data: data, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
      etag: etag, linkHeader: linkHeader)
  }
}

struct AppUpdateURLSessionTransport: AppUpdateTransport {
  let sessionConfiguration: URLSessionConfiguration?

  init(sessionConfiguration: URLSessionConfiguration? = nil) {
    self.sessionConfiguration = sessionConfiguration
  }

  private final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
    let publicTest: Bool
    init(publicTest: Bool) { self.publicTest = publicTest }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      let sanitized = AppUpdateLogic.redirectedRequest(request)
      if publicTest, let sanitized {
        let authorized = sanitized.value(forHTTPHeaderField: "Authorization") != nil
        Logger(subsystem: "org.tarven.mac", category: "UpdateTest")
          .notice("Public update redirect; authorization present: \(authorized, privacy: .public)")
      }
      completionHandler(sanitized)
    }
  }

  func transfer(_ request: URLRequest, maximumBytes: Int64, destination: URL?) async throws
    -> AppUpdateTransfer
  {
    try await transfer(request, maximumBytes: maximumBytes, destination: destination, progress: nil)
  }

  func transfer(
    _ request: URLRequest, maximumBytes: Int64, destination: URL?,
    progress: AppUpdateProgressHandler?
  ) async throws -> AppUpdateTransfer {
    let configuration =
      sessionConfiguration
      ?? {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        // A whole image over a slow line may take long; Linux allows 30 minutes (audit C-L11).
        config.timeoutIntervalForResource = 3600
        return config
      }()
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var handle: FileHandle?
    var completed = false
    defer {
      try? handle?.close()
      if !completed, let destination { try? FileManager.default.removeItem(at: destination) }
    }
    do {
      let (bytes, response) = try await session.bytes(
        for: request,
        delegate: Redirects(
          publicTest: AppUpdateSource.auditsAnonymousRequest(request)))
      // Validate headers before creating a destination or consuming a potentially huge response.
      _ = try AppUpdateTransferAccumulator(response: response, maximumBytes: maximumBytes)
      if let destination {
        try Data().write(to: destination, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: destination)
      }
      let output = handle
      var accumulator = try AppUpdateTransferAccumulator(
        response: response, maximumBytes: maximumBytes,
        write: output.map { file in { try file.write(contentsOf: $0) } }, progress: progress)
      var chunk = Data()
      chunk.reserveCapacity(65_536)
      for try await byte in bytes {
        chunk.append(byte)
        if chunk.count == 65_536 {
          try Task.checkCancellation()
          try accumulator.consume(chunk)
          chunk.removeAll(keepingCapacity: true)
        }
      }
      if !chunk.isEmpty { try accumulator.consume(chunk) }
      let result = try accumulator.finish()
      try handle?.synchronize()
      try handle?.close()
      handle = nil
      completed = true
      return result
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AppUpdateError.classify(error)
    }
  }
}

struct AppUpdateClient: Sendable {
  let transport: any AppUpdateTransport
  /// The minisign key the checksum list must be signed with; tests pass their own.
  let signingKey: String

  init(
    transport: any AppUpdateTransport = AppUpdateURLSessionTransport(),
    signingKey: String = AppUpdateSignature.publicKey
  ) {
    self.transport = transport
    self.signingKey = signingKey
  }

  func latestRelease(
    repository: String, ifNoneMatch: String? = nil
  ) async throws -> (release: AppRelease, etag: String?) {
    guard AppUpdateLogic.isRepository(repository),
      let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    else { throw AppUpdateError.invalidURL }
    let result: AppUpdateTransfer
    do {
      result = try await transfer(
        url, ifNoneMatch: ifNoneMatch, maximumBytes: 2 * 1_024 * 1_024)
    } catch AppUpdateError.github(404) {
      throw AppUpdateError.privateRepository
    }
    let release = try AppUpdateLogic.validatedRelease(
      fromLatest: result.data, repository: repository)
    return (release, result.etag)
  }

  static let maxBetaPages = 10

  /// Stable: GitHub's latest release. Beta: paginated release list (100 per page), pre-releases
  /// included.
  static func catalogURL(repository: String, beta: Bool) -> URL? {
    guard AppUpdateLogic.isRepository(repository) else { return nil }
    return URL(
      string: beta
        ? "https://api.github.com/repos/\(repository)/releases?per_page=100"
        : "https://api.github.com/repos/\(repository)/releases/latest")
  }

  func catalog(
    repository: String, cached: AppUpdateCatalogCache?, beta: Bool = false
  ) async throws -> (release: AppRelease, cache: AppUpdateCatalogCache?) {
    guard let url = Self.catalogURL(repository: repository, beta: beta) else {
      throw AppUpdateError.invalidURL
    }
    let limit: Int64 = 3 * 1_024 * 1_024
    let cachedRelease = cached.flatMap {
      try? AppUpdateLogic.release(in: $0.data, beta: beta, repository: repository)
    }
    if !beta {
      do {
        let result = try await transfer(
          url, ifNoneMatch: cachedRelease == nil ? nil : cached?.etag, maximumBytes: limit)
        let release = try AppUpdateLogic.validatedRelease(
          fromLatest: result.data, repository: repository)
        return (release, result.etag.map { AppUpdateCatalogCache(data: result.data, etag: $0) })
      } catch AppUpdateError.notModified {
        if let cached, let cachedRelease { return (cachedRelease, cached) }
        let result = try await transfer(url, maximumBytes: limit)
        return (
          try AppUpdateLogic.validatedRelease(fromLatest: result.data, repository: repository),
          result.etag.map { AppUpdateCatalogCache(data: result.data, etag: $0) }
        )
      } catch AppUpdateError.github(404) {
        throw AppUpdateError.privateRepository
      }
    }

    // Beta channel: check page 1 (with ETag cache), then walk Link rel="next" up to maxBetaPages
    // so server/Linux releases never hide an older Mac build.
    let firstPage: AppUpdateTransfer
    do {
      firstPage = try await transfer(
        url, ifNoneMatch: cachedRelease == nil ? nil : cached?.etag, maximumBytes: limit)
    } catch AppUpdateError.notModified {
      if let cached, let cachedRelease { return (cachedRelease, cached) }
      do {
        firstPage = try await transfer(url, maximumBytes: limit)
      } catch AppUpdateError.github(404) {
        throw AppUpdateError.privateRepository
      }
    } catch AppUpdateError.github(404) {
      throw AppUpdateError.privateRepository
    }
    if let release = try AppUpdateLogic.newestReleaseIfPresent(
      fromList: firstPage.data, repository: repository)
    {
      return (release, firstPage.etag.map { AppUpdateCatalogCache(data: firstPage.data, etag: $0) })
    }

    var visited: Set<URL> = [url]
    var nextURL = AppUpdateLogic.nextPageURL(
      fromLinkHeader: firstPage.linkHeader, repository: repository)
    var page = 1
    while page < Self.maxBetaPages, let pageURL = nextURL, visited.insert(pageURL).inserted {
      page += 1
      let result: AppUpdateTransfer
      do {
        result = try await transfer(pageURL, maximumBytes: limit)
      } catch AppUpdateError.github(404) {
        throw AppUpdateError.privateRepository
      }
      if let release = try AppUpdateLogic.newestReleaseIfPresent(
        fromList: result.data, repository: repository)
      {
        return (release, nil)
      }
      nextURL = AppUpdateLogic.nextPageURL(
        fromLinkHeader: result.linkHeader, repository: repository)
    }
    throw AppUpdateError.noMacRelease
  }

  func latest(
    repository: String, ifNoneMatch: String? = nil
  ) async throws -> AppRelease {
    try await latestRelease(repository: repository, ifNoneMatch: ifNoneMatch).release
  }

  private struct PendingInstallReference: Decodable {
    let directory: UUID
    let createdAt: Date?
  }

  /// Removes orphaned UUID download folders left behind by an earlier crash or force-quit once
  /// they are at least `maxAge` old and not referenced by a non-expired pending install request.
  static func pruneOrphanedDownloads(
    in folder: URL, maxAge: TimeInterval = 3_600, now: Date = Date(),
    fileManager: FileManager = .default
  ) {
    var protectedDirectory: UUID?
    let pendingPath = folder.appendingPathComponent("PendingInstall.json")
    if let pendingValues = try? pendingPath.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ]),
      pendingValues.isRegularFile == true, pendingValues.isSymbolicLink != true,
      let size = pendingValues.fileSize, size > 0, size <= 4_096,
      let data = try? Data(contentsOf: pendingPath),
      let ref = try? JSONDecoder().decode(PendingInstallReference.self, from: data)
    {
      if let createdAt = ref.createdAt {
        if now.timeIntervalSince(createdAt) < maxAge {
          protectedDirectory = ref.directory
        }
      } else {
        protectedDirectory = ref.directory
      }
    }
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
    ]
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: keys, options: [])
    else { return }
    for entry in entries {
      guard let uuid = UUID(uuidString: entry.lastPathComponent),
        uuid != protectedDirectory,
        let values = try? entry.resourceValues(forKeys: Set(keys)),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        let modified = values.contentModificationDate,
        now.timeIntervalSince(modified) >= maxAge
      else { continue }
      try? fileManager.removeItem(at: entry)
    }
  }

  func download(
    _ release: AppRelease, repository: String, currentBuild: Int, folder: URL,
    progress: AppUpdateProgressHandler? = nil
  ) async throws -> URL {
    guard let tag = AppUpdateLogic.parseTag(release.tag), tag.build == release.build,
      tag.version == release.version,
      release.diskImageName == AppUpdateLogic.diskImageName(tag: release.tag),
      AppUpdateLogic.isAnyAssetURL(release.diskImageURL, repository: repository),
      AppUpdateLogic.isAnyAssetURL(release.checksumsURL, repository: repository)
    else { throw AppUpdateError.invalidRelease }
    guard AppUpdateLogic.isNewer(build: release.build, than: currentBuild) else {
      throw AppUpdateError.notNewer
    }
    guard let signatureURL = release.signatureURL else { throw AppUpdateError.unsigned }
    guard AppUpdateLogic.isAnyAssetURL(signatureURL, repository: repository) else {
      throw AppUpdateError.invalidRelease
    }
    Self.pruneOrphanedDownloads(in: folder)
    let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    var complete = false
    defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let sums = try await transfer(release.checksumsURL, maximumBytes: 1_024 * 1_024)
      let signature = try await transfer(signatureURL, maximumBytes: 64 * 1_024)
      let expectedComment = AppUpdateSignature.expectedTrustedComment(
        version: release.version, build: release.build)
      guard
        AppUpdateSignature.verify(
          sums.data, signatureFile: String(decoding: signature.data, as: UTF8.self),
          publicKey: signingKey, expectedComment: expectedComment)
      else { throw AppUpdateError.badSignature }
      guard
        let expected = AppUpdateLogic.checksum(
          for: release.diskImageName, in: String(decoding: sums.data, as: UTF8.self))
      else { throw AppUpdateError.noChecksum }
      let destination = directory.appendingPathComponent(release.diskImageName)
      let image = try await transfer(
        release.diskImageURL, maximumBytes: 2 * 1_024 * 1_024 * 1_024,
        destination: destination, progress: progress)
      guard image.sha256 == expected else { throw AppUpdateError.checksumMismatch }
      complete = true
      return destination
    } catch is CancellationError {
      throw CancellationError()
    } catch { throw AppUpdateError.classify(error) }
  }

  private func transfer(
    _ url: URL, ifNoneMatch: String? = nil, maximumBytes: Int64,
    destination: URL? = nil, progress: AppUpdateProgressHandler? = nil
  ) async throws -> AppUpdateTransfer {
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    if let ifNoneMatch, !ifNoneMatch.isEmpty {
      request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
    }
    request.setValue(
      destination == nil ? "application/vnd.github+json" : "application/octet-stream",
      forHTTPHeaderField: "Accept")
    // Release assets, including checksums, must use binary asset accept header.
    if AppUpdateLogic.isAssetURL(url) || AppUpdateLogic.isPublicAssetURL(url) {
      request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    }
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if AppUpdateSource.auditsAnonymousRequest(request) {
      Logger(subsystem: "org.tarven.mac", category: "UpdateTest")
        .notice("Public update request; authorization present: false")
    }
    do {
      return try await transport.transfer(
        request, maximumBytes: maximumBytes, destination: destination, progress: progress)
    } catch is CancellationError { throw CancellationError() } catch {
      throw AppUpdateError.classify(error)
    }
  }
}
