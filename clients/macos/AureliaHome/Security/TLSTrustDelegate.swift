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

  init(mode: Mode, allowedHost: String) {
    self.mode = mode
    self.allowedHost = allowedHost
  }

  var capturedFingerprint: String? {
    lock.withLock { storedFingerprint }
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      challenge.protectionSpace.host.caseInsensitiveCompare(allowedHost) == .orderedSame,
      let trust = challenge.protectionSpace.serverTrust,
      let fingerprint = try? ServerPublicKeyFingerprint.calculate(from: trust)
    else {
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
