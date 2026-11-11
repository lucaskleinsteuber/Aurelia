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
  /// "macos", "linux", "windows" or "other"; nil from servers before 1.8.7.
  var platform: String?
  /// The systemd service from the Linux package, which saves power, restarts and updates itself.
  var linuxPackage: Bool?
}

/// Where the server runs, which decides the server settings Aurelia shows.
enum ServerHostingKind: Equatable, Sendable {
  case thisMac
  case otherMac
  case linuxPackage
  case other

  init(capabilities: ServerCapabilities?, isLocalHost: Bool) {
    if isLocalHost {
      self = .thisMac
    } else if capabilities?.linuxPackage == true {
      self = .linuxPackage
    } else if capabilities?.nativeHostOperations == true || capabilities?.platform == "macos" {
      self = .otherMac
    } else {
      self = .other
    }
  }

  var location: String? {
    switch self {
    case .thisMac: "Runs on this Mac"
    case .otherMac: "Runs on another Mac"
    case .linuxPackage: "Runs on a Linux computer"
    case .other: nil
    }
  }

  /// Settings for running the server inside Aurelia on a Mac.
  var hostsOnMac: Bool { self == .thisMac || self == .otherMac }
}

/// Updates of a Linux server installed from the package. Versions read "1.8.7 (91)"; state is
/// "idle", "checking", "installing" or "failed".
struct ServerUpdateStatus: Decodable, Equatable, Sendable {
  let available: Bool
  let installed: String
  let newest: String?
  let updateAvailable: Bool
  let state: String
  let checkedAt: String?
  let message: String?

  /// When the server last looked for a new version.
  var checkedDate: Date? {
    checkedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
  }
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
  var readiness: ServerReadinessSummary? = nil
  var recentRecoveryEvents: [ServerRecoveryEvent]? = nil
}

struct ServerReadinessSummary: Decodable, Sendable {
  let state: String
  let components: [ServerComponentStatus]
  let checkedAt: String
}

struct ServerComponentStatus: Decodable, Sendable, Identifiable {
  let id: String
  let state: String
  let reason: String?

  var title: String {
    switch id {
    case "storage": "Server storage"
    case "database": "Database"
    case "media": "Media drives"
    case "metadata": "Metadata provider"
    case "backups": "Backups"
    case "recovery": "Recovery"
    default: "Server component"
    }
  }

  var detail: String {
    switch reason {
    case "server_disk_full": "Server disk full"
    case "server_disk_low": "Server disk space low"
    case "server_storage_unwritable": "Server storage unavailable"
    case "database_unavailable": "Database unavailable"
    case "media_access_error": "Media access error"
    case "media_drive_disconnected": "Media drive disconnected"
    case "provider_retry_pending": "Waiting to retry"
    case "metadata_job_failed": "Metadata job failed"
    case "automatic_backups_disabled": "Automatic backups disabled"
    case "first_backup_pending": "First backup pending"
    case "scheduled_backup_overdue": "Scheduled backup overdue"
    case "backup_storage_unavailable": "Backup storage unavailable"
    case "backup_attempt_failed": "Last backup attempt failed"
    case "restore_in_progress": "Restore in progress"
    default: state.capitalized
    }
  }
}

struct ServerRecoveryEvent: Decodable, Sendable {
  let at: String
  let code: String
}
struct UserAccessSummary: Codable, Identifiable, Sendable {
  var id: UUID { user.id }
  let user: UserSummary
  let isEnabled: Bool
  let libraryIds: [UUID]
}

/// What a Linux server installed from the package does when unused: "off" keeps it running,
/// "stop" stops only Aurelia Server until a device connects, "sleep" puts the computer to sleep.
/// Times are 24-hour "HH:MM", and both are nil when the server has no awake hours.
struct ServerPowerSettings: Codable, Equatable, Sendable {
  var available: Bool
  var mode: String
  var idleMinutes: Int
  var awakeFrom: String?
  var awakeUntil: String?
  /// From server 2.8.0: the network card also wakes the computer when a device connects directly.
  var wakeOnAccess: Bool? = nil
  /// The card's ethtool wake letters; "u" allows `wakeOnAccess`. Empty or missing when unknown.
  var wakeSupport: String? = nil
  /// From server 2.10.0: "macApp" or "linuxApp" when the Aurelia app hosts the server on a desktop
  /// or laptop (then only "off" and "stop"), "linuxServer" or "server" otherwise.
  var hosting: String? = nil
  /// Power down five minutes after a player's sleep timer ended; nil from older servers (on).
  var afterSleepTimer: Bool? = nil

