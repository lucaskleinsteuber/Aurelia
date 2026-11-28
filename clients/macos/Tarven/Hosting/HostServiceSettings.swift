import Foundation

struct HostServiceRequest: Codable, Equatable, Sendable {
  let id: UUID
  let backgroundEnabled: Bool
  let startAtLogin: Bool
  let preventIdleSleep: Bool
  static func location() throws -> URL {
    try HostBootstrapLocation.directory().appendingPathComponent("hosting-request.json")
  }
  static func load() throws -> HostServiceRequest? {
    let url = try location()
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    try HostLaunchSecurity.validateConfigurationFile(
      at: url.path, bootstrapDirectory: url.deletingLastPathComponent())
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }
  var settings: HostServiceSettings {
    var result = (try? HostServiceSettings.load()) ?? HostServiceSettings()
    result.backgroundEnabled = backgroundEnabled
    result.startAtLogin = startAtLogin
    result.preventIdleSleep = preventIdleSleep
    return result
  }
  func save() throws {
    let url = try Self.location()
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      "\(UUID().uuidString).json")
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: try JSONEncoder().encode(self),
        attributes: [.posixPermissions: 0o600])
    else { throw HostLaunchSecurityError.invalidDescription }
    defer { try? FileManager.default.removeItem(at: temporary) }
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: url)
    }
  }
}

struct HostServiceSettings: Codable, Equatable, Sendable {
  var version = 1
  var backgroundEnabled = false
  var startAtLogin = false
  var preventIdleSleep = false
  var controlSecret = ""

  static func location() throws -> URL {
    try HostBootstrapLocation.directory().appendingPathComponent("background-settings.json")
  }
  static func load() throws -> HostServiceSettings {
    let url = try location()
    guard FileManager.default.fileExists(atPath: url.path) else { return HostServiceSettings() }
    try HostLaunchSecurity.validateConfigurationFile(
      at: url.path, bootstrapDirectory: url.deletingLastPathComponent())
    let settings = try JSONDecoder().decode(HostServiceSettings.self, from: Data(contentsOf: url))
    guard settings.version == 1,
      !settings.backgroundEnabled
        || (settings.controlSecret.count == 64 && settings.controlSecret.allSatisfy(\.isHexDigit))
    else { throw HostLaunchSecurityError.invalidDescription }
    return settings
  }
  func save() throws {
    let url = try Self.location()
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      "\(UUID().uuidString).json")
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: try JSONEncoder().encode(self),
        attributes: [.posixPermissions: 0o600])
    else { throw HostLaunchSecurityError.invalidDescription }
    defer { try? FileManager.default.removeItem(at: temporary) }
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: url)
    }
  }
  static var backgroundRendezvousName: String { "background-rendezvous.json" }
  var agentName: String {
    AppEdition.agentName(startAtLogin: startAtLogin)
  }
}
