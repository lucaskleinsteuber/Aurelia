import Foundation

// Server administration on Apple TV: copies of the server's management contracts
// (src/Tarven.Contracts), written for this app like the Mac's ServerManagementModels.swift.
// States and kinds stay plain strings, so a value from a newer server is shown, never refused.

/// Any JSON value. Settings the app edits keep every field the server sent, also ones this app
/// doesn't know yet, so saving never resets a newer server's setting.
enum TVJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([TVJSONValue])
  case object([String: TVJSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([TVJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: TVJSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value):
      if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
        try container.encode(Int64(value))
      } else {
        try container.encode(value)
      }
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  var int: Int? {
    if case .number(let value) = self, value.isFinite { return Int(value) }
    return nil
  }
  var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }
  var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }
  var stringArray: [String]? {
    guard case .array(let values) = self else { return nil }
    return values.compactMap(\.string)
  }
}

/// Who this profile is to the server. Mirrors the server's rules: the owner manages everything,
/// administrators manage the library and metadata, and storage needs the whole library.
struct TVAdminPermissions: Equatable, Sendable {
  let owner: Bool
  let administrator: Bool
  let storage: Bool

  init(role: String?, accessMode: String?) {
    owner = role == "owner"
    administrator = owner || role == "admin"
    storage = administrator && (owner || accessMode != "selectedTitles")
  }

  static let none = TVAdminPermissions(role: nil, accessMode: nil)
}

struct TVAdminUser: Codable, Equatable, Sendable {
  let id: UUID
  let username: String
  let role: String
  var createdAt: String? = nil
  var accessMode: String? = nil
  var pinProtectionEnabled: Bool? = nil
  var needsPinSetup: Bool? = nil
  var profileRevision: Int64? = nil
  var displayName: String? = nil
  var pictureKey: String? = nil
  var pictureRevision: Int64? = nil
  var ageLimit: Int? = nil

  var shownName: String {
    if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
      return displayName
    }
    return username
  }
  var roleTitle: String { TVAdminText.role(role) }
}

struct TVUserAccessSummary: Codable, Identifiable, Equatable, Sendable {
  var id: UUID { user.id }
  let user: TVAdminUser
  let isEnabled: Bool
  let libraryIds: [UUID]
}

struct TVTitleAccess: Codable, Equatable, Sendable {
  var mode: String
  var titleIds: [UUID]
  var revision: Int64
}

struct TVProfileEditor: Codable, Equatable, Sendable {
  let user: TVAdminUser
  let isEnabled: Bool
  let access: TVTitleAccess
  let revision: Int64
}

struct TVProfileCreateRequest: Codable, Equatable, Sendable {
  var username: String
  var role: String
  var isEnabled: Bool
  var pinProtectionEnabled: Bool
  var pin: String?
  var accessMode: String?
  var titleIds: [UUID]?
  var displayName: String? = nil
  var pictureKey: String? = nil
  var ageLimit: Int? = nil
}

struct TVProfileUpdateRequest: Codable, Equatable, Sendable {
  var revision: Int64
  var role: String
  var isEnabled: Bool
  var pinProtectionEnabled: Bool
  var pin: String?
  var accessMode: String?
  var titleIds: [UUID]?
}

struct TVProfileAgeLimit: Codable, Equatable, Sendable {
  var ageLimit: Int?
  var allowedTitleIds: [UUID]
  var hiddenTitleIds: [UUID]
  var revision: Int64
}

// MARK: Screen time rules, as the profile editor changes them

struct TVScreenTimeDayRule: Codable, Equatable, Sendable {
  var bedtime: String?
  var wakeTime: String
  var dailyLimitMinutes: Int?
}

struct TVScreenTimeRules: Codable, Equatable, Sendable {
  var enabled: Bool
  var lockScope: String
  var ending: String
  var maxOvertimeMinutes: Int
  var schoolNight: TVScreenTimeDayRule
  var weekend: TVScreenTimeDayRule
  var allowOfflineDownloads: Bool = false

