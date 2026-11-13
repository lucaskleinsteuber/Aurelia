import CryptoKit
import Foundation
import Testing

@Suite("iOS security and Face ID")
struct IOSSecurityTests {
  private let fingerprint = String(repeating: "C", count: 64)

  @Test func registeringSignsAFreshChallengeAndSendsThePublicKey() async throws {
    let signer = IOSSoftwarePasskeySigner()
    let passkey = """
      {"id":"75000000-0000-0000-0000-000000000001","userId":"75000000-0000-0000-0000-000000000002",
      "userName":"Owner","name":"Synthetic iPhone","createdAt":"2026-11-13T10:00:00Z","lastUsedAt":null,"isThisDevice":true}
      """
    let transport = IOSSecurityTestTransport(responses: [
      raw(#"{"challenge":"synthetic-challenge-1","expiresAt":"2099-01-01T00:00:00Z"}"#), raw(passkey),
    ])
    let saved = try await api(transport).registerPasskey(name: "Synthetic iPhone", signer: signer)
    #expect(saved.isThisDevice)
    let requests = await transport.requests
    #expect(requests.map(\.url?.path) == ["/api/v1/management/passkey-challenge", "/api/v1/management/passkeys"])
    let body = try JSONDecoder().decode([String: String].self, from: requests[1].httpBody ?? Data())
    let publicKey = try P256.Signing.PublicKey(x963Representation: try #require(Data(base64Encoded: body["publicKey"] ?? "")))
    let signature = try P256.Signing.ECDSASignature(derRepresentation: try #require(Data(base64Encoded: body["signature"] ?? "")))
    #expect(publicKey.isValidSignature(signature, for: IOSPasskeyMessage.data(purpose: "register", challenge: "synthetic-challenge-1")))
    #expect(!publicKey.isValidSignature(signature, for: IOSPasskeyMessage.data(purpose: "unlock", challenge: "synthetic-challenge-1")))
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Aurelia-Installation") != nil })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Aurelia-Client")?.hasPrefix("ios/") == true })
  }

