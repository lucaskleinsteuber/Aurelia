import Foundation

/// Bounded memory and disk cache for server-proxied wish poster bytes.
/// Platform views decode into `UIImage` lazily inside a separate bounded decoded cache.
@MainActor
final class IOSWishPosterByteCache {
  typealias Fetcher = @MainActor @Sendable (String, Int, IOSAPIClient) async throws -> Data

  private let memoryBytes = NSCache<NSString, NSData>()
  private let diskCache: IOSArtworkDiskCache?
  private let fetcher: Fetcher
  private let now: @MainActor @Sendable () -> Date
  private let failureRetryInterval: TimeInterval
  private var flights: [String: Task<Data?, Never>] = [:]
  private var failedKeys: [String: Date] = [:]
  private var failedOrder: [String] = []
  private var generation = UUID()
  private static let maxFailureEntries = 128

  static let standardDiskCache: IOSArtworkDiskCache? = {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
      !ProcessInfo.processInfo.arguments.contains("--aurelia-ui-testing"),
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    return IOSArtworkDiskCache(
      directory: caches.appendingPathComponent("Aurelia/WishPosters", isDirectory: true),
      byteLimit: 64 * 1_024 * 1_024)
  }()

  init(
    memoryLimitBytes: Int = 24 * 1_024 * 1_024,
    itemLimit: Int = 150,
    diskCache: IOSArtworkDiskCache? = IOSWishPosterByteCache.standardDiskCache,
    failureRetryInterval: TimeInterval = 30,
    now: @escaping @MainActor @Sendable () -> Date = { Date() },
    fetcher: @escaping Fetcher = { posterPath, width, client in
      try await client.wishPosterData(path: posterPath, width: width)
    }
  ) {
    memoryBytes.totalCostLimit = memoryLimitBytes
    memoryBytes.countLimit = itemLimit
    self.diskCache = diskCache
    self.failureRetryInterval = failureRetryInterval
    self.now = now
    self.fetcher = fetcher
  }

  func cachedData(posterPath: String?, width: Int = 342, serverID: UUID) -> Data? {
    guard let key = cacheKey(posterPath: posterPath, width: width, serverID: serverID) else {
      return nil
    }
    return memoryBytes.object(forKey: key as NSString) as Data?
  }

  func data(posterPath: String?, width: Int = 342, client: IOSAPIClient) async -> Data? {
    guard let serverID = client.connection?.serverID,
      let normalized = normalizePath(posterPath),
      let key = cacheKey(posterPath: normalized, width: width, serverID: serverID)
    else {
      return nil
    }
    if let mem = memoryBytes.object(forKey: key as NSString) {
      return mem as Data
    }
    if let retryAt = failedKeys[key] {
      guard now() >= retryAt else { return nil }
      failedKeys[key] = nil
      failedOrder.removeAll { $0 == key }
    }
    if let running = flights[key] {
      return await running.value
    }

    let run = generation
    let task = Task<Data?, Never> { @MainActor [weak self] in
      guard let self else { return nil }
      defer { if self.generation == run { self.flights[key] = nil } }

      let diskCache = self.diskCache
      if let diskCache {
        let disk = await Task.detached(priority: .utility) {
          diskCache.data(forKey: key)
        }.value
        guard !Task.isCancelled, self.generation == run else { return nil }
        if let disk, !disk.isEmpty {
          self.memoryBytes.setObject(disk as NSData, forKey: key as NSString, cost: disk.count)
          return disk
        }
      }
      do {
        let fetched = try await self.fetcher(normalized, width, client.background)
        guard !Task.isCancelled, self.generation == run else { return nil }
        guard !fetched.isEmpty else {
          self.recordFailure(key)
          return nil
        }
        self.memoryBytes.setObject(fetched as NSData, forKey: key as NSString, cost: fetched.count)
        if let diskCache {
          await Task.detached(priority: .utility) { diskCache.store(fetched, forKey: key) }.value
        }
        guard !Task.isCancelled, self.generation == run else { return nil }
        return fetched
      } catch {
        if !Task.isCancelled, self.generation == run, !(error is CancellationError),
          (error as? URLError)?.code != .cancelled
        {
          self.recordFailure(key)
        }
        return nil
      }
    }
    flights[key] = task
    return await task.value
  }

  func clear() {
    generation = UUID()
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
    guard failedKeys[key] == nil else { return }
    failedKeys[key] = now().addingTimeInterval(failureRetryInterval)
    failedOrder.append(key)
    while failedOrder.count > Self.maxFailureEntries {
      let oldest = failedOrder.removeFirst()
      failedKeys.removeValue(forKey: oldest)
    }
  }
}
