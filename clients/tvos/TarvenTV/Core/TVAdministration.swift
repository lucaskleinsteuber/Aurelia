import CryptoKit
import Foundation

// The rules behind Settings › Server Administration, kept free of UIKit so the logic tests run
// them on macOS. They follow the browser's logic.js and the Mac app.

/// A protected change: the server answers `approval_required`, the app asks for a one-time
/// approval of exactly this method, address and body, and sends the request again once. A
/// missing approval is refused before anything changes, so the single retry is safe.
enum TVApprovalExecutor {
  static func execute(
    send: (_ approval: String?) async throws -> Data,
    approve: () async throws -> String
  ) async throws -> Data {
    do {
      return try await send(nil)
    } catch let failure as TVCoreError where failure.isApprovalRequired {
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
    else { throw TVCoreError.invalidRequest }
    let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
    return method + " " + components.percentEncodedPath + query
  }

  /// SHA-256 of the body as lowercase hex; an empty body hashes the empty string.
  static func payloadHash(_ body: Data?) -> String {
    SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
  }
}

extension TVCoreError {
  /// Server management is locked: the Server Password unlocks it for ten minutes.
  var isManagementLocked: Bool { code == "management_locked" }
  var isApprovalRequired: Bool { statusCode == 403 && code == "approval_required" }
}

/// One whole-number setting of the owner's server policy, as Settings › Server shows it.
struct TVPolicyField: Identifiable, Equatable, Sendable {
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
enum TVServerPolicy {
  static let fields: [TVPolicyField] = [
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

  static func value(_ stored: [String: TVJSONValue], _ key: String) -> Int? { stored[key]?.int }

  /// The stored policy with `changes` applied, every number kept inside its range, and the
  /// problem that would make the server refuse it, if any.
  static func draft(
    stored: [String: TVJSONValue], numbers: [String: Int] = [:], switches: [String: Bool] = [:]
  ) -> (draft: [String: TVJSONValue], problem: String?) {
    var draft = stored
    for field in fields {
      guard let value = numbers[field.key] ?? stored[field.key]?.int else { continue }
      draft[field.key] = .number(
        Double(min(field.range.upperBound, max(field.range.lowerBound, value))))
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

/// What the server does when nobody uses Tarven (Settings › Power).
struct TVPowerMode: Identifiable, Equatable, Sendable {
  let id: String
  let label: String
  let explanation: String
}

enum TVPowerRules {
  static let idleChoices = [5, 10, 15, 30, 45, 60, 90, 120, 180]

  static func hostedByApp(_ hosting: String?) -> Bool {
    hosting == "macApp" || hosting == "linuxApp"
  }

  /// "Mac" or "Linux PC" for a server inside the Tarven app, otherwise nil.
  static func appHostName(_ hosting: String?) -> String? {
    hosting == "macApp" ? "Mac" : hosting == "linuxApp" ? "Linux PC" : nil
  }

  static func modes(for power: TVServerPower) -> [TVPowerMode] {
    if let computer = appHostName(power.hosting) {
      return [
        .init(
          id: "off", label: "Keep Running",
          explanation:
            "Tarven Server runs as long as the Tarven app does. While the \(computer) sleeps or is turned off, other devices show “Start Tarven on your \(computer)”."
        ),
        .init(
          id: "stop", label: "Stop Tarven Server",
          explanation:
            "Tarven Server stops, and the \(computer) may sleep as usual. Opening Tarven there starts it again. Nothing can wake it over the network."
        ),
      ]
    }
    return [
      .init(
        id: "off", label: "Keep Running",
        explanation:
          "Tarven and the computer keep running: ready at any moment, using the most power."),
      .init(
        id: "stop", label: "Stop Only Tarven Server",
        explanation:
          "Only Tarven stops. The computer stays on, and Tarven starts again within seconds when any device connects."
      ),
      .init(
        id: "sleep", label: "Put the Computer to Sleep",
        explanation:
          "The whole computer sleeps: fans and disks stop, and it uses only a few watts. This Apple TV wakes it with Wake-on-LAN when you open Tarven, in about 10 to 20 seconds. Usually the best choice."
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
  static func wakeCheck(_ power: TVServerPower, mode: String? = nil) -> [WakeCheckItem]? {
    let mode = mode ?? power.mode
    guard power.available, !hostedByApp(power.hosting), mode == "sleep" || mode == "shutdown" else {
      return nil
    }
    var items: [WakeCheckItem] = []
    func add(_ state: WakeCheckItem.State, _ title: String, _ detail: String) {
      items.append(WakeCheckItem(state: state, title: title, detail: detail))
    }
    let network = power.network ?? ""
    let wakeOn = power.wakeOn ?? ""
    let support = power.wakeSupport ?? ""
    switch network {
    case "wired":
      add(
        .ok, "Connected by cable",
        "Wake-on-LAN needs a network cable to the router, and this computer has one.")
    case "wifi":
      add(
        .problem, "Connected by Wi-Fi",
        "Almost no computer wakes over Wi-Fi. Connect it to the router with a network cable.")
    case "": break
    default:
      add(
        .info, "Connection not recognized",
        "Wake-on-LAN needs a network cable to the router; Tarven couldn't tell how this computer is connected."
      )
    }
    if !support.isEmpty && !support.contains("g") {
      add(
        .problem, "The network card can't wake the computer",
        "Choose “Stop Only Tarven Server” instead, or add a network card or USB network adapter that supports Wake-on-LAN."
      )
    } else if wakeOn.contains("g") {
      add(
        .ok, "Wake-on-LAN is on",
        "The network card wakes the computer when it gets a Wake-on-LAN call.")
    } else if !wakeOn.isEmpty {
      add(
        .warning, "Wake-on-LAN is off right now",
        "Tarven switches it on at every start and before powering down. If waking fails, restart the computer once."
      )
    } else {
      add(
        .info, "Network card not checked yet",
        "The server checks its network card when the computer starts. Restart it once, or update Tarven Server, to see it here."
      )
    }
    if mode == "sleep" {
      switch power.sleepKind ?? "" {
      case "deep":
        add(
          .ok, "Real sleep",
          "Fans and disks stop, it uses only a few watts, and waking takes about 10 to 20 seconds.")
      case "light":
        add(
          .warning, "Only light sleep",
          "This computer offers only a lighter sleep (s2idle). It may use more power, and some network cards can't wake it. Try it once."
        )
      case "none":
        add(
          .problem, "This computer can't sleep",
          "Choose “Shut Down the Computer” or “Stop Only Tarven Server” instead.")
      default: break
      }
    } else {
      add(
        .info, "Waking from off needs the BIOS",
        "Tarven can't check this from here. Open the BIOS setup (usually Del or F2 right after switching on), turn on “Wake on LAN”, “Power On By PCI-E” or “Resume by LAN”, and turn off “ErP” or “Deep Sleep”. Starting takes 30 to 60 seconds, because the whole computer starts up; waking from sleep is much faster."
      )
    }
    add(
      .info, "Try it once",
      "Let the server power down, then open Tarven on a Mac, Linux PC or iPhone: it sends the Wake-on-LAN call and connects once the server is back. If it stays off, its power button starts it as usual."
    )
    return items
  }

  /// Wake When a Device Connects matters only while the computer sleeps or is off, and only on a
  /// network card that can wake on a direct packet.
  static func offersWakeOnAccess(_ power: TVServerPower, mode: String? = nil) -> Bool {
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
    for draft: TVServerPower, awakeHours: Bool, server power: TVServerPower
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

  /// The time pickers show these defaults as soon as awake hours are enabled. Store the same
  /// values in the draft so saving without moving either picker sends what the person sees.
  static func withDefaultAwakeHours(_ power: TVServerPower) -> TVServerPower {
    var draft = power
    draft.awakeFrom = draft.awakeFrom ?? "07:00"
    draft.awakeUntil = draft.awakeUntil ?? "23:00"
    return draft
  }

  static func isTime(_ value: String) -> Bool {
    let parts = value.split(separator: ":")
    guard value.count == 5, parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1])
    else { return false }
    return (0...23).contains(hour) && (0...59).contains(minute)
  }
}

/// The rules for a profile edited in Settings › Profiles and Devices.
enum TVProfileRules {
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
    return newPIN.isEmpty ? hasPIN : TVProfilePIN.isValid(newPIN)
  }

  /// A profile name, as the server accepts it: 1 to 64 visible characters.
  static func isValidName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return (1...64).contains(trimmed.count)
      && !trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}

/// A Server Password typed on this device: never stored, only sent once to unlock management.
enum TVServerPassword {
  static func isPlausible(_ password: String) -> Bool {
    !password.isEmpty && password.count <= 1024
  }
}

/// Speech status retains completed jobs. Only these server states still need progress reads.
enum TVAdminPollingRules {
  static func speechJobIsActive(_ state: String) -> Bool {
    ["waiting", "listening", "saving"].contains(state)
  }
}

enum TVScreenTimeAdminText {
  /// "45 min", "1 h", "2 h 30 min".
  static func minutes(_ value: Int) -> String {
    if value < 60 { return "\(value) min" }
    return value % 60 == 0 ? "\(value / 60) h" : "\(value / 60) h \(value % 60) min"
  }
}
