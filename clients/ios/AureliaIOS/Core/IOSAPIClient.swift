import Foundation

public struct IOSAPIClient: Sendable {
  public enum Authentication: Sendable {
    case none
    case session
    case profile
  }

  public let baseURL: URL?
  public let fingerprint: String?
  public let sessionToken: String?
  public let profileToken: String?
  public let transport: any IOSHTTPTransport

  public init(
    baseURL: URL? = nil,
    fingerprint: String? = nil,
    sessionToken: String? = nil,
    profileToken: String? = nil,
    transport: any IOSHTTPTransport = IOSURLSessionTransport()
  ) {
    self.baseURL = baseURL
    self.fingerprint = fingerprint
    self.sessionToken = sessionToken
    self.profileToken = profileToken
    self.transport = transport
  }

  public func configured(
    baseURL: URL, fingerprint: String, sessionToken: String? = nil, profileToken: String? = nil
  ) -> IOSAPIClient {
    IOSAPIClient(
      baseURL: baseURL,
      fingerprint: fingerprint,
      sessionToken: sessionToken,
      profileToken: profileToken,
      transport: self.transport
    )
  }

  public func withTokens(sessionToken: String?, profileToken: String?) -> IOSAPIClient {
    IOSAPIClient(
      baseURL: self.baseURL,
      fingerprint: self.fingerprint,
      sessionToken: sessionToken,
      profileToken: profileToken,
      transport: self.transport
    )
  }

  // MARK: - Server Info & Discovery

