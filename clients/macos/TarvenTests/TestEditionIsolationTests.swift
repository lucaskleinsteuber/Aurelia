import Foundation
import Testing

@testable import Tarven

struct TestEditionIsolationTests {
  @Test func appEditionSeparatesTestServerFoldersAndPortsFromRealEdition() {
    #expect(AppEdition.serverDataFolderName(isTest: false) == "Tarven Server")
    #expect(AppEdition.localPort(isTest: false) == 43_110)
    #expect(AppEdition.defaultLanPort(isTest: false) == 43_111)

    #expect(AppEdition.serverDataFolderName(isTest: true) == "Tarven Test Server")
    #expect(AppEdition.localPort(isTest: true) == 43_120)
    #expect(AppEdition.defaultLanPort(isTest: true) == 43_121)

    #expect(
      AppEdition.serverDataFolderName == AppEdition.serverDataFolderName(isTest: AppEdition.isTest))
    #expect(AppEdition.localPort == AppEdition.localPort(isTest: AppEdition.isTest))
    #expect(AppEdition.defaultLanPort == AppEdition.defaultLanPort(isTest: AppEdition.isTest))
    #expect(AppEdition.localBaseURL == URL(string: "http://127.0.0.1:\(AppEdition.localPort)")!)
  }

  @Test func build11MigrationIsSkippedForTestEdition() throws {
    let fileManager = FileManager.default
    let home = fileManager.temporaryDirectory
      .appendingPathComponent("TarvenTestMigrationSkip-\(UUID().uuidString)", isDirectory: true)
    let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    let legacy = appSupport.appendingPathComponent("Aurelia Home Server", isDirectory: true)
    let destination = appSupport.appendingPathComponent("Tarven Server", isDirectory: true)
    try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: home) }

    let legacyDatabase = legacy.appendingPathComponent("aurelia-home.db")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [
      legacyDatabase.path,
      "CREATE TABLE ServerIdentity(Id INTEGER PRIMARY KEY, Value TEXT); INSERT INTO ServerIdentity VALUES(1, 'real');",
    ]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    // Test edition must never migrate Build 11 data.
    try ServerDataMigrator.migrateBuild11IfNeeded(to: destination, isTest: true, home: home)
    #expect(!fileManager.fileExists(atPath: destination.path))

    // Real edition still migrates when destination does not yet exist.
    try ServerDataMigrator.migrateBuild11IfNeeded(to: destination, isTest: false, home: home)
    #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("tarven.db").path))
  }

  @Test func testEditionServerResetRemovesOnlyTestFoldersAndRespectsGuardAndSymlinks() throws {
    let fileManager = FileManager.default
    let home = fileManager.temporaryDirectory
      .appendingPathComponent("TarvenTestServerReset-\(UUID().uuidString)", isDirectory: true)
    let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    let logs = home.appendingPathComponent("Library/Logs", isDirectory: true)
    let realData = appSupport.appendingPathComponent("Tarven Server", isDirectory: true)
    let realLogs = logs.appendingPathComponent("Tarven Server", isDirectory: true)
    let testData = appSupport.appendingPathComponent("Tarven Test Server", isDirectory: true)
    let testLogs = logs.appendingPathComponent("Tarven Test Server", isDirectory: true)
    defer { try? fileManager.removeItem(at: home) }

    for folder in [realData, realLogs, testData, testLogs] {
      try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let realMarker = realData.appendingPathComponent("tarven.db")
    let realLogFile = realLogs.appendingPathComponent("server.log")
    try Data("real-db".utf8).write(to: realMarker)
    try Data("real-log".utf8).write(to: realLogFile)
    try Data("test-db".utf8).write(to: testData.appendingPathComponent("tarven.db"))
    try Data("test-log".utf8).write(to: testLogs.appendingPathComponent("server.log"))

    // Guard prevents real builds from ever deleting anything.
    TestEditionServerReset.removeServerFolders(home: home, isTest: false, fileManager: fileManager)
    #expect(fileManager.fileExists(atPath: testData.path))
    #expect(fileManager.fileExists(atPath: testLogs.path))
    #expect(fileManager.fileExists(atPath: realMarker.path))
    #expect(fileManager.fileExists(atPath: realLogFile.path))

    // Test edition removes only "Tarven Test Server" folders and preserves "Tarven Server".
    TestEditionServerReset.removeServerFolders(home: home, isTest: true, fileManager: fileManager)
    #expect(!fileManager.fileExists(atPath: testData.path))
    #expect(!fileManager.fileExists(atPath: testLogs.path))
    #expect(try String(contentsOf: realMarker, encoding: .utf8) == "real-db")
    #expect(try String(contentsOf: realLogFile, encoding: .utf8) == "real-log")

    // If "Tarven Test Server" is a symlink pointing to "Tarven Server", only the symlink is removed.
    try fileManager.createSymbolicLink(at: testData, withDestinationURL: realData)
    TestEditionServerReset.removeServerFolders(home: home, isTest: true, fileManager: fileManager)
    #expect(!fileManager.fileExists(atPath: testData.path))
    #expect(try String(contentsOf: realMarker, encoding: .utf8) == "real-db")
  }

  @Test func hostLaunchDescriptionDecodesWithoutResetFlagAndHandoffEncodesResetFlag() throws {
    let legacyJSON = Data(
      """
      {
        "version": 1,
        "parentProcessID": 42,
        "rendezvousPath": "/tmp/r.json",
        "secretPipePath": "/tmp/s.pipe",
        "dataDirectory": null,
        "logDirectory": null,
        "serverName": "Tarven",
        "lanPort": 43111
      }
      """.utf8)
    let legacy = try JSONDecoder().decode(HostLaunchDescription.self, from: legacyJSON)
    #expect(legacy.resetTestData == nil)

    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("TarvenResetHandoff-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let handoff = try HostLaunchHandoff(
      secret: String(repeating: "R", count: 43),
      directory: root,
      rendezvous: root.appendingPathComponent("r.json"),
      serverName: "Tarven Test",
      lanPort: 43_121,
      environment: [:],
      processID: 23_456,
      resetTestData: true)
    defer { handoff.remove() }

    let decoded = try JSONDecoder().decode(
      HostLaunchDescription.self, from: Data(contentsOf: handoff.configurationURL))
    #expect(decoded.resetTestData == true)
    #expect(decoded.lanPort == 43_121)
  }
}
