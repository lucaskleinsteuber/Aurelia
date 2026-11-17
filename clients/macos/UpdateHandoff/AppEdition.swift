import Foundation

/// Which Aurelia this build is: the real app, or "Aurelia Test" — a separate app with its own bundle
/// identifier, App Group, Keychain entry and launch agents, built with AURELIA_TEST_EDITION=1 for trying
/// the first run again and again. The test edition never updates itself or touches the real app.
enum AppEdition {
  #if AURELIA_TEST_EDITION
    static let isTest = true
  #else
    static let isTest = false
  #endif

  static let bundleIdentifier = isTest ? "com.lucas.aurelia.media.test" : "com.lucas.aurelia.media"
  /// The App Group the app shares with its server helper. Its prefix is the signing team, which
  /// the build writes into both Info.plists (AureliaAppGroup); someone who builds Aurelia with
  /// their own Apple ID gets their team's group. Without the key, the owner's group.
  static let appGroup = appGroup(
    declared: Bundle.main.object(forInfoDictionaryKey: "AureliaAppGroup"))

  static func appGroup(declared: Any?) -> String {
    let suffix = isTest ? ".com.lucas.aurelia.media.test.host" : ".com.lucas.aurelia.media.host"
    if let declared = declared as? String, declared.hasSuffix(suffix),
      declared.count == 10 + suffix.count
    {
      return declared
    }
    return "B5N7JVK37J" + suffix
  }
  static let displayName = isTest ? "Aurelia Test" : "Aurelia"
  /// The launch agents of the bundled server host: "<identifier>.host.background" and ".host.login".
  static func agentName(startAtLogin: Bool) -> String {
    bundleIdentifier + (startAtLogin ? ".host.login" : ".host.background")
  }
}