  init(
    enabled: Bool, lockScope: String, ending: String, maxOvertimeMinutes: Int,
    schoolNight: TVScreenTimeDayRule, weekend: TVScreenTimeDayRule,
    allowOfflineDownloads: Bool = false
  ) {
    self.enabled = enabled
    self.lockScope = lockScope
    self.ending = ending
    self.maxOvertimeMinutes = maxOvertimeMinutes
    self.schoolNight = schoolNight
    self.weekend = weekend
    self.allowOfflineDownloads = allowOfflineDownloads
  }

  private enum CodingKeys: String, CodingKey {
    case enabled, lockScope, ending, maxOvertimeMinutes, schoolNight, weekend,
      allowOfflineDownloads
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decode(Bool.self, forKey: .enabled)
    lockScope = try container.decode(String.self, forKey: .lockScope)
    ending = try container.decode(String.self, forKey: .ending)
    maxOvertimeMinutes = try container.decode(Int.self, forKey: .maxOvertimeMinutes)
    schoolNight = try container.decode(TVScreenTimeDayRule.self, forKey: .schoolNight)
    weekend = try container.decode(TVScreenTimeDayRule.self, forKey: .weekend)
    allowOfflineDownloads =
      try container.decodeIfPresent(Bool.self, forKey: .allowOfflineDownloads) ?? false
  }

  static let `default` = TVScreenTimeRules(
    enabled: false, lockScope: "playbackOnly", ending: "finishTitle", maxOvertimeMinutes: 30,
    schoolNight: .init(bedtime: "19:30", wakeTime: "07:00", dailyLimitMinutes: nil),
    weekend: .init(bedtime: "20:30", wakeTime: "08:00", dailyLimitMinutes: nil))
}

struct TVScreenTimeToday: Codable, Equatable, Sendable {
  var extraMinutes: Int
  var bedtimeLifted: Bool
  var oneMoreTitle: Bool
  var oneMoreTitleUsed: Bool
}

struct TVProfileScreenTime: Codable, Equatable, Sendable {
  var rules: TVScreenTimeRules
  var today: TVScreenTimeToday
  var status: TVScreenTimeStatus?
  var revision: Int64
}

struct TVProfileScreenTimeUpdate: Codable, Equatable, Sendable {
  var rules: TVScreenTimeRules
  var revision: Int64
}

struct TVScreenTimeGrant: Codable, Equatable, Sendable {
  var addMinutes = 0
  var liftBedtime = false
  var oneMoreTitle = false
}

// MARK: Devices

struct TVDeviceSession: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let userId: UUID
  let deviceName: String
  let createdAt: String
  let lastSeenAt: String
  let expiresAt: String
  let revokedAt: String?
  let isCurrent: Bool

  func isActive(now: Date = Date()) -> Bool {
    guard revokedAt == nil, let expiry = TVServerDate.parse(expiresAt) else { return false }
    return expiry > now
  }
  var lastSeenDate: Date? { TVServerDate.parse(lastSeenAt) }
}

struct TVPairingCode: Codable, Equatable, Sendable {
  let code: String
  let expiresAt: String
  var expiryDate: Date? { TVServerDate.parse(expiresAt) }
}

struct TVDeviceAuthorizationPreview: Codable, Equatable, Sendable {
  let id: UUID
  let deviceName: String
  let serverId: UUID
  let serverName: String
  let state: String
  let expiresAt: String
}

// MARK: Libraries

struct TVServerFolder: Codable, Hashable, Sendable {
  let name: String
  let path: String
}

struct TVServerFolderListing: Codable, Equatable, Sendable {
  let path: String?
  let parent: String?
  let folders: [TVServerFolder]
}

struct TVCreateLibraryRequest: Codable, Equatable, Sendable {
  var name: String?
  var path: String
  var kind: String
  var combineExisting: Bool
  var requireImportPreview: Bool
}

struct TVLibrarySummary: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let path: String
  let kind: String
  let availability: String
  let createdAt: String
  let lastScanStartedAt: String?
  let lastScanCompletedAt: String?
  let lastError: String?
  var monitoringEnabled: Bool? = nil
  var lastObservedAt: String? = nil
  var health: String? = nil
  var importPreviewRequired: Bool? = nil

  var kindTitle: String { TVAdminText.libraryKind(kind) }
  var availabilityTitle: String {
    switch health ?? availability {
    case "available", "healthy": "Available"
    case "unavailable", "waitingForStorage": "Drive not connected"
    case "permissionDenied": "No permission to read"
    case "error": "Error"
    default: "Checking…"
    }
  }
  var isAvailable: Bool { availability == "available" }
}

