import Darwin
import Foundation

enum ServerDataMigrationError: Error, Equatable {
  case invalidSource
  case sqliteUnavailable
  case integrityCheckFailed
  case activationFailed
}

enum ServerDataMigrator {
  private static let legacyDatabaseName = "aurelia-home.db"
  private static let databaseName = "aurelia.db"

  static func migrateBuild11IfNeeded(to destination: URL) throws {
    guard destination.standardizedFileURL == defaultDestination else { return }
    try migrateIfNeeded(from: legacySource, to: destination)
  }

  static func migrateIfNeeded(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    let canonicalDestination = destination.standardizedFileURL

    if fileManager.fileExists(atPath: canonicalDestination.path) {
      guard isOwnedDirectory(canonicalDestination) else {
        throw ServerDataMigrationError.activationFailed
      }
      guard try fileManager.contentsOfDirectory(atPath: canonicalDestination.path).isEmpty else {
        return
      }
    }

    let source = source.standardizedFileURL
    var sourceIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else {
      return
    }
    let legacyDatabase = source.appendingPathComponent(legacyDatabaseName)
    guard sourceIsDirectory.boolValue, isOwnedDirectory(source),
      source.standardizedFileURL.resolvingSymlinksInPath() == source.standardizedFileURL,
      isOwnedRegularFile(legacyDatabase)
    else { throw ServerDataMigrationError.invalidSource }

    let staging = canonicalDestination.deletingLastPathComponent()
      .appendingPathComponent(".Aurelia-Server-Migration-\(UUID().uuidString)", isDirectory: true)
    do {
      try fileManager.createDirectory(
        at: staging,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      for item in try fileManager.contentsOfDirectory(
        at: source,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: [.skipsHiddenFiles])
      {
        guard !item.lastPathComponent.hasPrefix(legacyDatabaseName) else { continue }
        let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw ServerDataMigrationError.invalidSource }
        try fileManager.copyItem(
          at: item, to: staging.appendingPathComponent(item.lastPathComponent))
      }

      let migratedDatabase = staging.appendingPathComponent(databaseName)
      try sqliteBackup(
        source: legacyDatabase,
        destination: migratedDatabase)
      try validate(database: migratedDatabase)
      try applyPrivatePermissions(to: staging)
      if fileManager.fileExists(atPath: canonicalDestination.path) {
        try fileManager.removeItem(at: canonicalDestination)
      }
      try fileManager.moveItem(at: staging, to: canonicalDestination)
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
  }

  private static var defaultDestination: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Aurelia Server", isDirectory: true)
      .standardizedFileURL
  }

  private static var legacySource: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Aurelia Home Server", isDirectory: true)
      .standardizedFileURL
  }

  private static func sqliteBackup(source: URL, destination: URL) throws {
    let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
    let output = try runSQLite(database: source, statement: ".backup '\(escaped)'")
    guard output.status == 0 else { throw ServerDataMigrationError.integrityCheckFailed }
  }

  private static func validate(database: URL) throws {
    let output = try runSQLite(
      database: database,
      statement: "PRAGMA quick_check; PRAGMA integrity_check; PRAGMA foreign_key_check;")
    let lines = output.text.split(whereSeparator: \.isNewline).map(String.init)
    guard output.status == 0, lines == ["ok", "ok"] else {
      throw ServerDataMigrationError.integrityCheckFailed
    }
  }

  private static func runSQLite(database: URL, statement: String) throws
    -> (status: Int32, text: String)
  {
    let executable = URL(fileURLWithPath: "/usr/bin/sqlite3")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw ServerDataMigrationError.sqliteUnavailable
    }
    let pipe = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = ["-batch", database.path, statement]
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private static func applyPrivatePermissions(to root: URL) throws {
    let fileManager = FileManager.default
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { throw ServerDataMigrationError.activationFailed }
    for case let item as URL in enumerator {
      let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { throw ServerDataMigrationError.invalidSource }
      try fileManager.setAttributes(
        [.posixPermissions: values.isDirectory == true ? 0o700 : 0o600],
        ofItemAtPath: item.path)
    }
  }

  private static func isOwnedDirectory(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0
      && metadata.st_mode & S_IFMT == S_IFDIR
      && metadata.st_uid == getuid()
      && metadata.st_mode & 0o022 == 0
  }

  private static func isOwnedRegularFile(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0
      && metadata.st_mode & S_IFMT == S_IFREG
      && metadata.st_uid == getuid()
      && metadata.st_mode & 0o022 == 0
  }
}
