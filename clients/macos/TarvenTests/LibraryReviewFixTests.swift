import AppKit
import Foundation
import Testing

@testable import Tarven

/// Rules behind the library review fixes, with invented titles only; nothing is played or fetched.
@MainActor
struct LibraryReviewFixTests {
  private func item(
    kind: MediaKind = .episode, title: String = "Invented",
    progress: PlaybackProgressResponse? = nil,
    addedAt: String = "2026-11-01T00:00:00Z", genres: [String] = [], isFavorite: Bool = false
  ) -> CatalogItemSummary {
    CatalogItemSummary(
      id: UUID(), kind: kind, title: title, originalTitle: nil, year: 2020, overview: nil,
      genres: genres, poster: nil, backdrop: nil, availability: .available,
      isFavorite: isFavorite, progress: progress, addedAt: addedAt)
  }

  private func episode(season: Int, number: Int) -> EpisodePresentation {
    EpisodePresentation(
      item: item(title: "S\(season)E\(number)"), seasonNumber: season, episodeNumber: number)
  }

  private func download(
    title: String, parentId: UUID?, parentTitle: String?, episode: Int, downloadedAt: Date
  ) -> OfflineTitle {
    var result = OfflineTitle(
      id: UUID(), serverId: UUID(), userId: UUID(), title: title, subtitle: nil, kind: "episode",
      fileName: "title.mkv", contentType: "video/x-matroska", bytes: 4,
      downloadedAt: downloadedAt, positionMilliseconds: 0, durationMilliseconds: 0,
      isCompleted: false, progressSavedAt: nil, progressDirty: false, subtitles: [])
    result.parentId = parentId
    result.parentTitle = parentTitle
    result.seasonNumber = 1
    result.episodeNumber = episode
    return result
  }

  @Test
  func seriesPlayStartsWithTheFirstRegularEpisodeNotSpecials() {
    let episodes = [
      episode(season: 0, number: 1), episode(season: 1, number: 1), episode(season: 1, number: 2),
    ]
    #expect(DetailPlaybackPresentation.firstEpisode(episodes)?.seasonNumber == 1)
    #expect(DetailPlaybackPresentation.firstEpisode(episodes)?.episodeNumber == 1)
  }

  @Test
  func seriesWithOnlySpecialsStillPlaysTheFirstSpecial() {
    let specials = [episode(season: 0, number: 1), episode(season: 0, number: 2)]
    #expect(DetailPlaybackPresentation.firstEpisode(specials)?.episodeNumber == 1)
    #expect(DetailPlaybackPresentation.firstEpisode([]) == nil)
  }

  @Test
  func resumeShowsTheTimeLeft() {
    let id = UUID()
    let started = item(
      kind: .movie,
      progress: PlaybackProgressResponse(
        mediaId: id, positionMilliseconds: 600_000, durationMilliseconds: 2_000_000,
        isCompleted: false, lastPlayedAt: nil, updatedAt: nil))
    #expect(DetailPlaybackPresentation.remainingText(for: started) == "23 min left")

    let finished = item(
      kind: .movie,
      progress: PlaybackProgressResponse(
        mediaId: id, positionMilliseconds: 2_000_000, durationMilliseconds: 2_000_000,
        isCompleted: true, lastPlayedAt: nil, updatedAt: nil))
    #expect(DetailPlaybackPresentation.remainingText(for: finished) == nil)
    #expect(DetailPlaybackPresentation.remainingText(for: item(kind: .movie)) == nil)
  }

  @Test
  func downloadsGroupEpisodesBySeriesIdNotName() {
    let now = Date()
    let first = UUID()
    let second = UUID()
    let groups = OfflineTitlePresentation.seriesGroups([
      download(
        title: "A1", parentId: first, parentTitle: "Same Name", episode: 2, downloadedAt: now),
      download(
        title: "A2", parentId: first, parentTitle: "Same Name", episode: 1,
        downloadedAt: now.addingTimeInterval(-60)),
      download(
        title: "B1", parentId: second, parentTitle: "Same Name", episode: 1,
        downloadedAt: now.addingTimeInterval(-120)),
    ])
    #expect(groups.count == 2)
    #expect(groups.first?.id == "id:\(first.uuidString)")
    #expect(groups.first?.episodes.map(\.title) == ["A2", "A1"])
    #expect(groups.last?.episodes.map(\.title) == ["B1"])
  }

  @Test
  func downloadsWithoutSeriesIdFallBackToTheSeriesName() {
    let now = Date()
    let groups = OfflineTitlePresentation.seriesGroups([
      download(title: "E1", parentId: nil, parentTitle: "Old Show", episode: 1, downloadedAt: now),
      download(title: "E2", parentId: nil, parentTitle: "Old Show", episode: 2, downloadedAt: now),
    ])
    #expect(groups.count == 1)
    #expect(groups.first?.name == "Old Show")
  }

