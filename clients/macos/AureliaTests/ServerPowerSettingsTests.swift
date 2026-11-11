import Foundation
import Testing

@testable import Aurelia

@MainActor
struct ServerPowerSettingsTests {
  @Test func olderServersKeepTheirWakeChoiceBecauseNoneIsSent() throws {
    let older = try JSONDecoder().decode(
      ServerPowerSettings.self,
      from: Data(#"{"available":true,"mode":"sleep","idleMinutes":15,"awakeFrom":null,"awakeUntil":null}"#.utf8))
    #expect(older.wakeOnAccess == nil)
    #expect(!older.offersWakeOnAccess)
    let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? [String: Any]
    #expect(sent?["wakeOnAccess"] == nil)
  }

  @Test func wakeOnAccessIsOfferedOnlyWhileTheComputerPowersDownOnACardThatCan() {
    var settings = ServerPowerSettings(
      available: true, mode: "shutdown", idleMinutes: 30, awakeFrom: nil, awakeUntil: nil,
      wakeOnAccess: false, wakeSupport: "pumbg")
    #expect(settings.offersWakeOnAccess)
    settings.mode = "sleep"
    #expect(settings.offersWakeOnAccess)
    settings.mode = "stop"
    #expect(!settings.offersWakeOnAccess)
    settings.mode = "sleep"
    settings.wakeSupport = "g"
    #expect(!settings.offersWakeOnAccess)
  }

  @Test func everyModeIsExplained() {
    for mode in ["off", "stop", "sleep", "shutdown"] {
      #expect(!ServerPowerEditor.explanation(mode).isEmpty)
    }
    #expect(ServerPowerEditor.explanation("shutdown").contains("BIOS"))
  }

  @Test func aServerTheAppHostsOffersOnlyStopAndIsNeverWokenOverTheNetwork() throws {
    #expect(ServerPowerEditor.modes(hostedByApp: true) == ["off", "stop"])
    #expect(ServerPowerEditor.modes(hostedByApp: false) == ["off", "stop", "sleep", "shutdown"])
    #expect(ServerPowerEditor.explanation("stop", hostedByApp: true, hostName: "the Mac").contains("Start Aurelia"))
    let defaults = try #require(UserDefaults(suiteName: "ServerPowerSettingsTests-\(UUID().uuidString)"))
    let id = UUID()
    func info(_ hosting: String?, addresses: [String]?) -> ServerInfoResponse {
      ServerInfoResponse(
        serverId: id, name: "Invented", version: "2.10.0", isSetup: true, lanAccessEnabled: true,
        lanHttpsPort: 43111, publicKeyFingerprint: nil, displayFingerprint: nil,
        wakeOnLanAddresses: addresses, hosting: hosting)
    }
    WakeOnLan.remember(info("linuxServer", addresses: ["02:00:5e:10:00:01"]), defaults: defaults)
    #expect(WakeOnLan.addresses(for: id, defaults: defaults).count == 1)
    #expect(WakeOnLan.appHost(for: id, defaults: defaults) == nil)
    // The same server now runs inside Aurelia on a Mac: its old addresses go.
    WakeOnLan.remember(info("macApp", addresses: nil), defaults: defaults)
    #expect(WakeOnLan.addresses(for: id, defaults: defaults).isEmpty)
    #expect(WakeOnLan.appHost(for: id, defaults: defaults) == "macApp")
  }
}
