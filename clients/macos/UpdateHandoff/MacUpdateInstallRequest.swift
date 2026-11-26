import Foundation

/// Launch Services discards arguments from sandboxed callers. The app and its
/// same-team helper exchange a bounded, one-use request in their existing App Group.
struct MacUpdateInstallRequest: Codable, Equatable, Sendable {
  static let appGroup = AppEdition.appGroup
  static let pendingName = "PendingInstall.json"
  static let statusName = "InstallStatus.json"
  let id: UUID
  let directory: UUID
  let imageName: String
  let build: Int
  let appPID: Int32
  let createdAt: Date

  struct Status: Codable, Sendable {
    let id: UUID
    let build: Int
    let phase: String
    let message: String?
  }

  enum Failure: Error, Equatable {
    case invalidRequest, requestAlreadyPending, acknowledgementTimedOut
    case rejected(String?)
  }

  static func updatesDirectory() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
      .appendingPathComponent("Library/Caches/Aurelia/Updates", isDirectory: true)
  }

  static func prepare(image: URL, build: Int, appPID: Int32, root: URL, now: Date = Date()) throws
    -> Self
  {
    guard image.isFileURL,
      let directory = UUID(uuidString: image.deletingLastPathComponent().lastPathComponent),
      image.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        == root.standardizedFileURL
    else { throw Failure.invalidRequest }
    let request = Self(
      id: UUID(), directory: directory, imageName: image.lastPathComponent,
      build: build, appPID: appPID, createdAt: now)
    _ = try request.image(in: root, now: now)
    return request
  }

  func image(in root: URL, now: Date = Date()) throws -> URL {
    guard build > 0, appPID > 0, now.timeIntervalSince(createdAt) >= -5,
      now.timeIntervalSince(createdAt) < 120, imageName.utf8.count <= 160,
      imageName.range(
        of:
          "\\AAurelia-(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)-\(build)-macOS-(universal|arm64|x64)\\.dmg\\z",
        options: .regularExpression) != nil
    else { throw Failure.invalidRequest }
    let directory = root.appendingPathComponent(directory.uuidString, isDirectory: true)
    let image = directory.appendingPathComponent(imageName)
    let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    let directoryValues = try directory.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    let imageValues = try image.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
      directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
      imageValues.isRegularFile == true, imageValues.isSymbolicLink != true,
      let size = imageValues.fileSize, size > 0, size <= 2 * 1_024 * 1_024 * 1_024
    else { throw Failure.invalidRequest }
    return image
  }

  /// Checks whether a valid, non-expired pending install request is currently waiting in `root`.
  static func hasFreshPendingRequest(in root: URL, now: Date = Date()) -> Bool {
    let path = root.appendingPathComponent(pendingName)
    guard
      let values = try? path.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ]),
      values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size > 0, size <= 4_096,
      let bytes = try? Data(contentsOf: path),
      let existing = try? JSONDecoder().decode(Self.self, from: bytes),
      (try? existing.image(in: root, now: now)) != nil
    else { return false }
    return true
  }

  /// Removes an expired, corrupt or dangling pending request left behind by an earlier crash so
  /// it cannot block future updates, while leaving any active valid request untouched.
  static func removeStalePending(in root: URL, now: Date = Date()) {
    let path = root.appendingPathComponent(pendingName)
    guard
      FileManager.default.fileExists(atPath: path.path)
        || (try? path.checkResourceIsReachable()) == true
    else { return }
    guard !hasFreshPendingRequest(in: root, now: now) else { return }
    try? FileManager.default.removeItem(at: path)
  }

  func save(in root: URL, now: Date = Date()) throws {
    _ = try image(in: root, now: now)
    Self.removeStalePending(in: root, now: now)
    let path = root.appendingPathComponent(Self.pendingName)
    // Publish complete bytes with an atomic, non-overwriting hard link.
    let temporary = root.appendingPathComponent("InstallRequest-\(id.uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try JSONEncoder().encode(self).write(to: temporary, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    try FileManager.default.linkItem(at: temporary, to: path)
  }

  /// Atomically withdraws this pending request before cleanup. Returns `true` only if this exact
  /// request was reclaimed before any helper claimed it; `false` means a helper already claimed it
  /// (or it is no longer ours) and the downloaded image must not be deleted out from under it.
  func withdraw(in root: URL) -> Bool {
    let path = root.appendingPathComponent(Self.pendingName)
    let withdrawn = root.appendingPathComponent("WithdrawnInstall-\(UUID().uuidString).json")
    do {
      try FileManager.default.moveItem(at: path, to: withdrawn)
    } catch {
      return false
    }
    defer { try? FileManager.default.removeItem(at: withdrawn) }
    guard let data = try? Data(contentsOf: withdrawn),
      let existing = try? JSONDecoder().decode(Self.self, from: data),
      existing.id == id
    else {
      // Unexpectedly moved a different request; try to put it back so we don't drop it.
      try? FileManager.default.moveItem(at: withdrawn, to: path)
      return false
    }
    return true
  }

  /// Atomic rename makes the request single-use, even if two helpers start together.
  static func claim(in root: URL, now: Date = Date()) throws -> Self? {
    let path = root.appendingPathComponent(pendingName)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let values = try path.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size > 0, size <= 4_096
    else { throw Failure.invalidRequest }
    let claimed = root.appendingPathComponent("ClaimedInstall-\(UUID().uuidString).json")
    try FileManager.default.moveItem(at: path, to: claimed)
    defer { try? FileManager.default.removeItem(at: claimed) }
    let claimedValues = try claimed.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard claimedValues.isRegularFile == true, claimedValues.isSymbolicLink != true,
      let claimedSize = claimedValues.fileSize, claimedSize > 0, claimedSize <= 4_096
    else { throw Failure.invalidRequest }
    let request = try JSONDecoder().decode(Self.self, from: Data(contentsOf: claimed))
    _ = try request.image(in: root, now: now)
    return request
  }

  func writeStatus(_ phase: String, message: String? = nil, in root: URL) throws {
    let path = root.appendingPathComponent(Self.statusName)
    let value = Status(id: id, build: build, phase: phase, message: message)
    try JSONEncoder().encode(value).write(to: path, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  }

  static func status(in root: URL) -> Status? {
    let path = root.appendingPathComponent(statusName)
    guard
      let values = try? path.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ]),
      values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size > 0, size <= 4_096,
      let bytes = try? Data(contentsOf: path)
    else { return nil }
    return try? JSONDecoder().decode(Status.self, from: bytes)
  }

  func waitForAcknowledgement(in root: URL, timeoutSeconds: TimeInterval = 30) async throws {
    let steps = max(1, Int((timeoutSeconds / 0.05).rounded(.up)))
    for _ in 0..<steps {
      try Task.checkCancellation()
      if let status = Self.status(in: root), status.id == id, status.build == build {
        if status.phase == "accepted" || status.phase == "installed" {
          return
        }
        throw Failure.rejected(status.message)
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw Failure.acknowledgementTimedOut
  }
}
