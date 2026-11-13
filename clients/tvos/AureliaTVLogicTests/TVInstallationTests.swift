import Foundation
import Testing

@Suite("Apple TV installation identifier")
struct TVInstallationTests {
  @Test func theIdentifierIsRandomAndStaysTheSame() throws {
    let defaults = try #require(UserDefaults(suiteName: "aurelia.tv.installation.\(UUID().uuidString)"))
    let first = TVInstallation.identifier(defaults: defaults)
    #expect(UUID(uuidString: first) != nil)
    #expect(TVInstallation.identifier(defaults: defaults) == first)
    #expect(TVInstallation.clientHeader.hasPrefix("tvos/"))
  }
}
