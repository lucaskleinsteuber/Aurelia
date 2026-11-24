import Foundation
import Testing

@testable import Aurelia

/// Offline downloads with an invented title in a temporary folder; nothing is played or fetched.
@MainActor
struct OfflineDownloadTests {
  private func store() throws -> (OfflineDownloads, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aurelia-offline-\(UUID().uuidString)", isDirectory: true)
    return (OfflineDownloads(root: root), root)
  }

  private func invented(_ downloads: OfflineDownloads, id: UUID = UUID()) throws -> OfflineTitle {
    let title = OfflineTitle(
      id: id, serverId: UUID(), userId: UUID(), title: "Invented Film", subtitle: "2024",
      kind: "movie", fileName: "title.mkv", contentType: "video/x-matroska", bytes: 4,
      downloadedAt: Date(), positionMilliseconds: 60_000, durationMilliseconds: 600_000,
      isCompleted: false, progressSavedAt: nil, progressDirty: false,
      subtitles: [
        OfflineSubtitle(
          index: 1000, language: "de", title: "German", isForced: false, isSdh: false,
          fileName: "subtitle-1000.vtt")
      ])
    let folder = downloads.folder(for: id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([1, 2, 3, 4]).write(to: folder.appendingPathComponent("title.mkv"))
    try Data("WEBVTT\n".utf8).write(to: folder.appendingPathComponent("subtitle-1000.vtt"))
    let index = try JSONEncoder().encode([title])
    try index.write(to: downloads.root.appendingPathComponent("index.json"))
    return title
  }

  @Test
  func aDownloadPlaysFromItsFileWithItsSubtitlesAndKeepsProgress() async throws {
    let (first, root) = try store()
    defer { try? FileManager.default.removeItem(at: root) }
    let title = try invented(first)
    let downloads = OfflineDownloads(root: root)
    #expect(downloads.titles.map(\.id) == [title.id])
    #expect(downloads.titles(serverId: title.serverId, userId: title.userId).count == 1)
    let profile = StoredServerProfile(
      serverId: title.serverId, name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z")
    let client = OfflinePlaybackClient(profile: profile, title: title, downloads: downloads)
    let source = try await client.createPlayback(mediaId: title.id)
    #expect(source.progress.positionMilliseconds == 60_000)
    #expect(try client.streamURL(path: source.streamPath) == downloads.fileURL(for: title))
    let tracks = try await client.streamSubtitles(ticket: source.id)
    #expect(tracks.map(\.index) == [1000])
    #expect(tracks.first?.isSidecar == true)
    let relay = OfflineFileRelay(title: title, downloads: downloads)
    #expect(try await relay.start().isFileURL)
    #expect(relay.subtitleURL(index: 1000)?.lastPathComponent == "subtitle-1000.vtt")

    _ = try await client.updatePlaybackProgress(
      mediaId: title.id, positionMilliseconds: 120_000, durationMilliseconds: 600_000,
      isFinished: false)
    let reopened = OfflineDownloads(root: root)
    #expect(reopened.title(title.id)?.positionMilliseconds == 120_000)
    #expect(reopened.title(title.id)?.progressDirty == true)

    reopened.remove(title.id)
    #expect(!FileManager.default.fileExists(atPath: reopened.folder(for: title.id).path))
    #expect(OfflineDownloads(root: root).titles.isEmpty)
  }

  @Test
  func downloadsWaitTheirTurnAndAWaitingOneCanBeCancelled() throws {
    let (downloads, root) = try store()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = StoredServerProfile(
      serverId: UUID(), name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z",
      user: UserSummary(
        id: UUID(), username: "synthetic", role: .owner, createdAt: "2026-01-01T00:00:00Z"))
    func episode(_ number: Int) -> CatalogItemSummary {
      CatalogItemSummary(
        id: UUID(), kind: .episode, title: "Episode \(number)", originalTitle: nil, year: 2020,
        overview: nil, genres: [], poster: nil, backdrop: nil, availability: .available,
        isFavorite: false, progress: nil, addedAt: "2026-10-03T00:00:00Z",
        parentTitle: "Invented Show", seasonNumber: 1, episodeNumber: number)
    }
    let (first, second, third) = (episode(1), episode(2), episode(3))
    for item in [first, second, third] {
      downloads.download(item, subtitle: "S1 E\(item.episodeNumber ?? 0)", profile: profile)
    }
    // Only the first runs; the others wait in their order and the Downloads page says so.
    #expect(!downloads.isWaiting(first.id))
    #expect(downloads.waiting == [second.id, third.id])
    #expect(downloads.active.count == 3)

    downloads.cancel(second.id)
    #expect(downloads.waiting == [third.id])
    #expect(downloads.active[second.id] == nil)

    // Ending the running one starts the next waiting one.
    downloads.cancel(first.id)
    #expect(downloads.waiting.isEmpty)
    #expect(!downloads.isWaiting(third.id))
    #expect(downloads.active[third.id] != nil)
    downloads.cancel(third.id)
    #expect(downloads.active.isEmpty)
  }

  @Test
  func aTitleWhoseFileIsGoneIsForgotten() throws {
    let (first, root) = try store()
    defer { try? FileManager.default.removeItem(at: root) }
    let title = try invented(first)
    try FileManager.default.removeItem(at: first.fileURL(for: title))
    #expect(OfflineDownloads(root: root).titles.isEmpty)
    #expect(OfflineDownloads.fileExtension("video/mp4") == "mp4")
    #expect(OfflineDownloads.fileExtension("video/x-matroska") == "mkv")
  }

  @Test
  func withoutAnOpenProfileNoDownloadIsOffered() {
    let server = UUID()
    let child = UUID()
    let adult = UUID()
    func title(_ user: UUID) -> OfflineTitle {
      OfflineTitle(
        id: UUID(), serverId: server, userId: user, title: "Invented Film", subtitle: nil,
        kind: "movie", fileName: "title.mkv", contentType: "video/x-matroska", bytes: 4,
        downloadedAt: Date(), positionMilliseconds: 0, durationMilliseconds: 0,
        isCompleted: false, progressSavedAt: nil, progressDirty: false, subtitles: [])
    }
    let titles = [title(child), title(adult), title(adult)]
    // At "Server Not Answering" before anyone chose a profile: nothing, not every profile's titles.
    #expect(
      AppModel.visibleOfflineTitles(titles, server: server, user: nil, profileOpen: false).isEmpty)
    #expect(
      AppModel.visibleOfflineTitles(titles, server: server, user: child, profileOpen: false)
        .isEmpty)
    let childTitles = AppModel.visibleOfflineTitles(
      titles, server: server, user: child, profileOpen: true)
    #expect(childTitles.map(\.userId) == [child])
    #expect(
      AppModel.visibleOfflineTitles(titles, server: UUID(), user: adult, profileOpen: true)
        .isEmpty)
  }

  @Test
  func offlineProgressWinsWhileTheServerKeptItsRevisionWhateverTheClock() {
    var title = OfflineTitle(
      id: UUID(), serverId: UUID(), userId: UUID(), title: "Invented Film", subtitle: nil,
      kind: "movie", fileName: "title.mkv", contentType: "video/x-matroska", bytes: 4,
      downloadedAt: Date(), positionMilliseconds: 120_000, durationMilliseconds: 600_000,
      isCompleted: false, progressSavedAt: Date().addingTimeInterval(-7_200), progressDirty: true,
      subtitles: [], serverRevision: 7)
    // This Mac's clock runs two hours behind, so the server's time looks later.
    let now = ISO8601DateFormatter().string(from: Date())
    let unchanged = PlaybackProgressResponse(
      mediaId: title.id, positionMilliseconds: 0, durationMilliseconds: 600_000,
      isCompleted: false, lastPlayedAt: nil, updatedAt: now, revision: 7)
    #expect(OfflineDownloads.offlineIsNewer(title, server: unchanged))
    var elsewhere = unchanged
    elsewhere.revision = 8
    #expect(!OfflineDownloads.offlineIsNewer(title, server: elsewhere))
    title.serverRevision = nil
    #expect(!OfflineDownloads.offlineIsNewer(title, server: unchanged))
  }

  @Test
  func syncProgressDoesNotClearNewerOfflineProgressSavedMidSync() async throws {
    let (first, root) = try store()
    defer { try? FileManager.default.removeItem(at: root) }
    let title = try invented(first)
    let downloads = OfflineDownloads(root: root)
    downloads.saveProgress(title.id, position: 120_000, duration: 600_000, completed: false)
    let profile = StoredServerProfile(
      serverId: title.serverId, name: "Synthetic", baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z",
      user: UserSummary(
        id: title.userId, username: "synthetic", role: .owner, createdAt: "2026-01-01T00:00:00Z"))

    var sentPositions: [Int64] = []
    await downloads.syncProgress(
      profile: profile,
      fetchProgress: { mediaId in
        // Simulate playback writing a newer position while the network call is in flight.
        downloads.saveProgress(mediaId, position: 240_000, duration: 600_000, completed: false)
        return PlaybackProgressResponse(
          mediaId: mediaId, positionMilliseconds: 60_000, durationMilliseconds: 600_000,
          isCompleted: false, lastPlayedAt: nil, updatedAt: "2025-01-01T00:00:00Z", revision: 2)
      },
      updateProgress: { mediaId, position, duration, finished, _, _ in
        sentPositions.append(position)
        return PlaybackProgressResponse(
          mediaId: mediaId, positionMilliseconds: position, durationMilliseconds: duration,
          isCompleted: finished, lastPlayedAt: nil, updatedAt: "2026-01-01T00:00:00Z", revision: 3)
      })

    #expect(sentPositions == [120_000])
    #expect(downloads.title(title.id)?.progressDirty == true)
    #expect(downloads.title(title.id)?.positionMilliseconds == 240_000)
    #expect(downloads.title(title.id)?.serverRevision == nil)

    // A second sync with no concurrent writes clears progressDirty and records the server revision.
    await downloads.syncProgress(
      profile: profile,
      fetchProgress: { mediaId in
        PlaybackProgressResponse(
          mediaId: mediaId, positionMilliseconds: 120_000, durationMilliseconds: 600_000,
          isCompleted: false, lastPlayedAt: nil, updatedAt: "2025-01-01T00:00:00Z", revision: 3)
      },
      updateProgress: { mediaId, position, duration, finished, _, _ in
        sentPositions.append(position)
        return PlaybackProgressResponse(
          mediaId: mediaId, positionMilliseconds: position, durationMilliseconds: duration,
          isCompleted: finished, lastPlayedAt: nil, updatedAt: "2026-01-01T00:00:00Z", revision: 4)
      })
    #expect(sentPositions == [120_000, 240_000])
    #expect(downloads.title(title.id)?.progressDirty == false)
    #expect(downloads.title(title.id)?.serverRevision == 4)
  }

  @Test
  func removingDownloadWithUnsentProgressSyncsOrRetainsInOutboxAndWarnsOffline() async throws {
    let (first, root1) = try store()
    defer { try? FileManager.default.removeItem(at: root1) }
    let syncedTitle = try invented(first)
    let onlineDownloads = OfflineDownloads(root: root1)
    onlineDownloads.saveProgress(
      syncedTitle.id, position: 300_000, duration: 600_000, completed: false)
    let profile = StoredServerProfile(
      serverId: syncedTitle.serverId, name: "Synthetic",
      baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z",
      user: UserSummary(
        id: syncedTitle.userId, username: "synthetic", role: .owner,
        createdAt: "2026-01-01T00:00:00Z"))

    var uploadedPositions: [Int64] = []
    await onlineDownloads.remove(
      syncedTitle.id, profile: profile,
      fetchProgress: { mediaId in
        PlaybackProgressResponse(
          mediaId: mediaId, positionMilliseconds: 60_000, durationMilliseconds: 600_000,
          isCompleted: false, lastPlayedAt: nil, updatedAt: "2025-01-01T00:00:00Z", revision: 1)
      },
      updateProgress: { mediaId, position, duration, finished, _, _ in
        uploadedPositions.append(position)
        return PlaybackProgressResponse(
          mediaId: mediaId, positionMilliseconds: position, durationMilliseconds: duration,
          isCompleted: finished, lastPlayedAt: nil, updatedAt: "2026-01-01T00:00:00Z", revision: 2)
      })
    #expect(uploadedPositions == [300_000])
    #expect(onlineDownloads.titles.isEmpty)

    // When the server is unreachable, removing retains the unsent progress in the durable outbox.
    let (second, root2) = try store()
    defer { try? FileManager.default.removeItem(at: root2) }
    let offlineTitle = try invented(second)
    let fallbackDownloads = OfflineDownloads(root: root2)
    fallbackDownloads.saveProgress(
      offlineTitle.id, position: 420_000, duration: 600_000, completed: true)
    let fallbackProfile = StoredServerProfile(
      serverId: offlineTitle.serverId, name: "Synthetic",
      baseURL: URL(string: "https://fixture.invalid")!,
      publicKeyFingerprint: String(repeating: "A", count: 64), token: "test-only",
      sessionId: UUID(), expiresAt: "2099-01-01T00:00:00Z",
      user: UserSummary(
        id: offlineTitle.userId, username: "synthetic", role: .owner,
        createdAt: "2026-01-01T00:00:00Z"))
    let outboxDir = root2.appendingPathComponent("outbox", isDirectory: true)
    let outbox = PlaybackProgressOutbox(
      storageURL: outboxDir.appendingPathComponent("progress-outbox.json"))

    let dirtyBefore = try #require(fallbackDownloads.title(offlineTitle.id))
    #expect(
      OfflineTitleText.removalMessage(for: dirtyBefore, hasServerProfile: false)
        .localizedCaseInsensitiveContains("not been synced"))

    await fallbackDownloads.remove(
      offlineTitle.id, profile: fallbackProfile, outbox: outbox,
      fetchProgress: { _ in throw URLError(.notConnectedToInternet) },
      updateProgress: { _, _, _, _, _, _ in throw URLError(.notConnectedToInternet) })
    #expect(fallbackDownloads.titles.isEmpty)
    #expect(outbox.pendingCount(profile: fallbackProfile) == 1)
  }
}
