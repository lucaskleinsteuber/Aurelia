import CryptoKit
import Foundation

enum AppUpdateError: Error, Equatable, LocalizedError, Sendable {
  case github(Int)
  case invalidRelease, invalidTag, noDiskImage, noChecksum, checksumMismatch, noFolder
  case invalidURL, invalidResponse, tooLarge, emptyDownload, incompleteDownload, notNewer
  case timedOut, connectionLost, diskFull, writeFailed

  var errorDescription: String? { message }

  var message: String {
    switch self {
    case .github(401), .github(403):
      "GitHub didn't accept the token. Check it under Settings › App › Updates."
    case .github(404):
      "GitHub has no release here yet, or the token can't read this repository."
    case .github(let status): "GitHub answered with an error (\(status)). Try again later."
    case .invalidRelease: "GitHub returned an invalid release description. Try again later."
    case .invalidTag: "The newest release has an invalid version tag. It wasn't installed."
    case .noDiskImage: "The newest release has no Mac disk image."
    case .noChecksum: "The newest release has no checksum for its disk image."
    case .checksumMismatch:
      "The downloaded disk image doesn't match its published checksum, so it wasn't installed."
    case .noFolder: "Aurelia couldn't prepare a folder for the download."
    case .invalidURL: "The release contains an unexpected download address. It wasn't installed."
    case .invalidResponse: "GitHub returned an unexpected download response. Try again later."
    case .tooLarge: "The download exceeds Aurelia's size limit. It wasn't installed."
    case .emptyDownload: "GitHub returned an empty download. Try again later."
    case .incompleteDownload: "The download ended before it was complete. Try again."
    case .notNewer: "This release is not newer than the installed app."
    case .timedOut: "The update download timed out. Check the internet connection, then try again."
    case .connectionLost:
      "The update download was interrupted. Check the internet connection and try again."
    case .diskFull:
      "There isn't enough free disk space for the update. Free some space and try again."
    case .writeFailed: "Aurelia couldn't save the update. Check the download folder and try again."
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
}

/// The production transport and deterministic test transports share the same bounded contract.
protocol AppUpdateTransport: Sendable {
  func transfer(_ request: URLRequest, maximumBytes: Int64, destination: URL?) async throws
    -> AppUpdateTransfer
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

  init(response: URLResponse, maximumBytes: Int64, write: ((Data) throws -> Void)? = nil) throws {
    guard let http = response as? HTTPURLResponse else { throw AppUpdateError.invalidResponse }
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
  }

  mutating func finish() throws -> AppUpdateTransfer {
    guard count > 0 else { throw AppUpdateError.emptyDownload }
    guard expectedBytes == nil || expectedBytes == count else {
      throw AppUpdateError.incompleteDownload
    }
    return AppUpdateTransfer(
      data: data, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
  }
}

struct AppUpdateURLSessionTransport: AppUpdateTransport {
  private final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(AppUpdateLogic.redirectedRequest(request))
    }
  }

  func transfer(_ request: URLRequest, maximumBytes: Int64, destination: URL?) async throws
    -> AppUpdateTransfer
  {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 600
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var handle: FileHandle?
    var completed = false
    defer {
      try? handle?.close()
      if !completed, let destination { try? FileManager.default.removeItem(at: destination) }
    }
    do {
      let (bytes, response) = try await session.bytes(for: request, delegate: Redirects())
      // Validate headers before creating a destination or consuming a potentially huge response.
      _ = try AppUpdateTransferAccumulator(response: response, maximumBytes: maximumBytes)
      if let destination {
        try Data().write(to: destination, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: destination)
      }
      let output = handle
      var accumulator = try AppUpdateTransferAccumulator(
        response: response, maximumBytes: maximumBytes,
        write: output.map { file in { try file.write(contentsOf: $0) } })
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

  init(transport: any AppUpdateTransport = AppUpdateURLSessionTransport()) {
    self.transport = transport
  }

  func latest(repository: String, token: String) async throws -> AppRelease {
    guard AppUpdateLogic.isRepository(repository),
      let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    else { throw AppUpdateError.invalidURL }
    let result = try await transfer(url, token: token, maximumBytes: 2 * 1_024 * 1_024)
    return try AppUpdateLogic.validatedRelease(fromLatest: result.data, repository: repository)
  }

  func download(
    _ release: AppRelease, repository: String, token: String, currentBuild: Int, folder: URL
  ) async throws -> URL {
    guard let tag = AppUpdateLogic.parseTag(release.tag), tag.build == release.build,
      tag.version == release.version,
      release.diskImageName == AppUpdateLogic.diskImageName(tag: release.tag),
      AppUpdateLogic.isAssetURL(release.diskImageURL, repository: repository),
      AppUpdateLogic.isAssetURL(release.checksumsURL, repository: repository)
    else { throw AppUpdateError.invalidRelease }
    guard AppUpdateLogic.isNewer(build: release.build, than: currentBuild) else {
      throw AppUpdateError.notNewer
    }
    let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    var complete = false
    defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let sums = try await transfer(release.checksumsURL, token: token, maximumBytes: 1_024 * 1_024)
      guard
        let expected = AppUpdateLogic.checksum(
          for: release.diskImageName, in: String(decoding: sums.data, as: UTF8.self))
      else { throw AppUpdateError.noChecksum }
      let destination = directory.appendingPathComponent(release.diskImageName)
      let image = try await transfer(
        release.diskImageURL, token: token, maximumBytes: 2 * 1_024 * 1_024 * 1_024,
        destination: destination)
      guard image.sha256 == expected else { throw AppUpdateError.checksumMismatch }
      complete = true
      return destination
    } catch is CancellationError {
      throw CancellationError()
    } catch { throw AppUpdateError.classify(error) }
  }

  private func transfer(
    _ url: URL, token: String, maximumBytes: Int64, destination: URL? = nil
  ) async throws -> AppUpdateTransfer {
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(
      destination == nil ? "application/vnd.github+json" : "application/octet-stream",
      forHTTPHeaderField: "Accept")
    // Release assets, including checksums, must use GitHub's binary asset endpoint.
    if AppUpdateLogic.isAssetURL(url) {
      request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    }
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    do {
      return try await transport.transfer(
        request, maximumBytes: maximumBytes, destination: destination)
    } catch is CancellationError { throw CancellationError() } catch {
      throw AppUpdateError.classify(error)
    }
  }
}
