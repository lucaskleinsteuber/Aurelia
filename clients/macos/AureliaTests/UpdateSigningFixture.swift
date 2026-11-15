import CryptoKit
import Foundation

/// Minisign keys and signatures for the update tests. None of them is the owner's key.
enum UpdateSigningFixture {
  /// Made with `minisign -G` for these tests only, with a real legacy signature (`minisign -S -l`)
  /// of `realSignedSums`, so the app is checked against what the minisign tool writes.
  static let minisignPublicKey = "RWQ6PSL5QXlBp8BCr2TGH3Ao4mvKPzcjLyV0KAZs0bxRnedjn+6wYp3s"
  static let realSignedSums =
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  Aurelia-1.13.0-100-macOS-arm64.dmg\n"
  static let minisignSignature = """
    untrusted comment: signature from minisign secret key
    RWQ6PSL5QXlBp6/sLR6Ym4lJ88j4WvT1mOP8Qr8jaH0JT1Ap/YPPhGLgk1kIlxCTs/xy4mo321Zh7ASSd9kQHu8FT5RsW5tRQww=
    trusted comment: Aurelia for Mac 1.13.0 (100)
    C3MXK6s+zGh1jo4Pzlc0dErRxgM/N7ANisMWJeXfqjqlZ5JhKgXQb198VddFFlLmqku3eqAUIwhq56Fe6zwxBg==

    """

  /// A key the tests sign with themselves, written in the same format.
  private static let privateKey = try! Curve25519.Signing.PrivateKey(
    rawRepresentation: Data(repeating: 0x2A, count: 32))
  private static let keyID = Data("AURTEST1".utf8)

  static var publicKey: String {
    (Data("Ed".utf8) + keyID + privateKey.publicKey.rawRepresentation).base64EncodedString()
  }

  static func signature(for message: Data, comment: String = "Aurelia for Mac test") -> Data {
    let signature = try! privateKey.signature(for: message)
    let global = try! privateKey.signature(for: signature + Data(comment.utf8))
    let block = (Data("Ed".utf8) + keyID + signature).base64EncodedString()
    return Data(
      "untrusted comment: test signature\n\(block)\ntrusted comment: \(comment)\n\(global.base64EncodedString())\n"
        .utf8)
  }
}
