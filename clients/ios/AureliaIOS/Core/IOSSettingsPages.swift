import Foundation

/// The pages of the Settings tab. On iPhone each is a row that opens it; on iPad they form the
/// sidebar and the chosen one shows beside it. Every page says in one line what it is for.
enum IOSSettingsPage: String, Hashable, Identifiable, CaseIterable, Sendable {
  // You
  case nameAndPicture, playback, profilePIN, history, statistics, wishes, downloads
  // Server (owner and administrators)
  case library, metadata, people, security, server, power, smartHome, updates
  // This device
  case device, about
  // Connection
  case connection

  var id: String { rawValue }

  enum Group: String, CaseIterable, Sendable {
    case you, server, device, connection

    var title: String {
      switch self {
      case .you: "You"
      case .server: "Server"
      case .device: "This Device"
      case .connection: "Connection"
      }
    }
  }

  var group: Group {
    switch self {
    case .nameAndPicture, .playback, .profilePIN, .history, .statistics, .wishes, .downloads: .you
    case .library, .metadata, .people, .security, .server, .power, .smartHome, .updates: .server
    case .device, .about: .device
    case .connection: .connection
    }
  }

  var title: String {
    switch self {
    case .nameAndPicture: "Name and Picture"
    case .playback: "Playback"
    case .profilePIN: "Profile PIN"
    case .history: "Watch History"
    case .statistics: "Statistics"
    case .wishes: "Family Wishes"
    case .downloads: "Downloads"
    case .library: "Library"
    case .metadata: "Metadata"
    case .people: "Profiles and Devices"
    case .security: "Security"
    case .server: "Server"
    case .power: "Power"
    case .smartHome: "Smart Home"
    case .updates: "Server Updates"
    case .device: "Notifications and Storage"
    case .about: "About Aurelia"
    case .connection: "Connection"
    }
  }

  var systemImage: String {
    switch self {
    case .nameAndPicture: "person.crop.circle"
    case .playback: "play.rectangle"
    case .profilePIN: "lock"
    case .history: "clock.arrow.circlepath"
    case .statistics: "chart.bar"
    case .wishes: "sparkles"
    case .downloads: "arrow.down.circle"
    case .library: "externaldrive"
    case .metadata: "text.badge.star"
    case .people: "person.2"
    case .security: "lock.shield"
    case .server: "server.rack"
    case .power: "bolt"
    case .smartHome: "house"
    case .updates: "arrow.down.circle.dotted"
    case .device: "bell.badge"
    case .about: "info.circle"
    case .connection: "network"
    }
  }

  /// One line under the title that says what the page is for.
  var subtitle: String {
    switch self {
    case .nameAndPicture: "How your profile appears"
    case .playback: "Subtitles, audio, quality and skipping"
    case .profilePIN: "Who can open your profile"
    case .history: "What you watched and when"
    case .statistics: "Your viewing in numbers"
    case .wishes: "Movies and shows the family wants"
    case .downloads: "Titles stored for watching offline"
    case .library: "Storage locations, scans and import review"
    case .metadata: "Posters, descriptions and subtitles"
    case .people: "Profiles, new devices and sign-ins"
    case .security: "Sign-in log, Face ID and blocked devices"
    case .server: "Health, features, backups and network"
    case .power: "Sleep, shut down and Wake-on-LAN"
    case .smartHome: "Home Assistant, webhooks and keys"
    case .updates: "Install a newer server version"
    case .device: "Alerts and stored artwork"
    case .about: "Version, licenses and privacy"
    case .connection: "This server, waking it and disconnecting"
    }
  }

  /// What a profile may see. Power and Updates always show for the owner: when the server
  /// can't use them, the page says why instead of the row disappearing.
  struct Visibility: Equatable, Sendable {
    var permissions: IOSAdminPermissions
    var supportsWishes = false
    var supportsPersonalization = false
    var supportsSecurity = false
    var supportsAutomation = false

    func shows(_ page: IOSSettingsPage) -> Bool {
      switch page {
      case .nameAndPicture: supportsPersonalization
      case .wishes: supportsWishes
      case .library: permissions.storage
      case .metadata, .people: permissions.administrator
      case .security: permissions.owner && supportsSecurity
      case .smartHome: permissions.owner && supportsAutomation
      case .server, .power, .updates: permissions.owner
      default: true
      }
    }

    func pages(in group: Group) -> [IOSSettingsPage] {
      IOSSettingsPage.allCases.filter { $0.group == group && shows($0) }
    }
  }
}

/// Why a server feature can't be changed from here, in plain words.
enum IOSUnavailableReason {
  static func power(hosting: String?) -> String {
    switch hosting {
    case "macApp":
      "The Mac that hosts this server decides when it runs. Change it in Aurelia on that Mac."
    case "linuxApp":
      "The Linux computer that hosts this server decides when it runs. Change it in Aurelia there."
    default:
      "This server can’t sleep or turn off by itself. Power settings work when Aurelia Server is installed as a Linux package or runs in the Mac or Linux app."
    }
  }

  static let updates =
    "This server is updated together with the app or package it runs in, not from here. On a Linux package use “sudo aurelia update”; a server in the Mac or Linux app updates with that app."
}

/// The Server page's health in a few words, so the details can stay folded away.
enum IOSServerHealthText {
  static func isHealthy(_ health: IOSServerHealth, status: IOSServerStatus) -> Bool {
    let ready = (status.readiness?.components ?? []).allSatisfy {
      $0.state == "ready" || $0.state == "ok"
    }
    return ready && health.recentIssues.isEmpty && health.backup?.lastAttemptFailed != true
  }

  /// "Running for 3 days · 1.2 TB free · 2 problems this week".
  static func summary(_ health: IOSServerHealth) -> String {
    var parts = ["Running for \(IOSAdminText.uptime(health.uptimeSeconds))"]
    if let free = health.freeDiskBytes { parts.append("\(IOSAdminText.bytes(free)) free") }
    if !health.recentIssues.isEmpty {
      parts.append(
        "\(health.recentIssues.count) recent \(health.recentIssues.count == 1 ? "problem" : "problems")")
    }
    if health.backup?.lastAttemptFailed == true { parts.append("last backup failed") }
    return parts.joined(separator: " · ")
  }
}
