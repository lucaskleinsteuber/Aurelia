import Foundation

/// A title downloaded to this Mac to watch without the server (owner's decision, 07.11.2026):
/// the original file, streamed once through a normal playback ticket and kept in this app's own
/// data folder until someone removes it. Progress watched offline goes back to the server later.
struct OfflineTitle: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let serverId: UUID
  let userId: UUID
  let title: String
  let subtitle: String?
  let kind: String
  let fileName: String
  let contentType: String
  var bytes: Int64
  let downloadedAt: Date
  var positionMilliseconds: Int64
  var durationMilliseconds: Int64
  var isCompleted: Bool
  var progressSavedAt: Date?
  var progressDirty: Bool
  var subtitles: [OfflineSubtitle]
}

struct OfflineSubtitle: Codable, Equatable, Sendable {
  let index: Int
  let language: String
  let title: String
  let isForced: Bool
  let isSdh: Bool
  let fileName: String
}

/// The downloads on this Mac, their files and the ones still loading.
@MainActor
final class OfflineDownloads: ObservableObject {
  static let shared = OfflineDownloads()

  @Published private(set) var titles: [OfflineTitle] = []
  /// Titles downloading now, with their share done (0…1).
  @Published private(set) var active: [UUID: Double] = [:]
  /// The names of the titles downloading now, for the Downloads page.
  @Published private(set) var activeNames: [UUID: String] = [:]
  @Published var errorMessage: String?

  let root: URL
  private var tasks: [UUID: Task<Void, Never>] = [:]

  init(root: URL? = nil) {
    // Inside this app's own (sandboxed) Application Support, never next to the media.
    let base =
      root
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Aurelia Offline Titles", isDirectory: true)
    self.root = base
    load()
  }

  private var indexURL: URL { root.appendingPathComponent("index.json") }

  func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

  func fileURL(for title: OfflineTitle) -> URL {
    folder(for: title.id).appendingPathComponent(title.fileName)
  }

  func title(_ id: UUID) -> OfflineTitle? { titles.first { $0.id == id } }

  /// Downloads for one profile on one server.
  func titles(serverId: UUID, userId: UUID) -> [OfflineTitle] {
    titles.filter { $0.serverId == serverId && $0.userId == userId }
      .sorted { $0.downloadedAt > $1.downloadedAt }
  }

  var totalBytes: Int64 { titles.reduce(0) { $0 + $1.bytes } }

  func isDownloaded(_ id: UUID) -> Bool { title(id) != nil }

  /// Downloads a movie or episode for the signed-in profile.
  func download(_ item: CatalogItemSummary, subtitle: String?, profile: StoredServerProfile) {
    guard let userId = profile.user?.id, tasks[item.id] == nil, title(item.id) == nil else { return }
    active[item.id] = 0
    activeNames[item.id] = subtitle.map { "\(item.title) · \($0)" } ?? item.title
    errorMessage = nil
    tasks[item.id] = Task { [weak self] in
      guard let self else { return }
      do {
        let downloaded = try await self.fetch(
          item, subtitle: subtitle, profile: profile, userId: userId)
        self.titles.append(downloaded)
        self.save()
      } catch is CancellationError {
      } catch {
        self.errorMessage = "\(item.title) could not be downloaded. \(error.localizedDescription)"
      }
      self.active[item.id] = nil
      self.activeNames[item.id] = nil
      self.tasks[item.id] = nil
    }
  }

  func cancel(_ id: UUID) {
    tasks[id]?.cancel()
    tasks[id] = nil
    active[id] = nil
    activeNames[id] = nil
    try? FileManager.default.removeItem(at: folder(for: id))
  }

  /// Removes the downloaded file; progress not yet sent stays with the title until removal.
  func remove(_ id: UUID) {
    cancel(id)
    titles.removeAll { $0.id == id }
    save()
  }

  /// Progress watched offline, sent to the server once it answers again.
  func saveProgress(_ id: UUID, position: Int64, duration: Int64, completed: Bool) {
    guard let index = titles.firstIndex(where: { $0.id == id }) else { return }
    titles[index].positionMilliseconds = position
    titles[index].durationMilliseconds = max(duration, titles[index].durationMilliseconds)
    titles[index].isCompleted = completed
    titles[index].progressSavedAt = Date()
    titles[index].progressDirty = true
    save()
  }

