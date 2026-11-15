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

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      Self.sameHost(challenge.protectionSpace.host, allowedHost),
      let trust = challenge.protectionSpace.serverTrust,
      let fingerprint = try? ServerPublicKeyFingerprint.calculate(from: trust)
    else {
      lock.withLock { rejectedTrust = true }
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }

    let accepted: Bool
    switch mode {
    case .inspect:
      lock.withLock {
        storedFingerprint = fingerprint
      }
      accepted = true
    case .pinned(let expected):
      accepted = fingerprint.caseInsensitiveCompare(expected) == .orderedSame
    }
    if !accepted { lock.withLock { rejectedTrust = true } }

    completionHandler(
      accepted ? .useCredential : .cancelAuthenticationChallenge,
      accepted ? URLCredential(trust: trust) : nil)
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
