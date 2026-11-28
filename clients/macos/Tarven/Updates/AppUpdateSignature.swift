import CryptoKit
import Foundation

/// Checks the minisign signature (https://jedisct1.github.io/minisign/) of a Mac release's
/// SHA256SUMS with the owner's public key built into the app, the same key that signs the Linux
/// releases. GitHub alone, or a stolen GitHub token, cannot produce it, so a replaced disk image
/// with a matching checksum list is never installed (audit C-M1).
///
/// Mac releases are signed in minisign's legacy format ("Ed", the list itself is signed), as
/// CryptoKit offers Ed25519 but not the BLAKE2b hash of the newer format.
enum AppUpdateSignature {
  static let publicKey = "RWT0nYptHNjXQSXnVurY9XXdPF2Ssq5sUlSP+WoBwjA5GPXWnugBc7lE"

  /// The exact trusted comment `scripts/publish-release.sh` signs into each Mac release.
  static func expectedTrustedComment(version: String, build: Int) -> String {
    "Tarven for Mac \(version) (\(build))"
  }

  /// Returns the cryptographically verified trusted comment when `signatureFile` is a valid
  /// signature of `message` by `publicKey`, or `nil` if verification fails.
  static func verifiedTrustedComment(
    _ message: Data, signatureFile: String, publicKey: String = publicKey
  ) -> String? {
    guard let (keyID, key) = readPublicKey(publicKey) else { return nil }
    let lines = signatureFile.replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let trustedPrefix = "trusted comment: "
    guard lines.count >= 4, lines[0].hasPrefix("untrusted comment:"),
      lines[2].hasPrefix(trustedPrefix),
      let block = Data(base64Encoded: lines[1].trimmingCharacters(in: .whitespaces)),
      block.count == 2 + 8 + 64,
      let global = Data(base64Encoded: lines[3].trimmingCharacters(in: .whitespaces)),
      global.count == 64
    else { return nil }
    let bytes = [UInt8](block)
    guard bytes[0] == UInt8(ascii: "E"), bytes[1] == UInt8(ascii: "d"),
      Data(bytes[2..<10]) == keyID
    else { return nil }
    let signature = Data(bytes[10..<74])
    guard key.isValidSignature(signature, for: message) else { return nil }
    // The trusted comment is signed too, so its text cannot be swapped.
    let commentText = String(lines[2].dropFirst(trustedPrefix.count))
    let comment = Data(commentText.utf8)
    guard key.isValidSignature(global, for: signature + comment) else { return nil }
    return commentText
  }

  /// True when `signatureFile` is a valid signature of `message` by `publicKey` (and, when
  /// provided, carries the exact expected trusted comment).
  static func verify(
    _ message: Data, signatureFile: String, publicKey: String = publicKey,
    expectedComment: String? = nil
  ) -> Bool {
    guard
      let comment = verifiedTrustedComment(
        message, signatureFile: signatureFile, publicKey: publicKey)
    else { return false }
    return expectedComment == nil || comment == expectedComment
  }

  /// A minisign public key: "Ed", an eight-byte key id and the 32-byte Ed25519 key.
  static func readPublicKey(_ text: String) -> (keyID: Data, key: Curve25519.Signing.PublicKey)? {
    guard
      let line = text.split(whereSeparator: \.isNewline).map({
        $0.trimmingCharacters(in: .whitespaces)
      })
      .last(where: { !$0.isEmpty && !$0.hasPrefix("untrusted comment:") }),
      let data = Data(base64Encoded: line), data.count == 2 + 8 + 32
    else { return nil }
    let bytes = [UInt8](data)
    guard bytes[0] == UInt8(ascii: "E"), bytes[1] == UInt8(ascii: "d"),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(bytes[10..<42]))
    else { return nil }
    return (Data(bytes[2..<10]), key)
  }
}
