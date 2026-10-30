import CryptoKit
import Foundation
import Security

public enum IOSError: LocalizedError, Sendable, Equatable {
  case invalidAddress
  case identityMismatch
  case unauthorized
  case offline
  case pairingRejected
  case pairingExpired
  case profilePinRequired
  case networkError(String)

  public var errorDescription: String? {
    switch self {
    case .invalidAddress: return "The server address is invalid."
    case .identityMismatch: return "The server's TLS certificate does not match the paired server."
    case .unauthorized: return "Authorization failed or expired. Please sign in again."
    case .offline: return "The media server could not be reached. Check that it is turned on."
    case .pairingRejected: return "The pairing request was rejected by an administrator."
    case .pairingExpired: return "The pairing code has expired. Please try again."
    case .profilePinRequired: return "A 4-digit PIN is required to switch to this profile."
    case .networkError(let msg): return msg
    }
  }
}

public struct IOSStoredConnection: Codable, Sendable, Equatable {
  public let serverId: UUID
  public let serverName: String
  public let baseURL: URL
  public let fingerprint: String
  public var sessionToken: String?
  public var profileToken: String?
  public var activeProfileId: String?

  public init(
    serverId: UUID,
    serverName: String,
    baseURL: URL,
    fingerprint: String,
    sessionToken: String? = nil,
    profileToken: String? = nil,
    activeProfileId: String? = nil
  ) {
    self.serverId = serverId
    self.serverName = serverName
    self.baseURL = baseURL
    self.fingerprint = fingerprint
    self.sessionToken = sessionToken
    self.profileToken = profileToken
    self.activeProfileId = activeProfileId
  }

  public func validate() throws {
    guard IOSServerAddress.isValid(baseURL) else { throw IOSError.invalidAddress }
    guard IOSServerIdentity.isValidFingerprint(fingerprint) else { throw IOSError.identityMismatch }
  }
}

public enum IOSServerAddress {
  public static func normalize(_ input: String) throws -> URL {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard var components = URLComponents(string: value) else { throw IOSError.invalidAddress }
    if components.scheme?.lowercased() == "https" { components.scheme = "https" }
    components.port = components.port ?? 43111
    if components.path == "/" { components.path = "" }
    guard let url = components.url, isValid(url) else { throw IOSError.invalidAddress }
    return url
  }

  public static func isValid(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil, components.query == nil,
      components.fragment == nil, components.path.isEmpty || components.path == "/",
      (1...65_535).contains(components.port ?? 443)
    else { return false }
    return true
  }

  public static func trustHost(_ host: String) -> String {
    host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .replacingOccurrences(of: "%25", with: "%").lowercased()
  }
}

public enum IOSServerIdentity {
  private static let p256SPKIPrefix = Data([
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
  ])

  public static func isValidFingerprint(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      }
  }

  public static func fingerprint(rawP256Key: Data) throws -> String {
    guard rawP256Key.count == 65, rawP256Key.first == 4 else { throw IOSError.identityMismatch }
    return SHA256.hash(data: p256SPKIPrefix + rawP256Key).map { String(format: "%02X", $0) }
      .joined()
  }

  public static func fingerprint(trust: SecTrust) throws -> String {
    guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let certificate = certificates.first, let key = SecCertificateCopyKey(certificate),
      let attributes = SecKeyCopyAttributes(key) as? [String: Any],
      attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
      attributes[kSecAttrKeySizeInBits as String] as? Int == 256,
      let bytes = SecKeyCopyExternalRepresentation(key, nil) as Data?
    else { throw IOSError.identityMismatch }
    return try fingerprint(rawP256Key: bytes)
  }
}
