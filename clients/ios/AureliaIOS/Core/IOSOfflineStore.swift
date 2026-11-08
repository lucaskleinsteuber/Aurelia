import Combine
import Foundation

/// The downloads on this iPhone or iPad, the ones still loading and the profiles that may open
/// them offline. Files live in this app's own data folder, excluded from backups, never next to
/// the media and never on the server.
@MainActor
final class IOSOfflineStore: ObservableObject {
  static let shared = IOSOfflineStore(root: defaultRoot(), transfers: true)

  @Published private(set) var titles: [IOSOfflineTitle] = []
  @Published private(set) var pending: [IOSOfflinePending] = []
  @Published private(set) var cards: [IOSOfflineProfileCard] = []
  /// Titles whose download is being prepared (ticket, subtitles, pictures).
  @Published private(set) var preparing: Set<UUID> = []
  @Published var errorMessage: String?

  let root: URL
  private var downloader: IOSOfflineDownloader?
  /// The system's completion handler after it woke the app for finished transfers.
  var backgroundCompletion: (() -> Void)?

  init(root: URL, transfers: Bool) {
    self.root = root
    load()
    guard transfers else { return }
    let downloader = IOSOfflineDownloader(root: root, events: events())
    self.downloader = downloader
    Task { await reconcile(with: downloader) }
  }

