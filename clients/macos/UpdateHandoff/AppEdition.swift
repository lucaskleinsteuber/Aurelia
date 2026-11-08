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
  static let appGroup =
    isTest ? "B5N7JVK37J.com.lucas.aurelia.media.test.host" : "B5N7JVK37J.com.lucas.aurelia.media.host"
  static let displayName = isTest ? "Aurelia Test" : "Aurelia"
  /// The launch agents of the bundled server host: "<identifier>.host.background" and ".host.login".
  static func agentName(startAtLogin: Bool) -> String {
    bundleIdentifier + (startAtLogin ? ".host.login" : ".host.background")
  }
}