struct TVScanIssue: Codable, Equatable, Sendable {
  let code: String
  let message: String
  let path: String?
}

struct TVLibraryScan: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let libraryId: UUID
  let state: String
  let createdAt: String
  let startedAt: String?
  let completedAt: String?
  let filesDiscovered: Int
  let filesProcessed: Int
  let addedFiles: Int
  let updatedFiles: Int
  let missingFiles: Int
  let skippedFiles: Int
  let error: String?
  let issues: [TVScanIssue]
  var trigger: String? = nil
  var phase: String? = nil

  var isActive: Bool { state == "queued" || state == "running" || state == "waitingForStorage" }
  var progress: Double? {
    guard filesDiscovered > 0 else { return nil }
    return min(1, Double(filesProcessed) / Double(filesDiscovered))
  }
  var stateTitle: String { TVAdminText.jobState(state) }
}

struct TVExcludedMedia: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let libraryId: UUID
  let relativePath: String
  let isDirectory: Bool
}

struct TVLibraryDiscovery: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let libraryId: UUID
  let relativePath: String
  let detectedTitle: String
  let suggestedKind: String?
  let reason: String
  let decision: String?
}

struct TVLibraryImportReview: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let libraryId: UUID
  let relativePath: String
  let detectedTitle: String
  let reason: String
  let state: String
}

struct TVImportPreviewCounts: Codable, Equatable, Sendable {
  let files: Int
  let movies: Int
  let series: Int
  let episodes: Int
  let extras: Int
  let trailers: Int
  let pending: Int
  let ignored: Int
  let errors: Int
}

struct TVImportPreviewSummary: Codable, Identifiable, Equatable, Sendable {
  let previewId: UUID
  let libraryId: UUID
  let revision: String
  let state: String
  let counts: TVImportPreviewCounts
  let issues: [TVScanIssue]
  var targets: [TVImportPreviewTarget] = []
  var id: UUID { previewId }
}

/// A movie or series in the preview that extras, trailers and episodes can belong to.
struct TVImportPreviewTarget: Codable, Identifiable, Equatable, Sendable {
  let relativePath: String
  let title: String
  let kind: String
  let seasonNumbers: [Int]
  var id: String { relativePath }
}

struct TVImportPreviewItem: Codable, Identifiable, Equatable, Sendable {
  let relativePath: String
  let title: String
  let kind: String?
  let parentRelativePath: String?
  let seasonNumber: Int?
  let episodeNumber: Int?
  let category: String?
  let status: String
  let reason: String
  let isDirectory: Bool
  var id: String { "\(isDirectory ? "directory" : "file"):\(relativePath)" }
}

struct TVImportPreviewPage: Codable, Equatable, Sendable {
  let summary: TVImportPreviewSummary
  let items: [TVImportPreviewItem]
  let totalCount: Int
  let offset: Int
  let limit: Int
}

/// One correction in an import preview, as the Mac's Import Preview sends it.
struct TVImportAssignment: Codable, Equatable, Sendable {
  var relativePath: String
  var isDirectory: Bool
  var kind: String?
  var parentRelativePath: String? = nil
  var seasonNumber: Int? = nil
  var episodeNumber: Int? = nil
  var category: String? = nil
  var title: String? = nil
  var useAutomaticDetection = false
}

struct TVResetLibraryPreview: Codable, Equatable, Sendable {
  let libraryIds: [UUID]
  let revision: String
  let titles: Int
  let files: Int
  let artwork: Int
  let storageLocations: Int
}

struct TVLibraryMutation: Codable, Equatable, Sendable {
  let id: UUID
  let state: String
  let removedItems: Int
  let error: String?
}

// MARK: Library health

struct TVDuplicateItem: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let kind: String
  let year: Int?
  let fileName: String
  let fileSize: Int64?
  let availability: String
}

struct TVDuplicateGroup: Codable, Identifiable, Equatable, Sendable {
  let key: String
  let title: String
  let kind: String
  let year: Int?
  let items: [TVDuplicateItem]
  var id: String { key }
}

