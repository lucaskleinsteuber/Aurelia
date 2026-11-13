import CryptoKit
import Foundation

// The rules behind Settings › Server Administration, kept free of UIKit so the logic tests run
// them on macOS. They follow the browser's logic.js and the Mac app.

/// A protected change: the server answers `approval_required`, the app asks for a one-time
/// approval of exactly this method, address and body, and sends the request again once. A
/// missing approval is refused before anything changes, so the single retry is safe.
enum IOSApprovalExecutor {
  static func execute(
    send: (_ approval: String?) async throws -> Data,
    approve: () async throws -> String
  ) async throws -> Data {
    do {
      return try await send(nil)
    } catch let failure as IOSCoreError where failure.isApprovalRequired {
      try Task.checkCancellation()
      let proof = try await approve()
      try Task.checkCancellation()
      return try await send(proof)
    }
  }

  /// The action the server checks: the method and the target exactly as sent, query included.
  static func action(method: String, url: URL) throws -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      !components.percentEncodedPath.isEmpty
    else { throw IOSCoreError.invalidRequest }
    let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
    return method + " " + components.percentEncodedPath + query
  }

  /// SHA-256 of the body as lowercase hex; an empty body hashes the empty string.
  static func payloadHash(_ body: Data?) -> String {
    SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
  }
}

extension IOSCoreError {
  /// Server management is locked: the Server Password unlocks it for ten minutes.
  var isManagementLocked: Bool { code == "management_locked" }
  var isApprovalRequired: Bool { statusCode == 403 && code == "approval_required" }
}

/// One whole-number setting of the owner's server policy, as Settings › Server shows it.
struct IOSPolicyField: Identifiable, Equatable, Sendable {
  enum Group: String, Sendable { case limits, maintenance, backups, events }
  let key: String
  let label: String
  let unit: String
  let range: ClosedRange<Int>
  let step: Int
  let group: Group
  var id: String { key }
}

/// The owner's server policy: the same fields and limits as the browser and the server.
enum IOSServerPolicy {
  static let fields: [IOSPolicyField] = [
    .init(
      key: "deviceSessionDays", label: "Keep New Devices Signed In", unit: "days", range: 1...365,
      step: 1, group: .limits),
    .init(
      key: "globalStreamLimit", label: "Streams at the Same Time, in Total", unit: "streams",
      range: 1...128, step: 1, group: .limits),
    .init(
      key: "userStreamLimit", label: "Streams at the Same Time, per Profile", unit: "streams",
      range: 1...16, step: 1, group: .limits),
    .init(
      key: "reconciliationMinutes", label: "Full Check Every", unit: "minutes", range: 15...10080,
      step: 15, group: .maintenance),
    .init(
      key: "maintenanceStartHour", label: "Maintenance From", unit: ":00", range: 0...23, step: 1,
      group: .maintenance),
    .init(
      key: "maintenanceEndHour", label: "Maintenance Until", unit: ":00", range: 1...24, step: 1,
      group: .maintenance),
    .init(
      key: "jobQueueLimit", label: "Maximum Waiting Tasks", unit: "tasks", range: 10...10000,
      step: 10, group: .maintenance),
    .init(
      key: "backupIntervalHours", label: "Automatic Backup Every", unit: "hours", range: 1...168,
      step: 1, group: .backups),
    .init(
      key: "dailyBackupsRetained", label: "Daily Backups Kept", unit: "backups", range: 1...30,
      step: 1, group: .backups),
    .init(
      key: "weeklyBackupsRetained", label: "Weekly Backups Kept", unit: "backups", range: 1...12,
      step: 1, group: .backups),
    .init(
      key: "eventRetentionDays", label: "Keep Events For", unit: "days", range: 1...90, step: 1,
      group: .events),
    .init(
      key: "maximumEvents", label: "Maximum Events", unit: "events", range: 100...10000,
      step: 100, group: .events),
  ]

  /// Switches the settings screens change besides the numbers.
  static let toggles: [(key: String, label: String)] = [
    ("pairingEnabled", "Allow New Devices"),
    ("monitoringEnabled", "Watch Storage for Changes"),
    ("automaticBackupsEnabled", "Automatic Backups"),
  ]

  static func value(_ stored: [String: IOSJSONValue], _ key: String) -> Int? { stored[key]?.int }