  static func defaultRoot() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Aurelia Offline Titles", isDirectory: true)
  }

  // MARK: Reading

  func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
  func fileURL(for title: IOSOfflineTitle) -> URL {
    folder(for: title.id).appendingPathComponent(title.fileName)
  }
  func pictureURL(_ title: IOSOfflineTitle, backdrop: Bool = false, series: Bool = false) -> URL? {
    let name = series ? title.seriesPosterFile : backdrop ? title.backdropFile : title.posterFile
    return name.map { folder(for: title.id).appendingPathComponent($0) }
  }
  func subtitleURLs(_ title: IOSOfflineTitle) -> [Int: URL] {
    Dictionary(
      uniqueKeysWithValues: title.subtitles.map {
        ($0.index, folder(for: title.id).appendingPathComponent($0.fileName))
      })
  }

  func title(_ id: UUID) -> IOSOfflineTitle? { titles.first { $0.id == id } }
  func pending(_ id: UUID) -> IOSOfflinePending? { pending.first { $0.id == id } }

  func titles(serverID: UUID, profileID: UUID) -> [IOSOfflineTitle] {
    titles.filter { $0.serverID == serverID && $0.profileID == profileID }
      .sorted { $0.downloadedAt > $1.downloadedAt }
  }
  func pending(serverID: UUID, profileID: UUID) -> [IOSOfflinePending] {
    pending.filter { $0.title.serverID == serverID && $0.title.profileID == profileID }
  }
  func hasDownloads(serverID: UUID) -> Bool { titles.contains { $0.serverID == serverID } }

  /// The profiles with downloads from this server, with their cards when they have one.
  func offlineProfiles(serverID: UUID) -> [IOSOfflineProfileCard] {
    let owners = Set(titles.filter { $0.serverID == serverID }.map(\.profileID))
    return cards.filter { $0.serverID == serverID && owners.contains($0.profileID) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  var totalBytes: Int64 { titles.reduce(0) { $0 + $1.bytes } }

  var availableBytes: Int64 {
    let probe = FileManager.default.fileExists(atPath: root.path)
      ? root : root.deletingLastPathComponent()
    return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage) ?? Int64.max
  }

  // MARK: Downloading

  /// Downloads a movie or episode for the profile `api` is signed in with. Subtitles and
  /// pictures load first; the file itself then keeps loading while the app is in the background.
  func download(_ item: IOSCatalogItem, series: IOSCatalogItem?, api: IOSAPIClient) async {
    guard IOSOfflineRules.canDownload(item), let connection = api.connection,
      let session = api.session, let downloader, !preparing.contains(item.id),
      pending(item.id) == nil
    else { return }
    if let existing = title(item.id) {
      // One copy per title on this device: say so, rather than doing nothing.
      if existing.profileID != session.user.id {
        errorMessage = "\(item.title) is already downloaded on this device by another profile."
      }
      return
    }
    preparing.insert(item.id)
    errorMessage = nil
    defer { preparing.remove(item.id) }
    let folder = folder(for: item.id)
    var ticketID: UUID?
    do {
      let ticket = try await api.createTicket(mediaID: item.id)
      ticketID = ticket.id
      guard IOSOfflineRules.hasRoom(for: ticket.contentLength, available: availableBytes) else {
        throw IOSOfflineError.notEnoughSpace
      }
      try prepareRoot()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var title = IOSOfflineTitle(
        id: item.id, serverID: connection.serverID, profileID: session.user.id, title: item.title,
        subtitle: IOSOfflineRules.subtitle(for: item), kind: item.kind.rawValue,
        fileName: "title.\(IOSOfflineRules.fileExtension(ticket.contentType))",
        contentType: ticket.contentType, bytes: ticket.contentLength, downloadedAt: Date(),
        positionMilliseconds: ticket.progress.positionMilliseconds,
        durationMilliseconds: ticket.progress.durationMilliseconds,
        isCompleted: ticket.progress.isCompleted, progressSavedAt: nil, progressDirty: false,
        subtitles: [], serverRevision: ticket.progress.revision, overview: item.overview,
        year: item.year, genres: item.genres, parentID: item.parentId,
        parentTitle: item.parentTitle ?? series?.title, seasonNumber: item.seasonNumber,
        episodeNumber: item.episodeNumber)
      title.subtitles = await Self.subtitles(ticket: ticket, into: folder, api: api)
      title.posterFile = await Self.keep(item.poster, width: 640, as: "poster.image", in: folder, api: api)
      title.backdropFile = await Self.keep(
        item.backdrop, width: 1920, as: "backdrop.image", in: folder, api: api)
      title.seriesPosterFile = await Self.keep(
        series?.poster, width: 640, as: "series-poster.image", in: folder, api: api)
      let url = try api.validatedStreamURL(path: ticket.streamPath)
      var request = URLRequest(url: url)
      request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
      request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      request.cachePolicy = .reloadIgnoringLocalCacheData
      // The profile may have closed meanwhile; then nothing starts.
      guard pending(item.id) == nil, self.title(item.id) == nil else { return }
      let startNow = !pending.contains { $0.state == .downloading }
      let entry = IOSOfflinePending(
        title: title, ticketID: ticket.id, startedAt: Date(),
        state: startNow ? .downloading : .waiting, fingerprint: connection.fingerprint)
      pending.append(entry)
      savePending()
      downloader.start(
        request, media: item.id, fingerprint: connection.fingerprint, startNow: startNow)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      if let ticketID { Task { try? await api.revokeTicket(id: ticketID) } }
      errorMessage = "\(item.title) could not be downloaded. \(Self.describe(error))"
    }
  }

  /// Tries a stopped download again: where it stopped when it can, otherwise from the start.
  func retry(_ id: UUID, api: IOSAPIClient?) async {
    guard let entry = pending(id), entry.state == .failed, let downloader else { return }
    if entry.canResume(), let name = entry.resumeFile,
      let data = try? Data(contentsOf: folder(for: id).appendingPathComponent(name))
    {
      let startNow = !pending.contains { $0.state == .downloading }
      update(id) {
        $0.state = startNow ? .downloading : .waiting
        $0.message = nil
      }
      downloader.resume(data, media: id, fingerprint: entry.fingerprint, startNow: startNow)
      return
    }
    guard let api, api.session?.user.id == entry.title.profileID,
      let item = try? await api.summary(id: id)
    else {
      update(id) { $0.message = "Open Aurelia at home to try this download again." }
      return
    }
    let series: IOSCatalogItem? =
      if let parent = item.parentId { try? await api.summary(id: parent) } else { nil }
    discard(id)
    await download(item, series: series, api: api)
  }

  func cancel(_ id: UUID) {
    downloader?.cancel(media: id)
    discard(id)
    startNextWaiting()
  }

  /// Starts the oldest waiting download once none is loading.
  private func startNextWaiting() {
    guard let downloader, !pending.contains(where: { $0.state == .downloading }),
      let next = pending.filter({ $0.state == .waiting }).min(by: { $0.startedAt < $1.startedAt })
    else { return }
    update(next.id) { $0.state = .downloading }
    downloader.startQueued(media: next.id)
  }

  /// Removes the downloaded file; progress not yet sent goes with it.
  func remove(_ id: UUID) {
    cancel(id)
    titles.removeAll { $0.id == id }
    try? FileManager.default.removeItem(at: folder(for: id))
    saveTitles()
  }

  /// Everything from one server: its downloads and its profiles' offline cards. Used when this
  /// device is disconnected from that server.
  func forget(serverID: UUID) {
    for entry in pending where entry.title.serverID == serverID { cancel(entry.id) }
    for title in titles where title.serverID == serverID { remove(title.id) }
    cards.removeAll { $0.serverID == serverID }
    saveCards()
  }

  private func discard(_ id: UUID) {
    pending.removeAll { $0.id == id }
    if title(id) == nil { try? FileManager.default.removeItem(at: folder(for: id)) }
    savePending()
  }

  private func update(_ id: UUID, _ change: (inout IOSOfflinePending) -> Void) {
    guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
    change(&pending[index])
    savePending()
  }

  // MARK: Transfer events

  private func events() -> IOSOfflineDownloader.Events {
    IOSOfflineDownloader.Events(
      progress: { [weak self] id, received, expected in
        Task { @MainActor in self?.transferProgress(id, received: received, expected: expected) }
      },
      finished: { [weak self] id, staged, status in
        Task { @MainActor in self?.transferFinished(id, staged: staged, status: status) }
      },
      failed: { [weak self] id, message, resumeData in
        Task { @MainActor in self?.transferFailed(id, message: message, resumeData: resumeData) }
      },
      eventsFinished: { [weak self] in
        Task { @MainActor in
          self?.backgroundCompletion?()
          self?.backgroundCompletion = nil
        }
      })
  }

  func transferProgress(_ id: UUID, received: Int64, expected: Int64) {
    guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
    // Published at whole percents, not for every few kilobytes.
    let total = expected > 0 ? expected : pending[index].title.bytes
    let step = max(1, total / 100)
    if received / step != pending[index].receivedBytes / step || received == total {
      pending[index].receivedBytes = received
    }
  }

  func transferFinished(_ id: UUID, staged: URL, status: Int) {
    guard let index = pending.firstIndex(where: { $0.id == id }) else {
      try? FileManager.default.removeItem(at: staged)
      return
    }
    guard status == 200 || status == 206 else {
      try? FileManager.default.removeItem(at: staged)
      transferFailed(id, message: Self.describe(status: status), resumeData: nil)
      return
    }
    var title = pending[index].title
    let destination = fileURL(for: title)
    do {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: staged, to: destination)
    } catch {
      transferFailed(id, message: "The file could not be saved.", resumeData: nil)
      return
    }
    if let name = pending[index].resumeFile {
      try? FileManager.default.removeItem(at: folder(for: id).appendingPathComponent(name))
    }
    title.bytes =
      (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64)
      ?? title.bytes
    title.downloadedAt = Date()
    pending.remove(at: index)
    savePending()
    record(title)
    startNextWaiting()
  }

  /// Keeps a finished download whose file is already in its folder.
  func record(_ title: IOSOfflineTitle) {
    titles.removeAll { $0.id == title.id }
    titles.append(title)
    saveTitles()
  }

  func transferFailed(_ id: UUID, message: String, resumeData: Data?) {
    guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
    pending[index].state = .failed
    pending[index].message = message
    if let resumeData,
      (try? resumeData.write(to: folder(for: id).appendingPathComponent("resume.data"))) != nil
    {
      pending[index].resumeFile = "resume.data"
    } else {
      pending[index].resumeFile = nil
    }
    savePending()
    startNextWaiting()
  }

  /// After a restart: downloads the system no longer carries out stopped while the app was gone.
  private func reconcile(with downloader: IOSOfflineDownloader) async {
    // Only what was saved before this launch; a download started meanwhile is not yet listed.
    let saved = Set(pending.map(\.id))
    let known = await downloader.knownMedia()
    for entry in pending
    where saved.contains(entry.id) && entry.state != .failed && !known.contains(entry.id) {
      transferFailed(entry.id, message: "The download stopped.", resumeData: nil)
    }
    startNextWaiting()
  }

  // MARK: Progress

  /// Saves a position watched offline; it goes to the server when the profile opens there again.
  @discardableResult
  func saveProgress(_ id: UUID, position: Int64, duration: Int64, finished: Bool)
    -> IOSOfflineTitle?
  {
    guard let index = titles.firstIndex(where: { $0.id == id }) else { return nil }
    titles[index].positionMilliseconds = max(0, position)
    titles[index].durationMilliseconds = max(duration, titles[index].durationMilliseconds, position)
    titles[index].isCompleted = finished
    titles[index].progressSavedAt = Date()
    titles[index].progressDirty = true
    saveTitles()
    return titles[index]
  }

  /// Sends progress watched offline to the server when it is newer than the server's, and takes
  /// over the server's progress for downloads nobody watched offline since.
  func syncProgress(api: IOSAPIClient) async {
    guard let serverID = api.connection?.serverID, let profileID = api.session?.user.id else {
      return
    }
    for title in titles where title.serverID == serverID && title.profileID == profileID {
      guard let server = try? await api.progress(mediaID: title.id),
        let index = titles.firstIndex(where: { $0.id == title.id })
      else { continue }
      let current = titles[index]
      guard current.progressDirty else {
        titles[index] = IOSOfflineRules.adopting(server, into: current)
        continue
      }
      guard IOSOfflineRules.offlineIsNewer(current, server: server) else {
        titles[index] = IOSOfflineRules.adopting(server, into: current)
        titles[index].progressDirty = false
        continue
      }
      guard current.durationMilliseconds > 0,
        let saved = try? await api.saveProgress(
          mediaID: current.id, position: min(current.positionMilliseconds, current.durationMilliseconds),
          duration: current.durationMilliseconds, finished: current.isCompleted,
          expectedRevision: server.revision, mutationID: UUID()),
        let after = titles.firstIndex(where: { $0.id == current.id })
      else { continue }
      // Watched again meanwhile: that newer position is sent next time.
      if titles[after].progressSavedAt == current.progressSavedAt {
        titles[after].progressDirty = false
      }
      titles[after].serverRevision = saved.revision
    }
    saveTitles()
  }

  // MARK: Offline profiles

  func remember(_ card: IOSOfflineProfileCard) {
    cards.removeAll { $0.serverID == card.serverID && $0.profileID == card.profileID }
    cards.append(card)
    saveCards()
  }

  func card(serverID: UUID, profileID: UUID) -> IOSOfflineProfileCard? {
    cards.first { $0.serverID == serverID && $0.profileID == profileID }
  }

  // MARK: Files

  private var indexURL: URL { root.appendingPathComponent("index.json") }
  private var pendingURL: URL { root.appendingPathComponent("pending.json") }
  private var cardsURL: URL { root.appendingPathComponent("profiles.json") }

  private func prepareRoot() throws {
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var folder = root
    var values = URLResourceValues()
    // Downloads can be loaded again; they don't belong in an iCloud backup.
    values.isExcludedFromBackup = true
    try? folder.setResourceValues(values)
  }

  private func load() {
    let decoder = JSONDecoder()
    if let data = try? Data(contentsOf: indexURL),
      let stored = try? decoder.decode([IOSOfflineTitle].self, from: data)
    {
      // A title whose file is gone is forgotten.
      titles = stored.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
    }
    if let data = try? Data(contentsOf: pendingURL),
      let stored = try? decoder.decode([IOSOfflinePending].self, from: data)
    {
      pending = stored
    }
    if let data = try? Data(contentsOf: cardsURL),
      let stored = try? decoder.decode([IOSOfflineProfileCard].self, from: data)
    {
      cards = stored
    }
  }

  private func saveTitles() { write(titles, to: indexURL) }
  private func savePending() { write(pending, to: pendingURL) }
  private func saveCards() { write(cards, to: cardsURL) }

  private func write(_ value: some Encodable, to url: URL) {
    try? prepareRoot()
    guard let data = try? JSONEncoder().encode(value) else { return }
    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  // MARK: Helpers

  private static func subtitles(ticket: IOSPlaybackTicket, into folder: URL, api: IOSAPIClient)
    async -> [IOSOfflineSubtitle]
  {
    guard let tracks = try? await api.streamSubtitles(ticketID: ticket.id) else { return [] }
    var kept: [IOSOfflineSubtitle] = []
    for track in IOSLiveSubtitleTrack.sidecarFiles(tracks) {
      let name = "subtitle-\(track.index).vtt"
      guard
        let data = try? await api.streamSubtitleFile(streamPath: ticket.streamPath, index: track.index),
        (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil
      else { continue }
      kept.append(
        IOSOfflineSubtitle(
          index: track.index, language: track.language, title: track.title,
          isForced: track.isForced, isSdh: track.isSdh, fileName: name))
    }
    return kept
  }

  private static func keep(
    _ artwork: IOSArtwork?, width: Int, as name: String, in folder: URL, api: IOSAPIClient
  ) async -> String? {
    guard let artwork, let data = try? await api.artworkData(artwork: artwork, width: width),
      (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil
    else { return nil }
    return name
  }

  static func describe(_ error: Error) -> String {
    if let offline = error as? IOSOfflineError { return offline.errorDescription ?? "" }
    if let core = error as? IOSCoreError, let status = core.statusCode {
      return describe(status: status)
    }
    return "Check the connection to the server and try again."
  }

  static func describe(status: Int) -> String {
    switch status {
    case 401, 403: "Open your profile again and try again."
    case 404: "The title is no longer in the library."
    case 503: "The media drive isn’t connected to the server."
    default: "The server answered \(status)."
    }
  }
}

enum IOSOfflineError: LocalizedError {
  case notEnoughSpace

  var errorDescription: String? {
    switch self {
    case .notEnoughSpace: "There isn’t enough free space on this device."
    }
  }
}

/// The background transfers: the system keeps loading while the app is in the background or
/// closed, and wakes it when a file is complete. Every connection is checked against the
/// server's pinned key, as everywhere else in the app.
final class IOSOfflineDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  struct Events: Sendable {
    let progress: @Sendable (UUID, Int64, Int64) -> Void
    let finished: @Sendable (UUID, URL, Int) -> Void
    let failed: @Sendable (UUID, String, Data?) -> Void
    let eventsFinished: @Sendable () -> Void
  }

  /// What a transfer is about, kept with the system's task so it survives a restart.
  private struct Description: Codable {
    let media: UUID
    let fingerprint: String
  }

  static let identifier = (Bundle.main.bundleIdentifier ?? "com.lucas.aurelia.ios")
    + ".offline-downloads"

  private let root: URL
  private let events: Events
  private var session: URLSession!

  init(root: URL, events: Events) {
    self.root = root
    self.events = events
    super.init()
    let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForResource = 24 * 3600
    configuration.httpMaximumConnectionsPerHost = 1
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }

  /// A waiting download is handed to the system suspended, with its sign-in, and started later.
  func start(_ request: URLRequest, media: UUID, fingerprint: String, startNow: Bool) {
    let task = session.downloadTask(with: request)
    task.taskDescription = Self.describe(media: media, fingerprint: fingerprint)
    if startNow { task.resume() }
  }

  func resume(_ data: Data, media: UUID, fingerprint: String, startNow: Bool) {
    let task = session.downloadTask(withResumeData: data)
    task.taskDescription = Self.describe(media: media, fingerprint: fingerprint)
    if startNow { task.resume() }
  }

  func startQueued(media: UUID) {
    session.getAllTasks { [events] tasks in
      guard let task = tasks.first(where: { Self.description(of: $0)?.media == media }) else {
        events.failed(media, "The download stopped.", nil)
        return
      }
      task.resume()
    }
  }

  func cancel(media: UUID) {
    session.getAllTasks { tasks in
      for task in tasks where Self.description(of: task)?.media == media { task.cancel() }
    }
  }

  /// The downloads the system still carries out or holds for later.
  func knownMedia() async -> Set<UUID> {
    let tasks = await session.allTasks
    return Set(
      tasks.filter { $0.state == .running || $0.state == .suspended }
        .compactMap { Self.description(of: $0)?.media })
  }

  private static func describe(media: UUID, fingerprint: String) -> String? {
    (try? JSONEncoder().encode(Description(media: media, fingerprint: fingerprint)))
      .flatMap { String(data: $0, encoding: .utf8) }
  }

  private static func description(of task: URLSessionTask) -> Description? {
    task.taskDescription.flatMap { $0.data(using: .utf8) }
      .flatMap { try? JSONDecoder().decode(Description.self, from: $0) }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) ->
      Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let expected = Self.description(of: task)?.fingerprint,
      let trust = challenge.protectionSpace.serverTrust,
      let fingerprint = try? IOSServerIdentity.fingerprint(trust: trust),
      fingerprint.caseInsensitiveCompare(expected) == .orderedSame
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    guard let media = Self.description(of: downloadTask)?.media else { return }
    events.progress(media, totalBytesWritten, totalBytesExpectedToWrite)
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
  ) {
    guard let media = Self.description(of: downloadTask)?.media else { return }
    let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
    // The file at `location` is removed when this method returns; keep it in the title's folder.
    let folder = root.appendingPathComponent(media.uuidString, isDirectory: true)
    let staged = folder.appendingPathComponent("incoming-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: location, to: staged)
      events.finished(media, staged, status)
    } catch {
      events.failed(media, "The file could not be saved.", nil)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error, let media = Self.description(of: task)?.media else { return }
    // A transfer cancelled here was already forgotten by the store, which ignores this.
    let nsError = error as NSError
    let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    let message =
      nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
      ? "The server’s identity could not be confirmed."
      : "The connection to the server was lost."
    events.failed(media, message, resumeData)
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    events.eventsFinished()
  }
}
