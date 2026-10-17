import Foundation

/// One URLSession per pinned server identity, so requests share open HTTP/2 connections.
///
/// A new TLS connection to an Aurelia server costs about 50 ms; a reused one about 1 ms.
/// Every new connection is still verified against the pinned public key by the session's
/// trust delegate. Sessions carry no cookies or cache; credentials travel per request.
final class PinnedSessionPool: @unchecked Sendable {
  static let shared = PinnedSessionPool()
  static let capacity = 6

  private struct Entry {
    let session: URLSession
    let delegate: TLSTrustDelegate
    var lastUse: UInt64
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var useCounter: UInt64 = 0

  var count: Int { lock.withLock { entries.count } }

  func lease(host: String, port: Int?, fingerprint: String) -> (
    session: URLSession, delegate: TLSTrustDelegate
  ) {
    let key = "\(host.lowercased()):\(port ?? 0):\(fingerprint.lowercased())"
    var retired: [URLSession] = []
    defer { for session in retired { session.finishTasksAndInvalidate() } }
    return lock.withLock {
      useCounter += 1
      // A session whose trust check failed is never reused; the next lease starts fresh.
      if var entry = entries[key], !entry.delegate.didRejectTrust {
        entry.lastUse = useCounter
        entries[key] = entry
        return (entry.session, entry.delegate)
      }
      if let rejected = entries.removeValue(forKey: key) { retired.append(rejected.session) }
      let delegate = TLSTrustDelegate(mode: .pinned(fingerprint), allowedHost: host)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      entries[key] = Entry(session: session, delegate: delegate, lastUse: useCounter)
      while entries.count > Self.capacity,
        let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
      {
        if let entry = entries.removeValue(forKey: oldest) { retired.append(entry.session) }
      }
      return (session, delegate)
    }
  }

  /// Closes every pooled connection, for example after the server identity changed.
  func removeAll() {
    let sessions = lock.withLock {
      let sessions = entries.values.map(\.session)
      entries.removeAll()
      return sessions
    }
    for session in sessions { session.finishTasksAndInvalidate() }
  }
}
