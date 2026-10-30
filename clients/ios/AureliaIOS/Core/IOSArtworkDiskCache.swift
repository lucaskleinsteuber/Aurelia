import Foundation

public final class IOSArtworkDiskCache: @unchecked Sendable {
  public static let shared = IOSArtworkDiskCache()

  private let memory = NSCache<NSString, NSData>()
  private let lock = NSLock()
  private let cacheDirectory: URL

  public init(capacityBytes: Int = 100 * 1024 * 1024) {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    self.cacheDirectory = caches.appendingPathComponent("AureliaArtwork", isDirectory: true)
    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    memory.totalCostLimit = capacityBytes / 2
  }

  public func data(for key: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }

    let nsKey = key as NSString
    if let inMem = memory.object(forKey: nsKey) {
      return inMem as Data
    }

    let fileURL = cacheDirectory.appendingPathComponent(sanitized(key))
    if let data = try? Data(contentsOf: fileURL) {
      memory.setObject(data as NSData, forKey: nsKey, cost: data.count)
      return data
    }
    return nil
  }

  public func store(_ data: Data, for key: String) {
    lock.lock()
    defer { lock.unlock() }

    let nsKey = key as NSString
    memory.setObject(data as NSData, forKey: nsKey, cost: data.count)

    let fileURL = cacheDirectory.appendingPathComponent(sanitized(key))
    try? data.write(to: fileURL, options: .atomic)
  }

  public func clear() {
    lock.lock()
    defer { lock.unlock() }
    memory.removeAllObjects()
    try? FileManager.default.removeItem(at: cacheDirectory)
    try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
  }

  private func sanitized(_ key: String) -> String {
    key.replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
  }
}
