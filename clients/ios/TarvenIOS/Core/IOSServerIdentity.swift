import CryptoKit
import Foundation
import Security

enum IOSServerAddress {
  static func normalize(_ input: String) throws -> URL {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard var components = URLComponents(string: value) else { throw IOSCoreError.invalidAddress }
    if components.scheme?.lowercased() == "https" { components.scheme = "https" }
    components.port = components.port ?? 43111
    if components.path == "/" { components.path = "" }
    guard let url = components.url, isValid(url) else { throw IOSCoreError.invalidAddress }
    return url
  }

  static func isValid(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil, components.query == nil,
      components.fragment == nil, components.path.isEmpty || components.path == "/",
      (1...65_535).contains(components.port ?? 443)
    else { return false }
    return true
  }

  static func trustHost(_ host: String) -> String {
    host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .replacingOccurrences(of: "%25", with: "%").lowercased()
  }
}

enum IOSServerIdentity {
  private static let p256SPKIPrefix = Data([
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
  ])

  static func isValidFingerprint(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      }
  }

  static func fingerprint(rawP256Key: Data) throws -> String {
    guard rawP256Key.count == 65, rawP256Key.first == 4 else { throw IOSCoreError.identityMismatch }
    return SHA256.hash(data: p256SPKIPrefix + rawP256Key).map { String(format: "%02X", $0) }
      .joined()
  }

  static func fingerprint(trust: SecTrust) throws -> String {
    guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let certificate = certificates.first, let key = SecCertificateCopyKey(certificate),
      let attributes = SecKeyCopyAttributes(key) as? [String: Any],
      attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
      attributes[kSecAttrKeySizeInBits as String] as? Int == 256,
      let bytes = SecKeyCopyExternalRepresentation(key, nil) as Data?
    else { throw IOSCoreError.identityMismatch }
    return try fingerprint(rawP256Key: bytes)
  }

  static func display(_ fingerprint: String) -> String {
    let value = fingerprint.uppercased()
    return stride(from: 0, to: min(value.count, 24), by: 4).map { offset in
      let start = value.index(value.startIndex, offsetBy: offset)
      let end = value.index(
        start, offsetBy: min(4, value.distance(from: start, to: value.endIndex)))
      return String(value[start..<end])
    }.joined(separator: "-")
  }
}

enum IOSTrustMode: Equatable, Sendable {
  case inspect
  case pinned(String)
}

final class IOSTLSTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
  @unchecked Sendable
{
  typealias Mode = IOSTrustMode
  private let mode: Mode
  private let allowedHost: String
  private let lock = NSLock()
  private var captured: String?
  private var rejected = false

  init(mode: Mode, allowedHost: String) {
    self.mode = mode
    self.allowedHost = allowedHost
  }
  var capturedFingerprint: String? { lock.withLock { captured } }
  var didRejectTrust: Bool { lock.withLock { rejected } }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      IOSServerAddress.trustHost(challenge.protectionSpace.host)
        == IOSServerAddress.trustHost(allowedHost),
      let trust = challenge.protectionSpace.serverTrust,
      let fingerprint = try? IOSServerIdentity.fingerprint(trust: trust)
    else {
      lock.withLock { rejected = true }
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    let accepted: Bool
    switch mode {
    case .inspect: accepted = true
    case .pinned(let expected):
      accepted = fingerprint.caseInsensitiveCompare(expected) == .orderedSame
    }
    lock.withLock {
      captured = fingerprint
      if !accepted { rejected = true }
    }
    completionHandler(
      accepted ? .useCredential : .cancelAuthenticationChallenge,
      accepted ? URLCredential(trust: trust) : nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
