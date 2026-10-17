import CryptoKit
import Foundation

/// Persistent artwork bytes, scoped to one server and watching profile.
///
/// The key includes the artwork revision, so a changed image is a different entry and a
/// stored entry never needs to be checked with the server again. Only artwork with a
/// revision is stored. Media streams never enter this cache.
struct ArtworkDiskCache: Sendable {
  let directory: URL
  let byteLimit: Int

  /// The app's cache in the user's Caches folder; unavailable in test processes.
  static let standard: ArtworkDiskCache? = {
    let environment = ProcessInfo.processInfo.environment
    guard environment["XCTestConfigurationFilePath"] == nil,
      environment["AURELIA_RUNNING_TESTS"] != "1",
      environment["AURELIA_UI_TEST_MODE"] == nil,
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    return ArtworkDiskCache(
      directory: caches.appendingPathComponent("Aurelia/Artwork", isDirectory: true),
      byteLimit: 512 * 1_024 * 1_024)
  }()

  static func key(serverID: UUID, profileID: UUID?, path: String, revision: Int64) -> String {
    "\(serverID.uuidString):\(profileID?.uuidString ?? "device"):\(path):r\(revision)"
  }

  func data(forKey key: String) -> Data? {
    let url = fileURL(forKey: key)
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
    // Keep recently shown artwork during pruning without writing on every hit.
    let modified =
      (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    if let modified, modified < Date().addingTimeInterval(-3_600) {
      try? FileManager.default.setAttributes(
        [.modificationDate: Date()], ofItemAtPath: url.path)
    }
    return data
  }

  func store(_ data: Data, forKey key: String) {
    guard !data.isEmpty, data.count <= 24 * 1_024 * 1_024 else { return }
    let manager = FileManager.default
    do {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: fileURL(forKey: key), options: [.atomic])
    } catch {
      return
    }
    if Int.random(in: 0..<64) == 0 { prune() }
  }

  /// Removes the least recently used entries until the cache is below 80 % of its limit.
  func prune() {
    let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: Array(keys))
    else { return }
    var entries: [(url: URL, size: Int, modified: Date)] = []
    for file in files {
      guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true
      else { continue }
      entries.append(
        (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
    }
    var total = entries.reduce(0) { $0 + $1.size }
    guard total > byteLimit else { return }
    for entry in entries.sorted(by: { $0.modified < $1.modified }) {
      guard total > byteLimit * 8 / 10 else { break }
      if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
    }
  }

  private func fileURL(forKey key: String) -> URL {
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(digest + ".artwork", isDirectory: false)
  }
}
