import Foundation

struct TVHTTPResponse: Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data
  let fingerprint: String?

  func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

protocol TVHTTPTransport: Sendable {
  func execute(_ request: URLRequest, trust: TVTrustMode) async throws -> TVHTTPResponse
}

struct TVURLSessionTransport: TVHTTPTransport {
  func execute(_ request: URLRequest, trust: TVTrustMode) async throws -> TVHTTPResponse {
    guard let url = request.url, url.scheme == "https", let host = url.host else {
      throw TVCoreError.invalidAddress
    }
    let delegate = TVTLSTrustDelegate(mode: trust, allowedHost: host)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 40
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
      try Task.checkCancellation()
    } catch {
      if delegate.didRejectTrust { throw TVCoreError.identityMismatch }
      throw error
    }
    guard let http = response as? HTTPURLResponse else { throw TVCoreError.invalidResponse }
    let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
      if let name = item.key as? String, let value = item.value as? String { result[name] = value }
    }
    return TVHTTPResponse(
      statusCode: http.statusCode, headers: headers, body: data,
      fingerprint: delegate.capturedFingerprint)
  }
}
