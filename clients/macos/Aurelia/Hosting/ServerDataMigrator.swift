import Darwin
import Foundation

enum ServerDataMigrationError: Error, Equatable {
  case invalidSource
  case sqliteUnavailable
  case integrityCheckFailed
  case activationFailed
  case destinationUnavailable
}

enum ServerDataMigrator {
  private static let legacyDatabaseName = "aurelia-home.db"
  private static let databaseName = "aurelia.db"
  private static let stagingPrefix = ".Aurelia-Server-Migration-"

  static func migrateBuild11IfNeeded(
    to destination: URL,
    isTest: Bool = AppEdition.isTest,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws {
    guard !isTest, destination.standardizedFileURL == defaultDestination(in: home) else { return }
    try migrateIfNeeded(from: legacySource(in: home), to: destination)
  }

  static func migrateIfNeeded(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    let canonicalDestination = destination.standardizedFileURL
    cleanupAbandonedStagingDirectories(
      in: canonicalDestination.deletingLastPathComponent(), fileManager: fileManager)

    var destinationLinkMetadata = stat()
    if lstat(canonicalDestination.path, &destinationLinkMetadata) == 0,
      destinationLinkMetadata.st_mode & S_IFMT == S_IFLNK
    {
      var targetIsDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: canonicalDestination.path, isDirectory: &targetIsDirectory),
        targetIsDirectory.boolValue
      {
        // The user relocated the server data folder via a symbolic link to an available directory
        // (for example on an external drive). Leave it untouched instead of attempting Build 11
        // migration or failing startup.
        return
      }
      throw ServerDataMigrationError.destinationUnavailable
    }

    // Only migrate when the destination does not yet exist; an existing (even manually emptied)
    // destination must never silently re-import legacy Build 11 data.
    if fileManager.fileExists(atPath: canonicalDestination.path) {
      guard isOwnedDirectory(canonicalDestination) else {
        throw ServerDataMigrationError.activationFailed
      }
      return
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
      .appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)", isDirectory: true)
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
      try fileManager.moveItem(at: staging, to: canonicalDestination)
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
  }

  private static func cleanupAbandonedStagingDirectories(
    in parent: URL, fileManager: FileManager
  ) {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: parent, includingPropertiesForKeys: nil, options: [])
    else { return }
    for entry in entries {
      let name = entry.lastPathComponent
      guard name.hasPrefix(stagingPrefix),
        UUID(uuidString: String(name.dropFirst(stagingPrefix.count))) != nil,
        isOwnedDirectory(entry)
      else { continue }
      try? fileManager.removeItem(at: entry)
    }
  }

  private static func defaultDestination(in home: URL) -> URL {
    home
      .appendingPathComponent("Library/Application Support/Aurelia Server", isDirectory: true)
      .standardizedFileURL
  }

  private static func legacySource(in home: URL) -> URL {
    home
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
