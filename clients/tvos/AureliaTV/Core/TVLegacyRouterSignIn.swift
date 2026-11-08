import Foundation
import Security

/// Earlier versions could keep a FRITZ!Box sign-in in the Keychain to wake the server through the
/// router. That feature is gone; this removes such a sign-in so no router password stays behind.
enum TVLegacyRouterSignIn {
  static let service = "com.lucas.aurelia.tvos.router-wake"

  static func erase() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