  var hostedByApp: Bool { hosting == "macApp" || hosting == "linuxApp" }
  var hostName: String { hosting == "linuxApp" ? "the Linux PC" : hosting == "macApp" ? "the Mac" : "the server computer" }

  /// Wake When a Device Connects matters only while the computer sleeps or is off, and only on a
  /// card that can wake on a direct packet.
  var offersWakeOnAccess: Bool {
    (mode == "sleep" || mode == "shutdown") && (wakeSupport ?? "").contains("u")
  }
}

struct ScrubPreviewSettings: Codable, Equatable, Sendable {
  var available: Bool
  var mode: String
  var intervalSeconds: Int
  var storageCapMegabytes: Int
  var storedTitleCount: Int
  var storedBytes: Int64
  var activeCount: Int
  var pendingCount: Int
  var completedCount: Int
  var totalScheduledCount: Int
  var pausedForPlayback: Bool
}

struct UpdateScrubPreviewSettingsRequest: Codable, Equatable, Sendable {
  var mode: String
  var intervalSeconds: Int
  var storageCapMegabytes: Int
}

struct ServerHealthScanSummary: Decodable, Sendable {
  let scanId: UUID
  let state: String
  let startedAt: String
  let completedAt: String?
  let durationSeconds: Double?
  let addedFiles: Int
  let updatedFiles: Int
  let missingFiles: Int
  let failedFiles: Int
}

struct ServerHealthBackgroundJobs: Decodable, Sendable {
  let activeScans: Int
  let activeMetadataJobs: Int
  let activeScrubPreviewJobs: Int
}

struct ServerHealthEvent: Decodable, Sendable, Identifiable {
  var id: String { "\(at)-\(code)" }
  let at: String
  let code: String
  let severity: String
  let status: Int?
}

struct ServerHealthBackupSummary: Decodable, Sendable {
  let enabled: Bool
  let lastAttemptFailed: Bool
  let lastSucceededAt: String?
  let totalBackups: Int
  let totalBackupBytes: Int64
  let latestDailyAt: String?
  let latestWeeklyAt: String?
}

struct ServerHealthResponse: Decodable, Sendable {
  let uptimeSeconds: Double
  let freeDiskBytes: Int64?
  let databaseBytes: Int64
  let scrubPreviewTitleCount: Int
  let scrubPreviewBytes: Int64
  let scrubPreviewPendingCount: Int
  let activeLiveConversions: Int
  let activeStreams: Int
  let offlineMediaCount: Int
  let lastScan: ServerHealthScanSummary?
  let backgroundJobs: ServerHealthBackgroundJobs
  let recentIssues: [ServerHealthEvent]
  let backup: ServerHealthBackupSummary?
}

/// How the server converts video: its encoder, what converts now and, when a video chip is there
/// but unusable, the one step that usually fixes it.
struct TranscodingStatus: Decodable, Equatable, Sendable {
  struct Session: Decodable, Equatable, Sendable {
    let title: String
    let quality: String
    let encoder: String?
    let speed: Double?
    let converting: Bool
  }

  let available: Bool
  let encoder: String?
  let encoderName: String
  let device: String?
  let hardwareDecoding: Bool
  let hardwareResting: Bool
  let runningConversions: Int
  let videoLimit: Int
  let sessions: [Session]
  let hint: String?

  /// "Nvidia NVENC · decodes on the chip", or "Not available".
  var encoderSummary: String {
    guard available else { return "Not available" }
    var parts = [encoderName + (device.map { " (\(($0 as NSString).lastPathComponent))" } ?? "")]
    if hardwareDecoding { parts.append("decodes on the chip") }
    if hardwareResting { parts.append("the processor stands in after a chip error") }
    return parts.joined(separator: " · ")
  }

  static func sessionSummary(_ session: Session) -> String {
    let state =
      session.converting
      ? session.speed.map { String(format: "%.1f× real time", $0) } ?? "starting" : "ready"
    return "\(session.quality) · \(state)"
  }
}