struct TVHealthOfflineTitle: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let kind: String
  let year: Int?
  let libraryName: String
  let fileName: String
  let lastSeenAt: String
  let daysOffline: Int
}

struct TVUnmatchedTitle: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let kind: String
  let year: Int?
  let fileName: String
  let issueReason: String
}

// MARK: Metadata

struct TVMetadataProvider: Codable, Equatable, Sendable {
  let enabled: Bool
  let hasToken: Bool
  let language: String
  let artworkBytes: Int64
  let artworkLimitBytes: Int64
  let provider: String
  let attribution: String
}

struct TVMetadataJob: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let libraryId: UUID?
  let mediaId: UUID?
  let state: String
  let itemsTotal: Int
  let itemsProcessed: Int
  let itemsMatched: Int
  let itemsNeedingReview: Int
  let itemsFailed: Int
  let error: String?
  let createdAt: String
  let startedAt: String?
  let completedAt: String?
  var mode: String? = nil
  var waitReason: String? = nil
  var nextAttemptAt: String? = nil
  var itemsSkipped: Int? = nil

  var isActive: Bool { state == "queued" || state == "running" }
  var progress: Double? {
    guard itemsTotal > 0 else { return nil }
    return min(1, Double(itemsProcessed) / Double(itemsTotal))
  }

  /// "Done · 23 matched, 2 need review", as on the Mac.
  var summary: String {
    if isActive {
      let waiting =
        switch waitReason {
        case "tmdb": "Waiting for TMDB"
        case "storage": "Waiting for writable storage"
        case nil: nil as String?
        default: "Waiting"
        }
      return waiting ?? "\(itemsProcessed) of \(itemsTotal) titles checked"
    }
    var parts: [String] = []
    if itemsMatched > 0 { parts.append("\(itemsMatched) matched") }
    if itemsNeedingReview > 0 {
      parts.append("\(itemsNeedingReview) need\(itemsNeedingReview == 1 ? "s" : "") review")
    }
    if let skipped = itemsSkipped, skipped > 0 { parts.append("\(skipped) skipped") }
    if itemsFailed > 0 { parts.append("\(itemsFailed) failed") }
    let detail =
      parts.isEmpty
      ? "\(itemsTotal) \(itemsTotal == 1 ? "title" : "titles") checked"
      : parts.joined(separator: ", ")
    switch state {
    case "completed": return "Done · " + detail
    case "cancelled": return "Stopped · " + detail
    default: return "Did not finish · " + (error ?? detail)
    }
  }
}

struct TVMetadataCandidate: Codable, Identifiable, Equatable, Sendable {
  let provider: String
  let providerMediaId: String
  let mediaType: String
  let title: String
  let originalTitle: String?
  let year: Int?
  let overview: String?
  let posterPath: String?
  let confidence: Double
  var id: String { "\(provider):\(mediaType):\(providerMediaId)" }
}

struct TVMetadataReview: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let title: String
  let reason: String
  let state: String
  let candidates: [TVMetadataCandidate]
  let updatedAt: String
}

struct TVSubtitleProvider: Codable, Equatable, Sendable {
  let enabled: Bool
  let hasApiKey: Bool
  let hasAccount: Bool
  let accountName: String?
  let languages: [String]
  let automatic: Bool
  let provider: String
  let attribution: String
  let remainingDownloads: Int?
  let resetsAt: String?
  let lastAutomaticRunAt: String?
  let downloadedCount: Int
}

struct TVUpdateSubtitleProvider: Codable, Equatable, Sendable {
  var enabled: Bool
  var languages: [String]
  var automatic: Bool
  var apiKey: String? = nil
  var accountName: String? = nil
  var accountPassword: String? = nil
}

// MARK: Server

struct TVServerCapabilities: Codable, Equatable, Sendable {
  let nativeHostOperations: Bool
  let encryptedBackups: Bool
  let transcoding: Bool
  var platform: String? = nil
  var linuxPackage: Bool? = nil

  /// "Runs on a Mac" or "Runs on a Linux computer", for the server summary.
  var location: String? {
    if linuxPackage == true { return "Runs on a Linux computer" }
    if nativeHostOperations || platform == "macos" { return "Runs on a Mac" }
    if platform == "linux" { return "Runs on Linux" }
    return nil
  }
}

