import Darwin
import Foundation

/// Which Tarven this build is: the real app, or "Tarven Test" — a separate app with its own bundle
/// identifier, App Group, Keychain entry and launch agents, built with TARVEN_TEST_EDITION=1 for trying
/// the first run again and again. The test edition never updates itself or touches the real app.
enum AppEdition {
  #if TARVEN_TEST_EDITION
    static let isTest = true
  #else
    static let isTest = false
  #endif

  static let bundleIdentifier = isTest ? "org.tarven.mac.test" : "org.tarven.mac"
  /// The App Group the app shares with its server helper. Its prefix is the signing team, which
  /// the build writes into both Info.plists (TarvenAppGroup); someone who builds Tarven with
  /// their own Apple ID gets their team's group. Without the key, the owner's group.
  static let appGroup = appGroup(
    declared: Bundle.main.object(forInfoDictionaryKey: "TarvenAppGroup"))

  static func appGroup(declared: Any?) -> String {
    let suffix = isTest ? ".org.tarven.mac.test.host" : ".org.tarven.mac.host"
    if let declared = declared as? String, declared.hasSuffix(suffix),
      declared.count == 10 + suffix.count
    {
      return declared
    }
    return "B5N7JVK37J" + suffix
  }
  static let displayName = isTest ? "Tarven Test" : "Tarven"
  static func serverDataFolderName(isTest: Bool) -> String {
    isTest ? "Tarven Test Server" : "Tarven Server"
  }
  static func localPort(isTest: Bool) -> Int { isTest ? 43_120 : 43_110 }
  static func defaultLanPort(isTest: Bool) -> Int { isTest ? 43_121 : 43_111 }

  static let serverDataFolderName = serverDataFolderName(isTest: isTest)
  static let localPort = localPort(isTest: isTest)
  static let defaultLanPort = defaultLanPort(isTest: isTest)
  static let localBaseURL = URL(string: "http://127.0.0.1:\(localPort)")!

  /// The launch agents of the bundled server host: "<identifier>.host.background" and ".host.login".
  static func agentName(startAtLogin: Bool) -> String {
    bundleIdentifier + (startAtLogin ? ".host.login" : ".host.background")
  }
}

/// Removes only Tarven Test's own server data and log folders, never the real app's "Tarven Server".
enum TestEditionServerReset {
  private static let testFolderName = "Tarven Test Server"

  static func removeServerFolders(
    home: URL,
    isTest: Bool = AppEdition.isTest,
    fileManager: FileManager = .default
  ) {
    guard isTest else { return }
    let base = home.standardizedFileURL
    let candidates = [
      base.appendingPathComponent("Library/Application Support", isDirectory: true)
        .appendingPathComponent(testFolderName),
      base.appendingPathComponent("Library/Logs", isDirectory: true)
        .appendingPathComponent(testFolderName),
    ]
    for url in candidates {
      guard url.lastPathComponent == testFolderName else { continue }
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else { continue }
      try? fileManager.removeItem(at: url)
    }
  }
}
