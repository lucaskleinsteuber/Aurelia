import Foundation
import Testing

@testable import Aurelia

struct ProfilePINTests {
  @Test func onlyFourToEightAsciiDigitsAreAccepted() {
    for value in ["0000", "1234", "12345678"] { #expect(ProfilePIN.isValid(value)) }
    for value in ["", "123", "123456789", "12 34", "abcd", "١٢٣٤", "１２３４", "1234\n", " 1234"] {
      #expect(!ProfilePIN.isValid(value))
    }
  }
  @Test func olderStoredDeviceCredentialRemainsDecodableWithoutViewingState() throws {
    let data = Data(
      #"{"serverId":"00000000-0000-0000-0000-000000000001","name":"Synthetic","baseURL":"https://fixture.invalid","publicKeyFingerprint":"AAAA","token":"synthetic-only","sessionId":"00000000-0000-0000-0000-000000000002","expiresAt":"2099-01-01T00:00:00Z"}"#
        .utf8)
    let credential = try JSONDecoder().decode(StoredServerProfile.self, from: data)
    #expect(!credential.isViewingSession)
    #expect(credential.token == "synthetic-only")
  }
}