struct TVServerComponent: Codable, Identifiable, Equatable, Sendable {
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

struct TVServerReadiness: Codable, Equatable, Sendable {
  let state: String
  let components: [TVServerComponent]
  let checkedAt: String
}

struct TVServerStatus: Codable, Equatable, Sendable {
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
  var readiness: TVServerReadiness? = nil
}

struct TVServerHealthScan: Codable, Equatable, Sendable {
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

struct TVServerHealthJobs: Codable, Equatable, Sendable {
  let activeScans: Int
  let activeMetadataJobs: Int
  let activeScrubPreviewJobs: Int
}

struct TVServerHealthEvent: Codable, Identifiable, Equatable, Sendable {
  var id: String { "\(at)-\(code)" }
  let at: String
  let code: String
  let severity: String
  let status: Int?
}

struct TVServerHealthBackup: Codable, Equatable, Sendable {
  let enabled: Bool
  let lastAttemptFailed: Bool
  let lastSucceededAt: String?
  let totalBackups: Int
  let totalBackupBytes: Int64
}

struct TVServerHealth: Codable, Equatable, Sendable {
  let uptimeSeconds: Double
  let freeDiskBytes: Int64?
  let databaseBytes: Int64
  let scrubPreviewTitleCount: Int
  let scrubPreviewBytes: Int64
  let scrubPreviewPendingCount: Int
  let activeLiveConversions: Int
  let activeStreams: Int
  let offlineMediaCount: Int
  let lastScan: TVServerHealthScan?
  let backgroundJobs: TVServerHealthJobs
  let recentIssues: [TVServerHealthEvent]
  let backup: TVServerHealthBackup?
}

/// What the server measured about itself (server 2.14.0).
struct TVServerPerformance: Codable, Equatable, Sendable {
  let since: String
  let slowRequestMilliseconds: Int
  let slowQueryMilliseconds: Int
  let requests: Int64
  let p95Milliseconds: Double
  let endpoints: [TVEndpointTiming]
  let slowQueries: [TVSlowQuery]
}

struct TVEndpointTiming: Codable, Identifiable, Equatable, Sendable {
  var id: String { method + " " + route }
  let method: String
  let route: String
  let count: Int64
  let errors: Int64
  let slowCount: Int64
  let medianMilliseconds: Double
  let p95Milliseconds: Double
  let maxMilliseconds: Double
  let queriesPerRequest: Double
}

struct TVSlowQuery: Codable, Identifiable, Equatable, Sendable {
  var id: String { at + statement }
  let at: String
  let milliseconds: Double
  let kind: String
  let statement: String
  let endpoint: String?
  let warmUp: Bool
}

enum TVPerformanceText {
  /// "12 ms" or "1.4 s".
  static func duration(_ milliseconds: Double) -> String {
    milliseconds >= 1000
      ? String(format: "%.1f s", milliseconds / 1000) : "\(Int(milliseconds.rounded())) ms"
  }

  /// "/catalog/items/‹mediaId›" for "/api/v1/catalog/items/{mediaId:guid}".
  static func route(_ route: String) -> String {
    var text = route.hasPrefix("/api/v1") ? String(route.dropFirst(7)) : route
    while let open = text.firstIndex(of: "{"), let close = text[open...].firstIndex(of: "}") {
      let inner = text[text.index(after: open)..<close]
      let name = (inner.split(separator: ":").first.map(String.init) ?? String(inner))
        .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
      text.replaceSubrange(open...close, with: "‹\(name)›")
    }
    return text.isEmpty ? "/" : text
  }
}

/// The owner's server policy (`GET /api/v1/server/settings`). `stored` keeps every field.
struct TVServerConfiguration: Codable, Equatable, Sendable {
  let stored: [String: TVJSONValue]
  let active: TVActiveNetwork
  let restartRequired: Bool
}

struct TVActiveNetwork: Codable, Equatable, Sendable {
  let serverName: String
  let lanAccessEnabled: Bool
  let lanHttpsPort: Int
}

struct TVServerBackup: Codable, Identifiable, Equatable, Sendable {
  var id: String { name }
  let name: String
  let kind: String
  let createdAt: String
  let bytes: Int64
}

struct TVPreparedRestore: Codable, Equatable, Sendable {
  let id: UUID
  let serverId: UUID
  let revokesAllSessions: Bool
}

struct TVDiagnosticEvent: Codable, Identifiable, Equatable, Sendable {
  var id: String { "\(at)-\(code)-\(userId?.uuidString ?? "")" }
  let at: String
  let code: String
  let severity: String
  let userId: UUID?
  let status: Int?
}

struct TVServerJobs: Codable, Equatable, Sendable {
  let scans: [TVLibraryScan]
  let metadata: [TVMetadataJob]
}

struct TVHostOperation: Codable, Equatable, Sendable {
  let id: UUID
  let kind: String
  let state: String
  let confirmBefore: String?
  let httpsPort: Int?
}

struct TVServerUpdateStatus: Codable, Equatable, Sendable {
  let available: Bool
  let installed: String
  let newest: String?
  let updateAvailable: Bool
  let state: String
  let checkedAt: String?
  let message: String?
  /// From newer servers, while checking or installing: 0–100 and the current step ("starting",
  /// "checking", "verifying", "downloading", "unpacking" or "restarting"). Older servers send neither.
  var progressPercent: Int? = nil
  var phase: String? = nil

