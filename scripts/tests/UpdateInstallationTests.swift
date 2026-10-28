import Foundation

@main
struct UpdateInstallationTests {
  enum TestError: Error {
    case failed(String)
    case injected
  }

  static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestError.failed(message) }
  }

  static func main() {
    do { try run() } catch {
      FileHandle.standardError.write(Data("Installer tests failed: \(error)\n".utf8))
      exit(1)
    }
  }

  static func run() throws {
    let parent = URL(fileURLWithPath: CommandLine.arguments[1])
    let scenarios = [
      "valid", "wrong-build", "old-build", "wrong-app", "wrong-team", "unsigned",
      "tampered", "tampered-copy", "app-running", "helper-running", "late-process",
      "process-list-fails", "disk-full",
      "replace-fails", "rollback-fails",
    ]
    for scenario in scenarios {
      try exercise(scenario, root: parent.appendingPathComponent(scenario))
    }
    let app = URL(fileURLWithPath: "/invented/Aurelia.app")
    let processes = UpdateInstallation.otherProcesses(
      in: app,
      listing: """
        10 /invented/Aurelia.app/Contents/MacOS/Aurelia
        11 /invented/Aurelia.app/Contents/Helpers/Aurelia Server Host.app/Contents/MacOS/Aurelia Server Host
        12 /invented/Aurelia.app/Contents/Resources/Server/aurelia-server
        13 /invented/Aurelia.app.extra/Contents/MacOS/Aurelia
        14 /other/Aurelia.app/Contents/MacOS/Aurelia
        """, excluding: 11)
    try check(processes == [10, 12], "Only this bundle's other processes block replacement")
    try downloadCleanup(parent: parent)
    print("Passed 23 installer scenarios; no apps launched or installed.")
  }

  static func downloadCleanup(parent: URL) throws {
    let manager = FileManager.default
    let updates = parent.appendingPathComponent("Updates")
    try manager.createDirectory(at: updates, withIntermediateDirectories: true)
    for fails in [false, true] {
      let directory = updates.appendingPathComponent(UUID().uuidString)
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      let image = directory.appendingPathComponent("synthetic.dmg")
      try Data("synthetic image".utf8).write(to: image)
      var failed = false
      do {
        try UpdateInstallation.withDownloadedImage(at: image) {
          try check(manager.fileExists(atPath: image.path), "Keep the image during installation")
          if fails { throw TestError.injected }
        }
      } catch {
        failed = true
        try check(
          !manager.fileExists(atPath: directory.path), "Clean before diagnostic failure handling")
      }
      try check(failed == fails, "Do not swallow installer failures")
      try check(
        !manager.fileExists(atPath: directory.path), "Remove the image and empty UUID directory")
    }
    let withSibling = updates.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: withSibling, withIntermediateDirectories: true)
    let image = withSibling.appendingPathComponent("synthetic.dmg")
    let sibling = withSibling.appendingPathComponent("keep.txt")
    try Data("synthetic image".utf8).write(to: image)
    try Data("keep".utf8).write(to: sibling)
    UpdateInstallation.removeDownloadedImage(at: image)
    try check(!manager.fileExists(atPath: image.path), "Remove only the consumed image")
    try check(
      manager.fileExists(atPath: sibling.path), "Never recursively remove a nonempty workspace")
    let ordinary = parent.appendingPathComponent("Ordinary downloads")
    try manager.createDirectory(at: ordinary, withIntermediateDirectories: true)
    let ordinaryImage = ordinary.appendingPathComponent("synthetic.dmg")
    try Data("synthetic image".utf8).write(to: ordinaryImage)
    UpdateInstallation.removeDownloadedImage(at: ordinaryImage)
    try check(
      manager.fileExists(atPath: ordinary.path), "Do not remove an ordinary parent directory")
    try check(
      manager.fileExists(atPath: ordinaryImage.path),
      "Do not remove an image outside a managed download")
    let external = parent.appendingPathComponent("External sentinel")
    try manager.createDirectory(at: external, withIntermediateDirectories: true)
    let externalImage = external.appendingPathComponent("synthetic.dmg")
    try Data("keep".utf8).write(to: externalImage)
    let linkedDirectory = updates.appendingPathComponent(UUID().uuidString)
    try manager.createSymbolicLink(at: linkedDirectory, withDestinationURL: external)
    UpdateInstallation.removeDownloadedImage(
      at: linkedDirectory.appendingPathComponent("synthetic.dmg"))
    try check(
      manager.fileExists(atPath: externalImage.path), "Never follow a UUID directory symlink")
    let externalUpdates = parent.appendingPathComponent("External updates")
    let externalDownload = externalUpdates.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: externalDownload, withIntermediateDirectories: true)
    let externalDownloadImage = externalDownload.appendingPathComponent("synthetic.dmg")
    try Data("keep".utf8).write(to: externalDownloadImage)
    let linkRoot = parent.appendingPathComponent("Linked root")
    try manager.createDirectory(at: linkRoot, withIntermediateDirectories: true)
    let linkedUpdates = linkRoot.appendingPathComponent("Updates")
    try manager.createSymbolicLink(at: linkedUpdates, withDestinationURL: externalUpdates)
    UpdateInstallation.removeDownloadedImage(
      at: linkedUpdates.appendingPathComponent(externalDownload.lastPathComponent)
        .appendingPathComponent("synthetic.dmg"))
    try check(
      manager.fileExists(atPath: externalDownloadImage.path),
      "Never follow an Updates directory symlink")
    let unexpectedDirectory = updates.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("not-an-image.dmg")
    try manager.createDirectory(at: unexpectedDirectory, withIntermediateDirectories: true)
    let sentinel = unexpectedDirectory.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)
    UpdateInstallation.removeDownloadedImage(at: unexpectedDirectory)
    try check(
      manager.fileExists(atPath: sentinel.path),
      "Never recursively remove an unexpected image directory")
  }

  static func exercise(_ scenario: String, root: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let app = root.appendingPathComponent("Aurelia.app")
    let candidate = root.appendingPathComponent("image/Aurelia.app")
    let transaction = root.appendingPathComponent(".transaction")
    for bundle in [app, candidate] {
      try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
      try Data((bundle == app ? "original" : "candidate").utf8)
        .write(to: bundle.appendingPathComponent("marker"))
    }
    var moves = 0
    var checks = 0
    var waits = 0
    let operations = UpdateInstallation.Operations(
      identity: { bundle in
        let original = bundle == app
        return .init(
          identifier: !original && scenario == "wrong-app" ? "other.app" : "test.aurelia",
          build: original ? 100 : scenario == "wrong-build" ? 102 : 101,
          team: !original && scenario == "wrong-team"
            ? "OTHER" : scenario == "unsigned" ? nil : "TEST")
      },
      verifySignature: { bundle in
        checks += 1
        if scenario == "tampered"
          || (scenario == "tampered-copy"
            && bundle.deletingLastPathComponent().path == transaction.path)
        {
          throw UpdateInstallation.Failure.toolFailed("codesign")
        }
      },
      waitForProcesses: { _ in
        waits += 1
        if scenario == "process-list-fails" { throw UpdateInstallation.Failure.toolFailed("ps") }
        if scenario == "app-running" || scenario == "helper-running"
          || (scenario == "late-process" && waits == 2)
        {
          throw UpdateInstallation.Failure.appStillRunning
        }
      },
      copy: { source, destination in
        if scenario == "disk-full" { throw CocoaError(.fileWriteOutOfSpace) }
        try manager.copyItem(at: source, to: destination)
      },
      move: { source, destination in
        moves += 1
        if (scenario == "replace-fails" || scenario == "rollback-fails") && moves == 2 {
          throw TestError.injected
        }
        if scenario == "rollback-fails" && moves == 3 { throw TestError.injected }
        try manager.moveItem(at: source, to: destination)
      })
    var failure: Error?
    do {
      try UpdateInstallation.replace(
        app: app, candidate: candidate, expectedBuild: scenario == "old-build" ? 100 : 101,
        transaction: transaction, operations: operations)
    } catch { failure = error }
    if scenario == "valid" {
      try check(failure == nil, "A good candidate must install")
      try check(
        checks == 2 && waits == 2 && moves == 2, "Recheck staged signature and process exit")
      try check(tryMarker(app) == "candidate", "Candidate must replace original")
    } else if scenario == "rollback-fails" {
      guard case .recoveryRequired(let path) = failure as? UpdateInstallation.Failure else {
        throw TestError.failed("Rollback failure must explain recovery")
      }
      try check(
        tryMarker(URL(fileURLWithPath: path)) == "original",
        "Never delete the original on failed restoration")
      try check(!manager.fileExists(atPath: app.path), "Fixture must exercise both failed moves")
      return
    } else {
      try check(failure != nil, "\(scenario) must fail")
      try check(tryMarker(app) == "original", "\(scenario) must preserve original")
      if scenario == "replace-fails" {
        try check(moves == 3, "Second move failure must restore original")
      }
      if scenario != "replace-fails" {
        try check(moves == 0, "Reject unsafe candidates before any move")
      }
    }
    try check(
      !manager.fileExists(atPath: transaction.path), "Remove staging after success or safe failure")
    print("Passed: \(scenario)")
  }

  static func tryMarker(_ bundle: URL) -> String? {
    try? String(contentsOf: bundle.appendingPathComponent("marker"), encoding: .utf8)
  }
}
