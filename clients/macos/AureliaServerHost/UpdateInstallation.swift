import Darwin
import Foundation

/// The filesystem transaction used by the installer, independent of AppKit and process launch.
/// Tests inject identity, signature, process and move operations against invented bundles.
enum UpdateInstallation {
  /// Consume this request's image before reporting/relaunching, including diagnostic failures.
  static func withDownloadedImage(at image: URL, install: () throws -> Void) rethrows {
    defer { removeDownloadedImage(at: image) }
    try install()
  }

  static func removeDownloadedImage(at image: URL) {
    guard image.isFileURL else { return }
    let manager = FileManager.default
    let directory = image.deletingLastPathComponent()
    let updates = directory.deletingLastPathComponent()
    guard UUID(uuidString: directory.lastPathComponent) != nil,
      updates.lastPathComponent == "Updates",
      let directoryValues = try? directory.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ]),
      directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
      let updatesValues = try? updates.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ]),
      updatesValues.isDirectory == true, updatesValues.isSymbolicLink != true
    else { return }
    let values = try? image.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    if values?.isRegularFile == true, values?.isSymbolicLink != true {
      try? manager.removeItem(at: image)
    }
    // Unlike recursive removeItem, rmdir fails atomically if a sibling appeared or the
    // directory is a symlink. Never delete another download or any unexpected content.
    directory.path.withCString { _ = Darwin.rmdir($0) }
  }

  struct Identity: Equatable {
    let identifier: String
    let build: Int
    let team: String?
  }

  struct Operations {
    var identity: (URL) throws -> Identity
    var verifySignature: (URL) throws -> Void
    var waitForProcesses: (URL) throws -> Void
    var copy: (URL, URL) throws -> Void
    var move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
  }

  enum Failure: Error, LocalizedError {
    case notInstalled
    case appStillRunning
    case wrongApp
    case wrongVersion
    case wrongSigner
    case toolFailed(String)
    case recoveryRequired(String)

    var message: String {
      switch self {
      case .notInstalled: "The installed app could not be found."
      case .appStillRunning: "Aurelia or its server didn't quit in time."
      case .wrongApp: "The download doesn't contain Aurelia."
      case .wrongVersion: "The download contains a different or older version than expected."
      case .wrongSigner: "The download isn't signed by the same developer."
      case .toolFailed(let tool): "Checking or copying the update failed (\(tool))."
      case .recoveryRequired(let path):
        "The update and automatic restoration failed. The original app is preserved at \(path). Move it back before opening Aurelia."
      }
    }

    var errorDescription: String? { message }
  }

  static func validate(current: Identity, candidate: Identity, expectedBuild: Int) throws {
    guard candidate.identifier == current.identifier else { throw Failure.wrongApp }
    guard expectedBuild > current.build, candidate.build == expectedBuild else {
      throw Failure.wrongVersion
    }
    guard let team = current.team, !team.isEmpty, candidate.team == team else {
      throw Failure.wrongSigner
    }
  }

  static func otherProcesses(in app: URL, listing: String, excluding ownPID: Int32) -> [Int32] {
    let prefix = app.path + "/"
    return listing.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
      guard fields.count == 2, let pid = Int32(fields[0]), pid != ownPID,
        fields[1].hasPrefix(prefix)
      else { return nil }
      return pid
    }
  }

  /// `transaction` is a unique private directory beside the destination, so renames stay on
  /// its volume. A failed rollback deliberately keeps the original; cleanup must never erase it.
  static func replace(
    app: URL, candidate: URL, expectedBuild: Int, transaction: URL, operations: Operations
  ) throws {
    let manager = FileManager.default
    let isLink = try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false
    guard app.pathExtension == "app", !isLink,
      transaction.deletingLastPathComponent().standardizedFileURL
        == app.deletingLastPathComponent().standardizedFileURL
    else { throw Failure.notInstalled }
    let current = try operations.identity(app)
    try operations.waitForProcesses(app)
    try validate(
      current: current, candidate: operations.identity(candidate), expectedBuild: expectedBuild)
    try operations.verifySignature(candidate)
    try manager.createDirectory(
      at: transaction, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    var preserveOriginal = false
    defer { if !preserveOriginal { try? manager.removeItem(at: transaction) } }
    let staged = transaction.appendingPathComponent(app.lastPathComponent)
    let previous = transaction.appendingPathComponent("Previous.app")
    try operations.copy(candidate, staged)
    // Check the bytes being moved, as well as the read-only mounted source.
    try validate(
      current: current, candidate: operations.identity(staged), expectedBuild: expectedBuild)
    try operations.verifySignature(staged)
    try operations.waitForProcesses(app)
    try operations.move(app, previous)
    do {
      try operations.move(staged, app)
    } catch {
      let replacementError = error
      do {
        try operations.move(previous, app)
      } catch {
        preserveOriginal = true
        throw Failure.recoveryRequired(previous.path)
      }
      throw replacementError
    }
  }
}