  /// The server is checking or installing right now.
  var isBusy: Bool { state == "checking" || state == "installing" }
}

/// What Server Updates shows while the server checks or installs, worded as on the Mac.
/// `reconnecting` is the moment the server restarts with the new version and does not answer.
enum TVServerUpdateProgress {
  /// 0–100, or nil when the server reports no percentage (the bar then runs without one).
  static func percent(_ status: TVServerUpdateStatus, reconnecting: Bool) -> Int? {
    if reconnecting { return 95 }
    return status.progressPercent.map { min(max($0, 0), 100) }
  }

  static func fraction(_ status: TVServerUpdateStatus, reconnecting: Bool) -> Double? {
    percent(status, reconnecting: reconnecting).map { Double($0) / 100 }
  }

  static func text(_ status: TVServerUpdateStatus, reconnecting: Bool) -> String {
    if reconnecting { return "Waiting for server to restart…" }
    switch status.phase {
    case "starting":
      return status.state == "checking" ? "Starting update check…" : "Preparing server update…"
    case "checking": return "Checking GitHub for updates…"
    case "verifying": return "Verifying release signature…"
    case "downloading": return "Downloading server update…"
    case "unpacking": return "Verifying checksum and unpacking…"
    case "restarting": return "Installing and restarting server…"
    default:
      if status.state == "checking" { return "Checking GitHub for updates…" }
      if let newest = status.newest {
        return "Installing \(newest)… The server restarts by itself."
      }
      return "Installing server update…"
    }
  }
}

struct TVServerPower: Codable, Equatable, Sendable {
  var available: Bool
  var mode: String
  var idleMinutes: Int
  var awakeFrom: String?
  var awakeUntil: String?
  var wakeOnAccess: Bool? = nil
  var wakeSupport: String? = nil
  var hosting: String? = nil
  var afterSleepTimer: Bool? = nil
  /// From server 2.16.0, the Wake-on-LAN check: "wired", "wifi" or "other".
  var network: String? = nil
  /// The card's wake letters right now; "g" means a Wake-on-LAN call wakes it.
  var wakeOn: String? = nil
  /// The sleep "sleep" mode gives: "deep" (suspend to RAM), "light" (s2idle) or "none".
  var sleepKind: String? = nil
}

struct TVScrubPreviewSettings: Codable, Equatable, Sendable {
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

struct TVUpdateScrubPreviews: Codable, Equatable, Sendable {
  var mode: String
  var intervalSeconds: Int
  var storageCapMegabytes: Int
}

struct TVSegmentSettings: Codable, Equatable, Sendable {
  var available: Bool
  var enabled: Bool
  var pendingCount: Int
  var analyzedCount: Int
  var noResultCount: Int
  var running: Bool
  var pausedForPlayback: Bool
  var usePictures: Bool? = nil
  var totalCount: Int? = nil
  var currentTitle: String? = nil
  var currentStep: String? = nil
  var estimatedSecondsRemaining: Int? = nil
  var movieCount: Int? = nil
  var moviesWithCredits: Int? = nil
  var moviesPendingCount: Int? = nil