  /// Sends offline progress for this profile when it is newer than what the server has.
  func syncProgress(profile: StoredServerProfile) async {
    guard let userId = profile.user?.id else { return }
    let api = APIClient(profile: profile)
    for title in titles where title.progressDirty && title.serverId == profile.serverId
      && title.userId == userId
    {
      do {
        let server = try await api.playbackProgress(mediaId: title.id)
        let serverDate = server.updatedAt.flatMap(Self.date)
        if let saved = title.progressSavedAt, serverDate.map({ $0 < saved }) ?? true {
          _ = try await api.updatePlaybackProgress(
            mediaId: title.id, positionMilliseconds: title.positionMilliseconds,
            durationMilliseconds: title.durationMilliseconds, isFinished: title.isCompleted,
            expectedRevision: server.revision ?? 0, clientMutationId: UUID())
        }
        if let index = titles.firstIndex(where: { $0.id == title.id }) {
          titles[index].progressDirty = false
        }
      } catch {
        // Tried again at the next refresh.
      }
    }
    save()
  }

  private func fetch(
    _ item: CatalogItemSummary, subtitle: String?, profile: StoredServerProfile, userId: UUID
  ) async throws -> OfflineTitle {
    let api = APIClient(profile: profile)
    let ticket = try await api.createPlayback(mediaId: item.id)
    defer { Task { try? await api.revokePlayback(id: ticket.id) } }
    let available =
      (try? root.deletingLastPathComponent().resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey
      ]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
    guard ticket.contentLength <= 0 || ticket.contentLength + 1_000_000_000 < available else {
      throw OfflineDownloadError.notEnoughSpace
    }
    // The relay checks the server's pinned certificate and adds the sign-in; this Mac then
    // reads the whole file from it like a player would.
    let relay = try LoopbackStreamRelay(
      sourceURL: try api.streamURL(path: ticket.streamPath),
      publicKeyFingerprint: profile.publicKeyFingerprint, authorizationToken: profile.token)
    defer { relay.stop() }
    let local = try await relay.start()
    let folder = folder(for: item.id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let extensionName = Self.fileExtension(ticket.contentType)
    let fileName = "title.\(extensionName)"
    let destination = folder.appendingPathComponent(fileName)
    do {
      let id = item.id
      let temporary = try await OfflineFileDownload.run(from: local) { [weak self] share in
        Task { @MainActor in if self?.active[id] != nil { self?.active[id] = share } }
      }
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: temporary, to: destination)
      var subtitles: [OfflineSubtitle] = []
      if let tracks = try? await api.streamSubtitles(ticket: ticket.id) {
        for track in tracks where track.isSidecar && track.supported {
          guard let url = relay.subtitleURL(index: track.index),
            let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200
          else { continue }
          let name = "subtitle-\(track.index).vtt"
          try data.write(to: folder.appendingPathComponent(name))
          subtitles.append(
            OfflineSubtitle(
              index: track.index, language: track.language, title: track.title,
              isForced: track.isForced, isSdh: track.isSdh, fileName: name))
        }
      }
      let size =
        (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64)
        ?? ticket.contentLength
      return OfflineTitle(
        id: item.id, serverId: profile.serverId, userId: userId, title: item.title,
        subtitle: subtitle, kind: item.kind.rawValue, fileName: fileName,
        contentType: ticket.contentType, bytes: size, downloadedAt: Date(),
        positionMilliseconds: item.progress?.positionMilliseconds ?? 0,
        durationMilliseconds: item.progress?.durationMilliseconds ?? 0,
        isCompleted: item.progress?.isCompleted ?? false, progressSavedAt: nil,
        progressDirty: false, subtitles: subtitles)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  }

  static func fileExtension(_ contentType: String) -> String {
    switch contentType.lowercased() {
    case "video/mp4": "mp4"
    case "video/quicktime": "mov"
    case "video/x-m4v": "m4v"
    case "video/x-msvideo": "avi"
    case "video/webm": "webm"
    default: "mkv"
    }
  }

  static func date(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }

  private func load() {
    guard let data = try? Data(contentsOf: indexURL),
      let stored = try? JSONDecoder().decode([OfflineTitle].self, from: data)
    else { return }
    // A title whose file is gone (removed by hand) is forgotten.
    titles = stored.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
  }

  private func save() {
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(titles) {
      try? data.write(to: indexURL, options: .atomic)
    }
  }
}

enum OfflineDownloadError: LocalizedError {
  case notEnoughSpace
  case failed(Int)

