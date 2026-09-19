import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
  static var active: AppModel?
  @Published private(set) var operatingMode: OperatingMode?
  @Published private(set) var profile: StoredServerProfile?
  @Published private(set) var inspectedServer: InspectedServer?
  @Published private(set) var movies: [MovieSummary] = []
  @Published private(set) var series: [SeriesSummary] = []
  @Published private(set) var catalogItems: [CatalogItemSummary] = []
  @Published private(set) var home: HomeResponse?
  @Published private(set) var collections: [CollectionSummary] = []
  @Published private(set) var playback: PlaybackPresentation?
  @Published private(set) var hostSnapshot: NativeHostSnapshot = .stopped
  @Published private(set) var libraries: [LibrarySummary] = []
  @Published private(set) var activeScans: [LibraryScanSummary] = []
  @Published private(set) var recentScans: [LibraryScanSummary] = []
  @Published private(set) var libraryDiscoveries: [LibraryDiscoverySummary] = []
  @Published private(set) var pairingCode: PairingCodeResponse?
  @Published private(set) var sessions: [DeviceSessionSummary] = []
  @Published private(set) var metadataProvider: MetadataProviderStatus?
  @Published private(set) var metadataJob: MetadataJobSummary?
  @Published private(set) var needsInitialLibrarySetup = false
  @Published private(set) var isStarting = true
  @Published private(set) var isWorking = false
  @Published var errorMessage: String?
  @Published var isMediaManagerPresented = false

  let artworkLoader = ArtworkLoader()

  private let store: any ServerProfileStore
  private let serverHost: NativeServerHost
  private let syncController = LibrarySyncController()
  private var hasStarted = false
  private var hostPollTask: Task<Void, Never>?
  private var homeRefreshTask: Task<Void, Never>?
  private var scanPollTask: Task<Void, Never>?
  private var syncRefreshTask: Task<Void, Never>?
  private var isTerminationProtectionActive = false
  private static let operatingModeKey = "AureliaOperatingMode"
  private static let operatingModeSelectionVersionKey = "AureliaOperatingModeSelectionVersion"

  var canManageMedia: Bool { profile?.user?.role.canManageLibraries == true }
  var isLocalHost: Bool { operatingMode == .host }

  func showMediaManager() {
    isMediaManagerPresented = true
  }

  init(
    store: (any ServerProfileStore)? = nil,
    serverHost: NativeServerHost = NativeServerHost()
  ) {
    self.store = store ?? Self.defaultStore
    self.serverHost = serverHost
    self.operatingMode = UserDefaults.standard.string(forKey: Self.operatingModeKey)
      .flatMap(OperatingMode.init(rawValue:))
    Self.active = self
  }

  func start() async {
    guard !hasStarted else { return }
    hasStarted = true

    #if DEBUG
      if Self.uiTestMode == "library" || Self.uiTestMode == "library-admin" {
        operatingMode = .client
        profile =
          Self.uiTestMode == "library-admin" ? Self.previewOwnerProfile : Self.previewProfile
        movies = [
          MovieSummary(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            title: "El Camino",
            year: 2019,
            availability: .available)
        ]
        series = [
          SeriesSummary(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            title: "Breaking Bad",
            availability: .available,
            seasonCount: 5,
            episodeCount: 62)
        ]
        catalogItems = Self.previewCatalog
        home = Self.previewHome
        collections = Self.previewHome.collections
        isStarting = false
        return
      }
      if Self.uiTestMode == "pairing" {
        operatingMode = .client
        isStarting = false
        return
      }
      if Self.uiTestMode == "welcome" {
        operatingMode = nil
        isStarting = false
        return
      }
      if Self.uiTestMode == "host-setup" {
        operatingMode = .host
        hostSnapshot = NativeHostSnapshot(
          state: .setupRequired,
          message: nil,
          bootstrapToken: "ui-test-bootstrap-token",
          serverInfo: nil)
        isStarting = false
        return
      }
      if Self.uiTestMode == "host-starting" || Self.uiTestMode == "host-failed" {
        operatingMode = .host
        hostSnapshot = NativeHostSnapshot(
          state: Self.uiTestMode == "host-starting" ? .starting : .failed,
          message: Self.uiTestMode == "host-failed" ? "The test server could not start." : nil,
          bootstrapToken: nil,
          serverInfo: nil)
        isStarting = false
        return
      }
      if Self.uiTestMode == "library-setup" {
        operatingMode = .host
        profile = Self.previewOwnerProfile
        hostSnapshot = Self.previewHostSnapshot
        needsInitialLibrarySetup = true
        isStarting = false
        return
      }
      if Self.uiTestMode == "media-manager" {
        operatingMode = .host
        profile = Self.previewOwnerProfile
        hostSnapshot = Self.previewHostSnapshot
        let libraryID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        libraries = [
          LibrarySummary(
            id: libraryID,
            name: "Archive Drive",
            path: "/Volumes/Archive",
            kind: .movies,
            availability: .unavailable,
            createdAt: "2026-09-15T12:00:00Z",
            lastScanStartedAt: "2026-09-15T12:01:00Z",
            lastScanCompletedAt: nil,
            lastError: "The library directory is unavailable.",
            monitoringEnabled: true,
            lastObservedAt: "2026-09-15T12:01:00Z",
            health: .waitingForStorage)
        ]
        activeScans = [
          LibraryScanSummary(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            libraryId: libraryID,
            state: .waitingForStorage,
            createdAt: "2026-09-15T12:01:00Z",
            startedAt: nil,
            completedAt: nil,
            filesDiscovered: 0,
            filesProcessed: 0,
            addedFiles: 0,
            updatedFiles: 0,
            missingFiles: 0,
            skippedFiles: 0,
            error: "The library directory is unavailable.",
            issues: [],
            trigger: .scheduled,
            attempt: 2,
            targetRelativePath: nil)
        ]
        isStarting = false
        return
      }
      if Self.uiTestMode == "metadata-settings" {
        operatingMode = .host
        profile = Self.previewOwnerProfile
        hostSnapshot = Self.previewHostSnapshot
        metadataProvider = MetadataProviderStatus(
          enabled: true,
          hasToken: true,
          language: "en-US",
          artworkBytes: 42,
          artworkLimitBytes: 1_073_741_824,
          provider: "TMDB",
          attribution: "This product uses the TMDB API but is not endorsed or certified by TMDB.")
        isStarting = false
        return
      }
    #endif

    do {
      profile = try store.load()
      operatingMode = OperatingModePolicy.resolve(
        storedMode: operatingMode,
        storedSelectionVersion: UserDefaults.standard.integer(
          forKey: Self.operatingModeSelectionVersionKey),
        profile: profile)
      persistOperatingMode(explicit: false)
      if operatingMode == .host {
        await startNativeHost()
      } else if profile != nil {
        try await refresh()
        startSync()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    isStarting = false
  }

  func selectClientMode() {
    operatingMode = .client
    persistOperatingMode(explicit: true)
    errorMessage = nil
  }

  func selectHostMode() async {
    if let profile, !OperatingModePolicy.isLocal(profile.baseURL) {
      await disconnect()
    }
    operatingMode = .host
    persistOperatingMode(explicit: true)
    await startNativeHost()
  }

  func switchToClientMode() async {
    await PlaybackShutdownCoordinator.shared.shutdown()
    hostPollTask?.cancel()
    hostPollTask = nil
    await serverHost.stop()
    endTerminationProtection()
    hostSnapshot = .stopped
    operatingMode = .client
    persistOperatingMode(explicit: true)
    await disconnect()
  }

  func setupLocalOwner(
    serverName: String,
    username: String,
    password: String,
    confirmation: String,
    lanPort: Int
  ) async -> Bool {
    guard password == confirmation else {
      errorMessage = "The passwords do not match."
      return false
    }
    guard password.count >= 12 else {
      errorMessage = "The password must contain at least 12 characters."
      return false
    }
    guard let bootstrapToken = hostSnapshot.bootstrapToken else {
      errorMessage = "Native setup authorization is unavailable. Restart the server host."
      return false
    }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      try await serverHost.configure(name: serverName, lanPort: lanPort)
      let authentication = try await APIClient.setupOwner(
        username: username,
        password: password,
        deviceName: Host.current().localizedName ?? "Server Mac",
        bootstrapToken: bootstrapToken)
      try await finishLocalAuthentication(authentication, lanPort: lanPort)
      needsInitialLibrarySetup = true
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func loginToLocalServer(username: String, password: String) async -> Bool {
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let authentication = try await APIClient.loginLocally(
        username: username,
        password: password,
        deviceName: Host.current().localizedName ?? "Server Mac")
      let port = hostSnapshot.serverInfo?.lanHttpsPort ?? 43_111
      try await finishLocalAuthentication(authentication, lanPort: port, restart: false)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func restartNativeHost() async {
    errorMessage = nil
    #if DEBUG
      if Self.uiTestMode == "host-failed" {
        hostSnapshot = NativeHostSnapshot(
          state: .starting,
          message: nil,
          bootstrapToken: nil,
          serverInfo: nil)
        await Task.yield()
        hostSnapshot = NativeHostSnapshot(
          state: .setupRequired,
          message: nil,
          bootstrapToken: "ui-test-retry-bootstrap-token",
          serverInfo: nil)
        return
      }
    #endif
    if hostSnapshot.state == .failed || hostSnapshot.state == .stopped {
      await startNativeHost()
      return
    }
    do { try await serverHost.restart() } catch { errorMessage = error.localizedDescription }
  }

  func completeInitialLibrarySetup() {
    needsInitialLibrarySetup = false
  }

  func createStorageLocations(_ locations: [StorageLocationDraft]) async -> Bool {
    guard let profile else { return false }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let client = APIClient(profile: profile)
      var created: [LibrarySummary] = []
      for location in locations {
        let library = try await client.createLibrary(
          name: location.resolvedName,
          path: location.path,
          kind: location.kind)
        created.append(library)
        activeScans.append(try await client.startLibraryScan(id: library.id))
      }
      libraries = try await client.libraries()
      needsInitialLibrarySetup = false
      startScanPolling()
      try await refresh()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func reloadAdministration() async {
    guard let profile, profile.user?.role.canManageLibraries == true else { return }
    do {
      let client = APIClient(profile: profile)
      async let loadedLibraries = client.libraries()
      async let loadedSessions = client.sessions()
      libraries = try await loadedLibraries
      sessions = try await loadedSessions
      activeScans = try await client.activeLibraryScans()
      var history: [LibraryScanSummary] = []
      for library in libraries {
        history.append(contentsOf: try await client.libraryScans(id: library.id))
      }
      recentScans = Self.uniqueScans(history).sorted { $0.createdAt > $1.createdAt }
      libraryDiscoveries = try await loadDiscoveries(client: client, libraries: libraries)
      metadataProvider = try await client.metadataProviderStatus()
      startScanPolling()
    } catch { errorMessage = error.localizedDescription }
  }

  func addStorageLocations(
    _ locations: [StorageLocationDraft],
    combineExisting: Bool = false
  ) async -> Bool {
    guard let profile else { return false }
    isWorking = true
    defer { isWorking = false }
    do {
      let client = APIClient(profile: profile)
      var created: [LibrarySummary] = []
      for location in locations {
        let library = try await client.createLibrary(
          name: location.resolvedName,
          path: location.path,
          kind: location.kind,
          combineExisting: combineExisting)
        created.append(library)
        activeScans.append(try await client.startLibraryScan(id: library.id))
      }
      libraries.append(contentsOf: created)
      libraries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      startScanPolling()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func classifyDiscovery(_ discovery: LibraryDiscoverySummary, as decision: ClassificationDecision)
    async
  {
    guard let profile else { return }
    do {
      let scan = try await APIClient(profile: profile).updateClassification(
        libraryId: discovery.libraryId,
        discoveryId: discovery.id,
        decision: decision)
      activeScans.append(scan)
      libraryDiscoveries.removeAll { $0.id == discovery.id }
      startScanPolling()
    } catch { errorMessage = error.localizedDescription }
  }

  func reviewIgnoredDiscovery(_ discovery: LibraryDiscoverySummary) async {
    guard let profile else { return }
    do {
      let scan = try await APIClient(profile: profile).resetClassification(
        libraryId: discovery.libraryId,
        discoveryId: discovery.id)
      activeScans.append(scan)
      if let index = libraryDiscoveries.firstIndex(where: { $0.id == discovery.id }) {
        libraryDiscoveries[index] = LibraryDiscoverySummary(
          id: discovery.id,
          libraryId: discovery.libraryId,
          relativePath: discovery.relativePath,
          detectedTitle: discovery.detectedTitle,
          suggestedKind: discovery.suggestedKind,
          reason: discovery.reason,
          decision: nil)
      }
      startScanPolling()
    } catch { errorMessage = error.localizedDescription }
  }

  func removeLibrary(id: UUID) async {
    guard let profile else { return }
    do {
      try await APIClient(profile: profile).removeLibrary(id: id)
      libraries.removeAll { $0.id == id }
      try await refresh()
    } catch { errorMessage = error.localizedDescription }
  }

  func scanLibrary(id: UUID) async {
    guard let profile else { return }
    do {
      activeScans.append(try await APIClient(profile: profile).startLibraryScan(id: id))
      startScanPolling()
    } catch { errorMessage = error.localizedDescription }
  }

  func setMonitoring(libraryID: UUID, enabled: Bool) async {
    guard let profile else { return }
    do {
      let updated = try await APIClient(profile: profile).updateLibraryMonitoring(
        id: libraryID,
        enabled: enabled)
      if let index = libraries.firstIndex(where: { $0.id == libraryID }) {
        libraries[index] = updated
      }
    } catch { errorMessage = error.localizedDescription }
  }

  func cancelScan(id: UUID) async {
    guard let profile else { return }
    do {
      try await APIClient(profile: profile).cancelScan(id: id)
      if let latest = try? await APIClient(profile: profile).scan(id: id) {
        activeScans.removeAll { $0.id == id }
        recentScans = Self.uniqueScans([latest] + recentScans)
      }
    } catch { errorMessage = error.localizedDescription }
  }

  func generatePairingCode() async {
    guard let profile else { return }
    do { pairingCode = try await APIClient(profile: profile).createPairingCode() } catch {
      errorMessage = error.localizedDescription
    }
  }

  func revokeSession(id: UUID) async {
    guard let profile else { return }
    do {
      try await APIClient(profile: profile).revokeSession(id: id)
      sessions = try await APIClient(profile: profile).sessions()
    } catch { errorMessage = error.localizedDescription }
  }

  func configureMetadata(token: String) async {
    guard let profile else { return }
    do {
      metadataProvider = try await APIClient(profile: profile).configureMetadata(
        token: token, enabled: true)
    } catch { errorMessage = error.localizedDescription }
  }

  func disableMetadata() async {
    guard let profile else { return }
    do { metadataProvider = try await APIClient(profile: profile).removeMetadataToken() } catch {
      errorMessage = error.localizedDescription
    }
  }

  func enrichLibrary() async {
    guard let profile else { return }
    do {
      metadataJob = try await APIClient(profile: profile).startMetadataJob()
      guard let jobID = metadataJob?.id else { return }
      while metadataJob?.state == .queued || metadataJob?.state == .running {
        try await Task.sleep(for: .seconds(1))
        metadataJob = try await APIClient(profile: profile).metadataJob(id: jobID)
      }
      metadataProvider = try await APIClient(profile: profile).metadataProviderStatus()
    } catch { errorMessage = error.localizedDescription }
  }

  func pruneArtwork() async {
    guard let profile else { return }
    do {
      try await APIClient(profile: profile).pruneArtwork()
      metadataProvider = try await APIClient(profile: profile).metadataProviderStatus()
    } catch { errorMessage = error.localizedDescription }
  }

  func shutdown() async {
    await PlaybackShutdownCoordinator.shared.shutdown()
    hostPollTask?.cancel()
    homeRefreshTask?.cancel()
    scanPollTask?.cancel()
    syncRefreshTask?.cancel()
    await syncController.stop()
    if operatingMode == .host { await serverHost.stop() }
    endTerminationProtection()
  }

  func inspect(address: String) async {
    isWorking = true
    errorMessage = nil
    inspectedServer = nil
    defer { isWorking = false }
    do {
      let baseURL = try APIClient.normalizedServerURL(address)
      inspectedServer = try await APIClient.inspect(baseURL: baseURL)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func inspect(discovered: DiscoveredServer) async {
    await inspect(address: discovered.baseURL.absoluteString)
  }

  func cancelInspection() {
    inspectedServer = nil
    errorMessage = nil
  }

  func pair(code: String) async -> Bool {
    guard let inspectedServer else { return false }
    let normalizedCode = code.filter(\.isNumber)
    guard normalizedCode.count == 8 else {
      errorMessage = "Enter the eight-digit pairing code."
      return false
    }

    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let paired = try await APIClient.pair(
        inspected: inspectedServer,
        code: normalizedCode,
        deviceName: Host.current().localizedName ?? "Mac")
      try store.save(paired)
      profile = paired
      self.inspectedServer = nil
      try await refresh()
      startSync()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func refresh() async throws {
    guard let profile else { return }
    isWorking = true
    defer { isWorking = false }
    let client = APIClient(profile: profile)
    let info = try await client.serverInfo()
    guard info.serverId == profile.serverId else {
      throw APIClientError.serverIdentityMismatch
    }
    if profile.user == nil {
      let user = try await client.currentUser()
      let updated = StoredServerProfile(
        serverId: profile.serverId,
        name: info.name,
        baseURL: profile.baseURL,
        publicKeyFingerprint: profile.publicKeyFingerprint,
        token: profile.token,
        sessionId: profile.sessionId,
        expiresAt: profile.expiresAt,
        user: user)
      try store.save(updated)
      self.profile = updated
    }
    async let loadedMovies = client.movies()
    async let loadedSeries = client.series()
    async let loadedCatalog = client.catalogItems()
    async let loadedHome = client.home()
    async let loadedCollections = client.collections()
    movies = try await loadedMovies
    series = try await loadedSeries
    catalogItems = try await loadedCatalog
    home = try await loadedHome
    collections = try await loadedCollections
    scheduleHomeRefresh()
  }

  func refreshHome() async {
    #if DEBUG
      if Self.uiTestMode == "library" || Self.uiTestMode == "library-admin" {
        home = Self.previewHome
        scheduleHomeRefresh()
        return
      }
      if Self.uiTestMode != nil { return }
    #endif
    guard let profile else { return }
    do {
      home = try await APIClient(profile: profile).home()
      scheduleHomeRefresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func searchCatalog(_ query: String) async throws -> [CatalogItemSummary] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return catalogItems }
    #if DEBUG
      if Self.uiTestMode == "library" || Self.uiTestMode == "library-admin" {
        return (catalogItems + [Self.previewSearchEpisode]).filter { item in
          ([item.title, item.originalTitle ?? "", item.overview ?? ""] + item.genres)
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(trimmed)
        }
      }
    #endif
    guard let profile else { throw APIClientError.invalidResponse }
    return try await APIClient(profile: profile).searchCatalog(trimmed)
  }

  func catalogDetail(id: UUID) async throws -> CatalogDetailPresentation {
    #if DEBUG
      if Self.uiTestMode == "library" || Self.uiTestMode == "library-admin",
        let item = Self.previewCatalog.first(where: { $0.id == id })
      {
        return Self.previewDetail(for: item)
      }
    #endif
    guard let profile else { throw APIClientError.invalidResponse }
    return try await APIClient(profile: profile).catalogDetail(id: id)
  }

  func setFavorite(mediaId: UUID, isFavorite: Bool) async -> Bool {
    guard let profile else { return false }
    do {
      _ = try await APIClient(profile: profile).setFavorite(
        mediaId: mediaId, isFavorite: isFavorite)
      try await refresh()
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func saveMetadata(id: UUID, request: UpdateMediaMetadataRequest) async throws
    -> MediaMetadataSummary
  {
    guard let profile else { throw APIClientError.invalidResponse }
    let result = try await APIClient(profile: profile).updateMediaMetadata(id: id, request: request)
    try await refresh()
    return result
  }

  func metadataCandidates(mediaId: UUID, query: String) async throws
    -> [MetadataCandidateSummary]
  {
    guard let profile else { throw APIClientError.invalidResponse }
    return try await APIClient(profile: profile).metadataCandidates(mediaId: mediaId, query: query)
  }

  func selectMetadataMatch(
    mediaId: UUID,
    providerMediaId: String,
    mediaType: String
  ) async throws -> MediaMetadataSummary {
    guard let profile else { throw APIClientError.invalidResponse }
    let result = try await APIClient(profile: profile).selectMetadataMatch(
      mediaId: mediaId, providerMediaId: providerMediaId, mediaType: mediaType)
    try await refresh()
    return result
  }

  func clearMetadataMatch(mediaId: UUID) async throws -> MediaMetadataSummary {
    guard let profile else { throw APIClientError.invalidResponse }
    let result = try await APIClient(profile: profile).clearMetadataMatch(mediaId: mediaId)
    try await refresh()
    return result
  }

  func metadataReviews() async throws -> [MetadataReviewSummary] {
    guard let profile else { throw APIClientError.invalidResponse }
    return try await APIClient(profile: profile).metadataReviews()
  }

  func saveCollection(id: UUID?, name: String, mediaIds: [UUID]) async throws {
    guard let profile else { throw APIClientError.invalidResponse }
    let client = APIClient(profile: profile)
    if let id {
      _ = try await client.updateCollection(id: id, name: name, mediaIds: mediaIds)
    } else {
      _ = try await client.createCollection(name: name, mediaIds: mediaIds)
    }
    try await refresh()
  }

  func deleteCollection(id: UUID) async throws {
    guard let profile else { throw APIClientError.invalidResponse }
    try await APIClient(profile: profile).deleteCollection(id: id)
    try await refresh()
  }

  func refreshFromUI() async {
    errorMessage = nil
    do {
      try await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setApplicationActive(_ active: Bool) async {
    await syncController.setForeground(active, profile: profile) { [weak self] changes in
      await self?.handleSyncChanges(changes)
    }
  }

  func movieDetail(id: UUID) async throws -> MovieDetailResponse {
    #if DEBUG
      if Self.uiTestMode == "library" {
        return MovieDetailResponse(
          id: id,
          title: "El Camino - A Breaking Bad Movie",
          year: 2019,
          availability: .available,
          supplements: [
            SupplementSummary(
              id: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
              title: "Official Trailer",
              kind: .trailer,
              category: "Trailers",
              seasonNumber: nil,
              availability: .available)
          ])
      }
    #endif
    guard let profile else { throw APIClientError.invalidResponse }
    return try await APIClient(profile: profile).movie(id: id)
  }

  func seriesDetail(id: UUID) async throws -> SeriesDetailResponse {
    #if DEBUG
      if Self.uiTestMode == "library" {
        return SeriesDetailResponse(
          id: id,
          title: "Breaking Bad",
          availability: .available,
          seasons: [
            SeasonSummary(
              number: 1,
              episodes: [
                EpisodeSummary(
                  id: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
                  title: "Pilot",
                  seasonNumber: 1,
                  episodeNumber: 1,
                  availability: .available)
              ],
              supplements: [])
          ],
          supplements: [
            SupplementSummary(
              id: UUID(uuidString: "20000000-0000-0000-0000-000000000020")!,
              title: "Behind the Scenes",
              kind: .extra,
              category: "Special Features",
              seasonNumber: nil,
              availability: .available)
          ])
      }
    #endif
    guard let profile else { throw APIClientError.invalidResponse }
    return try await APIClient(profile: profile).series(id: id)
  }

  func startPlayback(mediaId: UUID, title: String, subtitle: String? = nil) {
    guard profile != nil else { return }
    playback = PlaybackPresentation(mediaId: mediaId, title: title, subtitle: subtitle)
  }

  func closePlayback() {
    playback = nil
  }

  func disconnect() async {
    let current = profile
    profile = nil
    await syncController.stop()
    syncRefreshTask?.cancel()
    syncRefreshTask = nil
    movies = []
    series = []
    catalogItems = []
    home = nil
    collections = []
    homeRefreshTask?.cancel()
    homeRefreshTask = nil
    artworkLoader.removeAll()
    inspectedServer = nil
    playback = nil
    errorMessage = nil
    if !Self.isTestProcess {
      try? store.delete()
      if let current {
        try? await APIClient(profile: current).logout()
      }
    }
  }

  private func startNativeHost() async {
    hostSnapshot = NativeHostSnapshot(
      state: .starting,
      message: nil,
      bootstrapToken: nil,
      serverInfo: nil)
    do {
      hostSnapshot = try await serverHost.start(
        serverName: "Aurelia on \(Host.current().localizedName ?? "This Mac")")
      beginTerminationProtection()
      startHostPolling()
      if profile != nil, hostSnapshot.state == .running {
        do { try await refresh() } catch { errorMessage = error.localizedDescription }
      }
    } catch {
      hostSnapshot = NativeHostSnapshot(
        state: .failed,
        message: error.localizedDescription,
        bootstrapToken: nil,
        serverInfo: nil)
    }
  }

  private func scheduleHomeRefresh() {
    homeRefreshTask?.cancel()
    guard let value = home?.recommendationChangesAt,
      let delay = HomeRefreshPolicy.delay(until: value)
    else { return }
    homeRefreshTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self else { return }
      await self.refreshHome()
    }
  }

  private func startHostPolling() {
    hostPollTask?.cancel()
    hostPollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(750))
        guard let self else { return }
        do {
          let snapshot = try await self.serverHost.status()
          self.hostSnapshot = snapshot
        } catch {
          self.hostSnapshot = NativeHostSnapshot(
            state: .failed,
            message: error.localizedDescription,
            bootstrapToken: nil,
            serverInfo: nil)
          return
        }
      }
    }
  }

  private func persistOperatingMode(explicit: Bool) {
    guard let operatingMode else { return }
    UserDefaults.standard.set(operatingMode.rawValue, forKey: Self.operatingModeKey)
    if explicit {
      UserDefaults.standard.set(
        OperatingModePolicy.selectionVersion,
        forKey: Self.operatingModeSelectionVersionKey)
    }
  }

  private func beginTerminationProtection() {
    guard !isTerminationProtectionActive else { return }
    ProcessInfo.processInfo.disableAutomaticTermination("Aurelia is hosting its server")
    ProcessInfo.processInfo.disableSuddenTermination()
    isTerminationProtectionActive = true
  }

  private func endTerminationProtection() {
    guard isTerminationProtectionActive else { return }
    ProcessInfo.processInfo.enableAutomaticTermination("Aurelia stopped hosting its server")
    ProcessInfo.processInfo.enableSuddenTermination()
    isTerminationProtectionActive = false
  }

  private func finishLocalAuthentication(
    _ authentication: AuthenticationResponse,
    lanPort: Int,
    restart: Bool = true
  ) async throws {
    if restart { try await serverHost.restart() }
    var inspected: InspectedServer?
    for _ in 0..<100 {
      inspected = try? await APIClient.inspect(
        baseURL: URL(string: "https://127.0.0.1:\(lanPort)")!)
      if inspected != nil { break }
      try await Task.sleep(for: .milliseconds(200))
    }
    guard let inspected else { throw NativeServerHostError.rendezvousTimedOut }
    let localProfile = APIClient.profile(authentication: authentication, inspected: inspected)
    try store.save(localProfile)
    profile = localProfile
    try await refresh()
    await reloadAdministration()
    startSync()
  }

  private func startScanPolling() {
    guard !activeScans.isEmpty else { return }
    scanPollTask?.cancel()
    scanPollTask = Task { [weak self] in
      guard let self, let profile = self.profile else { return }
      while !Task.isCancelled && !self.activeScans.isEmpty {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        var updated: [LibraryScanSummary] = []
        var completed: [LibraryScanSummary] = []
        for scan in self.activeScans {
          if let latest = try? await APIClient(profile: profile).scan(id: scan.id) {
            if latest.state == .queued || latest.state == .running
              || latest.state == .waitingForStorage
            {
              updated.append(latest)
            } else {
              completed.append(latest)
            }
          }
        }
        self.activeScans = updated
        if !completed.isEmpty {
          self.recentScans = Self.uniqueScans(completed + self.recentScans)
            .sorted { $0.createdAt > $1.createdAt }
          try? await self.refresh()
          await self.reloadAdministrationAfterScan()
        }
      }
      self.scanPollTask = nil
    }
  }

  private func startSync() {
    guard let profile else { return }
    Task { [weak self, profile] in
      guard let self else { return }
      await self.syncController.start(profile: profile) { changes in
        await self.handleSyncChanges(changes)
      }
    }
  }

  private func handleSyncChanges(_ changes: SyncChangesResponse) async {
    guard changes.resetRequired || !changes.changedAreas.isEmpty else { return }
    if changes.changedAreas.contains(.libraries), canManageMedia {
      await reloadAdministrationAfterScan()
    }
    guard syncRefreshTask == nil else { return }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.refresh()
      } catch {
        self.errorMessage = error.localizedDescription
      }
      self.syncRefreshTask = nil
    }
    syncRefreshTask = task
    await task.value
  }

  private func reloadAdministrationAfterScan() async {
    guard let profile else { return }
    let client = APIClient(profile: profile)
    if let refreshedLibraries = try? await client.libraries() {
      libraries = refreshedLibraries
      libraryDiscoveries =
        (try? await loadDiscoveries(
          client: client,
          libraries: refreshedLibraries)) ?? libraryDiscoveries
    }
  }

  private static func uniqueScans(_ scans: [LibraryScanSummary]) -> [LibraryScanSummary] {
    var seen = Set<UUID>()
    return scans.filter { seen.insert($0.id).inserted }
  }

  private func loadDiscoveries(
    client: APIClient,
    libraries: [LibrarySummary]
  ) async throws -> [LibraryDiscoverySummary] {
    var discoveries: [LibraryDiscoverySummary] = []
    for library in libraries where library.kind == .automatic {
      discoveries.append(contentsOf: try await client.libraryDiscoveries(id: library.id))
    }
    return discoveries.sorted {
      $0.detectedTitle.localizedCaseInsensitiveCompare($1.detectedTitle) == .orderedAscending
    }
  }

  #if DEBUG
    private static let previewMovieID = UUID(
      uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let previewSeriesID = UUID(
      uuidString: "20000000-0000-0000-0000-000000000001")!
    private static let previewEpisodeID = UUID(
      uuidString: "20000000-0000-0000-0000-000000000010")!
    private static let previewMissingID = UUID(
      uuidString: "10000000-0000-0000-0000-000000000099")!

    private static let previewCatalog: [CatalogItemSummary] = [
      CatalogItemSummary(
        id: previewMovieID,
        kind: .movie,
        title: "El Camino: A Breaking Bad Movie",
        originalTitle: nil,
        year: 2019,
        overview: "Jesse Pinkman must come to terms with his past in order to forge a future.",
        genres: ["Crime", "Drama"],
        poster: nil,
        backdrop: nil,
        availability: .available,
        isFavorite: true,
        progress: PlaybackProgressResponse(
          mediaId: previewMovieID,
          positionMilliseconds: 2_100_000,
          durationMilliseconds: 7_320_000,
          isCompleted: false,
          lastPlayedAt: "2026-09-10T08:00:00Z",
          updatedAt: "2026-09-10T08:00:00Z"),
        addedAt: "2026-09-09T08:00:00Z"),
      CatalogItemSummary(
        id: previewSeriesID,
        kind: .series,
        title: "Breaking Bad",
        originalTitle: nil,
        year: 2008,
        overview:
          "A chemistry teacher transforms himself into a ruthless player in the local drug trade.",
        genres: ["Drama", "Crime"],
        poster: nil,
        backdrop: nil,
        availability: .available,
        isFavorite: false,
        progress: nil,
        addedAt: "2026-09-08T08:00:00Z"),
      CatalogItemSummary(
        id: previewMissingID,
        kind: .movie,
        title: "Missing Feature",
        originalTitle: nil,
        year: 2024,
        overview: "This title remains in the library while its source is offline.",
        genres: ["Drama"],
        poster: nil,
        backdrop: nil,
        availability: .missing,
        isFavorite: false,
        progress: nil,
        addedAt: "2026-09-07T08:00:00Z"),
    ]

    private static let previewSearchEpisode = CatalogItemSummary(
      id: previewEpisodeID,
      kind: .episode,
      title: "Pilot",
      originalTitle: nil,
      year: 2008,
      overview: "Walter White makes a desperate choice after receiving life-changing news.",
      genres: ["Drama", "Crime"],
      poster: nil,
      backdrop: nil,
      availability: .available,
      isFavorite: false,
      progress: nil,
      addedAt: "2026-09-08T08:00:00Z",
      parentTitle: "Breaking Bad",
      seasonNumber: 1,
      episodeNumber: 1)

    private static let previewHome = HomeResponse(
      recommendation: previewCatalog[1],
      continueWatching: [previewCatalog[0]],
      recentlyAdded: previewCatalog,
      favorites: [previewCatalog[0]],
      collections: [
        CollectionSummary(
          id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
          name: "Breaking Bad Universe",
          poster: nil,
          items: previewCatalog)
      ],
      recommendationChangesAt: "2099-01-01T00:00:00Z")

    private static func previewDetail(for item: CatalogItemSummary)
      -> CatalogDetailPresentation
    {
      let metadata = MediaMetadataSummary(
        mediaId: item.id,
        title: item.title,
        originalTitle: item.originalTitle,
        overview: item.overview,
        releaseDate: item.year.map { "\($0)-01-01" },
        year: item.year,
        runtimeMinutes: item.kind == .movie ? 122 : nil,
        rating: 8.9,
        contentRating: "TV-MA",
        genres: item.genres,
        studios: ["Sony Pictures Television"],
        countries: ["United States"],
        credits: [
          CreditSummary(
            name: "Bryan Cranston",
            department: "Acting",
            job: nil,
            character: "Walter White",
            order: 0,
            profile: nil),
          CreditSummary(
            name: "Aaron Paul",
            department: "Acting",
            job: nil,
            character: "Jesse Pinkman",
            order: 1,
            profile: nil),
        ],
        poster: item.poster,
        backdrop: item.backdrop,
        still: nil,
        provider: "TMDB",
        providerMediaId: "preview",
        reviewState: .matched)
      let episodeItem = previewSearchEpisode
      let supplementID = UUID(
        uuidString: item.kind == .movie
          ? "10000000-0000-0000-0000-000000000010"
          : "20000000-0000-0000-0000-000000000020")!
      let supplementItem = CatalogItemSummary(
        id: supplementID,
        kind: item.kind == .movie ? .trailer : .extra,
        title: item.kind == .movie ? "Official Trailer" : "Inside Breaking Bad",
        originalTitle: nil,
        year: item.year,
        overview: nil,
        genres: [],
        poster: nil,
        backdrop: nil,
        availability: .available,
        isFavorite: false,
        progress: nil,
        addedAt: "2026-09-08T08:00:00Z")
      return CatalogDetailPresentation(
        item: item,
        metadata: metadata,
        seasons: item.kind == .series
          ? [
            SeasonPresentation(
              number: 1,
              episodes: [
                EpisodePresentation(item: episodeItem, seasonNumber: 1, episodeNumber: 1)
              ],
              supplements: [])
          ] : [],
        supplements: [
          SupplementPresentation(
            item: supplementItem,
            category: item.kind == .movie ? "Trailer" : "Extras",
            seasonNumber: nil)
        ])
    }

    private static let previewProfile = StoredServerProfile(
      serverId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
      name: "Aurelia",
      baseURL: URL(string: "https://aurelia.local:43111")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "ui-test-token",
      sessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
      expiresAt: "2099-01-01T00:00:00Z")

    private static let previewOwnerProfile = StoredServerProfile(
      serverId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
      name: "Aurelia on Test Mac",
      baseURL: URL(string: "https://127.0.0.1:43111")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "ui-test-owner-token",
      sessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
      expiresAt: "2099-01-01T00:00:00Z",
      user: UserSummary(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
        username: "owner",
        role: .owner,
        createdAt: "2099-01-01T00:00:00Z"))

    private static let previewHostSnapshot = NativeHostSnapshot(
      state: .running,
      message: nil,
      bootstrapToken: nil,
      serverInfo: ServerInfoResponse(
        serverId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        name: "Aurelia on Test Mac",
        version: "1.0.9",
        isSetup: true,
        lanAccessEnabled: true,
        lanHttpsPort: 43_111,
        publicKeyFingerprint: String(repeating: "A", count: 64),
        displayFingerprint: "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA"))
  #endif

  private static var uiTestMode: String? {
    #if DEBUG
      ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"]
    #else
      nil
    #endif
  }

  private static var defaultStore: any ServerProfileStore {
    #if DEBUG
      if isTestProcess {
        return InMemoryServerProfileStore()
      }
    #endif
    return KeychainServerStore()
  }

  private static var isTestProcess: Bool {
    #if DEBUG
      uiTestMode != nil
        || ProcessInfo.processInfo.environment["AURELIA_RUNNING_TESTS"] == "1"
    #else
      false
    #endif
  }
}
