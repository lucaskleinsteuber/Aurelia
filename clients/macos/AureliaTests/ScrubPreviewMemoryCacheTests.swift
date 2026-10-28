import Foundation
import Testing

@testable import Aurelia

struct ScrubPreviewMemoryCacheTests {
  @Test func evictionUsesDisplayRecencyAndBothFrameAndByteLimits() {
    var cache = ScrubPreviewMemoryCache(frameLimit: 3, byteLimit: 8)
    cache.insert(Data(repeating: 1, count: 3), for: 0)
    cache.insert(Data(repeating: 2, count: 3), for: 10)
    let recentlyShown = cache.data(for: 0)
    #expect(recentlyShown == Data(repeating: 1, count: 3))
    cache.insert(Data(repeating: 3, count: 3), for: 20)
    #expect(cache.contains(0))
    #expect(!cache.contains(10))
    #expect(cache.contains(20))
    #expect(cache.count == 2 && cache.byteCount == 6)
    cache.insert(Data(repeating: 4, count: 2), for: 30)
    #expect(cache.count == 3 && cache.byteCount == 8)
    cache.insert(Data([5]), for: 40)
    #expect(cache.count == 3 && cache.byteCount == 6)
    #expect(!cache.contains(0))
  }

  @Test func replacementOversizedDataAndClearingKeepExactByteAccounting() {
    var cache = ScrubPreviewMemoryCache(frameLimit: 2, byteLimit: 8)
    let first = cache.insert(Data(repeating: 1, count: 4), for: 0)
    #expect(first)
    let replacement = cache.insert(Data(repeating: 2, count: 2), for: 0)
    #expect(replacement)
    #expect(cache.count == 1 && cache.byteCount == 2)
    let oversized = cache.insert(Data(repeating: 3, count: 9), for: 10)
    #expect(!oversized)
    let empty = cache.insert(Data(), for: 10)
    #expect(!empty)
    #expect(cache.count == 1 && cache.byteCount == 2)
    cache.removeAll()
    #expect(cache.count == 0 && cache.byteCount == 0)
    let cleared = cache.data(for: 0)
    #expect(cleared == nil)
    var disabled = ScrubPreviewMemoryCache(frameLimit: 0, byteLimit: 8)
    let disabledInsertion = disabled.insert(Data([1]), for: 0)
    #expect(!disabledInsertion)
  }
}
