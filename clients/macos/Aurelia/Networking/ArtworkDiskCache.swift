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
  private let writeTracker = WriteTracker()

  private final class WriteTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var bytesSincePrune = 0
    private var writesSincePrune = 0

    func shouldPrune(addedBytes: Int, byteThreshold: Int, writeThreshold: Int) -> Bool {
      lock.withLock {
        bytesSincePrune += addedBytes
        writesSincePrune += 1
        if bytesSincePrune >= byteThreshold || writesSincePrune >= writeThreshold {
          bytesSincePrune = 0
          writesSincePrune = 0
          return true
        }
        return false
      }
    }
  }

  init(directory: URL, byteLimit: Int) {
    self.directory = directory
    self.byteLimit = byteLimit
  }

  /// The app's cache in the user's Caches folder; unavailable in test processes.
  static let standard: ArtworkDiskCache? = {
    let environment = ProcessInfo.processInfo.environment
    guard environment["XCTestConfigurationFilePath"] == nil,
      environment["AURELIA_RUNNING_TESTS"] != "1",
      environment["AURELIA_UI_TEST_MODE"] == nil,
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    let cache = ArtworkDiskCache(
      directory: caches.appendingPathComponent("Aurelia/Artwork", isDirectory: true),
      byteLimit: 512 * 1_024 * 1_024)
    Task.detached(priority: .utility) { cache.prune() }
    return cache
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
    // Prune deterministically after 32 MiB written or 32 writes so large responses cannot
    // temporarily overshoot the 512 MiB cap by many times the limit.
    if writeTracker.shouldPrune(
      addedBytes: data.count, byteThreshold: 32 * 1_024 * 1_024, writeThreshold: 32)
    {
      prune()
    }
  }

  /// Removes a single cached artwork entry (for example when stored bytes fail to decode).
  func remove(forKey key: String) {
    try? FileManager.default.removeItem(at: fileURL(forKey: key))
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

  /// Removes every cached artwork file on disk (for example when disconnecting from a server).
  func removeAll() {
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    for file in files where file.pathExtension == "artwork" {
      try? FileManager.default.removeItem(at: file)
    }
  }

  private func fileURL(forKey key: String) -> URL {
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(digest + ".artwork", isDirectory: false)
  }
}
