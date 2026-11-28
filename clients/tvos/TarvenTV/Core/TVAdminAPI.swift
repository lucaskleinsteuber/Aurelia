import Foundation

// Server administration requests, the same the Mac app and the browser send. Everything goes
// through `adminData`, which handles one-time approvals for protected changes.

extension TVAPIClient {
  private func admin<Value: Decodable>(
    _ path: String, method: String = "GET", query: [URLQueryItem] = [], longRunning: Bool = false
  ) async throws -> Value {
    try Self.decodeAdmin(
      Value.self,
      data: await adminData(path, method: method, query: query, longRunning: longRunning))
  }
  private func admin<Value: Decodable>(
    _ path: String, method: String, json payload: some Encodable, longRunning: Bool = false
  ) async throws -> Value {
    try Self.decodeAdmin(
      Value.self,
      data: await adminData(
        path, method: method, body: JSONEncoder().encode(payload), longRunning: longRunning))
  }
  private func adminSend(_ path: String, method: String, longRunning: Bool = false) async throws {
    _ = try await adminData(path, method: method, longRunning: longRunning)
  }
  private func adminSend(_ path: String, method: String, json payload: some Encodable)
    async throws
  {
    _ = try await adminData(path, method: method, body: JSONEncoder().encode(payload))
  }
  private static func id(_ value: UUID) -> String { value.uuidString.lowercased() }

  // MARK: Management unlock

  /// Unlocks server management for ten minutes; the password is sent once and never stored.
  func unlockManagement(password: String) async throws -> Date {
    guard TVServerPassword.isPlausible(password) else { throw TVCoreError.invalidRequest }
    struct Payload: Encodable { let password: String }
    struct Response: Decodable { let expiresAt: String }
    let response: Response = try await admin(
      "/api/v1/management/unlock", method: "POST", json: Payload(password: password))
    guard let date = TVServerDate.parse(response.expiresAt) else {
      throw TVCoreError.invalidResponse
    }
    return date
  }
  func lockManagement() async throws {
    try await adminSend("/api/v1/management/lock", method: "POST")
  }
  /// The signed-in profile as the server sees it now, with its role and access.
  func currentAdminUser() async throws -> TVAdminUser { try await admin("/api/v1/auth/me") }

  // MARK: Server

  func serverStatus() async throws -> TVServerStatus { try await admin("/api/v1/server/status") }
  func serverHealth() async throws -> TVServerHealth { try await admin("/api/v1/server/health") }
  func serverPerformance() async throws -> TVServerPerformance {
    try await admin("/api/v1/server/health/performance")
  }
  func resetServerPerformance() async throws {
    try await adminSend("/api/v1/server/health/performance", method: "DELETE")
  }
  func serverCapabilities() async throws -> TVServerCapabilities {
    try await admin("/api/v1/server/capabilities")
  }
  func restartServer() async throws -> TVHostOperation {
    try await admin("/api/v1/server/operations/restart", method: "POST")
  }
  func serverJobs() async throws -> TVServerJobs { try await admin("/api/v1/server/jobs") }
  func retryMetadataJob(id: UUID) async throws {
    try await adminSend("/api/v1/metadata/jobs/\(Self.id(id))/retry", method: "POST")
  }
  func serverTranscoding() async throws -> TVTranscodingStatus {
    try await admin("/api/v1/server/transcoding")
  }

  // MARK: Power and updates

  func serverPower() async throws -> TVServerPower { try await admin("/api/v1/server/power") }
  func saveServerPower(_ payload: TVPowerRules.Payload) async throws -> TVServerPower {
    try await admin("/api/v1/server/power", method: "PUT", json: payload)
  }
  func serverUpdates() async throws -> TVServerUpdateStatus {
    try await admin("/api/v1/server/updates")
  }
  func checkServerUpdates() async throws -> TVServerUpdateStatus {
    try await admin("/api/v1/server/updates/check", method: "POST")
  }
  func installServerUpdate() async throws -> TVServerUpdateStatus {
    try await admin("/api/v1/server/updates/install", method: "POST")
  }

  // MARK: Scrub previews, intros and credits, speech

