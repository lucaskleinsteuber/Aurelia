import Foundation
import Testing

struct TVArtworkDiskCacheTests {
  @Test func entriesAreScopedToProfileRevisionAndWidth() throws {
    let cache = temporaryCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let server = UUID()
    let profile = UUID()
    let artwork = poster(revision: 2)
    let key = try #require(
      TVArtworkDiskCache.key(serverID: server, profileID: profile, artwork: artwork, width: 640))
    cache.store(Data([1, 2, 3]), forKey: key)
    #expect(cache.data(forKey: key) == Data([1, 2, 3]))
    for other in [
      TVArtworkDiskCache.key(serverID: server, profileID: UUID(), artwork: artwork, width: 640),
      TVArtworkDiskCache.key(serverID: server, profileID: profile, artwork: artwork, width: 1280),
      TVArtworkDiskCache.key(
        serverID: server, profileID: profile, artwork: poster(id: artwork.id, revision: 3),
        width: 640),
    ] {
      #expect(cache.data(forKey: try #require(other)) == nil)
    }
    cache.remove(forKey: key)
    #expect(cache.data(forKey: key) == nil)
  }

  @Test func artworkWithoutRevisionIsNeverStored() {
    #expect(
      TVArtworkDiskCache.key(
        serverID: UUID(), profileID: UUID(), artwork: poster(revision: nil), width: 640) == nil)
  }

  @Test func pruningKeepsTheMostRecentlyUsedEntries() throws {
    let cache = temporaryCache(byteLimit: 1_000)
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    for index in 0..<4 {
      let payload = Data(repeating: UInt8(index), count: 400)
      cache.store(payload, forKey: "entry-\(index)")
      let file = try #require(
        try FileManager.default.contentsOfDirectory(
          at: cache.directory, includingPropertiesForKeys: nil
        ).first { (try? Data(contentsOf: $0)) == payload })
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 3_600)],
        ofItemAtPath: file.path)
    }
    cache.prune()
    #expect(cache.data(forKey: "entry-0") == nil)
    #expect(cache.data(forKey: "entry-1") == nil)
    #expect(cache.data(forKey: "entry-3") != nil)
  }

  @Test func collectionPosterAndBackdropSharingCollectionIDHaveDistinctKeys() throws {
    let server = UUID()
    let profile = UUID()
    let collectionID = UUID()
    let poster = TVArtwork(
      id: collectionID, kind: "poster",
      path: "/api/v1/artwork/collection/\(collectionID.uuidString.lowercased())/poster?kind=poster&rev=2",
      contentType: "image/jpeg", contentLength: 3, revision: 2)
    let backdrop = TVArtwork(
      id: collectionID, kind: "backdrop",
      path: "/api/v1/artwork/collection/\(collectionID.uuidString.lowercased())/backdrop?kind=backdrop&rev=2",
      contentType: "image/jpeg", contentLength: 3, revision: 2)
    let posterKey = try #require(
      TVArtworkDiskCache.key(serverID: server, profileID: profile, artwork: poster, width: 640))
    let backdropKey = try #require(
      TVArtworkDiskCache.key(serverID: server, profileID: profile, artwork: backdrop, width: 640))
    #expect(posterKey != backdropKey)
  }

  private func poster(id: UUID = UUID(), revision: Int64?) -> TVArtwork {
    TVArtwork(
      id: id, kind: "poster", path: "/api/v1/artwork/\(id.uuidString.lowercased())",
      contentType: "image/jpeg", contentLength: 3, revision: revision)
  }

  private func temporaryCache(byteLimit: Int = 1_024 * 1_024) -> TVArtworkDiskCache {
    TVArtworkDiskCache(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(
        "AureliaTVArtworkCacheTests-\(UUID().uuidString)", isDirectory: true),
      byteLimit: byteLimit)
  }
}
