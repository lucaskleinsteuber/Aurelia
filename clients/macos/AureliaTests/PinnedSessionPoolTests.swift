import Foundation
import Testing

@testable import Aurelia

struct PinnedSessionPoolTests {
  @Test
  func oneServerIdentityReusesOneSessionAndOthersStaySeparate() {
    let pool = PinnedSessionPool()
    let first = pool.lease(
      host: "127.0.0.1", port: 43111, fingerprint: String(repeating: "a", count: 64))
    let again = pool.lease(
      host: "127.0.0.1", port: 43111, fingerprint: String(repeating: "A", count: 64))
    #expect(first.session === again.session)
    let otherKey = pool.lease(
      host: "127.0.0.1", port: 43111, fingerprint: String(repeating: "b", count: 64))
    let otherPort = pool.lease(
      host: "127.0.0.1", port: 43112, fingerprint: String(repeating: "a", count: 64))
    #expect(otherKey.session !== first.session)
    #expect(otherPort.session !== first.session)
    #expect(pool.count == 3)
    pool.removeAll()
    #expect(pool.count == 0)
  }

  @Test
  func thePoolStaysBoundedAndKeepsTheMostRecentlyUsedSessions() {
    let pool = PinnedSessionPool()
    let kept = pool.lease(host: "kept.local", port: 1, fingerprint: "aa")
    for index in 0..<(PinnedSessionPool.capacity + 3) {
      _ = pool.lease(host: "host\(index).local", port: 1, fingerprint: "aa")
      _ = pool.lease(host: "kept.local", port: 1, fingerprint: "aa")
    }
    #expect(pool.count == PinnedSessionPool.capacity)
    #expect(pool.lease(host: "kept.local", port: 1, fingerprint: "aa").session === kept.session)
    pool.removeAll()
  }
}