  /// The stored policy with `changes` applied, every number kept inside its range, and the
  /// problem that would make the server refuse it, if any.
  static func draft(
    stored: [String: IOSJSONValue], numbers: [String: Int] = [:], switches: [String: Bool] = [:]
  ) -> (draft: [String: IOSJSONValue], problem: String?) {
    var draft = stored
    for field in fields {
      guard let value = numbers[field.key] ?? stored[field.key]?.int else { continue }
      draft[field.key] = .number(Double(min(field.range.upperBound, max(field.range.lowerBound, value))))
    }
    for (key, value) in switches { draft[key] = .bool(value) }
    if let user = draft["userStreamLimit"]?.int, let total = draft["globalStreamLimit"]?.int,
      user > total
    {
      return (draft, "Streams per profile can't be more than streams in total.")
    }
    if let start = draft["maintenanceStartHour"]?.int, let end = draft["maintenanceEndHour"]?.int,
      start == end
    {
      return (draft, "Maintenance needs to start and end at different hours.")
    }
    return (draft, nil)
  }
}

/// What the server does when nobody uses Aurelia (Settings › Power).
struct IOSPowerMode: Identifiable, Equatable, Sendable {
  let id: String
  let label: String
  let explanation: String
}

enum IOSPowerRules {
  static let idleChoices = [5, 10, 15, 30, 45, 60, 90, 120, 180]

  static func hostedByApp(_ hosting: String?) -> Bool {
    hosting == "macApp" || hosting == "linuxApp"
  }

  /// "Mac" or "Linux PC" for a server inside the Aurelia app, otherwise nil.
  static func appHostName(_ hosting: String?) -> String? {
    hosting == "macApp" ? "Mac" : hosting == "linuxApp" ? "Linux PC" : nil
  }

  static func modes(for power: IOSServerPower) -> [IOSPowerMode] {
    if let computer = appHostName(power.hosting) {
      return [
        .init(
          id: "off", label: "Keep Running",
          explanation:
            "Aurelia Server runs as long as the Aurelia app does. While the \(computer) sleeps or is turned off, other devices show “Start Aurelia on your \(computer)”."
        ),
        .init(
          id: "stop", label: "Stop Aurelia Server",
          explanation:
            "Aurelia Server stops, and the \(computer) may sleep as usual. Opening Aurelia there starts it again. Nothing can wake it over the network."
        ),
      ]
    }
    return [
      .init(
        id: "off", label: "Keep Running",
        explanation: "Aurelia and the computer keep running: ready at any moment, using the most power."),
      .init(
        id: "stop", label: "Stop Only Aurelia Server",
        explanation:
          "Only Aurelia stops. The computer stays on, and Aurelia starts again within seconds when any device connects."
      ),
      .init(
        id: "sleep", label: "Put the Computer to Sleep",
        explanation:
          "The whole computer sleeps: fans and disks stop, and it uses only a few watts. This iPhone wakes it with Wake-on-LAN when you open Aurelia, in about 10 to 20 seconds. Usually the best choice."
      ),
      .init(
        id: "shutdown", label: "Shut Down the Computer",
        explanation:
          "The computer turns off and uses almost nothing. Wake-on-LAN starts it again, which takes 30 to 60 seconds because the whole computer starts up, and only if its BIOS allows Wake-on-LAN while it is off (see the check below)."
      ),
    ]
  }

  struct WakeCheckItem: Equatable, Sendable {
    enum State: Equatable, Sendable { case ok, warning, problem, info }
    let state: State
    let title: String
    let detail: String
  }

  static let wakeCheckFooter =
    "Most desktop PCs connected by cable wake from sleep, even old ones. Waking from off also needs the BIOS setting. Wi-Fi, many laptops and some USB network adapters can't be woken."

