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
  @Test func lettersAreReportedWhileTypingAndLengthAfterConfirmation() {
    #expect(ProfilePIN.problem("") == nil)
    #expect(ProfilePIN.problem("12") == nil)
    for value in ["12a", "abcd", "12 34", "１２３４"] {
      #expect(ProfilePIN.problem(value)?.contains("only contain numbers") == true)
    }
    #expect(ProfilePIN.problem("123456789")?.contains("at most 8") == true)
    #expect(ProfilePIN.problem("12", confirmation: "12")?.contains("at least 4") == true)
    #expect(ProfilePIN.problem("1234", confirmation: "1235") == "The PINs don't match.")
    #expect(ProfilePIN.problem("1234", confirmation: "1234") == nil)
  }

  @Test func olderStoredDeviceCredentialRemainsDecodableWithoutViewingState() throws {
    let data = Data(
      #"{"serverId":"00000000-0000-0000-0000-000000000001","name":"Synthetic","baseURL":"https://fixture.invalid","publicKeyFingerprint":"AAAA","token":"synthetic-only","sessionId":"00000000-0000-0000-0000-000000000002","expiresAt":"2099-01-01T00:00:00Z"}"#
        .utf8)
    let credential = try JSONDecoder().decode(StoredServerProfile.self, from: data)
    #expect(!credential.isViewingSession)
    #expect(credential.token == "synthetic-only")
  }

  @Test func optionalPINIsAllowedOnlyForNormalProfiles() {
    #expect(
      ProfilePIN.canSave(role: .user, protectionEnabled: false, newPIN: "", hasExistingPIN: false))
    for role in [UserRole.owner, .admin] {
      #expect(
        !ProfilePIN.canSave(role: role, protectionEnabled: false, newPIN: "", hasExistingPIN: true))
      #expect(
        !ProfilePIN.canSave(role: role, protectionEnabled: true, newPIN: "", hasExistingPIN: false))
      #expect(
        ProfilePIN.canSave(
          role: role, protectionEnabled: true, newPIN: "1234", hasExistingPIN: false))
    }
    #expect(
      ProfilePIN.canSave(role: .user, protectionEnabled: true, newPIN: "", hasExistingPIN: true))
    #expect(
      !ProfilePIN.canSave(role: .user, protectionEnabled: true, newPIN: "12", hasExistingPIN: true))
    #expect(
      !ProfilePIN.canSave(
        role: .user, protectionEnabled: false, newPIN: "1234", hasExistingPIN: true))
  }

  @Test func olderProfileResponsesRemainProtected() throws {
    let profile = try JSONDecoder().decode(
      WatchingProfile.self,
      from: Data(
        #"{"id":"00000000-0000-0000-0000-000000000001","name":"Viewer","role":"user","needsPinSetup":false}"#
          .utf8))
    #expect(profile.pinProtectionEnabled)
    let user = try JSONDecoder().decode(
      UserSummary.self,
      from: Data(
        #"{"id":"00000000-0000-0000-0000-000000000001","username":"Viewer","role":"user","createdAt":"2026-01-01T00:00:00Z"}"#
          .utf8))
    #expect(user.pinProtectionEnabled)
    #expect(user.profileRevision == 0)
    #expect(!user.needsPinSetup)
  }

  @Test func optionalProtectionAndRevisionRoundTripWithoutAccountPassword() throws {
    let user = UserSummary(
      id: UUID(), username: "Viewer", role: .user, createdAt: "2026-01-01T00:00:00Z",
      accessMode: .selectedTitles, pinProtectionEnabled: false, profileRevision: 7)
    let encoded = try JSONEncoder().encode(user)
    #expect(try JSONDecoder().decode(UserSummary.self, from: encoded) == user)
    let request = ProfileCreateRequest(
      username: "Viewer", role: .user, isEnabled: true, pinProtectionEnabled: false, pin: nil,
      accessMode: .selectedTitles, titleIds: [])
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(object["password"] == nil)
    #expect(object["pin"] == nil)
    #expect(object["pinProtectionEnabled"] as? Bool == false)
  }

  @Test func unchangedAccessIsOmittedToPreserveStorageGrants() throws {
    let request = ProfileUpdateRequest(
      revision: 3, role: .user, isEnabled: true, pinProtectionEnabled: true, pin: nil,
      accessMode: nil, titleIds: nil)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(object["accessMode"] == nil)
    #expect(object["titleIds"] == nil)
    #expect(object["pin"] == nil)
    #expect(object["revision"] as? Int == 3)
  }
}
