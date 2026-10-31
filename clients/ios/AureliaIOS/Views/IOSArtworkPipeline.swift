import ImageIO
import UIKit

private struct IOSDecodedArtwork: @unchecked Sendable { let image: UIImage }

/// Profile-scoped, decoded artwork only. Media streams never enter this cache.
/// Downloaded bytes with a revision also persist on disk for the same profile.
actor IOSArtworkPipeline {
  private let cache = NSCache<NSString, UIImage>()
  private var requests: [String: Task<IOSDecodedArtwork, Error>] = [:]
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var generation = UUID()
  /// Views still waiting for each request. When all of them disappear, the
  /// download is cancelled so visible artwork is not queued behind it.
  private var interest: [String: Int] = [:]

  private let diskCache: IOSArtworkDiskCache?

  init(diskCache: IOSArtworkDiskCache? = .standard) {
    cache.totalCostLimit = 160 * 1024 * 1024
    cache.countLimit = 320
    self.diskCache = diskCache
  }

  func image(artwork: IOSArtwork, width: Int, api: IOSAPIClient) async throws -> UIImage {
    guard let connection = api.connection, let session = api.session else {
      throw IOSCoreError.profileRequired
    }
    let key =
      "\(connection.serverID):\(session.sessionId):\(artwork.id):\(artwork.revision ?? 0):\(width)"
    if let cached = cache.object(forKey: key as NSString) { return cached }
    if let pending = requests[key] { return try await waitFor(pending, key: key).image }
    let run = generation
    let diskCache = self.diskCache
    let diskKey = IOSArtworkDiskCache.key(
      serverID: connection.serverID, profileID: session.user.id, artwork: artwork, width: width)
    let task = Task<IOSDecodedArtwork, Error> {
      let stored: Data? =
        if let diskCache, let diskKey {
          await Task.detached(priority: .utility) { diskCache.data(forKey: diskKey) }.value
        } else { nil }
      let data: Data
      if let stored {
        data = stored
      } else {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        data = try await api.artworkData(artwork: artwork, width: width)
        if let diskCache, let diskKey {
          Task.detached(priority: .utility) { diskCache.store(data, forKey: diskKey) }
        }
      }
      do { return try await Self.decode(data, width: width) } catch IOSCoreError.invalidResponse {
        // A damaged stored entry is dropped so the next request downloads it again.
        if stored != nil, let diskCache, let diskKey { diskCache.remove(forKey: diskKey) }
        throw IOSCoreError.invalidResponse
      }
    }
    requests[key] = task
    do {
      let value = try await waitFor(task, key: key)
      guard generation == run else { throw CancellationError() }
      requests[key] = nil
      interest[key] = nil
      let cost = value.image.cgImage.map { $0.bytesPerRow * $0.height } ?? width * width * 4
      cache.setObject(value.image, forKey: key as NSString, cost: cost)
      return value.image
    } catch {
      if generation == run, requests[key] == task {
        requests[key] = nil
        interest[key] = nil
      }
      throw error
    }
  }

  private static func decode(_ data: Data, width: Int) async throws -> IOSDecodedArtwork {
    try await Task.detached(priority: .utility) {
      try Task.checkCancellation()
      let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
      guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
        let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
        sourceWidth > 0, sourceHeight > 0, sourceWidth <= 32_768, sourceHeight <= 32_768,
        Int64(sourceWidth) * Int64(sourceHeight) <= 100_000_000
      else { throw IOSCoreError.invalidResponse }
      let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
      let displayedWidth = (5...8).contains(orientation) ? sourceHeight : sourceWidth
      let maxDimension = max(sourceWidth, sourceHeight)
      let maxPixels = min(
        4096, Int(ceil(Double(width) * Double(maxDimension) / Double(displayedWidth))))
      guard
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary)
      else { throw IOSCoreError.invalidResponse }
      return IOSDecodedArtwork(image: UIImage(cgImage: image))
    }.value
  }

  private func waitFor(_ task: Task<IOSDecodedArtwork, Error>, key: String) async throws
    -> IOSDecodedArtwork
  {
    interest[key, default: 0] += 1
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      Task { await self.abandon(key, task: task) }
    }
  }

  private func abandon(_ key: String, task: Task<IOSDecodedArtwork, Error>) {
    guard requests[key] == task else { return }
    let remaining = (interest[key] ?? 1) - 1
    interest[key] = remaining
    guard remaining <= 0 else { return }
    task.cancel()
    requests[key] = nil
    interest[key] = nil
  }
  func clear() {
    generation = UUID()
    for request in requests.values { request.cancel() }
    requests.removeAll()
    interest.removeAll()
    cache.removeAllObjects()
  }
  /// The size of the artwork stored on this device.
  func storedBytes() -> Int { diskCache?.byteCount() ?? 0 }
  /// Forgets all artwork, in memory and on disk.
  func removeStored() {
    clear()
    diskCache?.removeAll()
  }
  private func acquire() async {
    if active < 6 {
      active += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }
  private func release() {
    if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
  }
}
