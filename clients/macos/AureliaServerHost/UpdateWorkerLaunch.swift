import Foundation

/// A one-shot launchd job survives Launch Services cleaning up the app's subordinate helpers.
/// No job file or login item is installed; the worker removes its exact transient job at exit.
enum UpdateWorkerLaunch {
  static let argument = "--install-pending-update"
  static let labelPrefix = "com.lucas.aurelia.media.update."

  static func isValidLabel(_ label: String) -> Bool {
    label.hasPrefix(labelPrefix)
      && UUID(uuidString: String(label.dropFirst(labelPrefix.count))) != nil
  }

  static func runIfRequested(_ arguments: [String], work: () -> Void) -> Bool {
    guard arguments.count == 3, arguments[1] == argument, isValidLabel(arguments[2]) else {
      return false
    }
    defer { remove(arguments[2]) }
    work()
    return true
  }

  @discardableResult
  static func submit(executable: URL) throws -> String {
    let label = labelPrefix + UUID().uuidString
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = [
      "submit", "-l", label, "-o", "/dev/null", "-e", "/dev/null", "--",
      executable.path, argument, label,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    return label
  }

  static func remove(_ label: String) {
    guard isValidLabel(label) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["remove", label]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    if process.isRunning { process.waitUntilExit() }
  }
}
