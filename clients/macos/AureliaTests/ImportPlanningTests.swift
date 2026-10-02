import AppKit
import SwiftUI
import Testing

@testable import Aurelia

@MainActor struct ImportPlanningTests {
  private func item(_ path: String, kind: MediaKind = .extra, season: Int? = nil)
    -> ImportPreviewItem
  {
    ImportPreviewItem(
      relativePath: path, title: URL(fileURLWithPath: path).lastPathComponent,
      kind: kind, parentRelativePath: "Breaking Bad", seasonNumber: season, episodeNumber: nil,
      category: "Featurettes", status: .recognized, reason: "Supplement folder context",
      isDirectory: kind == .series)
  }

  @Test func previewBuildsNestedFoldersAndKeepsSeasonAssignment() {
    let tree = ImportPreviewView.buildTree([
      item("Breaking Bad", kind: .series),
      item("Breaking Bad/Extras/Season 5/Featurettes 5.2/Inside Breaking Bad/ABQ.mkv", season: 5),
      item("Breaking Bad/Season 1/S01E01.mkv", kind: .episode, season: 1),
    ])
    #expect(tree.count == 1)
    #expect(tree[0].item?.kind == .series)
    let extras = tree[0].children?.first { $0.title == "Extras" }
    #expect(extras?.editableItem.isDirectory == true)
    #expect(extras?.editableItem.relativePath == "Breaking Bad/Extras")
    let fifth = extras?.children?.first
    #expect(fifth?.title == "Season 5")
    let featurettes = fifth?.children?.first
    #expect(featurettes?.title == "Featurettes 5.2")
    #expect(featurettes?.children?.first?.children?.first?.item?.seasonNumber == 5)
  }

  @Test func duplicatePathsDoNotCrashAndStorageRootIsRepresented() {
    let root = item("", kind: .series)
    let extra = item("Featurettes/Interview.mkv")
    let tree = ImportPreviewView.buildTree([root, extra, extra])
    #expect(tree.count == 1)
    #expect(tree[0].id == "")
    #expect(tree[0].children?.first?.children?.count == 1)
  }

  @Test func previewFlagIsOptInAndGeneralExtrasHaveNoSeason() throws {
    let request = CreateLibraryRequest(
      name: "Synthetic", path: "/synthetic", kind: .automatic, combineExisting: false,
      requireImportPreview: true)
    let body = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(body["requireImportPreview"] as? Bool == true)
    let general = ImportAssignmentUpdate(
      relativePath: "Chernobyl/Featurettes", isDirectory: true, kind: .extra,
      parentRelativePath: "Chernobyl")
    #expect(general.seasonNumber == nil)
    let data = try JSONEncoder().encode(general)
    #expect(try JSONDecoder().decode(ImportAssignmentUpdate.self, from: data) == general)
  }

  @Test func nativeImportPreviewRendersWithoutNetworkOrLibraryMutations() async throws {
    let previous = AppModel.active
    defer { AppModel.active = previous }
    let model = AppModel.serverSettingsRenderPreview()
    let library = LibrarySummary(
      id: UUID(), name: "Synthetic Archive", path: "/synthetic/Archive", kind: .automatic,
      availability: .available, createdAt: "2026-10-02T00:00:00Z",
      lastScanStartedAt: nil, lastScanCompletedAt: nil, lastError: nil,
      importPreviewRequired: true)
    let summary = ImportPreviewSummary(
      previewId: UUID(), libraryId: library.id, revision: "synthetic-revision", state: "Ready",
      counts: ImportPreviewCounts(
        files: 17, movies: 0, series: 1, episodes: 5, extras: 12,
        trailers: 0, pending: 0, ignored: 0, errors: 0), issues: [],
      targets: [
        ImportPreviewTarget(
          relativePath: "Chernobyl", title: "Chernobyl", kind: .series, seasonNumbers: [1])
      ])
    let view = NSHostingView(
      rootView: ImportPreviewView(
        library: library, previewSummary: summary,
        previewItems: [
          item("Chernobyl", kind: .series), item("Chernobyl/Featurettes/Interview.mkv"),
        ]
      )
      .environmentObject(model).environment(\.colorScheme, .dark).frame(width: 980, height: 760))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = view
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(150))
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(png.count > 10_000)
    Attachment.record(Array(png), named: "Native Import Preview - Synthetic.png")
  }

  @Test(arguments: [MediaKind.extra, .trailer, .episode])
  func nativeImportAssignmentControlsRenderForSupplementAndEpisodeKinds(kind: MediaKind)
    async throws
  {
    let fixture = ImportPreviewItem(
      relativePath: "Breaking Bad/Extras/Season 5/Featurettes 5.2/Inside Breaking Bad/ABQ.mkv",
      title: "Inside Breaking Bad: ABQ", kind: kind, parentRelativePath: "Breaking Bad",
      seasonNumber: 5, episodeNumber: kind == .episode ? 8 : nil,
      category: "Featurettes 5.2 / Inside Breaking Bad", status: .recognized,
      reason: "Synthetic assignment control fixture", isDirectory: false)
    let targets = [
      ImportPreviewTarget(
        relativePath: "Breaking Bad", title: "Breaking Bad", kind: .series,
        seasonNumbers: [1, 2, 3, 4, 5]),
      ImportPreviewTarget(
        relativePath: "El Camino", title: "El Camino", kind: .movie, seasonNumbers: []),
    ]
    let view = NSHostingView(
      rootView: ImportAssignmentEditor(items: [fixture], targets: targets) { _ in
        Issue.record("Render-only fixtures must not save an import assignment.")
      }
      .environment(\.colorScheme, .dark).frame(width: 610, height: 590))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 610, height: 590),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(150))
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(png.count > 10_000)
    Attachment.record(Array(png), named: "Native Import Assignment - \(kind.rawValue).png")
  }
}
