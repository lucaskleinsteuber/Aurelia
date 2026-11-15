import Foundation
import Testing

/// A server that moved to another computer keeps answering at its old address with where it went.
struct IOSServerMoveTests {
  private let serverID = UUID(uuidString: "6E1B7A52-2D0A-4C3E-9B57-1F2A3C4D5E6F")!

  @Test func movedServerInfoDecodesAndNamesTheNewAddresses() throws {
    let json = #"""
      {"serverId":"6e1b7a52-2d0a-4c3e-9b57-1f2a3c4d5e6f","name":"Home","version":"2.18.0",
       "isSetup":true,"lanAccessEnabled":true,"lanHttpsPort":8443,"publicKeyFingerprint":null,
       "displayFingerprint":null,"capabilities":[],
       "moved":{"serverId":"6e1b7a52-2d0a-4c3e-9b57-1f2a3c4d5e6f","name":"Home",
                "addresses":["https://192.168.1.40:8443","https://minipc.local:8443"]}}
      """#
    let info = try JSONDecoder().decode(IOSServerInfo.self, from: Data(json.utf8))
    let moved = try #require(info.moved)
    let old = URL(string: "https://192.168.1.20:8443")!
    #expect(
      moved.followable(for: serverID, tried: [old]).map(\.absoluteString) == [
        "https://192.168.1.40:8443", "https://minipc.local:8443",
      ])
  }

  @Test func infoWithoutMoveStaysUnmoved() throws {
    let json = #"""
      {"serverId":"6e1b7a52-2d0a-4c3e-9b57-1f2a3c4d5e6f","name":"Home","version":"2.17.1",
       "isSetup":true,"lanAccessEnabled":true,"lanHttpsPort":8443,"publicKeyFingerprint":null,
       "displayFingerprint":null,"capabilities":[]}
      """#
    #expect(try JSONDecoder().decode(IOSServerInfo.self, from: Data(json.utf8)).moved == nil)
  }

  @Test func aMoveToAnotherServerOrAnAddressAlreadyTriedIsNotFollowed() {
    let address = URL(string: "https://192.168.1.40:8443")!
    let elsewhere = IOSServerMoveTarget(serverId: UUID(), name: "Other", addresses: [address])
    #expect(elsewhere.followable(for: serverID, tried: []).isEmpty)
    let same = IOSServerMoveTarget(serverId: serverID, name: "Home", addresses: [address])
    #expect(same.followable(for: serverID, tried: [address]).isEmpty)
    let plain = IOSServerMoveTarget(
      serverId: serverID, name: "Home", addresses: [URL(string: "http://192.168.1.40:8080")!])
    #expect(plain.followable(for: serverID, tried: []).isEmpty)
  }
}
