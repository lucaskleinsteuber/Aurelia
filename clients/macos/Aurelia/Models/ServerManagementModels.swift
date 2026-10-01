import Foundation

struct ServerPolicySettings: Codable, Equatable, Sendable {
  var version: Int
  var serverName: String
  var lanAccessEnabled: Bool
  var lanHttpsPort: Int
  var revision: Int64
  var pairingEnabled: Bool
  var deviceSessionDays: Int
  var globalStreamLimit: Int
  var userStreamLimit: Int
  var bonjourEnabled: Bool
  var allowedNetworks: [String]?
  var monitoringEnabled: Bool
  var reconciliationMinutes: Int
  var maintenanceStartHour: Int
  var maintenanceEndHour: Int
  var jobQueueLimit: Int
  var automaticBackupsEnabled: Bool
  var backupIntervalHours: Int
  var dailyBackupsRetained: Int
  var weeklyBackupsRetained: Int
  var eventRetentionDays: Int
  var maximumEvents: Int
}
struct ServerCapabilities: Decodable, Sendable {
  let nativeHostOperations: Bool
  let encryptedBackups: Bool
  let transcoding: Bool
}
struct HostOperationStatus: Decodable, Sendable {
  let id: UUID
  let kind: String
  let state: String
  let confirmBefore: String?
  let httpsPort: Int?
}
struct ServerHostingStatus: Decodable, Sendable {
  let backgroundEnabled: Bool
  let backgroundRequested: Bool
  let startAtLogin: Bool
  let preventIdleSleep: Bool
  let state: String
}
struct ServerBackupSummary: Decodable, Identifiable, Sendable {
  var id: String { name }
  let name: String
  let kind: String
  let createdAt: String
  let bytes: Int64
}
struct ServerDiagnosticEvent: Decodable, Identifiable, Sendable {
  var id: String { "\(at)-\(code)-\(userId?.uuidString ?? "")" }
  let at: String
  let code: String
  let severity: String
  let userId: UUID?
  let status: Int?
}
struct PreparedServerRestore: Decodable, Sendable {
  let id: UUID
  let serverId: UUID
  let revokesAllSessions: Bool
}
struct ServerJobHistory: Decodable, Sendable {
  let scans: [LibraryScanSummary]
  let metadata: [MetadataJobSummary]
}
struct ActiveServerNetwork: Decodable, Sendable {
  let serverName: String
  let lanAccessEnabled: Bool
  let lanHttpsPort: Int
}
struct ServerConfigurationResponse: Decodable, Sendable {
  let stored: ServerPolicySettings
  let active: ActiveServerNetwork
  let restartRequired: Bool
}
struct ServerStatusSummary: Decodable, Sendable {
  let state: String
  let version: String
  let uptimeSeconds: Double
  let activeStreams: Int
  let databaseBytes: Int64
  let users: Int
  let libraries: Int
  let freeDiskBytes: Int64?
  let certificateExpiresAt: String?
  let networkAddresses: [String]
}
struct UserAccessSummary: Decodable, Identifiable, Sendable {
  var id: UUID { user.id }
  let user: UserSummary
  let isEnabled: Bool
  let libraryIds: [UUID]
}
