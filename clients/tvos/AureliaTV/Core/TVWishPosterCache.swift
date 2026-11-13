import Foundation

/// Bounded memory and disk cache for server-proxied wish poster bytes.
/// Views decode lazily inside a separate bounded UIImage cache so memory stays small.
@MainActor
final class TVWishPosterByteCache {
  typealias Fetcher = @MainActor @Sendable (String, Int, TVAPIClient) async throws -> Data

  private let memoryBytes = NSCache<NSString, NSData>()
  private let diskCache: TVArtworkDiskCache?
  private let fetcher: Fetcher
  private var flights: [String: Task<Data?, Never>] = [:]
  private var failedKeys: Set<String> = []
  private var failedOrder: [String] = []
  private static let maxFailureEntries = 128

  static let standardDiskCache: TVArtworkDiskCache? = {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
      !ProcessInfo.processInfo.arguments.contains("--aurelia-ui-testing"),
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    return TVArtworkDiskCache(
      directory: caches.appendingPathComponent("Aurelia/WishPosters", isDirectory: true),
      byteLimit: 64 * 1_024 * 1_024)
  }()

  init(
    memoryLimitBytes: Int = 24 * 1_024 * 1_024,
    itemLimit: Int = 150,
    diskCache: TVArtworkDiskCache? = TVWishPosterByteCache.standardDiskCache,
    fetcher: @escaping Fetcher = { posterPath, width, client in
      try await client.wishPosterData(path: posterPath, width: width)
    }
  ) {
    memoryBytes.totalCostLimit = memoryLimitBytes
    memoryBytes.countLimit = itemLimit
    self.diskCache = diskCache
    self.fetcher = fetcher
  }

  func cachedData(posterPath: String?, width: Int = 342, serverID: UUID) -> Data? {
    guard let key = cacheKey(posterPath: posterPath, width: width, serverID: serverID) else {
      return nil
    }
    return memoryBytes.object(forKey: key as NSString) as Data?
  }

  func data(posterPath: String?, width: Int = 342, client: TVAPIClient) async -> Data? {
    guard let serverID = client.connection?.serverID,
      let normalized = normalizePath(posterPath),
      let key = cacheKey(posterPath: normalized, width: width, serverID: serverID)
    else {
      return nil
    }
    if let mem = memoryBytes.object(forKey: key as NSString) {
      return mem as Data
    }
    if failedKeys.contains(key) {
      return nil
    }
    if let running = flights[key] {
      return await running.value
    }

    let task = Task<Data?, Never> { @MainActor [weak self] in
      guard let self else { return nil }
      defer { self.flights[key] = nil }

      if let disk = self.diskCache?.data(forKey: key), !disk.isEmpty {
        self.memoryBytes.setObject(disk as NSData, forKey: key as NSString, cost: disk.count)
        return disk
      }
      do {
        let fetched = try await self.fetcher(normalized, width, client)
        guard !fetched.isEmpty else {
          self.recordFailure(key)
          return nil
        }
        self.memoryBytes.setObject(fetched as NSData, forKey: key as NSString, cost: fetched.count)
        self.diskCache?.store(fetched, forKey: key)
        return fetched
      } catch {
        if !(error is CancellationError) {
          self.recordFailure(key)
        }
        return nil
      }
    }
    flights[key] = task
    return await task.value
  }

  func clear() {
    for task in flights.values { task.cancel() }
    flights.removeAll()
    memoryBytes.removeAllObjects()
    failedKeys.removeAll()
    failedOrder.removeAll()
  }

  private func normalizePath(_ posterPath: String?) -> String? {
    let trimmed = posterPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func cacheKey(posterPath: String?, width: Int, serverID: UUID) -> String? {
    guard let normalized = normalizePath(posterPath) else { return nil }
    return "\(serverID.uuidString):wish:\(normalized):w\(width)"
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
}
