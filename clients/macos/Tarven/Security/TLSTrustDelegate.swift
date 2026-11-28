@preconcurrency import Foundation
import Security

final class TLSTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
  @unchecked Sendable
{
  enum Mode: Sendable {
    case inspect
    case pinned(String)
  }

  private let mode: Mode
  private let allowedHost: String
  private let lock = NSLock()
  private var storedFingerprint: String?
  private var rejectedTrust = false

  init(mode: Mode, allowedHost: String) {
    self.mode = mode
    self.allowedHost = allowedHost
  }

  var capturedFingerprint: String? {
    lock.withLock { storedFingerprint }
  }

  var didRejectTrust: Bool { lock.withLock { rejectedTrust } }

  /// Compares host names the way an address may be written: an IPv6 address with or without its
  /// brackets and with its zone as "%en0" or "%25en0" is the same host (audit C-X19).
  nonisolated static func sameHost(_ first: String, _ second: String) -> Bool {
    func normalized(_ host: String) -> String {
      var value = host
      if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
      return value.replacingOccurrences(of: "%25", with: "%").lowercased()
    }
    let left = normalized(first)
    return !left.isEmpty && left == normalized(second)
  }

  /// Shared pinning evaluation for API, stream relay, and speech audio delegates so all three
  /// normalize IPv6 hosts identically (audit C-X19, MAC-NET-003).
  nonisolated static func evaluatePinnedServerTrust(
    _ challenge: URLAuthenticationChallenge,
    allowedHost: String,
    expectedFingerprint: String
  ) -> URLCredential? {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      sameHost(challenge.protectionSpace.host, allowedHost),
      let trust = challenge.protectionSpace.serverTrust,
      let fingerprint = try? ServerPublicKeyFingerprint.calculate(from: trust),
      fingerprint.caseInsensitiveCompare(expectedFingerprint) == .orderedSame
    else { return nil }
    return URLCredential(trust: trust)
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    switch mode {
    case .pinned(let expected):
      if let credential = Self.evaluatePinnedServerTrust(
        challenge, allowedHost: allowedHost, expectedFingerprint: expected)
      {
        completionHandler(.useCredential, credential)
      } else {
        lock.withLock { rejectedTrust = true }
        completionHandler(.cancelAuthenticationChallenge, nil)
      }
    case .inspect:
      guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
        Self.sameHost(challenge.protectionSpace.host, allowedHost),
        let trust = challenge.protectionSpace.serverTrust,
        let fingerprint = try? ServerPublicKeyFingerprint.calculate(from: trust)
      else {
        lock.withLock { rejectedTrust = true }
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      lock.withLock { storedFingerprint = fingerprint }
      completionHandler(.useCredential, URLCredential(trust: trust))
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