  var errorDescription: String? {
    switch self {
    case .notEnoughSpace: "There isn’t enough free space on this Mac."
    case .failed(let status): "The server answered \(status)."
    }
  }
}

/// One file download with progress, from the local relay to a temporary file.
final class OfflineFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let progress: @Sendable (Double) -> Void
  private var continuation: CheckedContinuation<URL, Error>?
  private let lock = NSLock()

  private init(progress: @escaping @Sendable (Double) -> Void) {
    self.progress = progress
  }

  static func run(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    let download = OfflineFileDownload(progress: progress)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 60 * 60 * 24
    let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let task = session.downloadTask(with: url)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        download.lock.withLock { download.continuation = continuation }
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  private func finish(_ result: Result<URL, Error>) {
    let waiting = lock.withLock {
      let value = continuation
      continuation = nil
      return value
    }
    waiting?.resume(with: result)
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0 else { return }
    progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
  ) {
    if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
      finish(.failure(OfflineDownloadError.failed(status)))
      return
    }
    // The file at `location` is removed when this method returns; keep it.
    let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
      try FileManager.default.moveItem(at: location, to: kept)
      finish(.success(kept))
    } catch {
      finish(.failure(error))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
    }
  }
}

/// Plays a downloaded title through the normal player, with no server: the ticket, progress and
/// subtitles come from this Mac.
@MainActor
final class OfflinePlaybackClient: PlaybackClientProtocol {
  let profile: StoredServerProfile
  private let downloads: OfflineDownloads
  private let title: OfflineTitle

  init(profile: StoredServerProfile, title: OfflineTitle, downloads: OfflineDownloads = .shared) {
    self.profile = profile
    self.title = title
    self.downloads = downloads
  }

  private var progress: PlaybackProgressResponse {
    let current = downloads.title(title.id) ?? title
    return PlaybackProgressResponse(
      mediaId: current.id, positionMilliseconds: current.positionMilliseconds,
      durationMilliseconds: current.durationMilliseconds, isCompleted: current.isCompleted,
      lastPlayedAt: nil, updatedAt: nil)
  }

  func createPlayback(mediaId: UUID) async throws -> PlaybackSourceResponse {
    PlaybackSourceResponse(
      id: UUID(), mediaId: title.id, streamPath: "/offline", contentType: title.contentType,
      contentLength: title.bytes, expiresAt: "2099-01-01T00:00:00Z", progress: progress)
  }

  func playbackProgress(mediaId: UUID) async throws -> PlaybackProgressResponse { progress }

  func updatePlaybackProgress(
    mediaId: UUID, positionMilliseconds: Int64, durationMilliseconds: Int64, isFinished: Bool
  ) async throws -> PlaybackProgressResponse {
    downloads.saveProgress(
      title.id, position: positionMilliseconds, duration: durationMilliseconds,
      completed: isFinished)
    return progress
  }

  func revokePlayback(id: UUID) async throws {}

  func streamURL(path: String) throws -> URL { downloads.fileURL(for: title) }

  func streamSubtitles(ticket: UUID) async throws -> [LiveSubtitleTrack] {
    title.subtitles.map {
      LiveSubtitleTrack(
        index: $0.index, codec: "webvtt", language: $0.language, title: $0.title,
        isForced: $0.isForced, supported: true, isSidecar: true, isSdh: $0.isSdh)
    }
  }
}

/// The "relay" of a downloaded title: the file itself and its subtitle files.
@MainActor
final class OfflineFileRelay: PlaybackRelayProtocol {
  private let file: URL
  private let subtitles: [Int: URL]

  init(title: OfflineTitle, downloads: OfflineDownloads = .shared) {
    file = downloads.fileURL(for: title)
    subtitles = Dictionary(
      uniqueKeysWithValues: title.subtitles.map {
        ($0.index, downloads.folder(for: title.id).appendingPathComponent($0.fileName))
      })
  }

  func start() async throws -> URL { file }
  func updateSourceURL(_ url: URL) {}
  func subtitleURL(index: Int) -> URL? { subtitles[index] }
  func stop() {}
}
