import Foundation
import Testing

@Suite("iOS offline downloads")
struct IOSOfflineTests {
  private let serverID = UUID(uuidString: "81000000-0000-0000-0000-000000000001")!
  private let profileID = UUID(uuidString: "82000000-0000-0000-0000-000000000001")!
  private let seriesID = UUID(uuidString: "83000000-0000-0000-0000-000000000001")!
  private let fingerprint = String(repeating: "B", count: 64)

  // MARK: Rules

  @Test func fiveWrongOfflinePinsMakeEveryFurtherTryWait() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    var lock = IOSOfflinePinLock()
    for _ in 1...4 { lock.recordFailure(now: start) }
    #expect(!lock.isLocked(now: start))
    lock.recordFailure(now: start)
    #expect(lock.isLocked(now: start.addingTimeInterval(29)))
    #expect(!lock.isLocked(now: start.addingTimeInterval(31)))
    #expect(
      lock.message(now: start.addingTimeInterval(10)) == "Too many wrong PINs. Try again in 20 s.")
    lock.recordFailure(now: start)
    #expect(lock.isLocked(now: start.addingTimeInterval(59)))
    for _ in 1...10 { lock.recordFailure(now: start) }
    #expect(!lock.isLocked(now: start.addingTimeInterval(301)))
    lock.recordSuccess()
    #expect(!lock.isLocked(now: start) && lock.failures == 0)
  }

  @Test func downloadsLeaveRoomOnTheDevice() {
    #expect(IOSOfflineRules.hasRoom(for: 4_000_000_000, available: 6_000_000_000))
    #expect(!IOSOfflineRules.hasRoom(for: 4_000_000_000, available: 4_500_000_000))
    // An unknown size is not refused up front.
    #expect(IOSOfflineRules.hasRoom(for: 0, available: 10))
  }

  @Test func offlineProgressWinsWhenTheServerDidNotChangeMeanwhile() {
    var title = title(position: 600_000)
    title.serverRevision = 7
    title.progressSavedAt = Date(timeIntervalSince1970: 100)
    // Same revision: offline wins whatever the clocks say.
    #expect(IOSOfflineRules.offlineIsNewer(title, server: server(revision: 7, updated: 9_999_999)))
    // Changed meanwhile: the later one wins.
    #expect(!IOSOfflineRules.offlineIsNewer(title, server: server(revision: 8, updated: 200)))
    #expect(IOSOfflineRules.offlineIsNewer(title, server: server(revision: 8, updated: 50)))
  }

  @Test func untouchedDownloadsTakeOverTheServersProgress() {
    let adopted = IOSOfflineRules.adopting(
      server(revision: 12, updated: 10, position: 90_000, completed: true), into: title())
    #expect(adopted.positionMilliseconds == 90_000 && adopted.isCompleted)
    #expect(adopted.serverRevision == 12)
  }

  @Test func namesAndSubtitlesFollowTheMac() {
    #expect(IOSOfflineRules.fileExtension("video/mp4") == "mp4")
    #expect(IOSOfflineRules.fileExtension("video/x-matroska") == "mkv")
    #expect(IOSOfflineRules.subtitle(for: item(kind: .episode)) == "Synthetic Show · S2 E5")
    #expect(IOSOfflineRules.subtitle(for: item(kind: .movie)) == "2026")
    #expect(IOSOfflineRules.canDownload(item(kind: .movie)))
    #expect(!IOSOfflineRules.canDownload(item(kind: .series)))
  }

  @Test func upNextOfflineIsTheNextDownloadedEpisodes() {
    let first = episode(season: 1, number: 1)
    let third = episode(season: 1, number: 3)
    let next = episode(season: 2, number: 1)
    let other = title()
    let queue = IOSOfflineRules.followingEpisodes(after: first, in: [next, other, third, first])
    #expect(queue.map(\.id) == [third.id, next.id])
  }

  @Test func layoutGroupsEpisodesBySeries() {
    var watching = title(position: 1_000)
    watching.progressSavedAt = Date()
    let layout = IOSOfflineLayout([
      episode(season: 1, number: 2), watching, episode(season: 1, number: 1),
    ])
    #expect(layout.movies.count == 1)
    #expect(layout.continueWatching.map(\.id) == [watching.id])
    #expect(layout.series.count == 1)
    #expect(layout.series[0].title == "Synthetic Show")
    #expect(layout.series[0].episodes.map(\.episodeNumber) == [1, 2])
  }

  // MARK: Offline profiles

  @Test func offlineCardsKeepOnlyAPinCheck() throws {
    let profile = IOSWatchingProfile(
      id: profileID, name: "Synthetic", role: "user", needsPinSetup: false,
      pinProtectionEnabled: true)
    let card = try #require(
      IOSOfflineProfileCard.make(serverID: serverID, profile: profile, pin: "4826"))
    #expect(card.accepts("4826"))
    #expect(!card.accepts("4827"))
    #expect(!card.accepts("48"))
    let stored = String(data: try JSONEncoder().encode(card), encoding: .utf8) ?? ""
    #expect(!stored.contains("4826"))
    // A PIN-protected profile is not remembered without its PIN.
    #expect(IOSOfflineProfileCard.make(serverID: serverID, profile: profile, pin: nil) == nil)
    let open = IOSWatchingProfile(
      id: profileID, name: "Open", role: "user", needsPinSetup: false, pinProtectionEnabled: false)
    #expect(
      IOSOfflineProfileCard.make(serverID: serverID, profile: open, pin: nil)?.accepts("") == true)
  }

  @Test @MainActor func rememberedCardsFollowANewNameAndPictureButKeepTheirPinCheck() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IOSOfflineStore(root: root, transfers: false)
    let before = IOSWatchingProfile(
      id: profileID, name: "Synthetic", role: "user", needsPinSetup: false,
      pinProtectionEnabled: true)
    store.remember(
      try #require(IOSOfflineProfileCard.make(serverID: serverID, profile: before, pin: "4826")))
    let after = IOSWatchingProfile(
      id: profileID, name: "Renamed", role: "user", needsPinSetup: false,
      pinProtectionEnabled: true, pictureKey: "symbol:rocket:orange", pictureRevision: 3)
    store.refreshCards(serverID: serverID, profiles: [after])
    let reopened = IOSOfflineStore(root: root, transfers: false)
    let card = try #require(reopened.card(serverID: serverID, profileID: profileID))
    #expect(card.name == "Renamed")
    #expect(card.pictureKey == "symbol:rocket:orange" && card.pictureRevision == 3)
    #expect(card.accepts("4826") && !card.accepts("4827"))
    // Another server's profile with the same id is left alone.
    store.refreshCards(serverID: UUID(), profiles: [before])
    #expect(store.card(serverID: serverID, profileID: profileID)?.name == "Renamed")
  }

  // MARK: Offline player

  @Test func theOfflineTransportAnswersThePlayersRequests() async throws {
    let book = IOSOfflineBook(title(position: 120_000, subtitles: true))
    let api = offlineAPI(book)
    let id = book.current.id
    let ticket = try await api.createTicket(mediaID: id)
    #expect(ticket.contentLength == 2_000_000 && ticket.progress.positionMilliseconds == 120_000)
    let stream = try api.validatedStreamURL(path: ticket.streamPath)
    #expect(IOSOfflineTransport.mediaID(streamURL: stream) == id)
    let tracks = try await api.streamSubtitles(ticketID: ticket.id)
    #expect(tracks.count == 1 && tracks[0].isSidecar)
    let saved = try await api.saveProgress(
      mediaID: id, position: 300_000, duration: 3_600_000, finished: false,
      expectedRevision: ticket.progress.revision, mutationID: UUID())
    #expect(saved.positionMilliseconds == 300_000 && saved.revision > ticket.progress.revision)
    #expect(book.current.progressDirty)
    try await api.revokeTicket(id: ticket.id)
    await #expect(throws: IOSCoreError.self) { try await api.createTicket(mediaID: UUID()) }
  }

  @Test func theOfflinePlayersJournalSavesToTheDownload() async throws {
    let book = IOSOfflineBook(title())
    let api = offlineAPI(book)
    let outbox = IOSProgressOutbox()
    let session = offlineSession.playerSession
    let scope = IOSProgressScope(connection: connection, session: session)
    await outbox.activate(scope: scope, client: api, sessionID: session.sessionId)
    let ticket = try await api.createTicket(mediaID: book.current.id)
    await outbox.noteBaseline(scope: scope, progress: ticket.progress, sessionID: session.sessionId)
    _ = await outbox.enqueue(
      scope: scope, mediaID: book.current.id,
      snapshot: IOSProgressSnapshot(position: 42_000, duration: 3_600_000, finished: false),
      baselineRevision: ticket.progress.revision, sessionID: session.sessionId)
    #expect(await outbox.flush(scope: scope, mediaID: book.current.id) == .saved)
    #expect(book.current.positionMilliseconds == 42_000)
  }

  // MARK: Store

  @Test(arguments: IOSOfflinePreparationTransport.Stage.allCases)
  @MainActor fileprivate func forgettingDuringPreparationNeverQueuesOrRestoresFiles(
    stage: IOSOfflinePreparationTransport.Stage
  ) async {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let transfer = IOSOfflineFakeTransfers()
    let store = IOSOfflineStore(root: root, transfers: false, transfer: transfer)
    let posterID = UUID()
    let poster = IOSArtwork(
      id: posterID, kind: "poster", path: "/api/v1/artwork/\(posterID.uuidString)",
      contentType: "image/png", contentLength: 3, revision: 1)
    let media = item(kind: .movie, poster: poster)
    let transport = IOSOfflinePreparationTransport(mediaID: media.id, blockedStage: stage)
    let api = preparationAPI(transport)
    let preparation = Task { await store.download(media, series: nil, api: api) }
    await transport.waitUntilBlocked()
    #expect(store.preparing.contains(media.id))
    store.forget(serverID: serverID)
    await transport.release()
    await preparation.value
    #expect(store.pending.isEmpty && store.titles.isEmpty && store.preparing.isEmpty)
    #expect(transfer.started.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.folder(for: media.id).path))
    #expect(store.errorMessage == nil)
  }

  @Test @MainActor func closingAProfileCancelsPreparationButKeepsAuthorizedTransfers() async {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let transfer = IOSOfflineFakeTransfers()
    let store = IOSOfflineStore(root: root, transfers: false, transfer: transfer)
    let queued = item(kind: .movie)
    await store.download(
      queued, series: nil,
      api: preparationAPI(IOSOfflinePreparationTransport(mediaID: queued.id)))
    #expect(store.pending.map(\.id) == [queued.id])

    let retired = item(kind: .movie)
    let transport = IOSOfflinePreparationTransport(mediaID: retired.id, blockedStage: .subtitleFile)
    let api = preparationAPI(transport)
    let preparation = Task { await store.download(retired, series: nil, api: api) }
    await transport.waitUntilBlocked()
    store.cancelPreparations(serverID: serverID, profileID: profileID)
    await transport.release()
    await preparation.value
    #expect(store.pending.map(\.id) == [queued.id])
    #expect(transfer.started == [queued.id] && transfer.cancelled.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.folder(for: retired.id).path))
  }

  @Test @MainActor func cancellingATitleRetiresItsPreparationBeforeItsResponseArrives() async {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let transfer = IOSOfflineFakeTransfers()
    let store = IOSOfflineStore(root: root, transfers: false, transfer: transfer)
    let media = item(kind: .movie)
    let transport = IOSOfflinePreparationTransport(mediaID: media.id, blockedStage: .ticket)
    let api = preparationAPI(transport)
    let preparation = Task { await store.download(media, series: nil, api: api) }
    await transport.waitUntilBlocked()
    store.cancel(media.id)
    await transport.release()
    await preparation.value
    #expect(store.pending.isEmpty && store.preparing.isEmpty && transfer.started.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.folder(for: media.id).path))
  }

  @Test @MainActor func anOldPreparationCannotRemoveANewerDownloadOfTheSameTitle() async {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let transfer = IOSOfflineFakeTransfers()
    let store = IOSOfflineStore(root: root, transfers: false, transfer: transfer)
    let media = item(kind: .movie)
    let old = IOSOfflinePreparationTransport(mediaID: media.id, blockedStage: .subtitleFile)
    let oldAPI = preparationAPI(old)
    let preparation = Task { await store.download(media, series: nil, api: oldAPI) }
    await old.waitUntilBlocked()
    store.cancel(media.id)
    await store.download(
      media, series: nil, api: preparationAPI(IOSOfflinePreparationTransport(mediaID: media.id)))
    await old.release()
    await preparation.value
    #expect(store.pending.map(\.id) == [media.id])
    #expect(transfer.started == [media.id])
    #expect(FileManager.default.fileExists(atPath: store.folder(for: media.id).path))
  }

  @Test(arguments: [false, true])
  @MainActor func retiringDuringRetryDoesNotStartAnotherTransfer(disconnect: Bool) async {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let transfer = IOSOfflineFakeTransfers()
    let store = IOSOfflineStore(root: root, transfers: false, transfer: transfer)
    let media = item(kind: .movie)
    await store.download(
      media, series: nil, api: preparationAPI(IOSOfflinePreparationTransport(mediaID: media.id)))
    store.transferFailed(media.id, message: "Synthetic interruption", resumeData: nil)
    let transport = IOSOfflinePreparationTransport(
      mediaID: media.id, blockedStage: .ticket, catalog: media)
    let api = preparationAPI(transport)
    let retry = Task { await store.retry(media.id, api: api) }
    await transport.waitUntilBlocked()
    if disconnect {
      store.forget(serverID: serverID)
    } else {
      store.cancelPreparations(serverID: serverID, profileID: profileID)
    }
    await transport.release()
    await retry.value
    #expect(transfer.started == [media.id])
    #expect(store.preparing.isEmpty)
    if disconnect {
      #expect(store.pending.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: store.folder(for: media.id).path))
    } else {
      #expect(store.pending(media.id)?.state == .failed)
    }
  }

  @Test @MainActor func retiredConversionCallbacksAndExpiryCannotChangeANewerRun() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IOSOfflineStore(root: root, transfers: false, transfer: IOSOfflineFakeTransfers())
    let media = item(kind: .movie)
    var started: [UUID] = []
    var ended: [UUID] = []
    store.convertedStarted = { _, run, _ in started.append(run) }
    store.convertedEnded = { _, run, _ in ended.append(run) }

    let old = IOSOfflinePreparationTransport(mediaID: media.id, blockConvertedPlaylist: true)
    await store.download(
      media, series: nil, api: preparationAPI(old), quality: "720p", expectedBytes: 1_000)
    await old.waitUntilBlocked()
    let oldRun = try #require(started.first)
    store.cancel(media.id)
    #expect(ended == [oldRun])

    let current = IOSOfflinePreparationTransport(mediaID: media.id, blockConvertedPlaylist: true)
    await store.download(
      media, series: nil, api: preparationAPI(current), quality: "720p", expectedBytes: 1_000)
    await current.waitUntilBlocked()
    let currentRun = try #require(started.last)
    #expect(currentRun != oldRun)
    let partial = store.folder(for: media.id).appendingPathComponent("title.mp4.part")
    let sentinel = Data("new request owns this file".utf8)
    try sentinel.write(to: partial)

    // Inject late production callbacks as well as releasing the cancelled network read.
    var staleProgress = IOSConvertedProgress(quality: "1080p", audio: nil)
    staleProgress.nextSegment = 99
    store.convertedSaved(media.id, staleProgress, run: oldRun)
    store.convertedFinished(media.id, partial: partial, size: 1, run: oldRun)
    store.convertedStopped(media.id, message: "Old failure", run: oldRun)
    store.pauseConverted(media.id, run: oldRun)
    await old.release()
    await old.waitUntilRevocations(2)

    #expect(store.pending(media.id)?.state == .downloading)
    #expect(store.pending(media.id)?.converted?.nextSegment == 0)
    #expect(store.pending(media.id)?.converted?.quality == "720p")
    #expect(store.titles.isEmpty)
    #expect(try Data(contentsOf: partial) == sentinel)
    #expect(ended == [oldRun])

    await current.release()
    await current.waitUntilRevocations(2)
    #expect(store.title(media.id)?.quality == "720p")
    #expect(store.pending(media.id) == nil)
    #expect(ended == [oldRun, currentRun])
    #expect(
      try Data(contentsOf: store.fileURL(for: #require(store.title(media.id))))
        == Data([1, 2, 3, 4]))
  }

  @Test @MainActor func storeKeepsDownloadsAndForgetsMissingFiles() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IOSOfflineStore(root: root, transfers: false)
    let kept = title()
    let lost = episode(season: 1, number: 1)
    try writeFile(for: kept, in: store)
    store.record(kept)
    store.record(lost)
    store.saveProgress(kept.id, position: 5_000, duration: 3_600_000, finished: false)
    let reopened = IOSOfflineStore(root: root, transfers: false)
    #expect(reopened.titles.map(\.id) == [kept.id])
    #expect(reopened.titles[0].progressDirty && reopened.titles[0].positionMilliseconds == 5_000)
    reopened.remove(kept.id)
    #expect(!FileManager.default.fileExists(atPath: reopened.folder(for: kept.id).path))
  }

  @Test @MainActor func cutOffDownloadsAreRemovedAndADamagedListIsSetAside() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IOSOfflineStore(root: root, transfers: false)
    let kept = title()
    try writeFile(for: kept, in: store)
    store.record(kept)
    let cutOff = store.folder(for: UUID())
    try FileManager.default.createDirectory(at: cutOff, withIntermediateDirectories: true)
    try Data(count: 10).write(to: cutOff.appendingPathComponent("incoming"))
    let reopened = IOSOfflineStore(root: root, transfers: false)
    #expect(!FileManager.default.fileExists(atPath: cutOff.path))
    #expect(reopened.titles.map(\.id) == [kept.id] && reopened.leftoverBytes == 0)

    try Data("{ damaged".utf8).write(to: root.appendingPathComponent("index.json"))
    let damaged = IOSOfflineStore(root: root, transfers: false)
    #expect(damaged.titles.isEmpty && damaged.errorMessage != nil)
    #expect(damaged.leftoverBytes > 0)
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(names.contains { $0.hasPrefix("index-damaged-") })
    damaged.removeLeftovers()
    #expect(!FileManager.default.fileExists(atPath: damaged.folder(for: kept.id).path))
    #expect(damaged.leftoverBytes == 0 && damaged.errorMessage == nil)
  }

  @Test func onlyARejectedServerKeyIsReportedAsAnIdentityProblem() {
    let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    #expect(
      IOSOfflineDownloader.failureMessage(cancelled, rejectedIdentity: true)
        == "The server’s identity could not be confirmed.")
    #expect(
      IOSOfflineDownloader.failureMessage(cancelled, rejectedIdentity: false)
        == "The download stopped.")
    #expect(
      IOSOfflineDownloader.failureMessage(
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost),
        rejectedIdentity: false) == "The connection to the server was lost.")
  }

  @Test @MainActor func forgettingAServerRemovesItsDownloadsAndCards() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IOSOfflineStore(root: root, transfers: false)
    let kept = title()
    try writeFile(for: kept, in: store)
    store.record(kept)
    let profile = IOSWatchingProfile(
      id: profileID, name: "Open", role: "user", needsPinSetup: false, pinProtectionEnabled: false)
    store.remember(
      try #require(IOSOfflineProfileCard.make(serverID: serverID, profile: profile, pin: nil)))
    #expect(store.offlineProfiles(serverID: serverID).count == 1)
    store.forget(serverID: serverID)
    #expect(store.titles.isEmpty && store.cards.isEmpty)
  }

  @Test @MainActor func syncSendsNewerOfflineProgressAndAdoptsTheServers() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = IOSOfflineStore(root: root, transfers: false)
    var watched = title(position: 0)
    watched.serverRevision = 4
    let untouched = episode(season: 1, number: 1)
    for value in [watched, untouched] {
      try writeFile(for: value, in: store)
      store.record(value)
    }
    store.saveProgress(watched.id, position: 700_000, duration: 3_600_000, finished: false)
    let transport = IOSOfflineServerTransport(progress: [
      watched.id: server(revision: 4, updated: 1, id: watched.id),
      untouched.id: server(revision: 9, updated: 1, position: 80_000, id: untouched.id),
    ])
    await store.syncProgress(api: onlineAPI(transport))
    let sent = await transport.saved
    #expect(sent.map(\.0) == [watched.id] && sent.first?.1 == 700_000)
    #expect(store.title(watched.id)?.progressDirty == false)
    #expect(store.title(watched.id)?.serverRevision == 5)
    #expect(store.title(untouched.id)?.positionMilliseconds == 80_000)
  }

  // MARK: Fixtures

  private var connection: IOSStoredConnection {
    IOSStoredConnection(
      serverID: serverID, name: "Synthetic server",
      baseURL: URL(string: "https://fixture.invalid:43111")!, fingerprint: fingerprint,
      deviceToken: String(repeating: "D", count: 43), deviceSessionID: UUID())
  }

  private var offlineSession: IOSOfflineSession {
    IOSOfflineSession(
      serverID: serverID, profileID: profileID, name: "Synthetic", pictureKey: nil,
      pictureRevision: 0)
  }

  private func offlineAPI(_ book: IOSOfflineBook) -> IOSAPIClient {
    IOSAPIClient(
      connection: connection, session: offlineSession.playerSession,
      transport: IOSOfflineTransport(
        title: { id in book.current.id == id ? book.current : nil },
        save: { _, position, duration, finished in
          book.save(position: position, duration: duration, finished: finished)
        }))
  }

  private func onlineAPI(_ transport: IOSOfflineServerTransport) -> IOSAPIClient {
    let session = IOSProfileSession(
      user: IOSUser(id: profileID, username: "Viewer", role: "user"),
      sessionId: UUID(), token: String(repeating: "P", count: 43),
      expiresAt: "2099-01-01T00:00:00Z")
    return IOSAPIClient(connection: connection, session: session, transport: transport)
  }

  private func preparationAPI(_ transport: IOSOfflinePreparationTransport) -> IOSAPIClient {
    let session = IOSProfileSession(
      user: IOSUser(id: profileID, username: "Viewer", role: "user"),
      sessionId: UUID(), token: String(repeating: "P", count: 43),
      expiresAt: "2099-01-01T00:00:00Z")
    return IOSAPIClient(connection: connection, session: session, transport: transport)
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("TarvenIOSOfflineTests-\(UUID().uuidString)", isDirectory: true)
  }

  @MainActor private func writeFile(for title: IOSOfflineTitle, in store: IOSOfflineStore) throws {
    try FileManager.default.createDirectory(
      at: store.folder(for: title.id), withIntermediateDirectories: true)
    try Data("synthetic".utf8).write(to: store.fileURL(for: title))
  }

  private func title(position: Int64 = 0, subtitles: Bool = false) -> IOSOfflineTitle {
    IOSOfflineTitle(
      id: UUID(), serverID: serverID, profileID: profileID, title: "Synthetic Movie",
      subtitle: "2026", kind: "movie", fileName: "title.mkv", contentType: "video/x-matroska",
      bytes: 2_000_000, downloadedAt: Date(timeIntervalSince1970: 10),
      positionMilliseconds: position, durationMilliseconds: 3_600_000, isCompleted: false,
      progressSavedAt: nil, progressDirty: false,
      subtitles: subtitles
        ? [
          IOSOfflineSubtitle(
            index: 2, language: "de", title: "Deutsch", isForced: false, isSdh: false,
            fileName: "subtitle-2.vtt")
        ] : [],
      serverRevision: 1, overview: nil, year: 2026, genres: [], parentID: nil, parentTitle: nil,
      seasonNumber: nil, episodeNumber: nil, posterFile: nil, backdropFile: nil,
      seriesPosterFile: nil)
  }

  private func episode(season: Int, number: Int) -> IOSOfflineTitle {
    IOSOfflineTitle(
      id: UUID(), serverID: serverID, profileID: profileID, title: "Episode \(number)",
      subtitle: nil, kind: "episode", fileName: "title.mp4", contentType: "video/mp4",
      bytes: 1_000_000, downloadedAt: Date(timeIntervalSince1970: 20), positionMilliseconds: 0,
      durationMilliseconds: 1_800_000, isCompleted: false, progressSavedAt: nil,
      progressDirty: false, subtitles: [], serverRevision: 1, overview: nil, year: 2026,
      genres: [], parentID: seriesID, parentTitle: "Synthetic Show", seasonNumber: season,
      episodeNumber: number, posterFile: nil, backdropFile: nil, seriesPosterFile: nil)
  }

  private func item(kind: IOSMediaKind, poster: IOSArtwork? = nil) -> IOSCatalogItem {
    IOSCatalogItem(
      id: UUID(), kind: kind, title: "Synthetic", originalTitle: nil, year: 2026, overview: nil,
      genres: [], poster: poster, backdrop: nil, availability: .available, isFavorite: false,
      progress: nil, addedAt: "2026-01-01T00:00:00Z",
      parentTitle: kind == .episode ? "Synthetic Show" : nil,
      seasonNumber: kind == .episode ? 2 : nil, episodeNumber: kind == .episode ? 5 : nil,
      parentId: nil, watchState: nil, libraryAvailability: .available)
  }

  private func server(
    revision: Int64, updated: TimeInterval, position: Int64 = 0, completed: Bool = false,
    id: UUID = UUID()
  ) -> IOSPlaybackProgress {
    IOSPlaybackProgress(
      mediaId: id, positionMilliseconds: position, durationMilliseconds: 3_600_000,
      isCompleted: completed, lastPlayedAt: nil,
      updatedAt: IOSServerDate.string(Date(timeIntervalSince1970: updated)), revision: revision,
      lastMutationId: nil)
  }
}

