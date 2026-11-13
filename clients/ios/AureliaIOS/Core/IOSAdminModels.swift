import Foundation

// Server administration on iPhone and iPad: copies of the server's management contracts
// (src/Aurelia.Contracts), written for this app like the Mac's ServerManagementModels.swift.
// States and kinds stay plain strings, so a value from a newer server is shown, never refused.

/// Any JSON value. Settings the app edits keep every field the server sent, also ones this app
/// doesn't know yet, so saving never resets a newer server's setting.
enum IOSJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([IOSJSONValue])
  case object([String: IOSJSONValue])

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
    } else if let value = try? container.decode([IOSJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: IOSJSONValue].self))
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
struct IOSAdminPermissions: Equatable, Sendable {
  let owner: Bool
  let administrator: Bool
  let storage: Bool

  init(role: String?, accessMode: String?) {
    owner = role == "owner"
    administrator = owner || role == "admin"
    storage = administrator && (owner || accessMode != "selectedTitles")
  }

  static let none = IOSAdminPermissions(role: nil, accessMode: nil)
}

struct IOSAdminUser: Codable, Equatable, Sendable {
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
  var roleTitle: String { IOSAdminText.role(role) }
}

struct IOSUserAccessSummary: Codable, Identifiable, Equatable, Sendable {
  var id: UUID { user.id }
  let user: IOSAdminUser
  let isEnabled: Bool
  let libraryIds: [UUID]
}

struct IOSTitleAccess: Codable, Equatable, Sendable {
  var mode: String
  var titleIds: [UUID]
  var revision: Int64
}

struct IOSProfileEditor: Codable, Equatable, Sendable {
  let user: IOSAdminUser
  let isEnabled: Bool
  let access: IOSTitleAccess
  let revision: Int64
}

struct IOSProfileCreateRequest: Codable, Equatable, Sendable {
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

struct IOSProfileUpdateRequest: Codable, Equatable, Sendable {
  var revision: Int64
  var role: String
  var isEnabled: Bool
  var pinProtectionEnabled: Bool
  var pin: String?
  var accessMode: String?
  var titleIds: [UUID]?
}

struct IOSProfileAgeLimit: Codable, Equatable, Sendable {
  var ageLimit: Int?
  var allowedTitleIds: [UUID]
  var hiddenTitleIds: [UUID]
  var revision: Int64
}

// MARK: Screen time rules, as the profile editor changes them

struct IOSScreenTimeDayRule: Codable, Equatable, Sendable {
  var bedtime: String?
  var wakeTime: String
  var dailyLimitMinutes: Int?
}

struct IOSScreenTimeRules: Codable, Equatable, Sendable {
  var enabled: Bool
  var lockScope: String
  var ending: String
  var maxOvertimeMinutes: Int
  var schoolNight: IOSScreenTimeDayRule
  var weekend: IOSScreenTimeDayRule

  static let `default` = IOSScreenTimeRules(
    enabled: false, lockScope: "playbackOnly", ending: "finishTitle", maxOvertimeMinutes: 30,
    schoolNight: .init(bedtime: "19:30", wakeTime: "07:00", dailyLimitMinutes: nil),
    weekend: .init(bedtime: "20:30", wakeTime: "08:00", dailyLimitMinutes: nil))
}

struct IOSScreenTimeToday: Codable, Equatable, Sendable {
  var extraMinutes: Int
  var bedtimeLifted: Bool
  var oneMoreTitle: Bool
  var oneMoreTitleUsed: Bool
}

struct IOSProfileScreenTime: Codable, Equatable, Sendable {
  var rules: IOSScreenTimeRules
  var today: IOSScreenTimeToday
  var status: IOSScreenTimeStatus?
  var revision: Int64
}

struct IOSProfileScreenTimeUpdate: Codable, Equatable, Sendable {
  var rules: IOSScreenTimeRules
  var revision: Int64
}

struct IOSScreenTimeGrant: Codable, Equatable, Sendable {
  var addMinutes = 0
  var liftBedtime = false
  var oneMoreTitle = false
}

// MARK: Devices

struct IOSDeviceSession: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let userId: UUID
  let deviceName: String
  let createdAt: String
  let lastSeenAt: String
  let expiresAt: String
  let revokedAt: String?
  let isCurrent: Bool

