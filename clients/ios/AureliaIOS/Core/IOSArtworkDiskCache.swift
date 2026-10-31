import CryptoKit
import Foundation

/// Persistent artwork bytes, scoped to one server and watching profile.
///
/// The key contains the artwork revision and width, so a changed image is a new entry and
/// stored artwork never needs another request after the app restarts. iOS may purge the
/// Caches folder at any time; the pipeline then simply downloads again. Streams never enter it.
struct IOSArtworkDiskCache: Sendable {
  let directory: URL
  let byteLimit: Int

  static let standard: IOSArtworkDiskCache? = {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
      !ProcessInfo.processInfo.arguments.contains("--aurelia-ui-testing"),
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    return IOSArtworkDiskCache(
      directory: caches.appendingPathComponent("Aurelia/Artwork", isDirectory: true),
      byteLimit: 256 * 1024 * 1024)
  }()

  static func key(serverID: UUID, profileID: UUID, artwork: IOSArtwork, width: Int) -> String? {
    guard let revision = artwork.revision else { return nil }
    return
      "\(serverID.uuidString):\(profileID.uuidString):\(artwork.id.uuidString):r\(revision):w\(width)"
  }

  func data(forKey key: String) -> Data? {
    let url = fileURL(forKey: key)
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
    let modified =
      (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    if let modified, modified < Date().addingTimeInterval(-3600) {
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
    return data
  }

  func store(_ data: Data, forKey key: String) {
    guard !data.isEmpty, data.count <= 24 * 1024 * 1024 else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: fileURL(forKey: key), options: [.atomic])
    } catch {
      return
    }
    if Int.random(in: 0..<64) == 0 { prune() }
  }

  func remove(forKey key: String) {
    try? FileManager.default.removeItem(at: fileURL(forKey: key))
  }

  /// The bytes the cache occupies on this device.
  func byteCount() -> Int {
    let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: Array(keys))
    else { return 0 }
    return files.reduce(0) { total, file in
      guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true
      else { return total }
      return total + (values.fileSize ?? 0)
    }
  }

  /// Deletes every stored image; they download again when they are next shown.
  func removeAll() {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    for file in files where file.pathExtension == "artwork" {
      try? FileManager.default.removeItem(at: file)
    }
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
      entries.append((file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
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
