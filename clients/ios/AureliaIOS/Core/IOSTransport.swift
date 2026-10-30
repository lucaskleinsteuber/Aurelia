import Foundation
import Security

public enum IOSTrustMode: Sendable, Equatable {
  case inspect
  case pinned(String)
}

public struct IOSHTTPResponse: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data
  public let fingerprint: String?

  public init(statusCode: Int, headers: [String: String], body: Data, fingerprint: String? = nil) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
    self.fingerprint = fingerprint
  }

  public func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

public protocol IOSHTTPTransport: Sendable {
  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse
}

final class IOSTLSTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
  let mode: IOSTrustMode
  let allowedHost: String
  private let lock = NSLock()
  private var _seenFingerprint: String?
  private var _didRejectTrust = false

  var seenFingerprint: String? {
    lock.lock()
    defer { lock.unlock() }
    return _seenFingerprint
  }

  var didRejectTrust: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _didRejectTrust
  }

  init(mode: IOSTrustMode, allowedHost: String) {
    self.mode = mode
    self.allowedHost = allowedHost
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust,
      let host = challenge.protectionSpace.host as String?,
      IOSServerAddress.trustHost(host) == IOSServerAddress.trustHost(allowedHost)
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }

    do {
      let fingerprint = try IOSServerIdentity.fingerprint(trust: trust)
      lock.lock()
      _seenFingerprint = fingerprint
      lock.unlock()

      switch mode {
      case .inspect:
        completionHandler(.useCredential, URLCredential(trust: trust))
      case .pinned(let expected):
        if fingerprint.caseInsensitiveCompare(expected) == .orderedSame {
          completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
          lock.lock()
          _didRejectTrust = true
          lock.unlock()
          completionHandler(.cancelAuthenticationChallenge, nil)
        }
      }
    } catch {
      lock.lock()
      _didRejectTrust = true
      lock.unlock()
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }
}

public struct IOSURLSessionTransport: IOSHTTPTransport {
  public init() {}

  public func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    guard let url = request.url, url.scheme == "https", let host = url.host else {
      throw IOSError.invalidAddress
    }

    let delegate = IOSTLSTrustDelegate(mode: trust, allowedHost: host)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 30
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
      try Task.checkCancellation()
    } catch {
      if delegate.didRejectTrust {
        throw IOSError.identityMismatch
      }
      throw IOSError.networkError(error.localizedDescription)
    }

    guard let http = response as? HTTPURLResponse else {
      throw IOSError.networkError("Invalid response")
    }

    let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
      if let name = item.key as? String, let value = item.value as? String {
        result[name] = value
      }
    }

    return IOSHTTPResponse(
      statusCode: http.statusCode,
      headers: headers,
      body: data,
      fingerprint: delegate.seenFingerprint
    )
  }
}