  func isActive(now: Date = Date()) -> Bool {
    guard revokedAt == nil, let expiry = IOSServerDate.parse(expiresAt) else { return false }
    return expiry > now
  }
  var lastSeenDate: Date? { IOSServerDate.parse(lastSeenAt) }
}

struct IOSPairingCode: Codable, Equatable, Sendable {
  let code: String
  let expiresAt: String
  var expiryDate: Date? { IOSServerDate.parse(expiresAt) }
}

struct IOSDeviceAuthorizationPreview: Codable, Equatable, Sendable {
  let id: UUID
  let deviceName: String
  let serverId: UUID
  let serverName: String
  let state: String
  let expiresAt: String
}

// MARK: Libraries

struct IOSServerFolder: Codable, Hashable, Sendable {
  let name: String
  let path: String
}

struct IOSServerFolderListing: Codable, Equatable, Sendable {
  let path: String?
  let parent: String?
  let folders: [IOSServerFolder]
}

struct IOSCreateLibraryRequest: Codable, Equatable, Sendable {
  var name: String?
  var path: String
  var kind: String
  var combineExisting: Bool
  var requireImportPreview: Bool
}

struct IOSLibrarySummary: Codable, Identifiable, Equatable, Sendable {
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

  var kindTitle: String { IOSAdminText.libraryKind(kind) }
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

struct IOSScanIssue: Codable, Equatable, Sendable {
  let code: String
  let message: String
  let path: String?
}

struct IOSLibraryScan: Codable, Identifiable, Equatable, Sendable {
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
  let issues: [IOSScanIssue]
  var trigger: String? = nil
  var phase: String? = nil

  var isActive: Bool { state == "queued" || state == "running" || state == "waitingForStorage" }
  var progress: Double? {
    guard filesDiscovered > 0 else { return nil }
    return min(1, Double(filesProcessed) / Double(filesDiscovered))
  }
  var stateTitle: String { IOSAdminText.jobState(state) }
}

struct IOSExcludedMedia: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let libraryId: UUID
  let relativePath: String
  let isDirectory: Bool
}

struct IOSLibraryDiscovery: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let libraryId: UUID
  let relativePath: String
  let detectedTitle: String
  let suggestedKind: String?
  let reason: String
  let decision: String?
}

struct IOSLibraryImportReview: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let libraryId: UUID
  let relativePath: String
  let detectedTitle: String
  let reason: String
  let state: String
}

struct IOSImportPreviewCounts: Codable, Equatable, Sendable {
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

struct IOSImportPreviewSummary: Codable, Identifiable, Equatable, Sendable {
  let previewId: UUID
  let libraryId: UUID
  let revision: String
  let state: String
  let counts: IOSImportPreviewCounts
  let issues: [IOSScanIssue]
  var targets: [IOSImportPreviewTarget] = []
  var id: UUID { previewId }
}

/// A movie or series in the preview that extras, trailers and episodes can belong to.
struct IOSImportPreviewTarget: Codable, Identifiable, Equatable, Sendable {
  let relativePath: String
  let title: String
  let kind: String
  let seasonNumbers: [Int]
  var id: String { relativePath }
}

struct IOSImportPreviewItem: Codable, Identifiable, Equatable, Sendable {
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

struct IOSImportPreviewPage: Codable, Equatable, Sendable {
  let summary: IOSImportPreviewSummary
  let items: [IOSImportPreviewItem]
  let totalCount: Int
  let offset: Int
  let limit: Int
}

/// One correction in an import preview, as the Mac's Import Preview sends it.
struct IOSImportAssignment: Codable, Equatable, Sendable {
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

struct IOSResetLibraryPreview: Codable, Equatable, Sendable {
  let libraryIds: [UUID]
  let revision: String
  let titles: Int
  let files: Int
  let artwork: Int
  let storageLocations: Int
}

struct IOSLibraryMutation: Codable, Equatable, Sendable {
  let id: UUID
  let state: String
  let removedItems: Int
  let error: String?
}

// MARK: Library health

struct IOSDuplicateItem: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let kind: String
  let year: Int?
  let fileName: String
  let fileSize: Int64?
  let availability: String
}

struct IOSDuplicateGroup: Codable, Identifiable, Equatable, Sendable {
  let key: String
  let title: String
  let kind: String
  let year: Int?
  let items: [IOSDuplicateItem]
  var id: String { key }
}

struct IOSHealthOfflineTitle: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let kind: String
  let year: Int?
  let libraryName: String
  let fileName: String
  let lastSeenAt: String
  let daysOffline: Int
}

struct IOSUnmatchedTitle: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let kind: String
  let year: Int?
  let fileName: String
  let issueReason: String
}