  /// Settings › Power › Wake-on-LAN Check for the chosen mode: what the server found about its
  /// network card, connection and sleep, what only a test shows, and what to change. Nil where
  /// nothing wakes over the network. Same items and words as the Mac app and the browser.
  static func wakeCheck(_ power: IOSServerPower, mode: String? = nil) -> [WakeCheckItem]? {
    let mode = mode ?? power.mode
    guard power.available, !hostedByApp(power.hosting), mode == "sleep" || mode == "shutdown" else { return nil }
    var items: [WakeCheckItem] = []
    func add(_ state: WakeCheckItem.State, _ title: String, _ detail: String) {
      items.append(WakeCheckItem(state: state, title: title, detail: detail))
    }
    let network = power.network ?? "", wakeOn = power.wakeOn ?? "", support = power.wakeSupport ?? ""
    switch network {
    case "wired":
      add(.ok, "Connected by cable", "Wake-on-LAN needs a network cable to the router, and this computer has one.")
    case "wifi":
      add(.problem, "Connected by Wi-Fi", "Almost no computer wakes over Wi-Fi. Connect it to the router with a network cable.")
    case "": break
    default:
      add(.info, "Connection not recognized", "Wake-on-LAN needs a network cable to the router; Aurelia couldn't tell how this computer is connected.")
    }
    if !support.isEmpty && !support.contains("g") {
      add(.problem, "The network card can't wake the computer", "Choose “Stop Only Aurelia Server” instead, or add a network card or USB network adapter that supports Wake-on-LAN.")
    } else if wakeOn.contains("g") {
      add(.ok, "Wake-on-LAN is on", "The network card wakes the computer when it gets a Wake-on-LAN call.")
    } else if !wakeOn.isEmpty {
      add(.warning, "Wake-on-LAN is off right now", "Aurelia switches it on at every start and before powering down. If waking fails, restart the computer once.")
    } else {
      add(.info, "Network card not checked yet", "The server checks its network card when the computer starts. Restart it once, or update Aurelia Server, to see it here.")
    }
    if mode == "sleep" {
      switch power.sleepKind ?? "" {
      case "deep":
        add(.ok, "Real sleep", "Fans and disks stop, it uses only a few watts, and waking takes about 10 to 20 seconds.")
      case "light":
        add(.warning, "Only light sleep", "This computer offers only a lighter sleep (s2idle). It may use more power, and some network cards can't wake it. Try it once.")
      case "none":
        add(.problem, "This computer can't sleep", "Choose “Shut Down the Computer” or “Stop Only Aurelia Server” instead.")
      default: break
      }
    } else {
      add(.info, "Waking from off needs the BIOS", "Aurelia can't check this from here. Open the BIOS setup (usually Del or F2 right after switching on), turn on “Wake on LAN”, “Power On By PCI-E” or “Resume by LAN”, and turn off “ErP” or “Deep Sleep”. Starting takes 30 to 60 seconds, because the whole computer starts up; waking from sleep is much faster.")
    }
    add(.info, "Try it once", "Let the server power down, then open Aurelia on a Mac, Linux PC or iPhone: it sends the Wake-on-LAN call and connects once the server is back. If it stays off, its power button starts it as usual.")
    return items
  }

  /// Wake When a Device Connects matters only while the computer sleeps or is off, and only on a
  /// network card that can wake on a direct packet.
  static func offersWakeOnAccess(_ power: IOSServerPower, mode: String? = nil) -> Bool {
    let mode = mode ?? power.mode
    return !hostedByApp(power.hosting) && (mode == "sleep" || mode == "shutdown")
      && (power.wakeSupport ?? "").contains("u")
  }

  struct Payload: Codable, Equatable, Sendable {
    let mode: String
    let idleMinutes: Int
    let awakeFrom: String?
    let awakeUntil: String?
    let afterSleepTimer: Bool
    let wakeOnAccess: Bool?
  }

  enum Problem: Error, Equatable, LocalizedError {
    case mode, idleMinutes, awakeTimes, sameAwakeTimes
    var errorDescription: String? {
      switch self {
      case .mode: "Choose what the server does when unused."
      case .idleMinutes: "Choose between 5 and 1440 minutes."
      case .awakeTimes: "Enter both times of the awake hours."
      case .sameAwakeTimes: "The awake hours need a different start and end."
      }
    }
  }

  /// The request for Settings › Power, or the problem to fix first.
  static func payload(
    for draft: IOSServerPower, awakeHours: Bool, server power: IOSServerPower
  ) throws -> Payload {
    guard modes(for: power).contains(where: { $0.id == draft.mode }) else { throw Problem.mode }
    guard (5...1440).contains(draft.idleMinutes) else { throw Problem.idleMinutes }
    var from: String?
    var until: String?
    if awakeHours {
      from = draft.awakeFrom.map { String($0.prefix(5)) }
      until = draft.awakeUntil.map { String($0.prefix(5)) }
      guard let start = from, let end = until, isTime(start), isTime(end) else {
        throw Problem.awakeTimes
      }
      guard start != end else { throw Problem.sameAwakeTimes }
    }
    // A card that can't do it never gets asked; nil keeps the server's stored choice.
    let wake =
      !hostedByApp(power.hosting) && (power.wakeSupport ?? "").contains("u")
      ? draft.wakeOnAccess ?? false : nil
    return Payload(
      mode: draft.mode, idleMinutes: draft.idleMinutes, awakeFrom: from, awakeUntil: until,
      afterSleepTimer: draft.afterSleepTimer ?? true, wakeOnAccess: wake)
  }

  static func isTime(_ value: String) -> Bool {
    let parts = value.split(separator: ":")
    guard value.count == 5, parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1])
    else { return false }
    return (0...23).contains(hour) && (0...59).contains(minute)
  }
}

/// The rules for a profile edited in Settings › Profiles and Devices.
enum IOSProfileRules {
  static let roles = ["user", "admin"]
  static let ageLimits: [Int?] = [nil, 0, 6, 12, 16]