/// One download's saved state, as the store would keep it.
private final class IOSOfflineBook: @unchecked Sendable {
  private let lock = NSLock()
  private var title: IOSOfflineTitle
  init(_ title: IOSOfflineTitle) { self.title = title }
  var current: IOSOfflineTitle { lock.withLock { title } }
  func save(position: Int64, duration: Int64, finished: Bool) -> IOSOfflineTitle {
    lock.withLock {
      title.positionMilliseconds = position
      title.durationMilliseconds = duration
      title.isCompleted = finished
      title.progressDirty = true
      return title
    }
  }
}

/// A synthetic server answering progress reads and writes.
private actor IOSOfflineServerTransport: IOSHTTPTransport {
  private var progress: [UUID: IOSPlaybackProgress]
  private(set) var saved: [(UUID, Int64)] = []
  init(progress: [UUID: IOSPlaybackProgress]) { self.progress = progress }

  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    let parts = (request.url?.path ?? "").split(separator: "/").map(String.init)
    guard parts.count == 5, let id = UUID(uuidString: parts[3]), let current = progress[id] else {
      return IOSHTTPResponse(statusCode: 404, headers: [:], body: Data(), fingerprint: nil)
    }
    if request.httpMethod == "PUT" {
      struct Payload: Decodable {
        let positionMilliseconds: Int64
        let clientMutationId: UUID
      }
      let payload = try JSONDecoder().decode(Payload.self, from: request.httpBody ?? Data())
      saved.append((id, payload.positionMilliseconds))
      let updated = IOSPlaybackProgress(
        mediaId: id, positionMilliseconds: payload.positionMilliseconds,
        durationMilliseconds: current.durationMilliseconds, isCompleted: false, lastPlayedAt: nil,
        updatedAt: nil, revision: current.revision + 1, lastMutationId: payload.clientMutationId)
      progress[id] = updated
      return try Self.json(updated)
    }
    return try Self.json(current)
  }

  private static func json(_ value: some Encodable) throws -> IOSHTTPResponse {
    IOSHTTPResponse(
      statusCode: 200, headers: [:], body: try JSONEncoder().encode(value), fingerprint: nil)
  }
}

