import Foundation
import Testing

@testable import Tarven

/// Tarven was called Aurelia: it takes over Aurelia's settings and the Mac's server folder once.
/// Synthetic settings and temporary folders only; never the real Library.
@Suite struct AureliaHandoverTests {
  @Test func settingsKeysAreRenamedTheWayTheCodeWas() {
    #expect(AureliaHandover.renamedKey("AureliaBetaUpdates") == "TarvenBetaUpdates")
    #expect(
      AureliaHandover.renamedKey("aurelia.library-browse.v1.movies")
        == "tarven.library-browse.v1.movies")
    #expect(AureliaHandover.renamedKey("NSWindow Frame Main") == "NSWindow Frame Main")
  }

  @Test func aureliasSettingsAreTakenOverWithoutReplacingTarvens() throws {
    let suite = "AureliaHandoverTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("aurelia-handover-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = AureliaHandover.preferencesFile(groupContainer: folder)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let exported: [String: Any] = [
      "AureliaBetaUpdates": true,
      "AureliaSidebarShow_People": false,
      "AureliaUpdateCatalog.v1.lucaskleinsteuber/Aurelia": Data([1]),
      "AureliaOperatingMode": "client",
    ]
    try PropertyListSerialization.data(fromPropertyList: exported, format: .binary, options: 0)
      .write(to: file)
    defaults.set("host", forKey: "TarvenOperatingMode")

    #expect(AureliaHandover.importPreferences(from: file, into: defaults) == 2)
    #expect(defaults.bool(forKey: "TarvenBetaUpdates"))
    #expect(defaults.object(forKey: "TarvenSidebarShow_People") as? Bool == false)
    #expect(defaults.string(forKey: "TarvenOperatingMode") == "host")
    #expect(defaults.object(forKey: "TarvenUpdateCatalog.v1.lucaskleinsteuber/Tarven") == nil)
    #expect(
      AureliaHandover.importPreferences(
        from: folder.appendingPathComponent("missing.plist"), into: defaults) == 0)
  }

  @Test func theServerFolderIsTakenOverOnceAndNeverWhileAureliasServerRuns() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("aurelia-home-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    let legacy = support.appendingPathComponent(ServerDataMigrator.aureliaFolderName)
    let current = support.appendingPathComponent(AppEdition.serverDataFolderName)
    let classic = support.appendingPathComponent("Aurelia")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: classic, withIntermediateDirectories: true)
    try Data("synthetic".utf8).write(to: legacy.appendingPathComponent("aurelia.db"))

    // A running Aurelia server holds its lock: nothing moves.
    let lock = legacy.appendingPathComponent("server.lock")
    FileManager.default.createFile(atPath: lock.path, contents: nil)
    let descriptor = open(lock.path, O_RDWR)
    #expect(descriptor >= 0)
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    #expect(throws: ServerDataMigrationError.legacyServerRunning) {
      try ServerDataMigrator.adoptAureliaIfNeeded(isTest: false, home: home)
    }
    flock(descriptor, LOCK_UN)
    close(descriptor)

    try ServerDataMigrator.adoptAureliaIfNeeded(isTest: false, home: home)
    #expect(
      FileManager.default.fileExists(atPath: current.appendingPathComponent("aurelia.db").path))
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    // Aurelia Classic's folder is never touched.
    #expect(FileManager.default.fileExists(atPath: classic.path))

    // The test edition never takes anything over.
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try ServerDataMigrator.adoptAureliaIfNeeded(isTest: true, home: home)
    #expect(FileManager.default.fileExists(atPath: legacy.path))
  }
}
