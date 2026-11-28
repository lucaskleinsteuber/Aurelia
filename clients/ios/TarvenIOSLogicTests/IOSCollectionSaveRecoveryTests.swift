import Foundation
import Testing

@Suite("iOS collection save recovery")
@MainActor
struct IOSCollectionSaveRecoveryTests {
  private let fingerprint = String(repeating: "a", count: 64)

  @Test func retryAfterArtworkFailureUpdatesTheCreatedCollection() async throws {
    let collection = IOSCollection(id: UUID(), name: "Invented Collection", poster: nil, items: [])
    let transport = IOSCollectionRecoveryTransport(responses: [
      try response(collection),
      IOSHTTPResponse(statusCode: 503, headers: [:], body: Data(), fingerprint: fingerprint),
      try response(collection),
    ])
    let client = api(transport)
    let recovery = IOSCollectionSaveRecovery()
    let payload = IOSSaveCollection(name: collection.name)
    let saved = try await recovery.saveDetails(existingID: nil, payload: payload, api: client)
    await #expect(throws: (any Error).self) {
      try await client.saveCollectionArtwork(
        collectionID: saved.id, kind: "poster", IOSSaveCollectionArtwork(uploadId: UUID()))
    }
    let retried = try await recovery.saveDetails(existingID: nil, payload: payload, api: client)
    #expect(retried.id == collection.id)
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["POST", "POST", "PUT"])
    #expect(requests[0].url?.path == "/api/v1/collections")
    #expect(requests[2].url?.path == "/api/v1/collections/\(collection.id.uuidString.lowercased())")
  }

  @Test func failedCreationDoesNotInventAnIdentityAndExistingCollectionsAlwaysUpdate() async throws
  {
    let collection = IOSCollection(id: UUID(), name: "Existing Collection", poster: nil, items: [])
    let transport = IOSCollectionRecoveryTransport(responses: [
      IOSHTTPResponse(statusCode: 503, headers: [:], body: Data(), fingerprint: fingerprint),
      try response(collection),
    ])
    let client = api(transport)
    let recovery = IOSCollectionSaveRecovery()
    let payload = IOSSaveCollection(name: collection.name)
    await #expect(throws: (any Error).self) {
      try await recovery.saveDetails(existingID: nil, payload: payload, api: client)
    }
    #expect(recovery.savedCollection == nil)
    let saved = try await recovery.saveDetails(
      existingID: collection.id, payload: payload, api: client)
    #expect(saved.id == collection.id)
    #expect(await transport.requests.last?.httpMethod == "PUT")
  }

  private func response(_ collection: IOSCollection) throws -> IOSHTTPResponse {
    IOSHTTPResponse(
      statusCode: 200, headers: [:], body: try JSONEncoder().encode(collection),
      fingerprint: fingerprint)
  }

  private func api(_ transport: IOSCollectionRecoveryTransport) -> IOSAPIClient {
    IOSAPIClient(
      connection: IOSStoredConnection(
        serverID: UUID(), name: "Invented Server", baseURL: URL(string: "https://127.0.0.1:43991")!,
        fingerprint: fingerprint, deviceToken: String(repeating: "D", count: 43),
        deviceSessionID: UUID()),
      session: IOSProfileSession(
        user: IOSUser(id: UUID(), username: "Alex", role: "owner"), sessionId: UUID(),
        token: String(repeating: "P", count: 43), expiresAt: "2099-01-01T00:00:00Z"),
      transport: transport)
  }
}

private actor IOSCollectionRecoveryTransport: IOSHTTPTransport {
  private var responses: [IOSHTTPResponse]
  private(set) var requests: [URLRequest] = []

  init(responses: [IOSHTTPResponse]) { self.responses = responses }

  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw IOSCoreError.invalidResponse }
    return responses.removeFirst()
  }
}