// MARK: Metadata

struct IOSMetadataProvider: Codable, Equatable, Sendable {
  let enabled: Bool
  let hasToken: Bool
  let language: String
  let artworkBytes: Int64
  let artworkLimitBytes: Int64
  let provider: String
  let attribution: String
}

struct IOSMetadataJob: Codable, Identifiable, Equatable, Sendable {
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
      ? "\(itemsTotal) \(itemsTotal == 1 ? "title" : "titles") checked" : parts.joined(separator: ", ")
    switch state {
    case "completed": return "Done · " + detail
    case "cancelled": return "Stopped · " + detail
    default: return "Did not finish · " + (error ?? detail)
    }
  }
}

struct IOSMetadataCandidate: Codable, Identifiable, Equatable, Sendable {
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

struct IOSMetadataReview: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let mediaId: UUID
  let title: String
  let reason: String
  let state: String
  let candidates: [IOSMetadataCandidate]
  let updatedAt: String
}

struct IOSSubtitleProvider: Codable, Equatable, Sendable {
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

struct IOSUpdateSubtitleProvider: Codable, Equatable, Sendable {
  var enabled: Bool
  var languages: [String]
  var automatic: Bool
  var apiKey: String? = nil
  var accountName: String? = nil
  var accountPassword: String? = nil
}

// MARK: Server

struct IOSServerCapabilities: Codable, Equatable, Sendable {
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

struct IOSServerComponent: Codable, Identifiable, Equatable, Sendable {
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

struct IOSServerReadiness: Codable, Equatable, Sendable {
  let state: String
  let components: [IOSServerComponent]
  let checkedAt: String
}

struct IOSServerStatus: Codable, Equatable, Sendable {
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
  var readiness: IOSServerReadiness? = nil
}

struct IOSServerHealthScan: Codable, Equatable, Sendable {
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

struct IOSServerHealthJobs: Codable, Equatable, Sendable {
  let activeScans: Int
  let activeMetadataJobs: Int
  let activeScrubPreviewJobs: Int
}

struct IOSServerHealthEvent: Codable, Identifiable, Equatable, Sendable {
  var id: String { "\(at)-\(code)" }
  let at: String
  let code: String
  let severity: String
  let status: Int?
}

struct IOSServerHealthBackup: Codable, Equatable, Sendable {
  let enabled: Bool
  let lastAttemptFailed: Bool
  let lastSucceededAt: String?
  let totalBackups: Int
  let totalBackupBytes: Int64
}

struct IOSServerHealth: Codable, Equatable, Sendable {
  let uptimeSeconds: Double
  let freeDiskBytes: Int64?
  let databaseBytes: Int64
  let scrubPreviewTitleCount: Int
  let scrubPreviewBytes: Int64
  let scrubPreviewPendingCount: Int
  let activeLiveConversions: Int
  let activeStreams: Int
  let offlineMediaCount: Int
  let lastScan: IOSServerHealthScan?
  let backgroundJobs: IOSServerHealthJobs
  let recentIssues: [IOSServerHealthEvent]
  let backup: IOSServerHealthBackup?
}

/// What the server measured about itself (server 2.14.0).
struct IOSServerPerformance: Codable, Equatable, Sendable {
  let since: String
  let slowRequestMilliseconds: Int
  let slowQueryMilliseconds: Int
  let requests: Int64
  let p95Milliseconds: Double
  let endpoints: [IOSEndpointTiming]
  let slowQueries: [IOSSlowQuery]
}

struct IOSEndpointTiming: Codable, Identifiable, Equatable, Sendable {
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

struct IOSSlowQuery: Codable, Identifiable, Equatable, Sendable {
  var id: String { at + statement }
  let at: String
  let milliseconds: Double
  let kind: String
  let statement: String
  let endpoint: String?
  let warmUp: Bool
}

enum IOSPerformanceText {
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
struct IOSServerConfiguration: Codable, Equatable, Sendable {
  let stored: [String: IOSJSONValue]
  let active: IOSActiveNetwork
  let restartRequired: Bool
}

struct IOSActiveNetwork: Codable, Equatable, Sendable {
  let serverName: String
  let lanAccessEnabled: Bool
  let lanHttpsPort: Int
}

struct IOSServerBackup: Codable, Identifiable, Equatable, Sendable {
  var id: String { name }
  let name: String
  let kind: String
  let createdAt: String
  let bytes: Int64
}

struct IOSPreparedRestore: Codable, Equatable, Sendable {
  let id: UUID
  let serverId: UUID
  let revokesAllSessions: Bool
}

struct IOSDiagnosticEvent: Codable, Identifiable, Equatable, Sendable {
  var id: String { "\(at)-\(code)-\(userId?.uuidString ?? "")" }
  let at: String
  let code: String
  let severity: String
  let userId: UUID?
  let status: Int?
}

struct IOSServerJobs: Codable, Equatable, Sendable {
  let scans: [IOSLibraryScan]
  let metadata: [IOSMetadataJob]
}

struct IOSHostOperation: Codable, Equatable, Sendable {
  let id: UUID
  let kind: String
  let state: String
  let confirmBefore: String?
  let httpsPort: Int?
}

struct IOSServerUpdateStatus: Codable, Equatable, Sendable {
  let available: Bool
  let installed: String
  let newest: String?
  let updateAvailable: Bool
  let state: String
  let checkedAt: String?
  let message: String?
}

struct IOSServerPower: Codable, Equatable, Sendable {
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

struct IOSScrubPreviewSettings: Codable, Equatable, Sendable {
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

struct IOSUpdateScrubPreviews: Codable, Equatable, Sendable {
  var mode: String
  var intervalSeconds: Int
  var storageCapMegabytes: Int
}

struct IOSSegmentSettings: Codable, Equatable, Sendable {
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

struct IOSSegmentSeries: Codable, Identifiable, Equatable, Sendable {
  let seriesId: UUID
  let title: String
  let episodeCount: Int
  let withIntro: Int
  let withCredits: Int
  let pendingCount: Int
  var id: UUID { seriesId }
}

struct IOSSpeechModelChoice: Codable, Identifiable, Equatable, Sendable {
  let name: String
  let label: String
  let bytes: Int64
  let description: String
  var id: String { name }
}

struct IOSSpeechModelDownload: Codable, Equatable, Sendable {
  let name: String
  let receivedBytes: Int64
  let totalBytes: Int64
}

struct IOSServerSpeechJob: Codable, Equatable, Sendable {
  let mediaId: UUID
  let title: String
  let kind: String
  let language: String
  let state: String
  let progress: Double
  let pausedForPlayback: Bool
  let message: String?
}

struct IOSServerSpeech: Codable, Equatable, Sendable {
  let available: Bool
  let model: String?
  let modelBytes: Int64
  let downloading: IOSSpeechModelDownload?
  let downloadError: String?
  let models: [IOSSpeechModelChoice]
  let jobs: [IOSServerSpeechJob]
}

struct IOSTranscodingSession: Codable, Equatable, Sendable {
  let title: String
  let quality: String
  let encoder: String?
  let speed: Double?
  let converting: Bool
}

struct IOSTranscodingStatus: Codable, Equatable, Sendable {
  let available: Bool
  let encoder: String?
  let encoderName: String
  let device: String?
  let hardwareDecoding: Bool
  let hardwareResting: Bool
  let runningConversions: Int
  let videoLimit: Int
  let sessions: [IOSTranscodingSession]
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
enum IOSAdminText {
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