  static func ageTitle(_ limit: Int?) -> String {
    guard let limit else { return "No Age Limit" }
    return "FSK \(limit)"
  }

  /// An administrator always needs a PIN; a viewer may go without. A new PIN must be valid; an
  /// unchanged profile keeps its PIN.
  static func canSave(role: String, protection: Bool, newPIN: String, hasPIN: Bool) -> Bool {
    if role == "owner" || role == "admin", !protection { return false }
    guard protection else { return newPIN.isEmpty }
    return newPIN.isEmpty ? hasPIN : IOSProfilePIN.isValid(newPIN)
  }

  /// A profile name, as the server accepts it: 1 to 64 visible characters.
  static func isValidName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return (1...64).contains(trimmed.count)
      && !trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}

/// A Server Password typed on this device: never stored, only sent once to unlock management.
enum IOSServerPassword {
  static func isPlausible(_ password: String) -> Bool {
    !password.isEmpty && password.count <= 1024
  }
}

/// Corrections in an import preview, with the browser's rules (logic.js).
enum IOSImportRules {
  struct Choice: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
  }
  static let all: [Choice] = [
    .init(id: "movie", label: "Movie"), .init(id: "series", label: "TV Show · Force Import"),
    .init(id: "episode", label: "Episode"), .init(id: "extra", label: "Extra"),
    .init(id: "trailer", label: "Trailer"), .init(id: "ignore", label: "Ignore"),
  ]

  /// A TV show only for folders, an episode only for one file.
  static func choices(for items: [IOSImportPreviewItem]) -> [Choice] {
    let folders = !items.isEmpty && items.allSatisfy(\.isDirectory)
    let oneFile = items.count == 1 && !items[0].isDirectory
    return all.filter { ($0.id != "series" || folders) && ($0.id != "episode" || oneFile) }
  }

  struct Form: Equatable, Sendable {
    var choice = "extra"
    var parentPath = ""
    var entireSeries = true
    var season = 1
    var episode = 1
    var category = ""
    var title = ""

    init() {}
    init(start items: [IOSImportPreviewItem]) {
      let first = items.first
      choice = all.contains { $0.id == first?.kind } ? first?.kind ?? "extra" : "extra"
      parentPath = first?.parentRelativePath ?? ""
      entireSeries = first?.seasonNumber == nil
      season = first?.seasonNumber ?? 1
      episode = first?.episodeNumber ?? 1
      category = first?.category ?? ""
      title = items.count == 1 && first?.isDirectory == false ? first?.title ?? "" : ""
    }
  }

  enum Problem: Error, Equatable, LocalizedError {
    case parent, episodeNeedsSeries, oneFile, episodeNumber, seasonNumber
    var errorDescription: String? {
      switch self {
      case .parent: "Choose the movie or series this belongs to."
      case .episodeNeedsSeries: "An episode belongs to a series."
      case .oneFile: "Choose one file for an episode."
      case .episodeNumber: "Enter an episode number from 1 to 999."
      case .seasonNumber: "Enter a season number from 0 to 99."
      }
    }
  }

  static func changes(
    items: [IOSImportPreviewItem], form: Form, targets: [IOSImportPreviewTarget]
  ) throws -> [IOSImportAssignment] {
    let needsParent = ["episode", "extra", "trailer"].contains(form.choice)
    let parent = needsParent ? targets.first { $0.relativePath == form.parentPath } : nil
    if needsParent && parent == nil { throw Problem.parent }
    let bySeason = form.choice == "episode" || (parent?.kind == "series" && !form.entireSeries)
    if form.choice == "episode" {
      guard parent?.kind == "series" else { throw Problem.episodeNeedsSeries }
      guard items.count == 1, !items[0].isDirectory else { throw Problem.oneFile }
      guard (1...999).contains(form.episode) else { throw Problem.episodeNumber }
    }
    if bySeason && !(0...99).contains(form.season) { throw Problem.seasonNumber }
    let oneFile = items.count == 1 && !items[0].isDirectory
    let category = form.category.trimmingCharacters(in: .whitespaces)
    let title = form.title.trimmingCharacters(in: .whitespaces)
    return items.map { item in
      IOSImportAssignment(
        relativePath: item.relativePath, isDirectory: item.isDirectory,
        kind: form.choice == "ignore" ? nil : form.choice,
        parentRelativePath: needsParent ? form.parentPath : nil,
        seasonNumber: bySeason ? form.season : nil,
        episodeNumber: form.choice == "episode" ? form.episode : nil,
        category: needsParent && !category.isEmpty ? category : nil,
        title: oneFile && !title.isEmpty ? title : nil)
    }
  }
}
