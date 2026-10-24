import Foundation
import Testing

@testable import Aurelia

struct BrowserAddressTests {
  @Test func aServerElsewhereIsOpenedAtTheAddressThisMacUses() throws {
    let address = try #require(
      BrowserAddress.resolve(
        serverURL: URL(string: "https://192.168.1.50:43111/api/v1")!, lanAccessEnabled: nil,
        lanPort: nil, localIPv4: { "10.0.0.5" }))
    #expect(address.url.absoluteString == "https://192.168.1.50:43111")
    #expect(!address.thisMacOnly)
  }

  @Test func aServerOnThisMacIsOpenedAtThisMacsHomeAddress() throws {
    let address = try #require(
      BrowserAddress.resolve(
        serverURL: URL(string: "http://127.0.0.1:43110")!, lanAccessEnabled: true, lanPort: 43_200,
        localIPv4: { "192.168.1.20" }))
    #expect(address.url.absoluteString == "https://192.168.1.20:43200")
    #expect(!address.thisMacOnly)
  }

  @Test func withoutHomeNetworkAccessOnlyThisMacsBrowserReachesTheServer() throws {
    let off = try #require(
      BrowserAddress.resolve(
        serverURL: URL(string: "http://127.0.0.1:43110")!, lanAccessEnabled: false, lanPort: 43_111,
        localIPv4: { "192.168.1.20" }))
    #expect(off.url.absoluteString == "http://127.0.0.1:43110")
    #expect(off.thisMacOnly)
    let noNetwork = try #require(
      BrowserAddress.resolve(
        serverURL: URL(string: "http://localhost:43110")!, lanAccessEnabled: true, lanPort: 43_111,
        localIPv4: { nil }))
    #expect(noNetwork.thisMacOnly)
  }

  @Test func onlyHomeNetworkAddressesCount() {
    #expect(BrowserAddress.isPrivate(0x0A00_0001))  // 10.0.0.1
    #expect(BrowserAddress.isPrivate(0xAC10_0001))  // 172.16.0.1
    #expect(BrowserAddress.isPrivate(0xAC1F_FFFF))  // 172.31.255.255
    #expect(!BrowserAddress.isPrivate(0xAC20_0001))  // 172.32.0.1
    #expect(BrowserAddress.isPrivate(0xC0A8_0132))  // 192.168.1.50
    #expect(!BrowserAddress.isPrivate(0x0808_0808))  // 8.8.8.8
  }
}
