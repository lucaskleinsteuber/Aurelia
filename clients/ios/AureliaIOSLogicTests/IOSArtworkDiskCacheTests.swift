import Foundation
import Testing

struct IOSArtworkDiskCacheTests {
  @Test func entriesAreScopedToProfileRevisionAndWidth() throws {
    let cache = temporaryCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    let server = UUID()
    let profile = UUID()
    let artwork = poster(revision: 2)
    let key = try #require(
      IOSArtworkDiskCache.key(serverID: server, profileID: profile, artwork: artwork, width: 640))
    cache.store(Data([1, 2, 3]), forKey: key)
    #expect(cache.data(forKey: key) == Data([1, 2, 3]))
    for other in [
      IOSArtworkDiskCache.key(serverID: server, profileID: UUID(), artwork: artwork, width: 640),
      IOSArtworkDiskCache.key(serverID: server, profileID: profile, artwork: artwork, width: 1280),
      IOSArtworkDiskCache.key(
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
      IOSArtworkDiskCache.key(
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

  @Test func sizeAndClearingCoverOnlyStoredArtwork() throws {
    let cache = temporaryCache()
    defer { try? FileManager.default.removeItem(at: cache.directory) }
    #expect(cache.byteCount() == 0)
    cache.store(Data(repeating: 1, count: 300), forKey: "first")
    cache.store(Data(repeating: 2, count: 200), forKey: "second")
    let unrelated = cache.directory.appendingPathComponent("keep.txt")
    try Data([9]).write(to: unrelated)
    #expect(cache.byteCount() == 501)
    cache.removeAll()
    #expect(cache.data(forKey: "first") == nil)
    #expect(cache.data(forKey: "second") == nil)
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
  }

  @Test func collectionPosterAndBackdropNeverCollideOnDisk() throws {
    let sharedID = UUID()
    let server = UUID()
    let profile = UUID()
    let posterArt = IOSArtwork(
      id: sharedID, kind: "poster",
      path: "/api/v1/artwork/collection/\(sharedID.uuidString.lowercased())?kind=poster&rev=2",
      contentType: "image/webp", contentLength: 3, revision: 2)
    let backdropArt = IOSArtwork(
      id: sharedID, kind: "backdrop",
      path: "/api/v1/artwork/collection/\(sharedID.uuidString.lowercased())?kind=backdrop&rev=2",
      contentType: "image/webp", contentLength: 3, revision: 2)
    let posterKey = try #require(
      IOSArtworkDiskCache.key(serverID: server, profileID: profile, artwork: posterArt, width: 640))
    let backdropKey = try #require(
      IOSArtworkDiskCache.key(serverID: server, profileID: profile, artwork: backdropArt, width: 640))
    #expect(posterKey != backdropKey)
  }

  private func poster(id: UUID = UUID(), revision: Int64?) -> IOSArtwork {
    IOSArtwork(
      id: id, kind: "poster", path: "/api/v1/artwork/\(id.uuidString.lowercased())",
      contentType: "image/jpeg", contentLength: 3, revision: revision)
  }

  private func temporaryCache(byteLimit: Int = 1_024 * 1_024) -> IOSArtworkDiskCache {
    IOSArtworkDiskCache(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(
        "AureliaIOSArtworkCacheTests-\(UUID().uuidString)", isDirectory: true),
      byteLimit: byteLimit)
  }
}
