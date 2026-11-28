import CryptoKit
import Foundation
import Security

enum FingerprintError: LocalizedError {
  case certificateMissing
  case publicKeyMissing
  case publicKeyExportFailed
  case unsupportedKey

  var errorDescription: String? {
    switch self {
    case .certificateMissing:
      "The server did not provide a certificate."
    case .publicKeyMissing:
      "The server certificate has no public key."
    case .publicKeyExportFailed:
      "The server public key could not be read."
    case .unsupportedKey:
      "The server uses an unsupported certificate key."
    }
  }
}

enum FingerprintFormatter {
  static func display(_ fingerprint: String) -> String {
    let normalized = fingerprint.uppercased()
    return stride(from: 0, to: min(normalized.count, 24), by: 4)
      .map { offset in
        let start = normalized.index(normalized.startIndex, offsetBy: offset)
        let end = normalized.index(
          start,
          offsetBy: min(4, normalized.distance(from: start, to: normalized.endIndex)))
        return String(normalized[start..<end])
      }
      .joined(separator: "-")
  }
}

enum ServerPublicKeyFingerprint {
  private static let p256SubjectPublicKeyInfoPrefix = Data([
    0x30, 0x59,
    0x30, 0x13,
    0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
    0x03, 0x42, 0x00,
  ])

  static func calculate(from trust: SecTrust) throws -> String {
    guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let certificate = certificates.first
    else {
      throw FingerprintError.certificateMissing
    }
    guard let key = SecCertificateCopyKey(certificate) else {
      throw FingerprintError.publicKeyMissing
    }
    guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
      attributes[kSecAttrKeyType as String] as? String
        == kSecAttrKeyTypeECSECPrimeRandom as String,
      attributes[kSecAttrKeySizeInBits as String] as? Int == 256
    else {
      throw FingerprintError.unsupportedKey
    }

    var error: Unmanaged<CFError>?
    guard let rawKey = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
      throw FingerprintError.publicKeyExportFailed
    }
    return calculateP256(rawPublicKey: rawKey)
  }

  static func calculateP256(rawPublicKey: Data) -> String {
    let digest = SHA256.hash(data: p256SubjectPublicKeyInfoPrefix + rawPublicKey)
    return digest.map { String(format: "%02X", $0) }.joined()
  }
}
