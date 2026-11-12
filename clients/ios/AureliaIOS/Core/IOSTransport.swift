import Foundation

struct IOSHTTPResponse: Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data
  let fingerprint: String?

  func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

protocol IOSHTTPTransport: Sendable {
  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse
}

struct IOSURLSessionTransport: IOSHTTPTransport {
  var pool: IOSPinnedSessionPool = .shared

  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    guard let url = request.url, url.scheme == "https", let host = url.host else {
      throw IOSCoreError.invalidAddress
    }
    // Inspection captures an unknown identity once, so it keeps a private session.
    // Pinned requests reuse one session per server identity: TLS handshakes and
    // connection setup happen once instead of for every catalog or artwork request.
    let lease: IOSPinnedSessionPool.Lease
    let ownsSession: Bool
    switch trust {
    case .inspect:
      let delegate = IOSTLSTrustDelegate(mode: trust, allowedHost: host)
      lease = .init(
        session: URLSession(
          configuration: IOSPinnedSessionPool.configuration(), delegate: delegate,
          delegateQueue: nil), delegate: delegate)
      ownsSession = true
    case .pinned(let fingerprint):
      lease = pool.lease(host: host, fingerprint: fingerprint, lane: IOSConnectionLane(path: url.path))
      ownsSession = false
    }
    defer { if ownsSession { lease.session.invalidateAndCancel() } }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await lease.session.data(for: request)
      try Task.checkCancellation()
    } catch {
      if lease.delegate.didRejectTrust {
        if case .pinned(let fingerprint) = trust {
          pool.discard(host: host, fingerprint: fingerprint)
          pool.discard(host: host, fingerprint: fingerprint, lane: .artwork)
        }
        throw IOSCoreError.identityMismatch
      }
      throw error
    }
    guard let http = response as? HTTPURLResponse else { throw IOSCoreError.invalidResponse }
    let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
      if let name = item.key as? String, let value = item.value as? String { result[name] = value }
    }
    return IOSHTTPResponse(
      statusCode: http.statusCode, headers: headers, body: data,
      fingerprint: lease.delegate.capturedFingerprint)
  }
}

/// Which connections a request uses. Pictures have their own, so the many posters a screen
/// loads at once never keep a title's details or its Play button waiting behind them.
enum IOSConnectionLane: String, Sendable {
  case api
  case artwork

  init(path: String) {
    self = path.hasPrefix("/api/v1/artwork/") ? .artwork : .api
  }
}

/// Long-lived sessions for already trusted servers. Every new TLS connection is
/// still checked against the pinned fingerprint by its delegate; a rejected
/// identity discards the session so nothing is reused after a mismatch.
final class IOSPinnedSessionPool: @unchecked Sendable {
  struct Lease {
    let session: URLSession
    let delegate: IOSTLSTrustDelegate
  }
  static let shared = IOSPinnedSessionPool()
  /// Two lanes for each of up to four servers.
  static let capacity = 8
  private let lock = NSLock()
  private var leases: [String: Lease] = [:]
  private var order: [String] = []

  static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 40
    configuration.httpMaximumConnectionsPerHost = 6
    return configuration
  }

  func lease(host: String, fingerprint: String, lane: IOSConnectionLane = .api) -> Lease {
    let key = Self.key(host: host, fingerprint: fingerprint, lane: lane)
    return lock.withLock {
      if let existing = leases[key] { return existing }
      let delegate = IOSTLSTrustDelegate(mode: .pinned(fingerprint), allowedHost: host)
      let lease = Lease(
        session: URLSession(
          configuration: Self.configuration(), delegate: delegate, delegateQueue: nil),
        delegate: delegate)
      leases[key] = lease
      order.append(key)
      while order.count > Self.capacity {
        leases.removeValue(forKey: order.removeFirst())?.session.finishTasksAndInvalidate()
      }
      return lease
    }
  }

  func discard(host: String, fingerprint: String, lane: IOSConnectionLane = .api) {
    let key = Self.key(host: host, fingerprint: fingerprint, lane: lane)
    lock.withLock {
      order.removeAll { $0 == key }
      leases.removeValue(forKey: key)?.session.invalidateAndCancel()
    }
  }

  var count: Int { lock.withLock { leases.count } }

  private static func key(host: String, fingerprint: String, lane: IOSConnectionLane) -> String {
    "\(IOSServerAddress.trustHost(host))|\(fingerprint.uppercased())|\(lane.rawValue)"
  }
}
