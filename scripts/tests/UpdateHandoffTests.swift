import Foundation

@main
struct UpdateHandoffTests {
  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: message, code: 1) }
  }
  static func main() async throws {
    let manager = FileManager.default
    let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Updates")
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let directory = root.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: directory, withIntermediateDirectories: false)
    let image = directory.appendingPathComponent("Aurelia-1.27.2-126-macOS-universal.dmg")
    try Data("invented bytes; never mounted".utf8).write(to: image)
    let request = try MacUpdateInstallRequest.prepare(
      image: image, build: 126, appPID: 42, root: root)
    try request.save(in: root)
    var refusedOverwrite = false
    do { try request.save(in: root) } catch { refusedOverwrite = true }
    try require(refusedOverwrite, "Never replace another pending request")
    let claimed = try MacUpdateInstallRequest.claim(in: root)
    try require(claimed == request, "Read the bounded request without launch arguments")
    try require(try MacUpdateInstallRequest.claim(in: root) == nil, "A request is consumed once")
    try request.writeStatus("accepted", in: root)
    try await request.waitForAcknowledgement(in: root)
    try require(
      MacUpdateInstallRequest.status(in: root)?.build == 126, "Acknowledge the exact build")
    let other = MacUpdateInstallRequest(
      id: UUID(), directory: request.directory, imageName: request.imageName,
      build: request.build, appPID: request.appPID, createdAt: request.createdAt)
    try other.writeStatus("accepted", in: root)
    let waiting = Task { try await request.waitForAcknowledgement(in: root) }
    waiting.cancel()
    do {
      try await waiting.value
      throw NSError(domain: "Cancellation must stop waiting", code: 1)
    } catch is CancellationError {}
    for scenario in ["old", "future", "pid", "build", "traversal", "wrong-name"] {
      let invalid = MacUpdateInstallRequest(
        id: UUID(), directory: request.directory,
        imageName: scenario == "traversal"
          ? "../outside.dmg"
          : scenario == "wrong-name" ? "Aurelia-1.27.2-125-macOS-universal.dmg" : request.imageName,
        build: scenario == "build" ? 0 : 126, appPID: scenario == "pid" ? 0 : 42,
        createdAt: Date().addingTimeInterval(
          scenario == "old" ? -121 : scenario == "future" ? 30 : 0))
      var rejected = false
      do { _ = try invalid.image(in: root) } catch { rejected = true }
      try require(rejected, "Reject \(scenario)")
    }
    let pending = root.appendingPathComponent(MacUpdateInstallRequest.pendingName)
    try Data(repeating: 65, count: 4_097).write(to: pending)
    var rejected = false
    do { _ = try MacUpdateInstallRequest.claim(in: root) } catch { rejected = true }
    try require(rejected, "Reject oversized request")
    try manager.removeItem(at: pending)
    try manager.createSymbolicLink(at: pending, withDestinationURL: image)
    rejected = false
    do { _ = try MacUpdateInstallRequest.claim(in: root) } catch { rejected = true }
    try require(rejected, "Reject symlink request")
    try manager.removeItem(at: pending)
    try manager.removeItem(at: image)
    let outside = root.appendingPathComponent("outside.dmg")
    try Data("synthetic unrelated file".utf8).write(to: outside)
    try manager.createSymbolicLink(at: image, withDestinationURL: outside)
    rejected = false
    do { _ = try request.image(in: root) } catch { rejected = true }
    try require(rejected, "Reject symlink image")
    try require(manager.fileExists(atPath: outside.path), "Preserve unrelated files")
    print("Passed 14 request/acknowledgement scenarios; no app, media or disk image opened.")
  }
}