  @Test func unlockingAndConfirmingSignForTheirOwnPurpose() async throws {
    let signer = IOSSoftwarePasskeySigner()
    let passkeyId = UUID()
    let requestId = UUID(uuidString: "75000000-0000-0000-0000-0000000000ab")!
    let transport = IOSSecurityTestTransport(responses: [
      raw(#"{"challenge":"unlock-challenge","expiresAt":"2099-01-01T00:00:00Z"}"#),
      raw(#"{"expiresAt":"2099-01-01T00:10:00Z"}"#),
      raw(#"{"challenge":"remote-challenge","expiresAt":"2099-01-01T00:00:00Z"}"#),
      IOSHTTPResponse(statusCode: 204, headers: [:], body: Data(), fingerprint: fingerprint),
    ])
    let client = api(transport)
    let expiry = try await client.unlockManagement(passkeyId: passkeyId, signer: signer)
    #expect(expiry == IOSServerDate.parse("2099-01-01T00:10:00Z"))
    try await client.decideRemoteUnlock(id: requestId, approve: true, passkeyId: passkeyId, signer: signer)
    let requests = await transport.requests
    #expect(requests[1].url?.path == "/api/v1/management/passkey-unlock")
    #expect(requests[3].url?.path == "/api/v1/management/remote-unlock/\(requestId.uuidString.lowercased())/decide")
    let unlock = try JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data()) as? [String: Any]
    let remote = try JSONSerialization.jsonObject(with: requests[3].httpBody ?? Data()) as? [String: Any]
    let key = signer.key.publicKey
    func valid(_ body: [String: Any]?, purpose: String, challenge: String) throws -> Bool {
      let signature = try P256.Signing.ECDSASignature(
        derRepresentation: try #require(Data(base64Encoded: body?["signature"] as? String ?? "")))
      return key.isValidSignature(signature, for: IOSPasskeyMessage.data(purpose: purpose, challenge: challenge))
    }
    #expect(try valid(unlock, purpose: "unlock", challenge: "unlock-challenge"))
    #expect(try valid(remote, purpose: "remote:750000000000000000000000000000ab", challenge: "remote-challenge"))
    #expect(remote?["approve"] as? Bool == true)
  }

  @Test func denyingNeedsNoKeyAndApprovingDoes() async throws {
    let transport = IOSSecurityTestTransport(responses: [
      IOSHTTPResponse(statusCode: 204, headers: [:], body: Data(), fingerprint: fingerprint)
    ])
    try await api(transport).decideRemoteUnlock(id: UUID(), approve: false, passkeyId: nil, signer: nil)
    #expect(await transport.requests.count == 1)
    await #expect(throws: IOSCoreError.invalidRequest) {
      try await api(transport).decideRemoteUnlock(id: UUID(), approve: true, passkeyId: nil, signer: nil)
    }
  }

  @Test func alertsAndTheLogReadTheServer() throws {
    let alerts = try JSONDecoder().decode(
      IOSSecurityAlerts.self,
      from: Data(
        """
        {"version":7,"newDevices":[{"id":"75000000-0000-0000-0000-000000000010","userId":"75000000-0000-0000-0000-000000000011",
        "userName":"Owner","deviceName":"Unknown Tablet","platform":"Browser · Safari on iPad","clientVersion":null,
        "ipAddress":"192.0.2.40","createdAt":"2026-11-13T10:00:00Z","lastSeenAt":"2026-11-13T10:00:00Z","isNew":true,
        "canBlock":true,"isCurrent":false}],
        "unlockRequests":[{"id":"75000000-0000-0000-0000-000000000012","profileName":"Owner","deviceName":"Linux Laptop",
        "ipAddress":null,"code":"0427","expiresAt":"2099-01-01T00:00:00Z"}],"later":true}
        """.utf8))
    #expect(alerts.version == 7)
    #expect(alerts.newDevices.first?.isNew == true)
    #expect(alerts.unlockRequests.first?.code == "0427")
    #expect(IOSSecurityText.deviceLine(platform: "Browser · Safari on iPad", ipAddress: "192.0.2.40") == "Browser · Safari on iPad · 192.0.2.40")
    #expect(IOSSecurityText.kind("wrong_pin") == "Wrong profile PIN")
    #expect(IOSSecurityText.kind("something_new") == "Something New")
    #expect(IOSPasskeyMessage.remotePurpose(UUID(uuidString: "75000000-0000-0000-0000-0000000000AB")!)
      == "remote:750000000000000000000000000000ab")
  }

  @Test func theInstallationIdentifierStaysTheSame() throws {
    let defaults = try #require(UserDefaults(suiteName: "aurelia.ios.installation.\(UUID().uuidString)"))
    let first = IOSInstallation.identifier(defaults: defaults)
    #expect(UUID(uuidString: first) != nil)
    #expect(IOSInstallation.identifier(defaults: defaults) == first)
  }

  private func api(_ transport: IOSSecurityTestTransport) -> IOSAPIClient {
    let connection = IOSStoredConnection(
      serverID: UUID(), name: "Synthetic server", baseURL: URL(string: "https://fixture.invalid:43111")!,
      fingerprint: fingerprint, deviceToken: String(repeating: "D", count: 43), deviceSessionID: UUID())
    let session = IOSProfileSession(
      user: IOSUser(id: UUID(), username: "Owner", role: "owner"), sessionId: UUID(),
      token: String(repeating: "P", count: 43), expiresAt: "2099-01-01T00:00:00Z")
    return IOSAPIClient(connection: connection, session: session, transport: transport)
  }

  private func raw(_ text: String) -> IOSHTTPResponse {
    IOSHTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8), fingerprint: fingerprint)
  }
}

private actor IOSSecurityTestTransport: IOSHTTPTransport {
  private var responses: [IOSHTTPResponse]
  private(set) var requests: [URLRequest] = []
  init(responses: [IOSHTTPResponse]) { self.responses = responses }
  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw IOSCoreError.invalidResponse }
    return responses.removeFirst()
  }
}