  @Test
  func smartListPreviewCountsAddedWithin() {
    let now = ServerDate.parse("2026-11-15T00:00:00Z")!
    let items = [
      item(kind: .movie, title: "Recent", addedAt: "2026-11-10T00:00:00Z"),
      item(kind: .movie, title: "Old", addedAt: "2026-01-01T00:00:00Z"),
    ]
    let rules = SmartCollectionRules(addedWithinDays: 30, match: "all")
    #expect(SmartCollectionPreview.matchCount(items, rules: rules, now: now) == 1)
  }

  @Test
  func smartListPreviewCombinesRulesWithAnyOrAll() {
    let now = ServerDate.parse("2026-11-15T00:00:00Z")!
    let items = [
      item(kind: .movie, title: "Recent Drama", addedAt: "2026-11-10T00:00:00Z", genres: ["Drama"]),
      item(kind: .movie, title: "Old Drama", addedAt: "2026-01-01T00:00:00Z", genres: ["Drama"]),
      item(kind: .movie, title: "Old Comedy", addedAt: "2026-01-01T00:00:00Z", genres: ["Comedy"]),
    ]
    let all = SmartCollectionRules(genres: ["drama"], addedWithinDays: 30, match: "all")
    let any = SmartCollectionRules(genres: ["drama"], addedWithinDays: 30, match: "any")
    #expect(SmartCollectionPreview.matchCount(items, rules: all, now: now) == 1)
    #expect(SmartCollectionPreview.matchCount(items, rules: any, now: now) == 2)
  }

  @Test
  func countTextUsesSingularForOneAndPluralOtherwise() {
    #expect(TarvenCountText.format(1, singular: "episode") == "1 episode")
    #expect(TarvenCountText.format(0, singular: "episode") == "0 episodes")
    #expect(TarvenCountText.format(1, singular: "title") == "1 title")
    #expect(TarvenCountText.format(2, singular: "title") == "2 titles")
    #expect(TarvenCountText.format(1, singular: "backup") == "1 backup")
    #expect(TarvenCountText.format(3, singular: "backup") == "3 backups")
    #expect(TarvenCountText.format(1, singular: "file") == "1 file")
    #expect(TarvenCountText.format(1, singular: "person", plural: "people") == "1 person")
    #expect(TarvenCountText.format(4, singular: "person", plural: "people") == "4 people")
  }

