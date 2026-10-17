import AppKit
import Foundation
import Testing

@testable import Aurelia

@MainActor
struct ArtworkDiskCacheTests {
  @Test
  func revisionAndProfileSelectSeparateEntries() throws {
    let cache = try temporaryCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let server = UUID()
    let profile = UUID()
    let current = ArtworkDiskCache.key(
      serverID: server, profileID: profile, path: "/api/v1/artwork/a?width=640", revision: 2)
    cache.store(Data([1, 2, 3]), forKey: current)
    #expect(cache.data(forKey: current) == Data([1, 2, 3]))
    let newerRevision = ArtworkDiskCache.key(
      serverID: server, profileID: profile, path: "/api/v1/artwork/a?width=640", revision: 3)
    let otherProfile = ArtworkDiskCache.key(
      serverID: server, profileID: UUID(), path: "/api/v1/artwork/a?width=640", revision: 2)
    #expect(cache.data(forKey: newerRevision) == nil)
    #expect(cache.data(forKey: otherProfile) == nil)
  }

  @Test
  func pruningRemovesTheLeastRecentlyUsedEntriesFirst() throws {
    let cache = try temporaryCache(byteLimit: 1_000)
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    for index in 0..<4 {
      let key = "entry-\(index)"
      cache.store(Data(repeating: UInt8(index), count: 400), forKey: key)
      let file = try #require(
        try FileManager.default.contentsOfDirectory(
          at: cache.directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ).first { (try? Data(contentsOf: $0)) == Data(repeating: UInt8(index), count: 400) })
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 3_600)],
        ofItemAtPath: file.path)
    }
    cache.prune()
    #expect(cache.data(forKey: "entry-0") == nil)
    #expect(cache.data(forKey: "entry-1") == nil)
    #expect(cache.data(forKey: "entry-3") != nil)
  }

  @Test
  func artworkSurvivesANewLoaderWithoutAnotherRequest() async throws {
    let cache = try temporaryCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    var requests = 0
    let fetcher: ArtworkLoader.Fetcher = { _, _ in
      requests += 1
      return Data([7, 7, 7])
    }
    let profile = StoredServerProfile(
      serverId: UUID(), name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
    let artwork = ArtworkSummary(
      id: UUID(), kind: .poster, path: "/api/v1/artwork/\(UUID().uuidString.lowercased())",
      contentType: "image/jpeg", contentLength: 3, revision: 4)
    let first = ArtworkLoader(diskCache: cache, fetcher: fetcher)
    #expect(try await first.data(for: artwork, profile: profile, width: 640) == Data([7, 7, 7]))
    for _ in 0..<200 {
      let stored = try? FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
      if stored?.isEmpty == false { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    // An app restart starts with an empty memory cache.
    let restarted = ArtworkLoader(diskCache: cache, fetcher: fetcher)
    #expect(
      try await restarted.data(for: artwork, profile: profile, width: 640) == Data([7, 7, 7]))
    #expect(requests == 1)

    var legacy = artwork
    legacy.revision = nil
    _ = try await restarted.data(for: legacy, profile: profile)
    _ = try await ArtworkLoader(diskCache: cache, fetcher: fetcher).data(
      for: legacy, profile: profile)
    #expect(requests == 3)
  }

  @Test
  func loadedArtworkIsAvailableSynchronouslyIncludingLargerVariants() async throws {
    let png = try #require(Self.syntheticPNG())
    let loader = ArtworkLoader(diskCache: nil) { _, _ in png }
    let profile = StoredServerProfile(
      serverId: UUID(), name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
    let artwork = ArtworkSummary(
      id: UUID(), kind: .backdrop, path: "/api/v1/artwork/\(UUID().uuidString.lowercased())",
      contentType: "image/png", contentLength: Int64(png.count), revision: 2)
    #expect(loader.cachedImage(for: artwork, profile: profile, width: 1280) == nil)
    _ = try await loader.data(for: artwork, profile: profile, width: 1920)
    // A detail page that needs 1280 pixels draws the prepared 1920 variant at once.
    #expect(loader.cachedImage(for: artwork, profile: profile, width: 1920) != nil)
    #expect(loader.cachedImage(for: artwork, profile: profile, width: 1280) != nil)
    var revised = artwork
    revised.revision = 3
    #expect(loader.cachedImage(for: revised, profile: profile, width: 1280) == nil)
    loader.removeAll()
    #expect(loader.cachedImage(for: artwork, profile: profile, width: 1920) == nil)
  }

  private static func syntheticPNG() -> Data? {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    return bitmap.representation(using: .png, properties: [:])
  }

  @Test
  func catalogPagesGrowOnlyForServersThatAcceptThem() {
    let client = APIClient(
      profile: StoredServerProfile(
        serverId: UUID(), name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
        publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
        sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z"))
    #expect(client.catalogPageSize == 100)
    #expect(client.pagingCatalog(for: ["artwork-variants-v1"]).catalogPageSize == 100)
    #expect(client.pagingCatalog(for: nil).catalogPageSize == 100)
    #expect(client.pagingCatalog(for: ["catalog-pages-500-v1"]).catalogPageSize == 500)
  }

  private func temporaryCache(byteLimit: Int = 1_024 * 1_024) throws -> ArtworkDiskCache {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AureliaArtworkCacheTests-\(UUID().uuidString)", isDirectory: true)
    return ArtworkDiskCache(directory: directory, byteLimit: byteLimit)
  }
}
