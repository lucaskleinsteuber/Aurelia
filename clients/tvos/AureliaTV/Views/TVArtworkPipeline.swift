import ImageIO
import UIKit

private struct TVDecodedArtwork: @unchecked Sendable { let image: UIImage }

/// Profile-scoped, decoded artwork only. Media streams never enter this cache.
actor TVArtworkPipeline {
  private let cache = NSCache<NSString, UIImage>()
  private var requests: [String: Task<TVDecodedArtwork, Error>] = [:]
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var generation = UUID()

  init() {
    cache.totalCostLimit = 80 * 1024 * 1024
    cache.countLimit = 180
  }

  func image(artwork: TVArtwork, width: Int, api: TVAPIClient) async throws -> UIImage {
    guard let connection = api.connection, let session = api.session else {
      throw TVCoreError.profileRequired
    }
    let key =
      "\(connection.serverID):\(session.sessionId):\(artwork.id):\(artwork.revision ?? 0):\(width)"
    if let cached = cache.object(forKey: key as NSString) { return cached }
    if let pending = requests[key] { return try await pending.value.image }
    let run = generation
    let task = Task<TVDecodedArtwork, Error> {
      await acquire()
      defer { release() }
      try Task.checkCancellation()
      let data = try await api.artworkData(artwork: artwork, width: width)
      return try await Task.detached(priority: .utility) {
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
          let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
          sourceWidth > 0, sourceHeight > 0, sourceWidth <= 32_768, sourceHeight <= 32_768,
          Int64(sourceWidth) * Int64(sourceHeight) <= 100_000_000
        else { throw TVCoreError.invalidResponse }
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
        else { throw TVCoreError.invalidResponse }
        return TVDecodedArtwork(image: UIImage(cgImage: image))
      }.value
    }
    requests[key] = task
    do {
      let value = try await task.value
      guard generation == run else { throw CancellationError() }
      requests[key] = nil
      let cost = value.image.cgImage.map { $0.bytesPerRow * $0.height } ?? width * width * 4
      cache.setObject(value.image, forKey: key as NSString, cost: cost)
      return value.image
    } catch {
      if generation == run { requests[key] = nil }
      throw error
    }
  }
  func clear() {
    generation = UUID()
    for request in requests.values { request.cancel() }
    requests.removeAll()
    cache.removeAllObjects()
  }
  private func acquire() async {
    if active < 4 {
      active += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }
  private func release() {
    if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
  }
}
