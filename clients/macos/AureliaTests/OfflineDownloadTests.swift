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
  func aTitleWhoseFileIsGoneIsForgotten() throws {
    let (first, root) = try store()
    defer { try? FileManager.default.removeItem(at: root) }
    let title = try invented(first)
    try FileManager.default.removeItem(at: first.fileURL(for: title))
    #expect(OfflineDownloads(root: root).titles.isEmpty)
    #expect(OfflineDownloads.fileExtension("video/mp4") == "mp4")
    #expect(OfflineDownloads.fileExtension("video/x-matroska") == "mkv")
  }
}
