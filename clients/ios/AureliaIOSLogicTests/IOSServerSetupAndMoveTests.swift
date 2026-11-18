import Foundation
import Testing

/// Setting up a server from iPhone and iPad, moving one, and Storage Location Moved. A fake server
/// and invented names only.
@Suite struct IOSServerSetupAndMoveTests {
  private let fingerprint = String(repeating: "C", count: 64)

  @Test func theSetupFormAsksWhatTheBrowserAsks() {
    #expect(IOSServerMoveText.setupCode("abcde fghjk") == "ABCDE-FGHJK")
    #expect(IOSServerMoveText.setupCode("ABCDE-FGHJ") == nil)
    func problem(
      _ code: String = "ABCDE-FGHJK", password: String = "a long invented pass",
      again: String? = nil, pin: String = "2468"
    ) -> String? {
      IOSServerMoveText.setupProblem(
        code: code, ownerName: "Invented Owner", password: password, repeat: again ?? password,
        pin: pin)
    }
    #expect(problem() == nil)
    #expect(problem("ABC")?.contains("setup code") == true)
    #expect(problem(password: "short")?.contains("12 characters") == true)
    #expect(problem(again: "something else") == "The passwords don’t match.")
    #expect(problem(pin: "12")?.contains("4 to 8 digits") == true)
  }

  @Test func setupSendsTheCodeAndKeepsTheSignIn() async throws {
    let token = String(repeating: "S", count: 43)
    let transport = SetupTransport(responses: [
      raw(
        #"{"user":{"id":"76000000-0000-0000-0000-000000000001","username":"Invented Owner","role":"owner"},"sessionId":"76000000-0000-0000-0000-000000000002","token":"\#(token)","expiresAt":"2099-01-01T00:00:00Z"}"#
      )
    ])
    let auth = try await api(transport).setupOwner(
      code: "ABCDE-FGHJK", ownerName: "Invented Owner", password: "a long invented pass",
      deviceName: "Invented iPhone")
    #expect(auth.token == token)
    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/api/v1/setup/code")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = try JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())
    #expect(body["code"] == "ABCDE-FGHJK" && body["ownerName"] == "Invented Owner")
  }

  @Test func theNewServersMoveCarriesTheSetupCodeNotASignIn() async throws {
    let transport = SetupTransport(responses: [
      raw(
        #"{"state":"received","progress":null,"error":null,"source":{"serverId":"76000000-0000-0000-0000-000000000003","name":"Old Server"},"locations":[{"id":"76000000-0000-0000-0000-000000000004","name":"Films","oldPath":"/old/Films","sampled":4,"suggestions":[{"path":"/new/Films","matched":4}]}]}"#
      )
    ])
    let status = try await api(transport).setupMoveNetwork(
      address: "192.0.2.10", code: "MOVE-1234", setupCode: "ABCDE-FGHJK")
    #expect(status.state == "received")
    #expect(status.locations.first?.suggestions.first?.matched == 4)
    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/api/v1/setup/move/network")
    #expect(request.value(forHTTPHeaderField: "X-Aurelia-Setup-Code") == "ABCDE-FGHJK")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test func aFolderWithoutTheFilesNeedsUseAnyway() {
    #expect(!IOSRelocateDecision(preview: nil).canConfirm)
    let found = IOSRelocateDecision(preview: IOSMoveLocationMatch(sampled: 415, matched: 412))
    #expect(found.canConfirm && !found.force)
    #expect(found.text == "412 of 415 sample files found")
    let empty = IOSRelocateDecision(preview: IOSMoveLocationMatch(sampled: 3, matched: 0))
    #expect(!empty.canConfirm && empty.needsSecondConfirmation)
    #expect(empty.text == "None of 3 sample files found. This may be the wrong folder.")
    let anyway = IOSRelocateDecision(
      preview: IOSMoveLocationMatch(sampled: 3, matched: 0), confirmedEmpty: true)
    #expect(anyway.canConfirm && anyway.force)
    #expect(IOSRelocateDecision.matchText(1, of: 1) == "All 1 sample file found")
  }

  @Test func relocatingGoesToTheLocationAndExplainsRefusals() async throws {
    let library = UUID(uuidString: "76000000-0000-0000-0000-0000000000aa")!
    let transport = SetupTransport(responses: [problem(409, "relocate_no_matches")])
    await #expect {
      _ = try await api(transport).relocate(library: library, path: "/new/Films", force: false)
    } throws: { error in
      IOSServerMoveText.message(error).contains("Use Anyway")
    }
    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/api/v1/libraries/\(library.uuidString.lowercased())/relocate")
    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    #expect(body?["force"] as? Bool == false && body?["path"] as? String == "/new/Films")
  }

  // MARK: Helpers

  private func api(_ transport: SetupTransport) -> IOSAPIClient {
    let connection = IOSStoredConnection(
      serverID: UUID(), name: "Synthetic server",
      baseURL: URL(string: "https://fixture.invalid:43111")!, fingerprint: fingerprint,
      deviceToken: String(repeating: "D", count: 43), deviceSessionID: UUID())
    let session = IOSProfileSession(
      user: IOSUser(id: UUID(), username: "Owner", role: "owner"),
      sessionId: UUID(), token: String(repeating: "P", count: 43),
      expiresAt: "2099-01-01T00:00:00Z")
    return IOSAPIClient(connection: connection, session: session, transport: transport)
  }
  private func raw(_ text: String) -> IOSHTTPResponse {
    IOSHTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8),
      fingerprint: fingerprint)
  }
  private func problem(_ status: Int, _ code: String) -> IOSHTTPResponse {
    IOSHTTPResponse(
      statusCode: status, headers: ["Content-Type": "application/json"],
      body: Data(#"{"code":"\#(code)","message":"Synthetic refusal."}"#.utf8),
      fingerprint: fingerprint)
  }
}

private actor SetupTransport: IOSHTTPTransport {
  private var responses: [IOSHTTPResponse]
  private(set) var requests: [URLRequest] = []
  init(responses: [IOSHTTPResponse]) { self.responses = responses }
  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw IOSCoreError.invalidResponse }
    return responses.removeFirst()
  }
}
