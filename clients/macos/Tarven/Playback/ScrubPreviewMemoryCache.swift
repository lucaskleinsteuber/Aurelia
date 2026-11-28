import Foundation

/// Compressed stills only. Reading a displayed frame updates recency; checking
/// whether work is already cached does not prevent old frames from being evicted.
struct ScrubPreviewMemoryCache {
  private struct Entry {
    let data: Data
    var used: UInt64
  }
  let frameLimit: Int
  let byteLimit: Int
  private var entries: [Int64: Entry] = [:]
  private var sequence: UInt64 = 0
  private(set) var byteCount = 0
  var count: Int { entries.count }

  init(frameLimit: Int, byteLimit: Int) {
    self.frameLimit = max(0, frameLimit)
    self.byteLimit = max(0, byteLimit)
  }

  func contains(_ bucket: Int64) -> Bool { entries[bucket] != nil }

  mutating func data(for bucket: Int64) -> Data? {
    guard var entry = entries[bucket] else { return nil }
    sequence &+= 1
    entry.used = sequence
    entries[bucket] = entry
    return entry.data
  }

  @discardableResult
  mutating func insert(_ data: Data, for bucket: Int64) -> Bool {
    guard frameLimit > 0, !data.isEmpty, data.count <= byteLimit else { return false }
    if let previous = entries.removeValue(forKey: bucket) { byteCount -= previous.data.count }
    sequence &+= 1
    entries[bucket] = Entry(data: data, used: sequence)
    byteCount += data.count
    while entries.count > frameLimit || byteCount > byteLimit {
      guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key,
        let removed = entries.removeValue(forKey: oldest)
      else { break }
      byteCount -= removed.data.count
    }
    return entries[bucket] != nil
  }

  mutating func removeAll() {
    entries.removeAll()
    byteCount = 0
    sequence = 0
  }
}
