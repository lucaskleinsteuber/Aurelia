import Foundation

/// Exercise the production diagnostic exit path and injectable installer entry points without
/// launching an application.
@main
struct UpdateInstallerDiagnostic {
  static func main() {
    if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--verify-entry-points" {
      do {
        try verifyEntryPoints(root: URL(fileURLWithPath: CommandLine.arguments[2]))
      } catch {
        FileHandle.standardError.write(Data("Entry-point verification failed: \(error)\n".utf8))
        exit(1)
      }
      return
    }
    guard UpdateInstaller.runIfRequested(CommandLine.arguments) else { exit(2) }
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: message, code: 1) }
  }

  private static func verifyEntryPoints(root: URL) throws {
    let fm = FileManager.default
    let updates = root.appendingPathComponent("EntryPoint/Updates", isDirectory: true)
    let apps = root.appendingPathComponent("EntryPoint/Apps", isDirectory: true)
    let app = apps.appendingPathComponent("Aurelia.app", isDirectory: true)
    let downloadDir = updates.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: app, withIntermediateDirectories: true)
    try fm.createDirectory(at: downloadDir, withIntermediateDirectories: true)

    let image = downloadDir.appendingPathComponent("Aurelia-2.30.0-200-macOS-arm64.dmg")
    try Data("synthetic image".utf8).write(to: image)

    // Expired pending request is ignored by UpdateInstaller.hasPendingRequest.
    let stale = MacUpdateInstallRequest(
      id: UUID(), directory: UUID(uuidString: downloadDir.lastPathComponent)!,
      imageName: image.lastPathComponent, build: 200, appPID: getpid(),
      createdAt: Date().addingTimeInterval(-300))
    try JSONEncoder().encode(stale).write(
      to: updates.appendingPathComponent(MacUpdateInstallRequest.pendingName))
    try require(
      !UpdateInstaller.hasPendingRequest(
        arguments: [], environment: [:], appURL: app, requiredAppPath: app.path,
        updatesRoot: updates),
      "Stale pending request must not hijack helper startup")

    // Fresh pending request respects --background, host environment, and app path guards.
    let fresh = try MacUpdateInstallRequest.prepare(
      image: image, build: 200, appPID: getpid(), root: updates)
    try fresh.save(in: updates)
    try require(
      !UpdateInstaller.hasPendingRequest(
        arguments: ["--background"], environment: [:], appURL: app, requiredAppPath: app.path,
        updatesRoot: updates),
      "--background launch must never enter update mode")
    try require(
      !UpdateInstaller.hasPendingRequest(
        arguments: [], environment: ["AURELIA_HOST_MODE": "1"], appURL: app,
        requiredAppPath: app.path, updatesRoot: updates),
      "Host environment launch must never enter update mode")
    try require(
      !UpdateInstaller.hasPendingRequest(
        arguments: [], environment: [:], appURL: app, requiredAppPath: "/Applications/Aurelia.app",
        updatesRoot: updates),
      "Non-Applications bundle must never consume an update request")
    try require(
      UpdateInstaller.hasPendingRequest(
        arguments: [], environment: [:], appURL: app, requiredAppPath: app.path,
        updatesRoot: updates),
      "Matching app path with fresh pending request must be detected")

    // Read-only destination fails pre-acceptance, writes failed status, cleans image, never relaunches.
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: apps.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: apps.path) }
    var relaunches = 0
    let result = UpdateInstaller.runPendingWorker(
      appURL: app, requiredAppPath: app.path, updatesRoot: updates,
      relaunch: { _ in relaunches += 1 })
    if case .failed = result {
      throw NSError(domain: "Pre-acceptance failure must not show helper alert", code: 1)
    }
    try require(relaunches == 0, "Pre-acceptance failure must not relaunch app")
    let status = MacUpdateInstallRequest.status(in: updates)
    try require(status?.id == fresh.id, "Status must match rejected request ID")
    try require(status?.phase == "failed", "Status must record failed phase")
    try require(
      status?.message == UpdateInstallation.Failure.notWritable.message,
      "Status must record notWritable error message")
    try require(!fm.fileExists(atPath: downloadDir.path), "Rejected image folder must be removed")
    print("Passed 6 UpdateInstaller entry-point scenarios; no app launched or installed.")
  }
}