  public func getServerInfo(at url: URL) async throws -> (IOSServerInfo, String?) {
    guard let infoUrl = URL(string: "/api/v1/server/info", relativeTo: url) else {
      throw IOSError.invalidAddress
    }
    var request = URLRequest(url: infoUrl)
    request.httpMethod = "GET"
    let response = try await transport.execute(request, trust: .inspect)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Server returned \(response.statusCode)")
    }
    let info = try JSONDecoder().decode(IOSServerInfo.self, from: response.body)
    return (info, response.fingerprint)
  }

  // MARK: - Pairing

  public func startPairing(clientName: String = "Aurelia iPhone") async throws
    -> IOSPairingStartResponse
  {
    let body = try JSONEncoder().encode(["clientName": clientName, "clientType": "ios"])
    let response = try await send(
      path: "/api/v1/pairing/start", method: "POST", body: body, auth: .none)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Pairing start failed (\(response.statusCode))")
    }
    return try JSONDecoder().decode(IOSPairingStartResponse.self, from: response.body)
  }

  public func pollPairing(pairingId: String) async throws -> IOSPairingPollResponse {
    let path = "/api/v1/pairing/\(pairingId)/poll"
    let response = try await send(path: path, method: "GET", auth: .none)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Pairing poll failed (\(response.statusCode))")
    }
    return try JSONDecoder().decode(IOSPairingPollResponse.self, from: response.body)
  }

  // MARK: - Profiles

  public func getProfiles() async throws -> [IOSUserProfile] {
    let response = try await send(path: "/api/v1/profiles", method: "GET", auth: .session)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Failed to fetch profiles (\(response.statusCode))")
    }
    return try JSONDecoder().decode([IOSUserProfile].self, from: response.body)
  }

  public func switchProfile(profileId: String, pin: String? = nil) async throws
    -> IOSSwitchProfileResponse
  {
    var payload: [String: String] = ["profileId": profileId]
    if let pin { payload["pin"] = pin }
    let body = try JSONEncoder().encode(payload)
    let response = try await send(
      path: "/api/v1/profiles/switch", method: "POST", body: body, auth: .session)
    if response.statusCode == 403 {
      throw IOSError.profilePinRequired
    }
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Profile switch failed (\(response.statusCode))")
    }
    return try JSONDecoder().decode(IOSSwitchProfileResponse.self, from: response.body)
  }

  // MARK: - Catalog

  public func getHomeCatalog() async throws -> IOSCatalogIndexResponse {
    let response = try await send(path: "/api/v1/catalog/home", method: "GET", auth: .profile)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Failed to fetch home catalog (\(response.statusCode))")
    }
    return try JSONDecoder().decode(IOSCatalogIndexResponse.self, from: response.body)
  }

  public func getMovies(sort: IOSSortOrder = .recentlyAdded, filter: IOSFilterWatched = .all)
    async throws -> [IOSCatalogItemSummary]
  {
    let path = "/api/v1/catalog/movies?sort=\(sort.rawValue)&filter=\(filter.rawValue)"
    let response = try await send(path: path, method: "GET", auth: .profile)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Failed to fetch movies (\(response.statusCode))")
    }
    return try JSONDecoder().decode([IOSCatalogItemSummary].self, from: response.body)
  }

  public func getShows(sort: IOSSortOrder = .recentlyAdded, filter: IOSFilterWatched = .all)
    async throws -> [IOSCatalogItemSummary]
  {
    let path = "/api/v1/catalog/shows?sort=\(sort.rawValue)&filter=\(filter.rawValue)"
    let response = try await send(path: path, method: "GET", auth: .profile)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Failed to fetch shows (\(response.statusCode))")
    }
    return try JSONDecoder().decode([IOSCatalogItemSummary].self, from: response.body)
  }

  public func getCatalogDetail(itemId: String) async throws -> IOSCatalogDetailResponse {
    let path = "/api/v1/catalog/items/\(itemId)"
    let response = try await send(path: path, method: "GET", auth: .profile)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Failed to fetch item detail (\(response.statusCode))")
    }
    return try JSONDecoder().decode(IOSCatalogDetailResponse.self, from: response.body)
  }

  public func search(query: String) async throws -> [IOSCatalogItemSummary] {
    guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
      return []
    }
    let path = "/api/v1/catalog/search?q=\(encoded)"
    let response = try await send(path: path, method: "GET", auth: .profile)
    guard response.statusCode == 200 else { return [] }
    return (try? JSONDecoder().decode([IOSCatalogItemSummary].self, from: response.body)) ?? []
  }

  // MARK: - Collections & Franchises

  public func getCollections() async throws -> [IOSCollectionSummary] {
    let response = try await send(path: "/api/v1/collections", method: "GET", auth: .profile)
    guard response.statusCode == 200 else { return [] }
    return (try? JSONDecoder().decode([IOSCollectionSummary].self, from: response.body)) ?? []
  }

  public func getCollectionDetail(collectionId: String) async throws -> IOSCollectionDetailResponse
  {
    let path = "/api/v1/collections/\(collectionId)"
    let response = try await send(path: path, method: "GET", auth: .profile)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Failed to fetch collection detail (\(response.statusCode))")
    }
    return try JSONDecoder().decode(IOSCollectionDetailResponse.self, from: response.body)
  }

  public func getFranchises() async throws -> [IOSFranchiseSummary] {
    let response = try await send(path: "/api/v1/franchises", method: "GET", auth: .profile)
    guard response.statusCode == 200 else { return [] }
    return (try? JSONDecoder().decode([IOSFranchiseSummary].self, from: response.body)) ?? []
  }

  public func getFranchiseDetail(franchiseId: String) async throws -> IOSFranchiseDetailResponse {
    let path = "/api/v1/franchises/\(franchiseId)"
    let response = try await send(path: path, method: "GET", auth: .profile)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Failed to fetch franchise detail (\(response.statusCode))")
    }
    return try JSONDecoder().decode(IOSFranchiseDetailResponse.self, from: response.body)
  }

  // MARK: - Playback Plan & Progress

  public func getPlaybackPlan(itemId: String) async throws -> IOSStreamPlanResponse {
    let path = "/api/v1/streams/plan/\(itemId)"
    let response = try await send(path: path, method: "POST", auth: .profile)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Failed to obtain playback plan (\(response.statusCode))")
    }
    return try JSONDecoder().decode(IOSStreamPlanResponse.self, from: response.body)
  }

  public func updatePlaybackProgress(
    itemId: String, positionSeconds: Double, durationSeconds: Double, watched: Bool
  ) async throws {
    let req = IOSProgressUpdateRequest(
      positionSeconds: positionSeconds, durationSeconds: durationSeconds, watched: watched)
    let body = try JSONEncoder().encode(req)
    _ = try await send(
      path: "/api/v1/catalog/items/\(itemId)/progress", method: "POST", body: body, auth: .profile)
  }

  // MARK: - History & Statistics

  public func getWatchHistory(page: Int = 1, pageSize: Int = 50) async throws
    -> IOSWatchHistoryResponse
  {
    let path = "/api/v1/history?page=\(page)&pageSize=\(pageSize)"
    let response = try await send(path: path, method: "GET", auth: .profile)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Failed to fetch history (\(response.statusCode))")
    }
    return try JSONDecoder().decode(IOSWatchHistoryResponse.self, from: response.body)
  }

  public func getPersonalStatistics() async throws -> IOSPersonalStatisticsResponse {
    let response = try await send(path: "/api/v1/statistics", method: "GET", auth: .profile)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Failed to fetch statistics (\(response.statusCode))")
    }
    return try JSONDecoder().decode(IOSPersonalStatisticsResponse.self, from: response.body)
  }

  // MARK: - Remote Playback

  public func getActivePlayers() async throws -> [IOSRemotePlayerDevice] {
    let response = try await send(path: "/api/v1/devices/players", method: "GET", auth: .profile)
    guard response.statusCode == 200 else { return [] }
    return (try? JSONDecoder().decode([IOSRemotePlayerDevice].self, from: response.body)) ?? []
  }

  public func sendRemotePlaybackCommand(targetDeviceId: String, command: IOSRemotePlaybackCommand)
    async throws
  {
    let body = try JSONEncoder().encode(command)
    let path = "/api/v1/devices/players/\(targetDeviceId)/commands"
    let response = try await send(path: path, method: "POST", body: body, auth: .profile)
    guard response.statusCode == 200 else {
      throw IOSError.networkError("Remote command failed (\(response.statusCode))")
    }
  }

  // MARK: - Internal HTTP Sender

  private func send(path: String, method: String, body: Data? = nil, auth: Authentication)
    async throws -> IOSHTTPResponse
  {
    guard let base = baseURL, let fp = fingerprint else {
      throw IOSError.offline
    }
    guard let url = URL(string: path, relativeTo: base) else {
      throw IOSError.invalidAddress
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
    }

    switch auth {
    case .none:
      break
    case .session:
      if let sessionToken {
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
      }
    case .profile:
      if let profileToken {
        request.setValue("Bearer \(profileToken)", forHTTPHeaderField: "Authorization")
      } else if let sessionToken {
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
      }
    }

    let response = try await transport.execute(request, trust: .pinned(fp))
    if response.statusCode == 401 {
      throw IOSError.unauthorized
    }
    return response
  }
}
