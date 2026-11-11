import Foundation
import Testing

@Suite("iOS Wake-on-LAN")
struct IOSWakeOnLanTests {
  private let serverID = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!

  private func isolatedDefaults() -> UserDefaults {
    let name = "aurelia.tv.wake.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private func info(_ addresses: [String]?, hosting: String? = nil) throws -> IOSServerInfo {
    var object: [String: Any] = [
      "serverId": serverID.uuidString, "name": "Synthetic", "version": "1.9.0",
      "isSetup": true, "lanAccessEnabled": true,
    ]
    if let addresses { object["wakeOnLanAddresses"] = addresses }
    if let hosting { object["hosting"] = hosting }
    return try JSONDecoder().decode(
      IOSServerInfo.self, from: JSONSerialization.data(withJSONObject: object))
  }

  @Test func remembersCardsAndOnlyNumericAddressesNewestFirst() throws {
    let defaults = isolatedDefaults()
    IOSWakeOnLan.remember(
      serverID: serverID, info: try info(["02-00-5E-10-00-01", "bad"]),
      hosts: ["10.0.0.20", "server.local"], defaults: defaults)
    IOSWakeOnLan.remember(
      serverID: serverID, info: try info(nil), hosts: ["10.0.0.21"], defaults: defaults)
    let target = try #require(IOSWakeOnLan.target(for: serverID, defaults: defaults))
    #expect(target.hardwareAddresses == ["02:00:5e:10:00:01"], "A missing list keeps the old one.")
    #expect(target.ipv4Hosts == ["10.0.0.21", "10.0.0.20"])
  }

  @Test func aDisconnectedServerIsForgotten() throws {
    let defaults = isolatedDefaults()
    IOSWakeOnLan.remember(
      serverID: serverID, info: try info(["02-00-5E-10-00-01"]), hosts: ["10.0.0.20"],
      defaults: defaults)
    #expect(IOSWakeOnLan.target(for: serverID, defaults: defaults) != nil)
    IOSWakeOnLan.forget(serverID: serverID, defaults: defaults)
    #expect(IOSWakeOnLan.target(for: serverID, defaults: defaults) == nil)
  }

  @Test func packetAndAddressRules() {
    let card: [UInt8] = [0x02, 0x00, 0x5E, 0x10, 0x00, 0x01]
    let packet = IOSWakeOnLan.magicPacket(card)
    #expect(packet.count == 102)
    #expect(packet.prefix(6).allSatisfy { $0 == 0xFF })
    #expect(Array(packet.suffix(6)) == card)
    #expect(IOSWakeOnLan.hardwareAddress("00:00:00:00:00:00") == nil)
    #expect(IOSWakeOnLan.hardwareAddress("02:00:5e:10:00") == nil)
    #expect(IOSWakeOnLan.subnetBroadcast(of: "10.0.0.20") == "10.0.0.255")
    #expect(IOSWakeOnLan.subnetBroadcast(of: "server.local") == nil)
  }

  @Test func oldServerInfoWithoutCardsStillDecodes() throws {
    #expect(try info(nil).wakeOnLanAddresses == nil)
  }

  @Test func aServerInsideTheAureliaAppIsNeverWokenAndSaysWhereToStartIt() throws {
    let defaults = isolatedDefaults()
    IOSWakeOnLan.remember(
      serverID: serverID, info: try info(["02-00-5E-10-00-01"], hosting: "linuxServer"),
      hosts: ["10.0.0.20"], defaults: defaults)
    #expect(IOSWakeOnLan.appHost(for: serverID, defaults: defaults) == nil)
    IOSWakeOnLan.remember(
      serverID: serverID, info: try info(nil, hosting: "macApp"), hosts: ["10.0.0.20"], defaults: defaults)
    let target = try #require(IOSWakeOnLan.target(for: serverID, defaults: defaults))
    #expect(target.hardwareAddresses.isEmpty, "A desktop or laptop is started by its owner.")
    #expect(IOSWakeOnLan.appHost(for: serverID, defaults: defaults) == "Mac")
    // A server too old to say where it runs changes nothing.
    IOSWakeOnLan.remember(serverID: serverID, info: try info(nil), hosts: [], defaults: defaults)
    #expect(IOSWakeOnLan.appHost(for: serverID, defaults: defaults) == "Mac")
  }
}
