import AppKit
import Security
import ServiceManagement

@MainActor
enum BackgroundHostingController {
  static func service(for settings: HostServiceSettings) -> SMAppService {
    .agent(plistName: settings.agentName + ".plist")
  }
  static var permissionState: String {
    guard let settings = try? HostServiceSettings.load(), settings.backgroundEnabled else {
      return "Only while Aurelia is running"
    }
    switch service(for: settings).status {
    case .enabled: return "Background service permitted"
    case .requiresApproval: return "Awaiting permission"
    case .notRegistered: return "Not registered"
    case .notFound: return "Service is unavailable"
    @unknown default: return "Permission status unavailable"
    }
  }
  static var permitted: Bool {
    guard let settings = try? HostServiceSettings.load() else { return false }
    return settings.backgroundEnabled && service(for: settings).status == .enabled
  }
  static func save(_ requested: HostServiceSettings) async throws -> Bool {
    var settings = requested
    let old = try HostServiceSettings.load()
    if settings.backgroundEnabled && settings.controlSecret.isEmpty {
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw NativeServerHostError.couldNotLaunch
      }
      settings.controlSecret = bytes.map { String(format: "%02x", $0) }.joined()
    }
    if old.backgroundEnabled && (!settings.backgroundEnabled || old.agentName != settings.agentName)
    {
      try await service(for: old).unregister()
    }
    try settings.save()
    if settings.backgroundEnabled {
      let target = service(for: settings)
      if target.status != .enabled && target.status != .requiresApproval { try target.register() }
      return target.status == .enabled
    }
    return false
  }
  static func openPermissions() { SMAppService.openSystemSettingsLoginItems() }
  static func startRegisteredService() async throws {
    guard permitted else { throw NativeServerHostError.rejected }
    let settings = try HostServiceSettings.load()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(settings.agentName)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      process.terminationHandler = { completed in
        if completed.terminationStatus == 0 {
          continuation.resume()
        } else {
          continuation.resume(throwing: NativeServerHostError.couldNotLaunch)
        }
      }
      do {
        try process.run()
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(5))
          if process.isRunning { process.terminate() }
        }
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }
}