  func serverScrubPreviews() async throws -> TVScrubPreviewSettings {
    try await admin("/api/v1/server/scrub-previews")
  }
  func saveServerScrubPreviews(_ settings: TVUpdateScrubPreviews) async throws
    -> TVScrubPreviewSettings
  {
    try await admin("/api/v1/server/scrub-previews", method: "PUT", json: settings)
  }
  func deleteServerScrubPreviews() async throws -> TVScrubPreviewSettings {
    try await admin("/api/v1/server/scrub-previews", method: "DELETE")
  }
  func serverSegments() async throws -> TVSegmentSettings {
    try await admin("/api/v1/server/media-segments")
  }
  func saveServerSegments(enabled: Bool, usePictures: Bool?) async throws -> TVSegmentSettings {
    struct Payload: Encodable {
      let enabled: Bool
      let usePictures: Bool?
    }
    return try await admin(
      "/api/v1/server/media-segments", method: "PUT",
      json: Payload(enabled: enabled, usePictures: usePictures))
  }
  func segmentSeries() async throws -> [TVSegmentSeries] {
    try await admin("/api/v1/server/media-segments/series")
  }
  /// Examines one series again, every movie (`movies`), or everything when both are nil.
  func reanalyzeSegments(seriesId: UUID? = nil, movies: Bool = false) async throws
    -> TVSegmentSettings
  {
    struct Payload: Encodable {
      let seriesId: String?
      let movies: Bool?
    }
    return try await admin(
      "/api/v1/server/media-segments/reanalyze", method: "POST",
      json: Payload(seriesId: seriesId.map(Self.id), movies: movies ? true : nil))
  }
  func serverSpeech() async throws -> TVServerSpeech { try await admin("/api/v1/server/speech") }
  func downloadSpeechModel(_ name: String) async throws -> TVServerSpeech {
    struct Payload: Encodable { let name: String }
    return try await admin("/api/v1/server/speech/model", method: "POST", json: Payload(name: name))
  }
  func removeSpeechModel() async throws -> TVServerSpeech {
    try await admin("/api/v1/server/speech/model", method: "DELETE")
  }

  // MARK: Profiles

  func serverUsers() async throws -> [TVUserAccessSummary] {
    try await admin("/api/v1/server/users")
  }
  func screenTime(user: UUID) async throws -> TVProfileScreenTime {
    try await admin("/api/v1/users/\(Self.id(user))/screen-time")
  }
  func setScreenTime(user: UUID, _ value: TVProfileScreenTimeUpdate) async throws
    -> TVProfileScreenTime
  {
    try await admin("/api/v1/users/\(Self.id(user))/screen-time", method: "PUT", json: value)
  }
  func grantScreenTime(user: UUID, _ grant: TVScreenTimeGrant) async throws -> TVProfileScreenTime {
    try await admin("/api/v1/users/\(Self.id(user))/screen-time/today", method: "POST", json: grant)
  }
  // MARK: Metadata

  func metadataReviews() async throws -> [TVMetadataReview] {
    try await admin("/api/v1/metadata/reviews")
  }
  func selectMetadataMatch(mediaId: UUID, candidate: TVMetadataCandidate) async throws {
    struct Payload: Encodable {
      let providerMediaId: String
      let mediaType: String
    }
    try await adminSend(
      "/api/v1/media/\(Self.id(mediaId))/metadata/match", method: "PUT",
      json: Payload(providerMediaId: candidate.providerMediaId, mediaType: candidate.mediaType))
  }
  func clearMetadataMatch(mediaId: UUID) async throws {
    try await adminSend("/api/v1/media/\(Self.id(mediaId))/metadata/match", method: "DELETE")
  }
  /// Movie and TV candidates for a title without information, as the Mac's "Match…".
  func searchMetadata(mediaId: UUID, query: String) async throws -> [TVMetadataCandidate] {
    try await admin(
      "/api/v1/media/\(Self.id(mediaId))/metadata/search",
      query: [URLQueryItem(name: "query", value: query)])
  }
  /// Asks to unlock management on another device: the TV shows the four-digit code, an iPhone,
  /// iPad or Mac with Face ID or Touch ID confirms it.
  func requestRemoteUnlock() async throws -> TVRemoteUnlockStart {
    try await admin("/api/v1/management/remote-unlock", method: "POST")
  }
  func remoteUnlockStatus(id: UUID) async throws -> TVRemoteUnlockStatus {
    try await admin("/api/v1/management/remote-unlock/\(Self.id(id))")
  }
  func subtitleProvider() async throws -> TVSubtitleProvider {
    try await admin("/api/v1/metadata/subtitles")
  }
  // MARK: Security ("security-v1")

  func securityDevices() async throws -> [TVSecurityDevice] {
    try await admin("/api/v1/server/security/devices")
  }
  func acknowledgeDevice(id: UUID) async throws {
    try await adminSend(
      "/api/v1/server/security/devices/\(Self.id(id))/acknowledge", method: "POST")
  }
  func blockDevice(id: UUID) async throws -> TVBlockResult {
    try await admin("/api/v1/server/security/devices/\(Self.id(id))/block", method: "POST")
  }
  /// Waits up to `waitSeconds` for a new device or unlock request after `version`.
  func securityAlerts(version: Int64, waitSeconds: Int) async throws -> TVSecurityAlerts {
    try await admin(
      "/api/v1/server/security/alerts",
      query: [
        URLQueryItem(name: "version", value: String(version)),
        URLQueryItem(name: "waitSeconds", value: String(min(max(waitSeconds, 0), 30))),
      ], longRunning: waitSeconds > 10)
  }
}
