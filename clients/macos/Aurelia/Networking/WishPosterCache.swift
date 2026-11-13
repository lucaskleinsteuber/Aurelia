import AppKit
import Foundation
import ImageIO

/// Bounded memory and disk cache for server-proxied wish posters.
/// Keeps poster traffic off the client-to-TMDB network and caps cache growth cleanly.
@MainActor
final class WishPosterCache {
  typealias Fetcher = @MainActor @Sendable (String, Int, StoredServerProfile) async throws -> Data

  private let memoryBytes = NSCache<NSString, NSData>()
  private let decodedImages = NSCache<NSString, NSImage>()
  private let diskCache: ArtworkDiskCache?
  private let fetcher: Fetcher
  private var flights: [String: Task<NSImage?, Never>] = [:]
  private var failedKeys: Set<String> = []
  private var failedOrder: [String] = []
  private static let maxFailureEntries = 128

  static let standardDiskCache: ArtworkDiskCache? = {
    let env = ProcessInfo.processInfo.environment
    guard env["XCTestConfigurationFilePath"] == nil,
      env["AURELIA_RUNNING_TESTS"] != "1",
      env["AURELIA_UI_TEST_MODE"] == nil,
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    return ArtworkDiskCache(
      directory: caches.appendingPathComponent("Aurelia/WishPosters", isDirectory: true),
      byteLimit: 64 * 1_024 * 1_024)
  }()

  init(
    memoryLimitBytes: Int = 24 * 1_024 * 1_024,
    decodedLimitBytes: Int = 48 * 1_024 * 1_024,
    itemLimit: Int = 150,
    diskCache: ArtworkDiskCache? = WishPosterCache.standardDiskCache,
    fetcher: @escaping Fetcher = { posterPath, width, profile in
      try await APIClient(profile: profile).wishPosterData(path: posterPath, width: width)
    }
  ) {
    memoryBytes.totalCostLimit = memoryLimitBytes
    memoryBytes.countLimit = itemLimit
    decodedImages.totalCostLimit = decodedLimitBytes
    decodedImages.countLimit = itemLimit
    self.diskCache = diskCache
    self.fetcher = fetcher
  }

  func cachedImage(posterPath: String?, width: Int = 342, profile: StoredServerProfile) -> NSImage?
  {
    guard let key = cacheKey(posterPath: posterPath, width: width, profile: profile) else {
      return nil
    }
    return decodedImages.object(forKey: key as NSString)
  }

  func image(posterPath: String?, width: Int = 342, profile: StoredServerProfile) async -> NSImage? {
    guard let normalized = normalizePath(posterPath),
      let key = cacheKey(posterPath: normalized, width: width, profile: profile)
    else {
      return nil
    }
    if let cached = decodedImages.object(forKey: key as NSString) {
      return cached
    }
    if failedKeys.contains(key) {
      return nil
    }
    if let running = flights[key] {
      return await running.value
    }

    let task = Task<NSImage?, Never> { @MainActor [weak self] in
      guard let self else { return nil }
      defer { self.flights[key] = nil }

      var imageData: Data?
      if let mem = self.memoryBytes.object(forKey: key as NSString) {
        imageData = mem as Data
      } else if let disk = self.diskCache?.data(forKey: key) {
        imageData = disk
        self.memoryBytes.setObject(disk as NSData, forKey: key as NSString, cost: disk.count)
      }

      if imageData == nil {
        do {
          let fetched = try await self.fetcher(normalized, width, profile)
          guard !fetched.isEmpty else {
            self.recordFailure(key)
            return nil
          }
          imageData = fetched
          self.memoryBytes.setObject(fetched as NSData, forKey: key as NSString, cost: fetched.count)
          self.diskCache?.store(fetched, forKey: key)
        } catch {
          if !(error is CancellationError) {
            self.recordFailure(key)
          }
          return nil
        }
      }

      guard let bytes = imageData else { return nil }
      let decoded = await Task.detached(priority: .userInitiated) {
        Self.decode(bytes, width: width)
      }.value
      guard !Task.isCancelled, let decoded else {
        self.recordFailure(key)
        return nil
      }
      let image = NSImage(cgImage: decoded.image, size: .zero)
      self.decodedImages.setObject(image, forKey: key as NSString, cost: decoded.bytes)
      return image
    }
    flights[key] = task
    return await task.value
  }

  func clear() {
    for task in flights.values { task.cancel() }
    flights.removeAll()
    memoryBytes.removeAllObjects()
    decodedImages.removeAllObjects()
    failedKeys.removeAll()
    failedOrder.removeAll()
  }

  private func normalizePath(_ posterPath: String?) -> String? {
    let trimmed = posterPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func cacheKey(posterPath: String?, width: Int, profile: StoredServerProfile) -> String? {
    guard let normalized = normalizePath(posterPath) else { return nil }
    return "\(profile.serverId.uuidString):wish:\(normalized):w\(width)"
  }

  private func recordFailure(_ key: String) {
    guard !failedKeys.contains(key) else { return }
    failedKeys.insert(key)
    failedOrder.append(key)
    while failedOrder.count > Self.maxFailureEntries {
      let oldest = failedOrder.removeFirst()
      failedKeys.remove(oldest)
    }
  }

  private struct DecodedPoster: @unchecked Sendable {
    let image: CGImage
    let bytes: Int
  }

  nonisolated private static func decode(_ data: Data, width: Int) -> DecodedPoster? {
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
      let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
      pixelWidth > 0, pixelHeight > 0, pixelWidth <= 32_768, pixelHeight <= 32_768
    else { return nil }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    let shownWidth = (5...8).contains(orientation) ? pixelHeight : pixelWidth
    let longest = max(pixelWidth, pixelHeight)
    let target = Int((Double(width) * Double(longest) / Double(shownWidth)).rounded(.up))
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: max(64, target),
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { return nil }
    return DecodedPoster(image: image, bytes: image.bytesPerRow * image.height)
  }
}
