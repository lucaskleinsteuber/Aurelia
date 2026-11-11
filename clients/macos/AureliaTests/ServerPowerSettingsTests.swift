import Foundation
import Testing

@testable import Aurelia

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
}
