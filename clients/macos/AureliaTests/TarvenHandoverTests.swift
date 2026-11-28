import Foundation
import Testing

@testable import Aurelia

/// Aurelia's new name is Tarven: this version keeps its settings ready for Tarven and points to
/// Tarven's release once there is one. Synthetic settings and temporary folders only.
@Suite struct TarvenHandoverTests {
  @Test func settingsAreWrittenForTarvenOnlyWhenTheyChange() throws {
    let suite = "TarvenHandoverTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let group = FileManager.default.temporaryDirectory
      .appendingPathComponent("tarven-handover-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: group) }

    #expect(
      TarvenHandover.exportPreferences(
        defaults: defaults, domain: suite, groupContainer: group, isTest: false) == nil)
    defaults.set(true, forKey: "AureliaBetaUpdates")
    defaults.set("sidebar", forKey: "AureliaSidebarShow_People")
    let file = try #require(
      TarvenHandover.exportPreferences(
        defaults: defaults, domain: suite, groupContainer: group, isTest: false))
    #expect(file.path.hasSuffix("Library/Application Support/Tarven Handover/preferences.plist"))
    let written = try #require(
      try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
        as? [String: Any])
    #expect(written["AureliaBetaUpdates"] as? Bool == true)
    #expect(written["AureliaSidebarShow_People"] as? String == "sidebar")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
    #expect(mode as? Int == 0o600)

    // Unchanged settings leave the file alone; the test edition never writes one.
    let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
    #expect(
      TarvenHandover.exportPreferences(
        defaults: defaults, domain: suite, groupContainer: group, isTest: false) == file)
    #expect(
      try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        == before as? Date)
    try FileManager.default.removeItem(at: file)
    #expect(
      TarvenHandover.exportPreferences(
        defaults: defaults, domain: suite, groupContainer: group, isTest: true) == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test func onlyATarvenReleaseWithAMacDiskImageIsAnnounced() throws {
    func list(_ releases: [[String: Any]]) throws -> Data {
      try JSONSerialization.data(withJSONObject: releases)
    }
    let page = "https://github.com/lucaskleinsteuber/Tarven/releases/tag/3.1.0-189"
    let mac: [String: Any] = [
      "draft": false, "html_url": page,
      "assets": [["name": "Tarven-3.1.0-189-macOS-arm64.dmg"], ["name": "SHA256SUMS"]],
    ]
    let server: [String: Any] = [
      "draft": false,
      "html_url": "https://github.com/lucaskleinsteuber/Tarven/releases/tag/server-4.0.0-181",
      "assets": [["name": "Tarven-Server-4.0.0-181-linux-x64.tar.gz"]],
    ]
    #expect(TarvenHandover.macReleasePage(fromList: try list([server])) == nil)
    #expect(
      TarvenHandover.macReleasePage(fromList: try list([server, mac]))?.absoluteString == page)

    var draft = mac
    draft["draft"] = true
    #expect(TarvenHandover.macReleasePage(fromList: try list([draft])) == nil)
    var elsewhere = mac
    elsewhere["html_url"] = "https://example.invalid/lucaskleinsteuber/Tarven/releases/tag/x"
    #expect(TarvenHandover.macReleasePage(fromList: try list([elsewhere])) == nil)
    var otherRepository = mac
    otherRepository["html_url"] = "https://github.com/someone/Tarven/releases/tag/x"
    #expect(TarvenHandover.macReleasePage(fromList: try list([otherRepository])) == nil)
    #expect(TarvenHandover.macReleasePage(fromList: Data("not json".utf8)) == nil)

    #expect(TarvenHandover.isMacDiskImage("Tarven-3.1.0-189-macOS-x64.dmg"))
    #expect(!TarvenHandover.isMacDiskImage("Aurelia-3.1.0-189-macOS-arm64.dmg"))
    #expect(!TarvenHandover.isMacDiskImage("Tarven-3.1.0-189-macOS-arm64.dmg.zip"))
  }
}
