import Foundation

/// Launch Services discards arguments from sandboxed callers. The app and its
/// same-team helper exchange a bounded, one-use request in their existing App Group.
struct MacUpdateInstallRequest: Codable, Equatable, Sendable {
  static let appGroup = "B5N7JVK37J.com.lucas.aurelia.media.host"
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

  enum Failure: Error { case invalidRequest, requestAlreadyPending, acknowledgementTimedOut }

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
          "\\AAurelia-(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)-\(build)-macOS-arm64\\.dmg\\z",
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

  func save(in root: URL) throws {
    _ = try image(in: root)
    let path = root.appendingPathComponent(Self.pendingName)
    // Publish complete bytes with an atomic, non-overwriting hard link.
    let temporary = root.appendingPathComponent("InstallRequest-\(id.uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try JSONEncoder().encode(self).write(to: temporary, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    try FileManager.default.linkItem(at: temporary, to: path)
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

  func waitForAcknowledgement(in root: URL) async throws {
    for _ in 0..<200 {
      try Task.checkCancellation()
      if let status = Self.status(in: root), status.id == id, status.build == build {
        guard status.phase == "accepted" || status.phase == "installed" else {
          throw Failure.invalidRequest
        }
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw Failure.acknowledgementTimedOut
  }
}
