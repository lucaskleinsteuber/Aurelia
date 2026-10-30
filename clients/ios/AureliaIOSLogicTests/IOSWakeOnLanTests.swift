import Foundation
import Testing

@Suite("iOS Wake on LAN Tests")
struct IOSWakeOnLanTests {
  @Test func parseHardwareAddresses() {
    let colonSeparated = IOSWakeOnLan.hardwareAddress("30:85:a9:ea:98:b0")
    #expect(colonSeparated == [0x30, 0x85, 0xa9, 0xea, 0x98, 0xb0])

    let dashSeparated = IOSWakeOnLan.hardwareAddress("30-85-A9-EA-98-B0")
    #expect(dashSeparated == [0x30, 0x85, 0xa9, 0xea, 0x98, 0xb0])

    #expect(IOSWakeOnLan.hardwareAddress("invalid") == nil)
    #expect(IOSWakeOnLan.hardwareAddress("00:00:00:00:00:00") == nil)
  }

  @Test func magicPacketGeneration() {
    let mac: [UInt8] = [0x30, 0x85, 0xa9, 0xea, 0x98, 0xb0]
    let packet = IOSWakeOnLan.magicPacket(mac)

    #expect(packet.count == 102)
    #expect(Array(packet.prefix(6)) == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

    for i in 0..<16 {
      let start = 6 + i * 6
      let slice = Array(packet[start..<start + 6])
      #expect(slice == mac)
    }
  }

  @Test func ipv4Validation() {
    #expect(IOSWakeOnLan.isIPv4("192.168.178.81"))
    #expect(IOSWakeOnLan.isIPv4("10.0.0.1"))
    #expect(!IOSWakeOnLan.isIPv4("fe80::1"))
    #expect(!IOSWakeOnLan.isIPv4("server.local"))
  }
}
