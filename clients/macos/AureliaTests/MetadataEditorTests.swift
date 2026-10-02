import AppKit
import SwiftUI
import Testing

@testable import Aurelia

@MainActor struct MetadataEditorTests {
  private func document() -> MediaEditorDocument {
    var automatic = MediaEditorValues()
    automatic.title = "Automatic Title"
    automatic.releaseYear = 2019
    automatic.runtimeMinutes = 103
    automatic.overview = "A synthetic description used only for native editor verification."
    automatic.genres = ["Drama", "Comedy"]
    automatic.studios = ["Test Studio"]
    automatic.country = "US"
    automatic.credits = [
      EditorCredit(
        id: UUID(), name: "Test Actor", department: "Acting", job: "Actor",
        character: "Main Character")
    ]
    return MediaEditorDocument(
      mediaId: UUID(), libraryId: UUID(), kind: .movie, revision: 7,
      values: automatic, overrideFields: [], sourcePath: "/synthetic/Movies/Test Movie.mkv",
      relativeSourcePath: "Test Movie.mkv", automaticValues: automatic)
  }

  @Test func draftMarksManualBlanksAndCanExplicitlyReturnToAutomaticValues() {
    let state = MetadataDraft()
    let fixture = document()
    state.load(fixture)
    #expect(!state.dirty)
    state.text(\.overview, field: "overview").wrappedValue = ""
    #expect(state.overrides.contains("overview"))
    #expect(state.dirty)
    #expect(state.values.overview == "")
    state.automatic("overview")
    #expect(state.values.overview == fixture.automaticValues.overview)
    #expect(!state.overrides.contains("overview"))
    #expect(!state.dirty)
    state.source = "Another Movie.mkv"
    #expect(state.dirty)
    state.load(fixture)
    #expect(state.source == nil)
  }

  @Test func draftValidationRetainsInvalidYearAndIncompletePersonUntilCorrected() {
    let state = MetadataDraft()
    state.load(document())
    state.year = "not a year"
    #expect(!state.valid)
    state.year = "2026"
    #expect(state.valid)
    state.values.credits.append(EditorCredit(id: UUID(), name: "", department: "Acting"))
    #expect(!state.valid)
    state.values.credits.removeLast()
    state.runtime = "0"
    #expect(!state.valid)
    state.runtime = ""
    #expect(state.valid)
  }

  @Test func revokedAndExpiredDevicesAreNotActive() {
    let id = UUID()
    let user = UUID()
    let active = DeviceSessionSummary(
      id: id, userId: user, deviceName: "Active",
      createdAt: "2026-01-01T00:00:00Z", lastSeenAt: "2026-01-01T00:00:00Z",
      expiresAt: "2099-01-01T00:00:00.123Z", revokedAt: nil, isCurrent: true)
    #expect(active.isActive)
    let revoked = DeviceSessionSummary(
      id: id, userId: user, deviceName: "Revoked",
      createdAt: active.createdAt, lastSeenAt: active.lastSeenAt, expiresAt: active.expiresAt,
      revokedAt: "2026-01-01T00:00:00Z", isCurrent: false)
    #expect(!revoked.isActive)
    let expired = DeviceSessionSummary(
      id: id, userId: user, deviceName: "Expired",
      createdAt: active.createdAt, lastSeenAt: active.lastSeenAt, expiresAt: "2020-01-01T00:00:00Z",
      revokedAt: nil, isCurrent: false)
    #expect(!expired.isActive)
  }

  @Test func resetRequiresPasswordApprovalButEditingAndExclusionReimportDoNot() {
    #expect(
      APIClient.requiresAdministrationApproval(path: "/api/v1/libraries/reset", method: "POST"))
    #expect(
      !APIClient.requiresAdministrationApproval(
        path: "/api/v1/libraries/reset/preview", method: "POST"))
    #expect(
      !APIClient.requiresAdministrationApproval(
        path: "/api/v1/media/\(UUID())/editor", method: "PUT"))
    #expect(
      !APIClient.requiresAdministrationApproval(
        path: "/api/v1/libraries/\(UUID())/exclusions/\(UUID())", method: "DELETE"))
  }

  @Test func nativeEditorRendersAllFourSectionsWithSyntheticData() async throws {
    let previous = AppModel.active
    defer { AppModel.active = previous }
    let model = AppModel.serverSettingsRenderPreview()
    let fixture = document()
    let metadata = MediaMetadataSummary(
      mediaId: fixture.mediaId, title: fixture.values.title,
      originalTitle: nil, overview: fixture.values.overview, releaseDate: nil, year: 2019,
      runtimeMinutes: 103, rating: nil, contentRating: nil, genres: fixture.values.genres,
      studios: fixture.values.studios, countries: ["US"], credits: [], poster: nil, backdrop: nil,
      still: nil, provider: nil, providerMediaId: nil, reviewState: .matched)
    for section in MetadataEditorSheet.Page.allCases {
      let view = NSHostingView(
        rootView: MetadataEditorSheet(
          metadata: metadata, onSaved: {}, previewDocument: fixture, page: section
        )
        .environmentObject(model).environment(\.colorScheme, .dark).frame(width: 940, height: 720))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 940, height: 720), styleMask: [.titled, .resizable],
        backing: .buffered, defer: false)
      window.contentView = view
      try await Task.sleep(for: .milliseconds(150))
      view.layoutSubtreeIfNeeded()
      defer { window.orderOut(nil) }
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      #expect(png.count > 10_000)
      Attachment.record(Array(png), named: "Metadata Editor - \(section.rawValue).png")
    }
  }

  @Test func cropPreservesOriginalAndRendersRotationAndCircularPersonPreview() async throws {
    let original = NSImage(size: NSSize(width: 600, height: 300))
    original.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 300, height: 300).fill()
    NSColor.systemOrange.setFill()
    NSRect(x: 300, y: 0, width: 300, height: 300).fill()
    original.unlockFocus()
    let rotated = CropImage.rotated(original, degrees: 90)
    #expect(rotated.size == NSSize(width: 300, height: 600))
    let crop = ArtworkCrop(x: 0, y: 0.25, width: 1, height: 0.5, rotation: 90)
    #expect(CropImage.render(original, crop: crop).size == NSSize(width: 300, height: 300))
    #expect(original.size == NSSize(width: 600, height: 300))
    let view = NSHostingView(
      rootView: ArtworkCropSheet(
        image: original, ratio: 1, roundPreview: true, initial: crop, onSave: { _ in }
      )
      .environment(\.colorScheme, .dark))
    view.frame = NSRect(x: 0, y: 0, width: 640, height: 580)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    Attachment.record(Array(png), named: "Person photo crop - synthetic.png")
  }
}
