import Foundation

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
    self.diskCache = diskCache
    self.fetcher = fetcher
  }

  func data(for artwork: ArtworkSummary, profile: StoredServerProfile, width: Int? = nil)
    async throws -> Data
  {
    let artwork = ArtworkVariantRequest.artwork(artwork, width: width)
    guard APIClient.isValidArtworkPath(artwork.path) else {
      throw APIClientError.invalidResponse
    }
    let flightKey =
      "\(profile.serverId.uuidString):\(profile.sessionId.uuidString):\(artwork.path):r\(artwork.revision ?? 0)"
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
