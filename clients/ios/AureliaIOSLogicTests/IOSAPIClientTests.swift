import Foundation
import Testing

final class MockIOSTransport: IOSHTTPTransport, @unchecked Sendable {
  var handler: ((URLRequest, IOSTrustMode) throws -> IOSHTTPResponse)?

  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    if let handler {
      return try handler(request, trust)
    }
    return IOSHTTPResponse(statusCode: 404, headers: [:], body: Data())
  }
}

@Suite("iOS API Client Tests")
struct IOSAPIClientTests {
  @Test func serverInfoInspection() async throws {
    let mock = MockIOSTransport()
    let expectedFingerprint = String(repeating: "F", count: 64)
    let infoJSON = """
      {
        "serverId": "11111111-2222-3333-4444-555555555555",
        "name": "Aurelia Test Server",
        "version": "1.23.0",
        "isSetup": true,
        "lanAccessEnabled": true,
        "publicKeyFingerprint": "\(expectedFingerprint)",
        "displayFingerprint": "FFFF-FFFF-FFFF",
        "capabilities": ["collections-v2", "remote-playback-v1"]
      }
      """.data(using: .utf8)!

    mock.handler = { request, trust in
      #expect(request.url?.path == "/api/v1/server/info")
      #expect(trust == .inspect)
      return IOSHTTPResponse(
        statusCode: 200, headers: [:], body: infoJSON, fingerprint: expectedFingerprint)
    }

    let client = IOSAPIClient(transport: mock)
    let (info, fp) = try await client.getServerInfo(at: URL(string: "https://server.local:43111")!)

    #expect(info.name == "Aurelia Test Server")
    #expect(info.version == "1.23.0")
    #expect(info.capabilities.contains("collections-v2"))
    #expect(fp == expectedFingerprint)
  }

  @Test func homeCatalogDecoding() async throws {
    let mock = MockIOSTransport()
    let catalogJSON = """
      {
        "continueWatching": [
          {
            "id": "item-1",
            "type": "movie",
            "title": "Inception",
            "watched": false,
            "positionSeconds": 1200
          }
        ],
        "upNext": [],
        "recentlyAdded": [],
        "movies": [],
        "shows": []
      }
      """.data(using: .utf8)!

    mock.handler = { request, trust in
      #expect(request.url?.path == "/api/v1/catalog/home")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-profile-token")
      return IOSHTTPResponse(statusCode: 200, headers: [:], body: catalogJSON)
    }

    let client = IOSAPIClient(
      baseURL: URL(string: "https://server.local:43111")!,
      fingerprint: String(repeating: "F", count: 64),
      profileToken: "test-profile-token",
      transport: mock
    )

    let home = try await client.getHomeCatalog()
    #expect(home.continueWatching.count == 1)
    #expect(home.continueWatching.first?.title == "Inception")
    #expect(home.continueWatching.first?.positionSeconds == 1200)
  }

  @Test func remotePlaybackCommandDispatch() async throws {
    let mock = MockIOSTransport()
    var dispatchedBody: Data?

    mock.handler = { request, trust in
      #expect(request.url?.path == "/api/v1/devices/players/target-tv/commands")
      #expect(request.httpMethod == "POST")
      dispatchedBody = request.httpBody
      return IOSHTTPResponse(statusCode: 200, headers: [:], body: Data())
    }

    let client = IOSAPIClient(
      baseURL: URL(string: "https://server.local:43111")!,
      fingerprint: String(repeating: "F", count: 64),
      profileToken: "token",
      transport: mock
    )

    let cmd = IOSRemotePlaybackCommand(
      action: "play", titleId: "movie-99", title: "Interstellar", positionSeconds: 300)
    try await client.sendRemotePlaybackCommand(targetDeviceId: "target-tv", command: cmd)

    #expect(dispatchedBody != nil)
    let decoded = try JSONDecoder().decode(IOSRemotePlaybackCommand.self, from: dispatchedBody!)
    #expect(decoded.action == "play")
    #expect(decoded.titleId == "movie-99")
    #expect(decoded.positionSeconds == 300)
  }
}
