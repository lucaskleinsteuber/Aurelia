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

  @Test func theWakeOnLanCheckSaysWhatTheServerFoundAndWhatOnlyATestShows() throws {
    var settings = ServerPowerSettings(
      available: true, mode: "sleep", idleMinutes: 15, awakeFrom: nil, awakeUntil: nil,
      wakeSupport: "pumbg", hosting: "linuxServer", network: "wired", wakeOn: "g", sleepKind: "deep")
    func titles() -> [String] { (settings.wakeCheck ?? []).map { "\($0.state): \($0.title)" } }
    #expect(titles() == ["ok: Connected by cable", "ok: Wake-on-LAN is on", "ok: Real sleep", "info: Try it once"])
    settings.mode = "shutdown"
    #expect(titles() == ["ok: Connected by cable", "ok: Wake-on-LAN is on", "info: Waking from off needs the BIOS", "info: Try it once"])
    #expect(settings.wakeCheck?[2].detail.contains("Power On By PCI-E") == true)
    settings.mode = "sleep"
    settings.network = "wifi"
    settings.wakeOn = "d"
    settings.sleepKind = "light"
    #expect(titles() == ["problem: Connected by Wi-Fi", "warning: Wake-on-LAN is off right now", "warning: Only light sleep", "info: Try it once"])
    settings.wakeSupport = "d"
    settings.sleepKind = "none"
    #expect(Array(titles()[1...2]) == ["problem: The network card can't wake the computer", "problem: This computer can't sleep"])
    for mode in ["off", "stop"] {
      settings.mode = mode
      #expect(settings.wakeCheck == nil)
    }
    settings.mode = "sleep"
    settings.hosting = "macApp"
    #expect(settings.wakeCheck == nil)

    // An older server sends none of it: the network card isn't checked yet.
    let older = try JSONDecoder().decode(
      ServerPowerSettings.self,
      from: Data(#"{"available":true,"mode":"sleep","idleMinutes":15,"awakeFrom":null,"awakeUntil":null,"wakeSupport":"pumbg"}"#.utf8))
    #expect((older.wakeCheck ?? []).map(\.title) == ["Network card not checked yet", "Try it once"])
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
