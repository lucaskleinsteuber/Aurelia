import Combine
import Foundation

/// Scheduling is separate from preparation so logic checks never start a system transfer.
protocol IOSOfflineTransferring: AnyObject, Sendable {
  func start(_ request: URLRequest, media: UUID, fingerprint: String, startNow: Bool)
  func resume(_ data: Data, media: UUID, fingerprint: String, startNow: Bool)
  func startQueued(media: UUID)
  func cancel(media: UUID)
  func knownMedia() async -> Set<UUID>
}

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
  /// Space taken by download folders no listed title uses, kept only after the list of downloads
  /// was damaged; Downloads offers to remove it.
  @Published private(set) var leftoverBytes: Int64 = 0

  let root: URL
  private var downloader: (any IOSOfflineTransferring)?
  private struct Preparation {
    let token: UUID
    let serverID: UUID
    let profileID: UUID
  }
  private var preparations: [UUID: Preparation] = [:]
  /// Converted downloads running now, and the client each one continues with.
  private var convertedTasks: [UUID: Task<Void, Never>] = [:]
  private var convertedRuns: [UUID: UUID] = [:]
  private var convertedClients: [UUID: IOSAPIClient] = [:]
  /// Lets the app keep a converted download going in the background (BGContinuedProcessingTask):
  /// called when one starts, as it moves on (0…1) and when it ends.
  var convertedStarted: ((_ media: UUID, _ run: UUID, _ title: String) -> Void)?
  var convertedProgressed: ((_ media: UUID, _ run: UUID, _ share: Double) -> Void)?
  var convertedEnded: ((_ media: UUID, _ run: UUID, _ success: Bool) -> Void)?
  /// The system's completion handler after it woke the app for finished transfers.
  var backgroundCompletion: (() -> Void)?

  init(root: URL, transfers: Bool, transfer: (any IOSOfflineTransferring)? = nil) {
    self.root = root
    load()
    if let transfer {
      downloader = transfer
      return
    }
    guard transfers else { return }
    let downloader = IOSOfflineDownloader(root: root, events: events())
    self.downloader = downloader
    Task { await reconcile(with: downloader) }
  }

  static func defaultRoot() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Tarven Offline Titles", isDirectory: true)
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
    let probe =
      FileManager.default.fileExists(atPath: root.path)
      ? root : root.deletingLastPathComponent()
    return
      (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage) ?? Int64.max
  }

  // MARK: Downloading

  /// Downloads a movie or episode for the profile `api` is signed in with. Subtitles and
  /// pictures load first; the file itself then keeps loading while the app is in the background.
  ///
  /// With a `quality` the server converts a smaller copy ("converted-downloads-v1"), fetched
  /// segment by segment while the app runs (owner's decision, 15.11.2026).
  func download(
    _ item: IOSCatalogItem, series: IOSCatalogItem?, api: IOSAPIClient, quality: String? = nil,
    audio: Int? = nil, expectedBytes: Int64? = nil
  ) async {
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
    let preparation = Preparation(
      token: UUID(), serverID: connection.serverID, profileID: session.user.id)
    preparations[item.id] = preparation
    let isCurrent: @MainActor () -> Bool = { [weak self] in
      self?.preparations[item.id]?.token == preparation.token && !Task.isCancelled
    }
    errorMessage = nil
    defer {
      if preparations[item.id]?.token == preparation.token {
        preparations[item.id] = nil
        preparing.remove(item.id)
      }
    }
    let folder = folder(for: item.id)
    var ticketID: UUID?
    do {
      let ticket = try await api.createTicket(mediaID: item.id, forDownload: true)
      ticketID = ticket.id
      guard isCurrent() else { throw CancellationError() }
      let needed = quality == nil ? ticket.contentLength : (expectedBytes ?? 0)
      guard IOSOfflineRules.hasRoom(for: needed, available: availableBytes) else {
        throw IOSOfflineError.notEnoughSpace
      }
      try prepareRoot()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var title = IOSOfflineTitle(
        id: item.id, serverID: connection.serverID, profileID: session.user.id, title: item.title,
        subtitle: IOSOfflineRules.subtitle(for: item), kind: item.kind.rawValue,
        fileName: quality == nil
          ? "title.\(IOSOfflineRules.fileExtension(ticket.contentType))" : "title.mp4",
        contentType: quality == nil ? ticket.contentType : "video/mp4",
        bytes: quality == nil ? ticket.contentLength : (expectedBytes ?? 0), downloadedAt: Date(),
        positionMilliseconds: ticket.progress.positionMilliseconds,
        durationMilliseconds: ticket.progress.durationMilliseconds,
        isCompleted: ticket.progress.isCompleted, progressSavedAt: nil, progressDirty: false,
        subtitles: [], serverRevision: ticket.progress.revision, overview: item.overview,
        year: item.year, genres: item.genres, parentID: item.parentId,
        parentTitle: item.parentTitle ?? series?.title, seasonNumber: item.seasonNumber,
        episodeNumber: item.episodeNumber)
      title.quality = quality
      title.subtitles = await Self.subtitles(
        ticket: ticket, into: folder, api: api, isCurrent: isCurrent)
      guard isCurrent() else { throw CancellationError() }
      title.posterFile = await Self.keep(
        item.poster, width: 640, as: "poster.image", in: folder, api: api, isCurrent: isCurrent)
      guard isCurrent() else { throw CancellationError() }
      title.backdropFile = await Self.keep(
        item.backdrop, width: 1920, as: "backdrop.image", in: folder, api: api,
        isCurrent: isCurrent)
      guard isCurrent() else { throw CancellationError() }
      title.seriesPosterFile = await Self.keep(
        series?.poster, width: 640, as: "series-poster.image", in: folder, api: api,
        isCurrent: isCurrent)
      guard isCurrent() else { throw CancellationError() }
      let url = try api.validatedStreamURL(path: ticket.streamPath)
      var request = URLRequest(url: url)
      request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
      request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      request.cachePolicy = .reloadIgnoringLocalCacheData
      // The profile may have closed meanwhile; then nothing starts.
      guard pending(item.id) == nil, self.title(item.id) == nil else { return }
      let startNow = !pending.contains { $0.state == .downloading }
      var entry = IOSOfflinePending(
        title: title, ticketID: ticket.id, startedAt: Date(),
        state: startNow ? .downloading : .waiting, fingerprint: connection.fingerprint)
      if let quality {
        entry.converted = IOSConvertedProgress(quality: quality, audio: audio)
        pending.append(entry)
        savePending()
        convertedClients[item.id] = api
        // The converted copy asks for its own ticket when it starts; this one has done its part.
        Task { try? await api.revokeTicket(id: ticket.id) }
        if startNow { startConverted(item.id) }
        return
      }
      pending.append(entry)
      savePending()
      downloader.start(
        request, media: item.id, fingerprint: connection.fingerprint, startNow: startNow)
    } catch {
      if let ticketID { Task { try? await api.revokeTicket(id: ticketID) } }
      // A retired preparation's folder may already belong to a new request for this title.
      guard preparations[item.id]?.token == preparation.token else { return }
      try? FileManager.default.removeItem(at: folder)
      guard !(error is CancellationError), !Task.isCancelled else { return }
      errorMessage = "\(item.title) could not be downloaded. \(Self.describe(error))"
    }
  }

  /// Tries a stopped download again: where it stopped when it can, otherwise from the start.
  func retry(_ id: UUID, api: IOSAPIClient?) async {
    guard let entry = pending(id), entry.state == .failed, let downloader else { return }
    if entry.converted != nil {
      // A converted copy continues at the segment where it stopped, with the open profile.
      guard let api, api.session?.user.id == entry.title.profileID else {
        update(id) { $0.message = "Open Tarven at home to continue this download." }
        return
      }
      convertedClients[id] = api
      let startNow = !pending.contains { $0.state == .downloading }
      update(id) {
        $0.state = startNow ? .downloading : .waiting
        $0.message = nil
      }
      if startNow { startConverted(id) }
      return
    }
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
    guard let api, api.session?.user.id == entry.title.profileID else {
      update(id) { $0.message = "Open Tarven at home to try this download again." }
      return
    }
    let preparation = Preparation(
      token: UUID(), serverID: entry.title.serverID, profileID: entry.title.profileID)
    preparations[id] = preparation
    preparing.insert(id)
    defer {
      if preparations[id]?.token == preparation.token {
        preparations[id] = nil
        preparing.remove(id)
      }
    }
    let item = try? await api.summary(id: id)
    guard !Task.isCancelled, preparations[id]?.token == preparation.token,
      pending(id)?.ticketID == entry.ticketID
    else { return }
    guard let item else {
      update(id) { $0.message = "Open Tarven at home to try this download again." }
      return
    }
    let series: IOSCatalogItem? =
      if let parent = item.parentId { try? await api.summary(id: parent) } else { nil }
    guard !Task.isCancelled, preparations[id]?.token == preparation.token,
      pending(id)?.ticketID == entry.ticketID
    else { return }
    preparations[id] = nil
    preparing.remove(id)
    discard(id)
    await download(item, series: series, api: api)
  }

  func cancel(_ id: UUID) {
    cancelPreparation(id)
    if let run = convertedRuns.removeValue(forKey: id) { convertedEnded?(id, run, false) }
    convertedTasks.removeValue(forKey: id)?.cancel()
    convertedClients[id] = nil
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
    if next.converted != nil {
      startConverted(next.id)
    } else {
      downloader.startQueued(media: next.id)
    }
  }

  // MARK: Converted downloads

  /// Fetches a converted copy segment by segment, continuing where it stopped.
  private func startConverted(_ id: UUID) {
    guard let entry = pending(id), let converted = entry.converted, convertedTasks[id] == nil else {
      return
    }
    guard let api = convertedClients[id] else {
      transferFailed(
        id, message: "Open Tarven at home to continue this download.", resumeData: nil)
      return
    }
    let run = UUID()
    convertedRuns[id] = run
    convertedStarted?(id, run, entry.title.title)
    guard convertedRuns[id] == run else { return }
    let folder = folder(for: id)
    let partial = folder.appendingPathComponent("title.mp4.part")
    convertedTasks[id] = Task { [weak self] in
      let tickets = IOSDownloadTickets()
      do {
        let ticket = try await api.createTicket(mediaID: id, forDownload: true)
        await tickets.add(ticket.id)
        let size = try await IOSConvertedDownloader(api: api, mediaID: id).run(
          ticket: ticket, from: converted, into: partial,
          saved: { [weak self] state in await self?.convertedSaved(id, state, run: run) },
          renewed: { ticket in await tickets.add(ticket.id) })
        self?.convertedFinished(id, partial: partial, size: size, run: run)
      } catch is CancellationError {
        self?.convertedStopped(id, message: nil, run: run)
      } catch {
        self?.convertedStopped(id, message: Self.describe(error), run: run)
      }
      let used = await tickets.all
      Task { for ticket in used { try? await api.revokeTicket(id: ticket) } }
    }
  }

  func convertedSaved(_ id: UUID, _ state: IOSConvertedProgress, run: UUID) {
    guard convertedRuns[id] == run else { return }
    guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
    let before = pending[index].converted?.nextSegment ?? 0
    pending[index].converted = state
    pending[index].receivedBytes = state.writtenBytes
    // Saved every few segments, so a stop loses little and the disk isn't written constantly.
    if state.nextSegment == 0 || state.nextSegment == state.segmentCount
      || (state.nextSegment != before && state.nextSegment % 5 == 0)
    {
      savePending()
    }
    convertedProgressed?(id, run, state.share)
  }

  func convertedFinished(_ id: UUID, partial: URL, size: Int64, run: UUID) {
    guard convertedRuns[id] == run else { return }
    guard let index = pending.firstIndex(where: { $0.id == id }) else {
      convertedRuns[id] = nil
      convertedTasks[id] = nil
      convertedClients[id] = nil
      try? FileManager.default.removeItem(at: partial)
      convertedEnded?(id, run, false)
      return
    }
    var title = pending[index].title
    let destination = fileURL(for: title)
    do {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: partial, to: destination)
    } catch {
      convertedStopped(id, message: "The file could not be saved.", run: run)
      return
    }
    title.bytes = size
    title.downloadedAt = Date()
    convertedRuns[id] = nil
    convertedTasks[id] = nil
    convertedClients[id] = nil
    pending.remove(at: index)
    savePending()
    record(title)
    convertedEnded?(id, run, true)
    startNextWaiting()
  }

  /// A converted download that stopped keeps what it has; Try Again continues from there.
  func convertedStopped(_ id: UUID, message: String?, run: UUID) {
    guard convertedRuns[id] == run else { return }
    convertedRuns[id] = nil
    convertedTasks[id] = nil
    convertedEnded?(id, run, false)
    guard pending(id) != nil else { return }
    transferFailed(
      id, message: message ?? "Paused. Try Again continues where it stopped.", resumeData: nil)
  }

  /// The system ended the time it gave the app in the background: the download pauses.
  func pauseConverted(_ id: UUID, run: UUID) {
    guard convertedRuns[id] == run else { return }
    convertedTasks[id]?.cancel()
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
    cancelPreparations(serverID: serverID)
    for entry in pending where entry.title.serverID == serverID { cancel(entry.id) }
    for title in titles where title.serverID == serverID { remove(title.id) }
    cards.removeAll { $0.serverID == serverID }
    saveCards()
  }

  /// Stops only metadata/ticket preparation. Already authorized background downloads continue
  /// across profile changes; disconnecting removes those separately in forget(serverID:).
  func cancelPreparations(serverID: UUID, profileID: UUID? = nil) {
    let retired = preparations.filter {
      $0.value.serverID == serverID && (profileID == nil || $0.value.profileID == profileID)
    }.map(\.key)
    for id in retired { cancelPreparation(id) }
  }

  private func cancelPreparation(_ id: UUID) {
    guard preparations.removeValue(forKey: id) != nil else { return }
    preparing.remove(id)
    if pending(id) == nil, title(id) == nil {
      try? FileManager.default.removeItem(at: folder(for: id))
    }
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
      (try? resumeData.write(
        to: folder(for: id).appendingPathComponent("resume.data"),
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    {
      pending[index].resumeFile = "resume.data"
    } else {
      pending[index].resumeFile = nil
    }
    savePending()
    startNextWaiting()
  }

  /// After a restart: downloads the system no longer carries out stopped while the app was gone.
  private func reconcile(with downloader: any IOSOfflineTransferring) async {
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
          mediaID: current.id,
          position: min(current.positionMilliseconds, current.durationMilliseconds),
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

  /// Keeps remembered profiles' names and pictures as the server shows them now, so the offline
  /// chooser doesn't show an old picture. Their PIN checks stay as they are.
  func refreshCards(serverID: UUID, profiles: [IOSWatchingProfile]) {
    var changed = false
    for profile in profiles {
      guard
        let index = cards.firstIndex(where: {
          $0.serverID == serverID && $0.profileID == profile.id
        })
      else { continue }
      let card = cards[index]
      guard
        card.name != profile.name || card.pictureKey != profile.pictureKey
          || card.pictureRevision != profile.pictureRevision
      else { continue }
      cards[index].name = profile.name
      cards[index].pictureKey = profile.pictureKey
      cards[index].pictureRevision = profile.pictureRevision
      changed = true
    }
    if changed { saveCards() }
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

  private static let damagedListMessage =
    "The list of downloads was damaged and has been set aside."

  private func load() {
    let decoder = JSONDecoder()
    var readable = true
    if let data = try? Data(contentsOf: indexURL) {
      if let stored = try? decoder.decode([IOSOfflineTitle].self, from: data) {
        // A title whose file is gone is forgotten.
        titles = stored.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
      } else {
        // Kept beside the folders instead of being replaced by the next save.
        readable = false
        let stamp = ISO8601DateFormatter.string(
          from: Date(), timeZone: .gmt, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        try? FileManager.default.moveItem(
          at: indexURL, to: root.appendingPathComponent("index-damaged-\(stamp).json"))
        errorMessage = Self.damagedListMessage
      }
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
    // Folders without a listed or loading title are downloads that were cut off or titles
    // forgotten above: they are removed. After a damaged list they may be whole downloads, so
    // they stay until the person removes them in Downloads (audit C-L7).
    let orphans = orphanFolders()
    if readable {
      for folder in orphans { try? FileManager.default.removeItem(at: folder) }
    } else {
      leftoverBytes = orphans.reduce(0) { $0 + Self.bytes(in: $1) }
    }
  }

  /// Removes the folders a damaged list of downloads left behind.
  func removeLeftovers() {
    for folder in orphanFolders() { try? FileManager.default.removeItem(at: folder) }
    leftoverBytes = 0
    if errorMessage == Self.damagedListMessage { errorMessage = nil }
  }

  /// Download folders (named after a title id) that no listed, loading or preparing title uses.
  private func orphanFolders() -> [URL] {
    let used = Set(titles.map(\.id)).union(pending.map(\.id)).union(preparing)
    let folders =
      (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    return folders.filter { folder in
      guard let id = UUID(uuidString: folder.lastPathComponent), !used.contains(id) else {
        return false
      }
      return (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
  }

  private static func bytes(in folder: URL) -> Int64 {
    guard
      let files = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: [.fileSizeKey])
    else { return 0 }
    var total: Int64 = 0
    for case let file as URL in files {
      total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
  }

  private func saveTitles() { write(titles, to: indexURL) }
  private func savePending() { write(pending, to: pendingURL) }
  private func saveCards() { write(cards, to: cardsURL) }

  private func write(_ value: some Encodable, to url: URL) {
    try? prepareRoot()
    guard let data = try? JSONEncoder().encode(value) else { return }
    try? data.write(
      to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  // MARK: Helpers

  private static func subtitles(
    ticket: IOSPlaybackTicket, into folder: URL, api: IOSAPIClient,
    isCurrent: @MainActor () -> Bool
  ) async -> [IOSOfflineSubtitle] {
    guard let tracks = try? await api.streamSubtitles(ticketID: ticket.id), isCurrent() else {
      return []
    }
    var kept: [IOSOfflineSubtitle] = []
    for track in IOSLiveSubtitleTrack.sidecarFiles(tracks) {
      guard isCurrent() else { return kept }
      let name = "subtitle-\(track.index).vtt"
      guard
        let data = try? await api.streamSubtitleFile(
          streamPath: ticket.streamPath, index: track.index),
        isCurrent(),
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
    _ artwork: IOSArtwork?, width: Int, as name: String, in folder: URL, api: IOSAPIClient,
    isCurrent: @MainActor () -> Bool
  ) async -> String? {
    guard let artwork, let data = try? await api.artworkData(artwork: artwork, width: width),
      isCurrent(),
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

/// The tickets one converted download used, so every one is closed at its end.
actor IOSDownloadTickets {
  private(set) var all: [UUID] = []
  func add(_ id: UUID) { all.append(id) }
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
final class IOSOfflineDownloader: NSObject, URLSessionDownloadDelegate, IOSOfflineTransferring,
  @unchecked Sendable
{
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

  static let identifier =
    (Bundle.main.bundleIdentifier ?? "org.tarven.ios")
    + ".offline-downloads"

  private let root: URL
  private let events: Events
  private var session: URLSession!
  /// Transfers this downloader stopped because the server's key did not match its pin. Only
  /// those report an identity problem; any other cancellation is not a security warning
  /// (audit C-L12).
  private let rejectedLock = NSLock()
  private var rejectedTasks: Set<Int> = []

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
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) ->
      Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let expected = Self.description(of: task)?.fingerprint,
      let trust = challenge.protectionSpace.serverTrust,
      let fingerprint = try? IOSServerIdentity.fingerprint(trust: trust),
      fingerprint.caseInsensitiveCompare(expected) == .orderedSame
    else {
      rejectedLock.withLock { _ = rejectedTasks.insert(task.taskIdentifier) }
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  /// What a transfer that ended with an error tells the person.
  static func failureMessage(_ error: NSError, rejectedIdentity: Bool) -> String {
    if rejectedIdentity { return "The server’s identity could not be confirmed." }
    if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
      return "The download stopped."
    }
    return "The connection to the server was lost."
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
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
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
    let rejected = rejectedLock.withLock { rejectedTasks.remove(task.taskIdentifier) != nil }
    guard let error, let media = Self.description(of: task)?.media else { return }
    // A transfer cancelled here was already forgotten by the store, which ignores this.
    let nsError = error as NSError
    let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    events.failed(
      media, Self.failureMessage(nsError, rejectedIdentity: rejected), resumeData)
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    events.eventsFinished()
  }
}