/// A controllable server read, deliberately returning even after the store retires preparation.
private actor IOSOfflinePreparationTransport: IOSHTTPTransport {
  enum Stage: CaseIterable, Sendable { case ticket, subtitles, subtitleFile, artwork }
  private let mediaID: UUID
  private let blockedStage: Stage?
  private let catalog: IOSCatalogItem?
  private let blockConvertedPlaylist: Bool
  private let ticketID = UUID()
  private var blocked = false
  private var continuation: CheckedContinuation<Void, Never>?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var revocations = 0
  private var revocationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  init(
    mediaID: UUID, blockedStage: Stage? = nil, catalog: IOSCatalogItem? = nil,
    blockConvertedPlaylist: Bool = false
  ) {
    self.mediaID = mediaID
    self.blockedStage = blockedStage
    self.catalog = catalog
    self.blockConvertedPlaylist = blockConvertedPlaylist
  }

  func execute(_ request: URLRequest, trust: IOSTrustMode) async throws -> IOSHTTPResponse {
    let path = request.url?.path ?? ""
    if request.httpMethod == "DELETE" {
      revocations += 1
      let ready = revocationWaiters.filter { $0.0 <= revocations }
      revocationWaiters.removeAll { $0.0 <= revocations }
      for (_, waiter) in ready { waiter.resume() }
      return response(Data())
    }
    if path.hasSuffix("/index.m3u8") {
      if blockConvertedPlaylist { await block() }
      return response(Data("#EXTM3U\n#EXTINF:1,\n0.m4s\n".utf8))
    }
    if path.hasSuffix("/init.mp4") { return response(Data([1, 2])) }
    if path.hasSuffix("/0.m4s") { return response(Data([3, 4])) }
    if path.hasSuffix("/summary"), let catalog {
      await blockIfNeeded(.ticket)
      return response(try JSONEncoder().encode(catalog))
    }
    if path.hasSuffix("/playback") {
      await blockIfNeeded(.ticket)
      let ticket = IOSPlaybackTicket(
        id: ticketID, mediaId: mediaID,
        streamPath: "/api/v1/streams/" + String(repeating: "S", count: 43),
        contentType: "video/mp4", contentLength: 1_000, expiresAt: "2099-01-01T00:00:00Z",
        progress: IOSPlaybackProgress(
          mediaId: mediaID, positionMilliseconds: 0, durationMilliseconds: 1_000,
          isCompleted: false, lastPlayedAt: nil, updatedAt: nil, revision: 1,
          lastMutationId: nil))
      return response(try JSONEncoder().encode(ticket))
    }
    if path.hasSuffix("/subtitles") {
      await blockIfNeeded(.subtitles)
      return response(
        Data(
          #"[{"index":1000,"format":"subrip","language":"en","title":"Synthetic","isDefault":true,"isForced":false,"supported":true,"isSidecar":true,"isSdh":false}]"#
            .utf8))
    }
    if path.hasSuffix("/subtitles/1000") {
      await blockIfNeeded(.subtitleFile)
      return response(Data("WEBVTT\n\n00:00.000 --> 00:01.000\nSynthetic\n".utf8))
    }
    if path.hasPrefix("/api/v1/artwork/") {
      await blockIfNeeded(.artwork)
      return response(Data([1, 2, 3]), contentType: "image/png")
    }
    return IOSHTTPResponse(statusCode: 404, headers: [:], body: Data(), fingerprint: nil)
  }

  func waitUntilBlocked() async {
    if blocked { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }

  func waitUntilRevocations(_ count: Int) async {
    if revocations >= count { return }
    await withCheckedContinuation { revocationWaiters.append((count, $0)) }
  }

  private func blockIfNeeded(_ stage: Stage) async {
    guard stage == blockedStage else { return }
    await block()
  }

  private func block() async {
    guard !blocked else { return }
    blocked = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
    await withCheckedContinuation { continuation = $0 }
  }

  private func response(_ data: Data, contentType: String = "application/json") -> IOSHTTPResponse {
    IOSHTTPResponse(
      statusCode: 200, headers: ["Content-Type": contentType], body: data, fingerprint: nil)
  }
}

/// Captures transfer scheduling without touching URLSession or receiving media bytes.
private final class IOSOfflineFakeTransfers: IOSOfflineTransferring, @unchecked Sendable {
  private let lock = NSLock()
  private var startedIDs: [UUID] = []
  private var cancelledIDs: [UUID] = []
  var started: [UUID] { lock.withLock { startedIDs } }
  var cancelled: [UUID] { lock.withLock { cancelledIDs } }

  func start(_ request: URLRequest, media: UUID, fingerprint: String, startNow: Bool) {
    lock.withLock { startedIDs.append(media) }
  }
  func resume(_ data: Data, media: UUID, fingerprint: String, startNow: Bool) {}
  func startQueued(media: UUID) {}
  func cancel(media: UUID) { lock.withLock { cancelledIDs.append(media) } }
  func knownMedia() async -> Set<UUID> { [] }
}
