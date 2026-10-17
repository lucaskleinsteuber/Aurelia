import AppKit
import Foundation
import ImageIO

@MainActor
final class ArtworkLoader {
  typealias Fetcher =
    @MainActor @Sendable (ArtworkSummary, StoredServerProfile) async throws -> Data

  private struct Flight {
    let id: UUID
    let task: Task<Void, Never>
    var continuations: [UUID: CheckedContinuation<Data, Error>]
  }

  private let cache = NSCache<NSString, NSData>()
  private let images = NSCache<NSString, NSImage>()
  private var flights: [String: Flight] = [:]
  private let fetcher: Fetcher
  private let diskCache: ArtworkDiskCache?

  init(
    memoryLimit: Int = 96 * 1_024 * 1_024,
    itemLimit: Int = 300,
    diskCache: ArtworkDiskCache? = .standard,
    fetcher: @escaping Fetcher = { artwork, profile in
      try await APIClient(profile: profile).artworkData(path: artwork.path)
    }
  ) {
    cache.totalCostLimit = memoryLimit
    cache.countLimit = itemLimit
    // Decoded images are bounded by their pixel memory, not only by count.
    images.totalCostLimit = 2 * memoryLimit
    images.countLimit = itemLimit
    self.diskCache = diskCache
    self.fetcher = fetcher
  }

  /// Artwork already in memory, for drawing it in a view's first frame. A larger prepared
  /// variant of the same revision is used when the requested width is not loaded yet.
  func cachedImage(for artwork: ArtworkSummary, profile: StoredServerProfile, width: Int?)
    -> NSImage?
  {
    let widths: [Int?] =
      if let width { [width] + [640, 1280, 1920].filter { $0 > width } } else { [nil] }
    for candidate in widths {
      let key =
        Self.cacheKey(
          ArtworkVariantRequest.artwork(artwork, width: candidate), profile: profile) as NSString
      if let image = images.object(forKey: key) { return image }
      if let data = cache.object(forKey: key), let image = NSImage(data: data as Data) {
        images.setObject(image, forKey: key, cost: data.length)
        return image
      }
    }
    return nil
  }

  /// Artwork decoded off the main thread at the size it is shown, as the Apple TV does, so
  /// drawing it never stalls scrolling or animations.
  func image(for artwork: ArtworkSummary, profile: StoredServerProfile, width: Int?)
    async throws -> NSImage
  {
    let key =
      Self.cacheKey(ArtworkVariantRequest.artwork(artwork, width: width), profile: profile)
      as NSString
    if let image = images.object(forKey: key) { return image }
    let data = try await data(for: artwork, profile: profile, width: width)
    if let image = images.object(forKey: key) { return image }
    let decoded = await Task.detached(priority: .userInitiated) {
      Self.decode(data, width: width)
    }.value
    try Task.checkCancellation()
    guard let decoded else { throw APIClientError.invalidResponse }
    let image = NSImage(cgImage: decoded.image, size: .zero)
    images.setObject(image, forKey: key, cost: decoded.bytes)
    return image
  }

  private struct DecodedArtwork: @unchecked Sendable {
    let image: CGImage
    let bytes: Int
  }

  nonisolated private static func decode(_ data: Data, width: Int?) -> DecodedArtwork? {
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
    let target = width.map { Int((Double($0) * Double(longest) / Double(shownWidth)).rounded(.up)) }
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
          kCGImageSourceThumbnailMaxPixelSize: min(target ?? longest, longest, 4_096),
        ] as CFDictionary)
    else { return nil }
    return DecodedArtwork(image: image, bytes: image.bytesPerRow * image.height)
  }

  private static func cacheKey(_ artwork: ArtworkSummary, profile: StoredServerProfile) -> String {
    "\(profile.serverId.uuidString):\(profile.sessionId.uuidString):\(artwork.path):r\(artwork.revision ?? 0)"
  }

  func data(for artwork: ArtworkSummary, profile: StoredServerProfile, width: Int? = nil)
    async throws -> Data
  {
    let artwork = ArtworkVariantRequest.artwork(artwork, width: width)
    guard APIClient.isValidArtworkPath(artwork.path) else {
      throw APIClientError.invalidResponse
    }
    let flightKey = Self.cacheKey(artwork, profile: profile)
    let cacheKey = flightKey as NSString
    if let cached = cache.object(forKey: cacheKey) {
      return cached as Data
    }

    let requestID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        attach(
          continuation,
          requestID: requestID,
          artwork: artwork,
          flightKey: flightKey,
          cacheKey: cacheKey,
          profile: profile)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancel(flightKey: flightKey, requestID: requestID)
      }
    }
  }

  func removeAll() {
    cache.removeAllObjects()
    images.removeAllObjects()
    for flight in flights.values { flight.task.cancel() }
    let pending = flights.values.flatMap(\.continuations.values)
    flights.removeAll()
    for continuation in pending { continuation.resume(throwing: CancellationError()) }
  }

  private func attach(
    _ continuation: CheckedContinuation<Data, Error>,
    requestID: UUID,
    artwork: ArtworkSummary,
    flightKey: String,
    cacheKey: NSString,
    profile: StoredServerProfile
  ) {
    if var flight = flights[flightKey] {
      flight.continuations[requestID] = continuation
      flights[flightKey] = flight
      return
    }

    let fetcher = self.fetcher
    let flightID = UUID()
    // Artwork with a revision survives app restarts; a new revision is a new entry.
    let diskCache = self.diskCache
    let diskKey = artwork.revision.map {
      ArtworkDiskCache.key(
        serverID: profile.serverId, profileID: profile.user?.id, path: artwork.path, revision: $0)
    }
    let task = Task { [weak self] in
      do {
        let data: Data
        if let diskCache, let diskKey,
          let stored = await Task.detached(
            priority: .utility,
            operation: {
              diskCache.data(forKey: diskKey)
            }
          ).value
        {
          data = stored
        } else {
          data = try await fetcher(artwork, profile)
          if let diskCache, let diskKey {
            Task.detached(priority: .utility) { diskCache.store(data, forKey: diskKey) }
          }
        }
        guard !Task.isCancelled else { throw CancellationError() }
        self?.finish(
          flightKey: flightKey, flightID: flightID, cacheKey: cacheKey, result: .success(data))
      } catch {
        self?.finish(
          flightKey: flightKey, flightID: flightID, cacheKey: cacheKey, result: .failure(error))
      }
    }
    flights[flightKey] = Flight(id: flightID, task: task, continuations: [requestID: continuation])
  }

  private func cancel(flightKey: String, requestID: UUID) {
    guard var flight = flights[flightKey],
      let continuation = flight.continuations.removeValue(forKey: requestID)
    else { return }
    continuation.resume(throwing: CancellationError())
    if flight.continuations.isEmpty {
      flight.task.cancel()
      flights[flightKey] = nil
    } else {
      flights[flightKey] = flight
    }
  }

  private func finish(
    flightKey: String, flightID: UUID, cacheKey: NSString, result: Result<Data, Error>
  ) {
    guard let flight = flights[flightKey], flight.id == flightID else { return }
    flights[flightKey] = nil
    if case .success(let data) = result {
      cache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
    }
    for continuation in flight.continuations.values {
      continuation.resume(with: result)
    }
  }
}