  var progress: Double {
    let total = max(totalCount ?? 0, pendingCount + analyzedCount + noResultCount)
    return total == 0 ? 1 : Double(total - pendingCount) / Double(total)
  }
}

struct TVSegmentSeries: Codable, Identifiable, Equatable, Sendable {
  let seriesId: UUID
  let title: String
  let episodeCount: Int
  let withIntro: Int
  let withCredits: Int
  let pendingCount: Int
  var id: UUID { seriesId }
}

struct TVSpeechModelChoice: Codable, Identifiable, Equatable, Sendable {
  let name: String
  let label: String
  let bytes: Int64
  let description: String
  var id: String { name }
}

struct TVSpeechModelDownload: Codable, Equatable, Sendable {
  let name: String
  let receivedBytes: Int64
  let totalBytes: Int64
}

struct TVServerSpeechJob: Codable, Equatable, Sendable {
  let mediaId: UUID
  let title: String
  let kind: String
  let language: String
  let state: String
  let progress: Double
  let pausedForPlayback: Bool
  let message: String?
}

struct TVServerSpeech: Codable, Equatable, Sendable {
  let available: Bool
  let model: String?
  let modelBytes: Int64
  let downloading: TVSpeechModelDownload?
  let downloadError: String?
  let models: [TVSpeechModelChoice]
  let jobs: [TVServerSpeechJob]
}

struct TVTranscodingSession: Codable, Equatable, Sendable {
  let title: String
  let quality: String
  let encoder: String?
  let speed: Double?
  let converting: Bool
}

struct TVTranscodingStatus: Codable, Equatable, Sendable {
  let available: Bool
  let encoder: String?
  let encoderName: String
  let device: String?
  let hardwareDecoding: Bool
  let hardwareResting: Bool
  let runningConversions: Int
  let videoLimit: Int
  let sessions: [TVTranscodingSession]
  let hint: String?

  /// "Nvidia NVENC · decodes on the chip", or "Not available".
  var encoderSummary: String {
    guard available else { return "Not available" }
    var parts = [
      encoderName + (device.map { " (\(($0 as NSString).lastPathComponent))" } ?? "")
    ]
    if hardwareDecoding { parts.append("decodes on the chip") }
    if hardwareResting { parts.append("the processor stands in after a chip error") }
    return parts.joined(separator: " · ")
  }
}

/// Words the administration screens share with the Mac and the browser.
enum TVAdminText {
  static func role(_ role: String) -> String {
    switch role {
    case "owner": "Owner"
    case "admin": "Administrator"
    default: "Viewer"
    }
  }

  static func libraryKind(_ kind: String) -> String {
    switch kind {
    case "movies": "Movies"
    case "tvShows": "TV Shows"
    default: "Automatic"
    }
  }

  static func jobState(_ state: String) -> String {
    switch state {
    case "queued": "Waiting"
    case "running": "Running"
    case "waitingForStorage": "Waiting for the drive"
    case "completed": "Done"
    case "failed": "Failed"
    case "interrupted": "Interrupted"
    case "cancelled": "Stopped"
    default: state.capitalized
    }
  }

  /// "3 h 12 min" or "2 days".
  static func uptime(_ seconds: Double) -> String {
    let minutes = Int(max(0, seconds) / 60)
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    if hours < 48 { return "\(hours) h \(minutes % 60) min" }
    return "\(hours / 24) days"
  }

  static func bytes(_ value: Int64?) -> String {
    guard let value else { return "—" }
    return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }

  /// A diagnostics code as a sentence, never the raw identifier when a phrase is known.
  static func event(_ code: String) -> String {
    switch code {
    case "authentication_rejected": "A sign-in was rejected"
    case "access_rejected": "A request was not allowed"
    case "request_rate_limited": "Too many requests"
    case "network_access_rejected": "A device outside the allowed networks"
    case "host_rejected": "A request for another address"
    case "invalid_credentials": "Wrong Server Password"
    case "invalid_profile_pin": "Wrong profile PIN"
    case "credential_locked": "Sign-in paused after wrong passwords"
    case "profile_pin_locked": "Profile paused after wrong PINs"
    case "invalid_pairing_code": "Wrong device code"
    case "owner_change_completed": "A protected setting was changed"
    case "request_failed": "A request failed on the server"
    default: code.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }
}
