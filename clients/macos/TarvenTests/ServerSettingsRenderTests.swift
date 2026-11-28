import AppKit
import SwiftUI
import Testing

@testable import Tarven

struct ServerSettingsRenderTests {
  @Test
  @MainActor
  func nativeServerSettingsRenderWithIsolatedReadOnlyFixtures() async throws {
    let png = try await ServerSettingsVisualProbe.render()
    #expect(png.count > 10_000)
    Attachment.record(Array(png), named: "Native Server Settings - All Sections.png")
  }
}
