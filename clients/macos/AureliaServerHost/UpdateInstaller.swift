import AppKit
import Foundation
import OSLog

/// Installs an update the app downloaded and checked: `--install-update <disk image> <build>
/// <app pid> [--no-relaunch]`. It waits for the app to quit, checks the new bundle (same
/// identifier and team, the expected build, a valid signature), then replaces only the app
/// bundle; the old one is moved aside first and put back if anything fails, so the app is never
/// left missing. Data, settings and the library are not touched. The sandboxed app cannot do
/// this itself; this helper runs outside the sandbox.
enum UpdateInstaller {
  private static let logger = Logger(
    subsystem: "com.lucas.aurelia.media.server-host", category: "update")

  static func hasPendingRequest() -> Bool {
    let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().standardizedFileURL
    guard app.path == "/Applications/Aurelia.app",
      let root = MacUpdateInstallRequest.updatesDirectory()
    else { return false }
    return FileManager.default.fileExists(
      atPath: root.appendingPathComponent(MacUpdateInstallRequest.pendingName).path)
  }

  static func runPendingIfRequested() -> Bool {
    let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().standardizedFileURL
    // Synthetic host tests and other copies never inspect the installed app's requests.
    guard app.path == "/Applications/Aurelia.app",
      let root = MacUpdateInstallRequest.updatesDirectory()
    else { return false }
    var request: MacUpdateInstallRequest?
    do {
      guard let claimed = try MacUpdateInstallRequest.claim(in: root) else { return false }
      request = claimed
      let image = try claimed.image(in: root)
      try claimed.writeStatus("accepted", in: root)
      try UpdateInstallation.withDownloadedImage(at: image) {
        try install(image: image, expectedBuild: claimed.build, appPID: claimed.appPID, app: app)
      }
      try? claimed.writeStatus("installed", in: root)
      logger.notice(
        "Installed build \(claimed.build, privacy: .public) through the App Group handoff.")
      open(app)
    } catch {
      let message =
        (error as? InstallError)?.message
        ?? "The update request could not be completed. Please try again."
      if let request { try? request.writeStatus("failed", message: message, in: root) }
      logger.error("App Group update failed: \(message, privacy: .public)")
      report(message)
      open(app)
    }
    return true
  }

  static func runIfRequested(_ arguments: [String]) -> Bool {
    guard let index = arguments.firstIndex(of: "--install-update"), arguments.count >= index + 4,
      let build = Int(arguments[index + 2]), let pid = pid_t(arguments[index + 3])
    else { return false }
    let image = URL(fileURLWithPath: arguments[index + 1])
    let relaunch = !arguments.contains("--no-relaunch")
    // The helper lives at <app>/Contents/Helpers/Aurelia Server Host.app.
    let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().standardizedFileURL
    do {
      try UpdateInstallation.withDownloadedImage(at: image) {
        try install(image: image, expectedBuild: build, appPID: pid, app: app)
      }
      logger.notice("Installed build \(build, privacy: .public).")
      if relaunch { open(app) }
    } catch {
      let message = (error as? InstallError)?.message ?? error.localizedDescription
      logger.error("Update failed: \(message, privacy: .public)")
      if relaunch {
        report(message)
        open(app)
      } else {
        FileHandle.standardError.write(Data("Update failed: \(message)\n".utf8))
        exit(1)
      }
    }
    return true
  }

  static func install(image: URL, expectedBuild: Int, appPID: pid_t, app: URL) throws {
    let fileManager = FileManager.default
    try waitUntilGone(pid: appPID)

    let mount = fileManager.temporaryDirectory.appendingPathComponent(
      "AureliaUpdate-\(UUID().uuidString)")
    try fileManager.createDirectory(at: mount, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: mount)
    }
    try run(
      "/usr/bin/hdiutil",
      ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path])
    defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }

    let transaction = app.deletingLastPathComponent().appendingPathComponent(
      ".aurelia-update-\(UUID().uuidString)", isDirectory: true)
    try UpdateInstallation.replace(
      app: app, candidate: mount.appendingPathComponent(app.lastPathComponent),
      expectedBuild: expectedBuild, transaction: transaction,
      operations: .init(
        identity: identity,
        verifySignature: {
          _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", $0.path])
        },
        waitForProcesses: waitForOtherProcesses,
        copy: { source, destination in
          try run("/usr/bin/ditto", ["--noqtn", source.path, destination.path])
          _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
        }))
  }

  private static func identity(_ app: URL) throws -> UpdateInstallation.Identity {
    guard let bundle = Bundle(url: app), let identifier = bundle.bundleIdentifier,
      let build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    else { throw InstallError.wrongApp }
    return .init(identifier: identifier, build: build, team: try teamIdentifier(app))
  }

  private static func waitUntilGone(pid: pid_t) throws {
    guard pid > 0, pid != getpid() else { throw InstallError.appStillRunning }
    for _ in 0..<600 {
      if kill(pid, 0) != 0 && errno == ESRCH { return }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw InstallError.appStillRunning
  }

  /// A server host started from the old bundle must have stopped before the bundle is replaced.
  private static func waitForOtherProcesses(in app: URL) throws {
    for _ in 0..<300 {
      // A failed process listing cannot establish that replacement is safe.
      let listing = try run("/bin/ps", ["-axo", "pid=,comm="])
      let others = UpdateInstallation.otherProcesses(in: app, listing: listing, excluding: getpid())
      if others.isEmpty { return }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw InstallError.appStillRunning
  }

  private static func teamIdentifier(_ bundle: URL) throws -> String? {
    let output = try run("/usr/bin/codesign", ["-dv", bundle.path])
    return output.split(whereSeparator: \.isNewline)
      .first { $0.hasPrefix("TeamIdentifier=") }
      .map { String($0.dropFirst("TeamIdentifier=".count)) }
      .flatMap { $0 == "not set" ? nil : $0 }
  }

  @discardableResult
  private static func run(_ tool: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw InstallError.toolFailed(URL(fileURLWithPath: tool).lastPathComponent)
    }
    return output
  }

  private static func open(_ app: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [app.path]
    try? process.run()
    process.waitUntilExit()
  }

  /// Called from `main()`, which runs on the main thread.
  private static func report(_ message: String) {
    MainActor.assumeIsolated {
      let application = NSApplication.shared
      application.setActivationPolicy(.accessory)
      application.activate()
      let alert = NSAlert()
      alert.messageText = "Aurelia Couldn't Be Updated"
      alert.informativeText = message
      alert.runModal()
    }
  }

  typealias InstallError = UpdateInstallation.Failure
}