  @Test
  func deviceNamePrefersComputerNameAndStripsLocalSuffix() {
    #expect(
      TarvenDeviceName.resolve(computerName: "Living Room Mac", hostName: "studio.local")
        == "Living Room Mac")
    #expect(TarvenDeviceName.resolve(computerName: "   ", hostName: "studio.local") == "studio")
    #expect(TarvenDeviceName.resolve(computerName: nil, hostName: "  ") == "Mac")
  }

  @Test
  func sheetLayoutClampsTallSheetsToVisibleScreenHeight() {
    #expect(
      TarvenSheetLayout.clampedHeight(ideal: 760, minimum: 520, visibleScreenHeight: 740) == 636)
    #expect(
      TarvenSheetLayout.clampedHeight(ideal: 560, minimum: 400, visibleScreenHeight: 1000) == 560)
    #expect(
      TarvenSheetLayout.clampedHeight(ideal: 760, minimum: 520, visibleScreenHeight: nil) == 760)
  }

  @Test
  func keyboardShortcutsTableIncludesNavigationAndEditorShortcuts() {
    let allKeys = Set(TarvenKeyboardShortcuts.sections.flatMap(\.entries).flatMap(\.keys))
    for required in [
      "⌘F", "⌘[", "⌃⌘S", "⌘,", "⌘O", "?", "⌘/", "Esc", "⌘S", "⌘Z", "⇧⌘Z", "←", "→", "Space",
    ] {
      #expect(allKeys.contains(required), "Missing shortcut \(required)")
    }
  }

  @Test
  func menuCommandPolicyGatesOfflineAndOverlayCommands() {
    #expect(AppMenuCommandPolicy.canOpenSettings(isOfflineMode: false))
    #expect(!AppMenuCommandPolicy.canOpenSettings(isOfflineMode: true))

    #expect(
      AppMenuCommandPolicy.canAddMedia(
        hasProfile: true, canManageMedia: true, isPlaying: false,
        isInWrapped: false, isOfflineMode: false))
    #expect(
      !AppMenuCommandPolicy.canAddMedia(
        hasProfile: true, canManageMedia: true, isPlaying: true,
        isInWrapped: false, isOfflineMode: false))
    #expect(
      !AppMenuCommandPolicy.canAddMedia(
        hasProfile: true, canManageMedia: true, isPlaying: false,
        isInWrapped: true, isOfflineMode: false))
    #expect(
      !AppMenuCommandPolicy.settingsCoversFullWindowOverlay(
        isPlaying: false, isInWrapped: false))
    #expect(
      AppMenuCommandPolicy.settingsCoversFullWindowOverlay(
        isPlaying: true, isInWrapped: false))
    #expect(
      AppMenuCommandPolicy.settingsCoversFullWindowOverlay(
        isPlaying: false, isInWrapped: true))
  }

  @Test
  func wakeStatusFormatsMinutesAndSwitchesGuidanceAfterTwoMinutes() {
    #expect(ServerWakeStatusPresentation.elapsedText(seconds: 42) == "42 s")
    #expect(ServerWakeStatusPresentation.elapsedText(seconds: 120) == "2 min")
    #expect(ServerWakeStatusPresentation.elapsedText(seconds: 343) == "5 min 43 s")
    #expect(ServerWakeStatusPresentation.elapsedText(seconds: 3_900) == "1 h 5 min")

    #expect(ServerWakeStatusPresentation.guidance(elapsedSeconds: 30).contains("half a minute"))
    #expect(
      ServerWakeStatusPresentation.guidance(elapsedSeconds: 120).contains("longer than usual"))
  }

  @Test
  func wrappedDisplayStateCoversLoadingEmptyErrorAndClampedSlides() {
    #expect(WrappedDisplayState.resolve(wrapped: nil, index: 0, error: nil) == .loading)
    #expect(
      WrappedDisplayState.resolve(wrapped: nil, index: 0, error: "Server offline")
        == .failed("Server offline"))

    let empty = YearWrapped(year: 2026, profileName: "Alex", slides: [], month: nil)
    #expect(WrappedDisplayState.resolve(wrapped: empty, index: 0, error: nil) == .empty)

    let slide = WrappedSlide(
      kind: "intro", eyebrow: "2026", headline: "Your Year", bigNumber: nil, unit: nil, detail: nil,
      quip: "", accent: "night", mediaId: nil, poster: nil, posters: nil, facts: nil)
    let populated = YearWrapped(year: 2026, profileName: "Alex", slides: [slide], month: nil)
    #expect(WrappedDisplayState.resolve(wrapped: populated, index: 5, error: nil) == .slide(0))
  }

  @Test
  func profilePhotoCacheMarksFailuresAndMigratesLegacyCache() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("tarven-photo-test-\(UUID().uuidString)", isDirectory: true)
    let primary = tempRoot.appendingPathComponent("primary", isDirectory: true)
    let legacy = tempRoot.appendingPathComponent("legacy", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let cache = ProfilePhotoCache(folder: primary, legacyFolder: legacy)
    let missingId = UUID()
    #expect(cache.image(id: missingId, revision: 1) == nil)
    // Without a server loader (e.g., offline mode), loading immediately marks failed so initials show.
    cache.load(id: missingId, revision: 1)
    #expect(cache.hasFailed(id: missingId, revision: 1))

    // Storing a photo clears failure state.
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let jpeg = try #require(rep.representation(using: .jpeg, properties: [:]))
    let storedImage = try #require(NSImage(data: jpeg))
    cache.store(storedImage, data: jpeg, id: missingId, revision: 1)
    #expect(!cache.hasFailed(id: missingId, revision: 1))
    #expect(cache.image(id: missingId, revision: 1) != nil)

    // Legacy Caches photo is loaded and migrated into the primary folder.
    let migratedId = UUID()
    let legacyFile = legacy.appendingPathComponent("\(migratedId.uuidString)-2.jpg")
    try jpeg.write(to: legacyFile)
    #expect(cache.image(id: migratedId, revision: 2) != nil)
    let migratedFile = primary.appendingPathComponent("\(migratedId.uuidString)-2.jpg")
    #expect(FileManager.default.fileExists(atPath: migratedFile.path))
  }

  @Test
  func highContrastAppearanceAndSetupStepBarRules() {
    #expect(
      TarvenWindowAppearance.name(increaseContrast: true) == .accessibilityHighContrastDarkAqua)
    #expect(TarvenWindowAppearance.name(increaseContrast: false) == .darkAqua)
    #expect(TarvenDesign.strokeWidth(for: .increased) > TarvenDesign.strokeWidth(for: .standard))

    let steps: [SetupStep] = [.choose, .connect, .profile, .done]
    #expect(SetupStepBar.showsSkipAssistant(steps: steps, current: .connect))
    #expect(!SetupStepBar.showsSkipAssistant(steps: steps, current: .done))
    #expect(!SetupStepBar.isStepDone(position: 1, currentIndex: 1, stepCount: steps.count))
    #expect(SetupStepBar.isStepDone(position: 3, currentIndex: 3, stepCount: steps.count))
  }
}
