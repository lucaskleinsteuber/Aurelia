import Foundation

/// This app's own random identifier, sent as `X-Aurelia-Installation` so the owner can tell its
/// devices apart in Settings › Security and block one. It identifies an installation, not a person.
enum AureliaInstallation {
  static let defaultsKey = "AureliaMacInstallationId"

  static func identifier(defaults: UserDefaults = .standard) -> String {
    if let saved = defaults.string(forKey: defaultsKey), UUID(uuidString: saved) != nil { return saved }
    let created = UUID().uuidString
    defaults.set(created, forKey: defaultsKey)
    return created
  }

  /// "macos/2.15.0".
  static var clientHeader: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    return "macos/" + version.filter { $0.isNumber || $0 == "." }
  }
}
