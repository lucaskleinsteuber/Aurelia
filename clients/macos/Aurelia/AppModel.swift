import AppKit
import Foundation
import OSLog

@MainActor
final class AppModel: ObservableObject {
  static var active: AppModel?
  @Published private(set) var operatingMode: OperatingMode?
  @Published private(set) var profile: StoredServerProfile? {
    didSet {
      guard
        oldValue?.serverId != profile?.serverId || oldValue?.sessionId != profile?.sessionId
          || oldValue?.token != profile?.token
      else { return }
      if !Self.isTestProcess, !NativePreflightIsolation.isRequested {
        PlaybackProgressOutbox.shared.deactivate()
      }
      let retiredGeneration = connectionGeneration
      connectionGeneration = UUID()
      cancelConnectionWork()
      let controller = syncController
      Task { await controller.stop(runID: retiredGeneration) }
      homeRefresher.invalidate()
      artworkLoader.removeAll()
    }
  }
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
  @Published private(set) var scanStatusUnavailable: Set<UUID> = []
  @Published private(set) var recentScans: [LibraryScanSummary] = []
  @Published private(set) var libraryDiscoveries: [LibraryDiscoverySummary] = []
  @Published private(set) var libraryImportReviews: [LibraryImportReviewSummary] = []
  @Published private(set) var pairingCode: PairingCodeResponse?
  @Published private(set) var sessions: [DeviceSessionSummary] = []
  @Published private(set) var metadataProvider: MetadataProviderStatus?
  @Published private(set) var metadataJob: MetadataJobSummary?
  @Published private(set) var needsInitialLibrarySetup = false
  @Published private(set) var isStarting = true
  @Published private(set) var isWorking = false
  @Published private(set) var isRecoveringLocalHost = false
  @Published var errorMessage: String?
  @Published var isMediaManagerPresented = false
  @Published var importPreviewLibrary: LibrarySummary?

  let artworkLoader = ArtworkLoader()

  private let store: any ServerProfileStore
  private let serverHost: NativeServerHost
  private let syncController: LibrarySyncController
  private let homeRefresher = HomeRefreshCoordinator()
  private var hasStarted = false
  private var hostPollTask: Task<Void, Never>?
  private var homeRefreshTask: Task<Void, Never>?
  private var scanPollTask: Task<Void, Never>?
  private var scanPollingRun = UUID()
  private var syncStartTask: Task<Void, Never>?
  private var connectionGeneration = UUID()
  private var inspectionGeneration = UUID()
  private let administrationFetcher:
    (@MainActor (StoredServerProfile) async throws -> AdministrationSnapshot)?

  struct AdministrationSnapshot {
    var libraries: [LibrarySummary] = []
    var sessions: [DeviceSessionSummary] = []
    var scans: [LibraryScanSummary] = []
    var history: [LibraryScanSummary] = []
    var discoveries: [LibraryDiscoverySummary] = []
    var reviews: [LibraryImportReviewSummary] = []
    var metadataProvider: MetadataProviderStatus?
  }

  private func isCurrent(_ generation: UUID) -> Bool {
    connectionGeneration == generation && profile != nil && !Task.isCancelled
  }

  private func currentConnection<T>(_ operation: @MainActor () async throws -> T) async throws -> T
  {
    let generation = connectionGeneration
    do {
      let value = try await operation()
      guard isCurrent(generation) else { throw CancellationError() }
      return value
    } catch {
      guard isCurrent(generation) else { throw CancellationError() }
      throw error
    }
  }

  private func cancelConnectionWork() {
    homeRefreshTask?.cancel()
    homeRefreshTask = nil
    scanPollTask?.cancel()
    scanPollTask = nil
    scanPollingRun = UUID()
    scanStatusUnavailable = []
    syncStartTask?.cancel()
    syncStartTask = nil
  }
  private var isTerminationProtectionActive = false
  private var hostHealth = HostHealthPolicy()
  private static let hostLogger = Logger(subsystem: "com.lucas.aurelia.media", category: "Hosting")
  private static let operatingModeKey = "AureliaOperatingMode"
  private static let operatingModeSelectionVersionKey = "AureliaOperatingModeSelectionVersion"

  var canManageMedia: Bool { profile?.user?.role.canManageLibraries == true }
  var isLocalHost: Bool { operatingMode == .host }
  var canRestoreLocalHosting: Bool {
    guard let profile else { return false }
    return OperatingModePolicy.isLocal(profile.baseURL) && operatingMode != .host
  }
  var isImportPreviewUITest: Bool {
    #if DEBUG
      Self.uiTestMode == "import-preview"
    #else
      false
    #endif
  }

  func showMediaManager() {
    isMediaManagerPresented = true
  }

  init(
    store: (any ServerProfileStore)? = nil,
    serverHost: NativeServerHost = NativeServerHost(),
    initialProfile: StoredServerProfile? = nil,
    syncController: LibrarySyncController = LibrarySyncController(),
    administrationFetcher: (
      @MainActor (StoredServerProfile) async throws -> AdministrationSnapshot
    )? = nil
  ) {
    self.store = store ?? Self.defaultStore
    self.serverHost = serverHost
    self.syncController = syncController
    self.administrationFetcher = administrationFetcher
    self.profile = initialProfile
    self.operatingMode = UserDefaults.standard.string(forKey: Self.operatingModeKey)
      .flatMap(OperatingMode.init(rawValue:))
    Self.active = self
  }

  func start() async {
    guard !hasStarted else { return }
    hasStarted = true
    if NativePreflightIsolation.isRequested {
      Self.hostLogger.notice(
        "Preflight isolation active: \(NativePreflightIsolation.isActive); bundle: \(Bundle.main.bundleURL.path, privacy: .public)"
      )
      guard NativePreflightIsolation.isActive else {
        operatingMode = .client
        errorMessage =
          "The isolated test launch was rejected. No saved account or host settings were accessed."
        isStarting = false
        return
      }
    }

    #if DEBUG
      if Self.uiTestMode == "local-host-recovery" {
        operatingMode = .client
        profile = Self.previewOwnerProfile
        errorMessage = "The saved local server is not running. Your account is still connected."
        isStarting = false
        return
      }
      if Self.uiTestMode == "import-preview" {
        operatingMode = .client
        profile = Self.previewOwnerProfile
        isStarting = false
        return
      }
      if Self.uiTestMode == "server-settings" {
        operatingMode = .client
        profile = Self.previewOwnerProfile
        isStarting = false
        if let path = ProcessInfo.processInfo.environment["AURELIA_SERVER_SETTINGS_RENDER"] {
          do {
            let writesDescriptor =
              ProcessInfo.processInfo.environment["AURELIA_SERVER_SETTINGS_RENDER_STDOUT"] == "1"
            let destination = try ServerSettingsVisualProbe.validatedOutput(
              path, allowsEmptyOutputDescriptor: writesDescriptor)
            let png = try await ServerSettingsVisualProbe.render()
            if writesDescriptor {
              // The sandbox can write the output descriptor supplied by Launch
              // Services without granting access to an external test directory.
              try FileHandle.standardOutput.write(contentsOf: png)
            } else {
              try png.write(to: destination, options: .atomic)
            }
            NSApplication.shared.terminate(nil)
          } catch {
            fputs("Isolated server settings render failed: \(error.localizedDescription)\n", stderr)
            exit(2)
          }
        }
        return
      }
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
        home = CinemaUITestFixture.home(Self.previewHome)
        collections = home?.collections ?? Self.previewHome.collections
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

    #if DEBUG
      if Self.isTestProcess && Self.uiTestMode == nil {
        operatingMode = .client
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
      Self.hostLogger.info(
        "Resolved startup mode: \(self.operatingMode?.rawValue ?? "unselected", privacy: .public); managed connection: \(self.profile?.locallyManaged == true)"
      )
      if operatingMode == .host {
        await startNativeHost()
      } else if profile != nil {
        try await refresh(requireCompleteSnapshot: true)
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

  /// Starts the existing local server without signing out, redeeming a code, or setting up an owner.
  func restoreLocalHosting() async {
    guard canRestoreLocalHosting, !isRecoveringLocalHost else { return }
    errorMessage = nil
    #if DEBUG
      if Self.uiTestMode == "local-host-recovery" {
        isRecoveringLocalHost = true
        defer { isRecoveringLocalHost = false }
        try? await Task.sleep(for: .milliseconds(400))
        profile = profile?.retainingLocalHosting()
        hostSnapshot = Self.previewHostSnapshot
        operatingMode = .host
        home = Self.previewHome
        catalogItems = Self.previewCatalog
        return
      }
    #endif
    if await startNativeHost() {
      operatingMode = .host
      persistOperatingMode(explicit: true)
      await reloadAdministration()
    }
  }

  func selectHostMode() async {
    if let profile, !OperatingModePolicy.isLocal(profile.baseURL) {
      await disconnect()
      guard self.profile == nil else { return }
    }
    operatingMode = .host
    persistOperatingMode(explicit: true)
    await startNativeHost()
  }

  func switchToClientMode() async {
    await disconnect()
    guard profile == nil else { return }
    await PlaybackShutdownCoordinator.shared.shutdown()
    hostPollTask?.cancel()
    hostPollTask = nil
    await serverHost.stop()
    endTerminationProtection()
    hostSnapshot = .stopped
    operatingMode = .client
    persistOperatingMode(explicit: true)
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
    let generation = connectionGeneration
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
      guard connectionGeneration == generation, !Task.isCancelled else { return false }
      try await finishLocalAuthentication(
        authentication, lanPort: lanPort, expectedGeneration: generation)
      guard profile != nil else { return false }
      needsInitialLibrarySetup = true
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func loginToLocalServer(username: String, password: String) async -> Bool {
    let generation = connectionGeneration
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let authentication = try await APIClient.loginLocally(
        username: username,
        password: password,
        deviceName: Host.current().localizedName ?? "Server Mac")
      guard connectionGeneration == generation, !Task.isCancelled else { return false }
      let port = hostSnapshot.serverInfo?.lanHttpsPort ?? 43_111
      try await finishLocalAuthentication(
        authentication, lanPort: port, restart: false, expectedGeneration: generation)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func restartNativeHost() async {
    errorMessage = nil
    hostHealth = HostHealthPolicy()
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
    do {
      if let profile {
        _ = try await APIClient(profile: profile).restartServer()
      } else {
        try await serverHost.restart()
      }
    } catch { errorMessage = error.localizedDescription }
  }

  func completeInitialLibrarySetup() {
    needsInitialLibrarySetup = false
  }

  func createStorageLocations(_ locations: [StorageLocationDraft]) async -> Bool {
    guard let profile else { return false }
    let generation = connectionGeneration
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
          kind: location.kind,
          requireImportPreview: true)
        created.append(library)
      }
      let registered = try await client.libraries()
      guard isCurrent(generation) else { return false }
      libraries = registered
      importPreviewLibrary = created.first
      return true
    } catch {
      guard isCurrent(generation) else { return false }
      errorMessage = error.localizedDescription
      if let registered = try? await APIClient(profile: profile).libraries() {
        guard isCurrent(generation) else { return false }
        libraries = registered
      }
      return false
    }
  }

  func reloadAdministration() async {
    #if DEBUG
      if Self.uiTestMode == "local-host-recovery" { return }
    #endif
    guard let profile, profile.user?.role.canManageLibraries == true else { return }
    let generation = connectionGeneration
    do {
      let snapshot: AdministrationSnapshot
      if let administrationFetcher {
        snapshot = try await administrationFetcher(profile)
      } else {
        let client = APIClient(profile: profile)
        async let loadedLibraries = client.libraries()
        async let loadedSessions = client.sessions()
        let freshLibraries = try await loadedLibraries
        let freshSessions = try await loadedSessions
        let freshScans = try await client.activeLibraryScans()
        var history: [LibraryScanSummary] = []
        for library in freshLibraries {
          history.append(contentsOf: try await client.libraryScans(id: library.id))
        }
        snapshot = try await AdministrationSnapshot(
          libraries: freshLibraries, sessions: freshSessions, scans: freshScans, history: history,
          discoveries: loadDiscoveries(client: client, libraries: freshLibraries),
          reviews: loadImportReviews(client: client, libraries: freshLibraries),
          metadataProvider: profile.user?.role == .owner ? client.metadataProviderStatus() : nil)
      }
      guard isCurrent(generation) else { return }
      libraries = snapshot.libraries
      sessions = snapshot.sessions
      activeScans = snapshot.scans
      scanStatusUnavailable.formIntersection(Set(snapshot.scans.map(\.id)))
      recentScans = Self.uniqueScans(snapshot.history).sorted { $0.createdAt > $1.createdAt }
      libraryDiscoveries = snapshot.discoveries
      libraryImportReviews = snapshot.reviews
      metadataProvider = snapshot.metadataProvider
      startScanPolling()
    } catch { if isCurrent(generation) { errorMessage = error.localizedDescription } }
  }

  func addStorageLocations(
    _ locations: [StorageLocationDraft],
    combineExisting: Bool = false
  ) async -> Bool {
    guard let profile else { return false }
    let generation = connectionGeneration
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
          kind: location.kind,
          combineExisting: combineExisting,
          requireImportPreview: true)
        created.append(library)
      }
      let registered = try await client.libraries()
      guard isCurrent(generation) else { return false }
      libraries = registered
      importPreviewLibrary = created.first
      return true
    } catch {
      guard isCurrent(generation) else { return false }
      errorMessage = error.localizedDescription
      if let registered = try? await APIClient(profile: profile).libraries() {
        guard isCurrent(generation) else { return false }
        libraries = registered
      }
      return false
    }
  }

  func didConfirmImport(scan: LibraryScanSummary) async {
    activeScans = Self.uniqueScans(activeScans + [scan])
    startScanPolling()
    await reloadAdministration()
    if !libraries.contains(where: { $0.importPreviewRequired == true }) {
      needsInitialLibrarySetup = false
    }
  }

  func classifyDiscovery(_ discovery: LibraryDiscoverySummary, as decision: ClassificationDecision)
    async
  {
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      let scan = try await APIClient(profile: profile).updateClassification(
        libraryId: discovery.libraryId,
        discoveryId: discovery.id,
        decision: decision)
      guard isCurrent(generation) else { return }
      activeScans.append(scan)
      libraryDiscoveries.removeAll { $0.id == discovery.id }
      startScanPolling()
    } catch { if isCurrent(generation) { errorMessage = error.localizedDescription } }
  }

  func reviewIgnoredDiscovery(_ discovery: LibraryDiscoverySummary) async {
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      let scan = try await APIClient(profile: profile).resetClassification(
        libraryId: discovery.libraryId,
        discoveryId: discovery.id)
      guard isCurrent(generation) else { return }
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
    } catch { if isCurrent(generation) { errorMessage = error.localizedDescription } }
  }

  func removeLibrary(id: UUID) async {
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      let client = APIClient(profile: profile)
      let preview = try await client.previewReset(libraries: [id])
      let result = try await client.resetLibrary(preview: preview)
      guard isCurrent(generation) else { return }
      guard result.state == "completed" else {
        throw APIClientError.serverRejected(
          code: "cleanup_pending",
          message: result.error ?? "The library reset is awaiting artwork cleanup.")
      }
      libraries.removeAll { $0.id == id }
      try await refresh()
    } catch { if isCurrent(generation) { errorMessage = error.localizedDescription } }
  }

  func scanLibrary(id: UUID) async {
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      let scan = try await APIClient(profile: profile).startLibraryScan(id: id)
      guard isCurrent(generation) else { return }
      activeScans.append(scan)
      startScanPolling()
    } catch { if isCurrent(generation) { errorMessage = error.localizedDescription } }
  }

  func setMonitoring(libraryID: UUID, enabled: Bool) async {
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      let updated = try await APIClient(profile: profile).updateLibraryMonitoring(
        id: libraryID,
        enabled: enabled)
      guard isCurrent(generation) else { return }
      if let index = libraries.firstIndex(where: { $0.id == libraryID }) {
        libraries[index] = updated
      }
    } catch { if isCurrent(generation) { errorMessage = error.localizedDescription } }
  }

  func cancelScan(id: UUID) async {
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      try await APIClient(profile: profile).cancelScan(id: id)
      if let latest = try? await APIClient(profile: profile).scan(id: id) {
        guard isCurrent(generation) else { return }
        if [.queued, .running, .waitingForStorage].contains(latest.state) {
          activeScans = activeScans.map { $0.id == id ? latest : $0 }
        } else {
          activeScans.removeAll { $0.id == id }
          recentScans = Self.uniqueScans([latest] + recentScans)
        }
        scanStatusUnavailable.remove(id)
      }
    } catch { if isCurrent(generation) { errorMessage = error.localizedDescription } }
  }

  func generatePairingCode() async {
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      let code = try await APIClient(profile: profile).createPairingCode()
      guard isCurrent(generation) else { return }
      pairingCode = code
    } catch {
      if isCurrent(generation) { errorMessage = error.localizedDescription }
    }
  }

  func revokeSession(id: UUID) async {
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      try await APIClient(profile: profile).revokeSession(id: id)
      guard isCurrent(generation) else { return }
      sessions.removeAll { $0.id == id }
      await reloadDevices()
    } catch { if isCurrent(generation) { errorMessage = error.localizedDescription } }
  }

  func configureMetadata(token: String) async {
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      let provider = try await APIClient(profile: profile).configureMetadata(
        token: token, enabled: true)
      guard isCurrent(generation) else { return }
      metadataProvider = provider
    } catch { if isCurrent(generation) { errorMessage = error.localizedDescription } }
  }

  func disableMetadata() async {
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      let provider = try await APIClient(profile: profile).removeMetadataToken()
      guard isCurrent(generation) else { return }
      metadataProvider = provider
    } catch {
      if isCurrent(generation) { errorMessage = error.localizedDescription }
    }
  }

  func enrichLibrary() async {
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      let client = APIClient(profile: profile)
      if profile.user?.role == .owner {
        let job = try await client.startMetadataJob()
        guard isCurrent(generation) else { return }
        metadataJob = job
      } else {
        // Administrators can request only explicitly shared libraries, never a
        // server-wide metadata refresh or a change to provider credentials.
        for library in libraries {
          let job = try await client.startMetadataJob(libraryId: library.id)
          guard isCurrent(generation) else { return }
          metadataJob = job
        }
      }
      guard let jobID = metadataJob?.id else { return }
      while metadataJob?.state == .queued || metadataJob?.state == .running {
        try await Task.sleep(for: .seconds(1))
        guard isCurrent(generation) else { return }
        let job = try await APIClient(profile: profile).metadataJob(id: jobID)
        guard isCurrent(generation) else { return }
        metadataJob = job
      }
      if profile.user?.role == .owner {
        let provider = try await client.metadataProviderStatus()
        guard isCurrent(generation) else { return }
        metadataProvider = provider
      }
    } catch { if isCurrent(generation) { errorMessage = error.localizedDescription } }
  }

  func pruneArtwork() async {
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      try await APIClient(profile: profile).pruneArtwork()
      let provider = try await APIClient(profile: profile).metadataProviderStatus()
      guard isCurrent(generation) else { return }
      metadataProvider = provider
    } catch { if isCurrent(generation) { errorMessage = error.localizedDescription } }
  }

  func shutdown() async {
    connectionGeneration = UUID()
    cancelConnectionWork()
    await PlaybackShutdownCoordinator.shared.shutdown()
    hostPollTask?.cancel()
    homeRefreshTask?.cancel()
    scanPollTask?.cancel()
    await syncController.stop()
    if operatingMode == .host && !serverHost.isBackgroundService { await serverHost.stop() }
    endTerminationProtection()
  }
  func saveHostingSettings(_ settings: HostServiceSettings) async throws {
    guard isLocalHost, profile?.user?.role == .owner else { throw NativeServerHostError.rejected }
    guard let profile else { throw NativeServerHostError.rejected }
    let operation = try await APIClient(profile: profile).authorizeHostingChange(settings)
    let wasBackground = serverHost.isBackgroundService
    let previous = try HostServiceSettings.load()
    if wasBackground && (!settings.backgroundEnabled || previous.agentName != settings.agentName) {
      // Release the old independent host before unregistering its agent; report
      // completion through the new host, not a control channel macOS just removed.
      await serverHost.stop()
      _ = try await BackgroundHostingController.save(settings)
      await startNativeHost()
      guard hostSnapshot.state != .failed else { throw NativeServerHostError.couldNotLaunch }
      try await serverHost.hostingSettingsApplied(
        operationID: operation.id,
        permitted: !settings.backgroundEnabled || BackgroundHostingController.permitted)
      return
    }
    let permitted = try await BackgroundHostingController.save(settings)
    try await serverHost.hostingSettingsApplied(
      operationID: operation.id, permitted: !settings.backgroundEnabled || permitted)
    if settings.backgroundEnabled && permitted {
      if !serverHost.isBackgroundService { try await serverHost.handoffToBackground() }
      await startNativeHost()
    } else if !settings.backgroundEnabled {
      await serverHost.stop()
      await startNativeHost()
    }
  }

  func acceptConfirmedNetwork(profile updated: StoredServerProfile) throws {
    guard profile?.serverId == updated.serverId, profile?.sessionId == updated.sessionId,
      profile?.publicKeyFingerprint == updated.publicKeyFingerprint
    else { throw APIClientError.invalidResponse }
    try store.save(updated)
    profile = updated
    startSync()
  }

  func inspect(address: String) async {
    let generation = UUID()
    inspectionGeneration = generation
    isWorking = true
    errorMessage = nil
    inspectedServer = nil
    defer { if inspectionGeneration == generation { isWorking = false } }
    do {
      let baseURL = try APIClient.normalizedServerURL(address)
      let inspected = try await APIClient.inspect(baseURL: baseURL)
      guard inspectionGeneration == generation, !Task.isCancelled else { return }
      inspectedServer = inspected
    } catch {
      if inspectionGeneration == generation, !Task.isCancelled {
        errorMessage = error.localizedDescription
      }
    }
  }

  func inspect(discovered: DiscoveredServer) async {
    await inspect(address: discovered.baseURL.absoluteString)
  }

  func cancelInspection() {
    inspectionGeneration = UUID()
    inspectedServer = nil
    errorMessage = nil
  }

  func pair(code: String) async -> Bool {
    guard let inspectedServer else { return false }
    var generation = connectionGeneration
    let inspection = inspectionGeneration
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
      guard connectionGeneration == generation, inspectionGeneration == inspection,
        !Task.isCancelled
      else { return false }
      try store.save(paired)
      profile = paired
      generation = connectionGeneration
      self.inspectedServer = nil
      try await refresh()
      startSync()
      return true
    } catch {
      if connectionGeneration == generation, !Task.isCancelled {
        errorMessage = error.localizedDescription
      }
      return false
    }
  }

  func refresh(requireCompleteSnapshot: Bool = false) async throws {
    #if DEBUG
      if Self.uiTestMode == "library" || Self.uiTestMode == "library-admin" { return }
    #endif
    guard let profile else { return }
    let generation = connectionGeneration
    isWorking = true
    defer { isWorking = false }
    let homeRequest = homeRefresher.beginRequest()
    let client = APIClient(profile: profile)
    let info = try await client.serverInfo()
    guard info.serverId == profile.serverId else {
      throw APIClientError.serverIdentityMismatch
    }
    guard isCurrent(generation)
    else { return }
    if profile.user == nil {
      let user = try await client.currentUser()
      guard isCurrent(generation)
      else { return }
      let updated = StoredServerProfile(
        serverId: profile.serverId,
        name: info.name,
        baseURL: profile.baseURL,
        publicKeyFingerprint: profile.publicKeyFingerprint,
        token: profile.token,
        sessionId: profile.sessionId,
        expiresAt: profile.expiresAt,
        user: user,
        locallyManaged: profile.locallyManaged)
      try store.save(updated)
      self.profile = updated
    }
    async let loadedMovies = client.movies()
    async let loadedSeries = client.series()
    async let loadedCatalog = client.catalogItems()
    async let loadedHome = homeRefresher.load(request: homeRequest, profile: profile)
    async let loadedCollections = client.collections()
    let (newMovies, newSeries, newCatalog, newHome, newCollections) = try await (
      loadedMovies, loadedSeries, loadedCatalog, loadedHome, loadedCollections
    )
    guard isCurrent(generation)
    else { return }
    guard let newHome, homeRefresher.isCurrent(homeRequest) else {
      if requireCompleteSnapshot { throw APIClientError.invalidResponse }
      return
    }
    movies = newMovies
    series = newSeries
    catalogItems = newCatalog
    collections = newCollections
    home = newHome
    scheduleHomeRefresh()
    if !Self.isTestProcess, !NativePreflightIsolation.isRequested, let current = self.profile {
      PlaybackProgressOutbox.shared.activate(profile: current)
      PlaybackProgressOutbox.shared.retryAfterReconnect()
    }
  }

  func refreshHome() async {
    #if DEBUG
      if Self.uiTestMode == "library" || Self.uiTestMode == "library-admin" {
        home = CinemaUITestFixture.home(Self.previewHome)
        scheduleHomeRefresh()
        return
      }
      if Self.uiTestMode != nil { return }
    #endif
    // The library view can appear as soon as its saved profile is loaded.
    // Its task/activation must not supersede the initial coherent snapshot.
    guard !isStarting, !isRecoveringLocalHost else { return }
    guard let profile else { return }
    let generation = connectionGeneration
    let request = homeRefresher.beginRequest()
    do {
      guard let refreshed = try await homeRefresher.load(request: request, profile: profile),
        isCurrent(generation)
      else { return }
      home = refreshed
      scheduleHomeRefresh()
    } catch {
      if isCurrent(generation) { errorMessage = error.localizedDescription }
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
    return try await currentConnection {
      try await APIClient(profile: profile).searchCatalog(trimmed)
    }
  }

  func searchMoviesForImportReview(
    _ query: String,
    libraryId: UUID
  ) async throws -> [CatalogItemSummary] {
    guard let profile else { throw APIClientError.invalidResponse }
    return try await currentConnection {
      try await APIClient(profile: profile).searchMoviesForImportReview(query, libraryId: libraryId)
    }
  }

  func resolveImportReview(
    _ review: LibraryImportReviewSummary,
    action: LibraryImportReviewAction,
    movieId: UUID? = nil
  ) async {
    guard let profile, canManageMedia else { return }
    let generation = connectionGeneration
    do {
      let scan = try await APIClient(profile: profile).updateLibraryImportReview(
        libraryId: review.libraryId,
        reviewId: review.id,
        action: action,
        movieId: movieId)
      guard isCurrent(generation) else { return }
      activeScans.append(scan)
      libraryImportReviews.removeAll { $0.id == review.id }
      startScanPolling()
    } catch {
      if isCurrent(generation) { errorMessage = error.localizedDescription }
    }
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
    return try await currentConnection {
      try await APIClient(profile: profile).catalogDetail(id: id)
    }
  }

  func setFavorite(mediaId: UUID, isFavorite: Bool) async -> Bool {
    guard let profile else { return false }
    let generation = connectionGeneration
    do {
      _ = try await APIClient(profile: profile).setFavorite(
        mediaId: mediaId, isFavorite: isFavorite)
      guard isCurrent(generation) else { return false }
      try await refresh()
      return isCurrent(generation)
    } catch {
      if isCurrent(generation) { errorMessage = error.localizedDescription }
      return false
    }
  }

  func saveMetadata(id: UUID, request: UpdateMediaMetadataRequest) async throws
    -> MediaMetadataSummary
  {
    guard let profile else { throw APIClientError.invalidResponse }
    let generation = connectionGeneration
    let result = try await APIClient(profile: profile).updateMediaMetadata(id: id, request: request)
    guard isCurrent(generation) else { throw CancellationError() }
    try await refresh()
    guard isCurrent(generation) else { throw CancellationError() }
    return result
  }

  func removeMedia(id: UUID) async throws {
    guard let profile else { throw APIClientError.invalidResponse }
    let generation = connectionGeneration
    let result = try await APIClient(profile: profile).removeMedia(id: id)
    guard isCurrent(generation) else { throw CancellationError() }
    try await refresh()
    guard isCurrent(generation) else { throw CancellationError() }
    guard result.state == "completed" else {
      throw APIClientError.serverRejected(
        code: "cleanup_pending",
        message: result.error
          ?? "The title was removed. Artwork cleanup is pending and will be retried automatically.")
    }
  }

  func reloadDevices() async {
    #if DEBUG
      if Self.uiTestMode == "local-host-recovery" { return }
    #endif
    guard let profile else { return }
    let generation = connectionGeneration
    do {
      let updated = try await APIClient(profile: profile).sessions()
      guard isCurrent(generation) else { return }
      sessions = updated
    } catch {
      if isCurrent(generation) { errorMessage = error.localizedDescription }
    }
  }

  func metadataCandidates(mediaId: UUID, query: String) async throws
    -> [MetadataCandidateSummary]
  {
    guard let profile else { throw APIClientError.invalidResponse }
    return try await currentConnection {
      try await APIClient(profile: profile).metadataCandidates(mediaId: mediaId, query: query)
    }
  }

  func selectMetadataMatch(
    mediaId: UUID,
    providerMediaId: String,
    mediaType: String
  ) async throws -> MediaMetadataSummary {
    guard let profile else { throw APIClientError.invalidResponse }
    let generation = connectionGeneration
    let result = try await currentConnection {
      try await APIClient(profile: profile).selectMetadataMatch(
        mediaId: mediaId, providerMediaId: providerMediaId, mediaType: mediaType)
    }
    try await refresh()
    guard isCurrent(generation) else { throw CancellationError() }
    return result
  }

  func clearMetadataMatch(mediaId: UUID) async throws -> MediaMetadataSummary {
    guard let profile else { throw APIClientError.invalidResponse }
    let generation = connectionGeneration
    let result = try await currentConnection {
      try await APIClient(profile: profile).clearMetadataMatch(mediaId: mediaId)
    }
    try await refresh()
    guard isCurrent(generation) else { throw CancellationError() }
    return result
  }

  func metadataReviews() async throws -> [MetadataReviewSummary] {
    guard let profile else { throw APIClientError.invalidResponse }
    return try await currentConnection { try await APIClient(profile: profile).metadataReviews() }
  }

  func saveCollection(id: UUID?, name: String, mediaIds: [UUID]) async throws {
    guard let profile else { throw APIClientError.invalidResponse }
    let generation = connectionGeneration
    let client = APIClient(profile: profile)
    if let id {
      _ = try await client.updateCollection(id: id, name: name, mediaIds: mediaIds)
    } else {
      _ = try await client.createCollection(name: name, mediaIds: mediaIds)
    }
    guard isCurrent(generation) else { throw CancellationError() }
    try await refresh()
  }

  func deleteCollection(id: UUID) async throws {
    guard let profile else { throw APIClientError.invalidResponse }
    let generation = connectionGeneration
    try await APIClient(profile: profile).deleteCollection(id: id)
    guard isCurrent(generation) else { throw CancellationError() }
    try await refresh()
  }

  func refreshFromUI() async {
    let generation = connectionGeneration
    guard !isRecoveringLocalHost else { return }
    if operatingMode == .host,
      hostSnapshot.state == .failed || hostSnapshot.state == .stopped
    {
      errorMessage = nil
      hostHealth = HostHealthPolicy()
      _ = await startNativeHost()
      return
    }
    errorMessage = nil
    do {
      try await refresh()
    } catch {
      if isCurrent(generation) { errorMessage = error.localizedDescription }
    }
  }

  func setApplicationActive(_ active: Bool) async {
    #if DEBUG
      // Synthetic UI fixtures have no live host or transport to observe.
      // Keep real lifecycle observation enabled for unit and preflight tests.
      if Self.uiTestMode != nil { return }
    #endif
    let canObserve = !isStarting && !isRecoveringLocalHost
    if active, canObserve, operatingMode == .host, hostPollTask == nil { startHostPolling() }
    if active, canObserve, !activeScans.isEmpty, scanPollTask == nil { startScanPolling() }
    let generation = connectionGeneration
    await syncController.setForeground(
      active, profile: canObserve ? profile : nil, runID: generation,
      onFailure: { [weak self] error in
        guard let self, self.isCurrent(generation) else { return }
        self.errorMessage = error.localizedDescription
      },
      onChanges: { [weak self] changes in
        guard let self, self.isCurrent(generation) else { throw CancellationError() }
        try await self.handleSyncChanges(changes)
      }
    )
  }

  func systemWillSleep() async {
    hostPollTask?.cancel()
    hostPollTask = nil
    scanPollTask?.cancel()
    scanPollTask = nil
    scanPollingRun = UUID()
    await syncController.stop(runID: connectionGeneration)
  }

  func systemDidWake() async {
    #if DEBUG
      if Self.uiTestMode != nil { return }
    #endif
    // Waking does not prove a server failure. Resume observation first and
    // require the normal confirmation policy before attempting recovery.
    if operatingMode == .host { startHostPolling() }
    if !activeScans.isEmpty { startScanPolling() }
    await setApplicationActive(NSApplication.shared.isActive)
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
    return try await currentConnection { try await APIClient(profile: profile).movie(id: id) }
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
    return try await currentConnection { try await APIClient(profile: profile).series(id: id) }
  }

  func startPlayback(
    mediaId: UUID,
    title: String,
    subtitle: String? = nil,
    queue: [PlaybackQueueItem] = []
  ) {
    guard profile != nil else { return }
    playback = PlaybackPresentation(
      mediaId: mediaId,
      title: title,
      subtitle: subtitle,
      queue: queue)
  }

  func startPlayback(item: CatalogItemSummary) {
    guard profile != nil, let presentation = CatalogPlaybackLogic.presentation(for: item) else {
      return
    }
    playback = presentation
  }

  // The player awaits its final progress write before calling this method.
  func closePlayback() async {
    playback = nil
    await refreshHome()
  }

  func disconnect() async {
    do {
      try store.delete()
    } catch {
      errorMessage = "The connection could not be removed securely. \(error.localizedDescription)"
      return
    }
    let current = profile
    let retiredGeneration = connectionGeneration
    inspectionGeneration = UUID()
    profile = nil
    homeRefresher.invalidate()
    movies = []
    series = []
    catalogItems = []
    home = nil
    collections = []
    libraries = []
    activeScans = []
    scanStatusUnavailable = []
    recentScans = []
    libraryDiscoveries = []
    libraryImportReviews = []
    sessions = []
    pairingCode = nil
    metadataProvider = nil
    metadataJob = nil
    importPreviewLibrary = nil
    needsInitialLibrarySetup = false
    homeRefreshTask?.cancel()
    homeRefreshTask = nil
    artworkLoader.removeAll()
    inspectedServer = nil
    playback = nil
    errorMessage = nil
    await syncController.stop(runID: retiredGeneration)
    if !Self.isTestProcess {
      if let current {
        try? await APIClient(profile: current).logout()
      }
    }
  }

  @discardableResult
  private func startNativeHost() async -> Bool {
    guard !isRecoveringLocalHost else { return false }
    isRecoveringLocalHost = true
    defer { isRecoveringLocalHost = false }
    await syncController.stop()
    errorMessage = nil
    hostSnapshot = NativeHostSnapshot(
      state: .starting,
      message: nil,
      bootstrapToken: nil,
      serverInfo: nil)
    do {
      hostSnapshot = try await serverHost.start(
        serverName: "Aurelia on \(Host.current().localizedName ?? "This Mac")")
      beginTerminationProtection()
      // A live helper may still be starting Kestrel. Do not treat its first
      // rendezvous response as proof that the saved account can load its library.
      for _ in 0..<120 {
        guard OperatingModePolicy.isAwaitingReadiness(hostSnapshot.state) else { break }
        try await Task.sleep(for: .milliseconds(250))
        hostSnapshot = try await serverHost.status()
      }
      if OperatingModePolicy.isAwaitingReadiness(hostSnapshot.state) {
        throw NativeServerHostError.rendezvousTimedOut
      }
      guard hostSnapshot.state == .running || hostSnapshot.state == .setupRequired else {
        throw NativeHostStartupError.failed(
          hostSnapshot.message ?? "The local server stopped during startup.")
      }
      if let profile {
        try OperatingModePolicy.validateLocalHost(hostSnapshot, profile: profile)
        // Readiness includes loading the catalog, not merely a live helper.
        // A superseded/partial snapshot must never be reported as successful.
        try await refresh(requireCompleteSnapshot: true)
        guard let current = self.profile, current.serverId == profile.serverId,
          current.sessionId == profile.sessionId
        else { return false }
        let managed = current.retainingLocalHosting()
        try store.save(managed)
        self.profile = managed
        startSync()
      }
      startHostPolling()
      writeIsolatedHostResult(ready: true)
      Self.hostLogger.info("Local host ready; saved connection retained.")
      return true
    } catch is CancellationError {
      // Sleep/shutdown can cancel a recovery while the helper is still alive;
      // cancellation is not evidence that the server or saved account failed.
      return false
    } catch {
      guard !Task.isCancelled else { return false }
      hostSnapshot = NativeHostSnapshot(
        state: .failed,
        message: error.localizedDescription,
        bootstrapToken: nil,
        serverInfo: nil)
      errorMessage =
        "Local server could not start: \(error.localizedDescription) Your saved account and library have not been reset."
      Self.hostLogger.error("Local host startup failed; connection retained.")
      writeIsolatedHostResult(ready: false)
      return false
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
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        guard let self, !Task.isCancelled else { return }
        var confirmedExit = false
        do {
          let snapshot = try await self.serverHost.status()
          guard !Task.isCancelled else { return }
          if snapshot.state == .failed || snapshot.state == .stopped {
            confirmedExit = true
            throw NativeHostStartupError.failed(snapshot.message ?? "The local server stopped.")
          }
          self.hostSnapshot = snapshot
          self.hostHealth.healthy(at: ProcessInfo.processInfo.systemUptime)
        } catch {
          guard !Task.isCancelled else { return }
          let action = self.hostHealth.failed(
            at: ProcessInfo.processInfo.systemUptime, confirmedExit: confirmedExit)
          switch action {
          case .wait(let delay):
            // A transient control-channel timeout must not restart a live host.
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
          case .recover:
            guard self.operatingMode == .host,
              self.profile == nil || self.profile?.locallyManaged == true
            else {
              self.errorMessage =
                "The local host could not be reached. Choose Try Again to reconnect."
              self.hostPollTask = nil
              return
            }
            Self.hostLogger.notice("Local host unavailable; attempting bounded recovery.")
            do { try await Task.sleep(for: .seconds(self.hostHealth.recoveryDelay)) } catch {
              return
            }
            if await self.startNativeHost() { return }
          case .stop:
            self.hostSnapshot = NativeHostSnapshot(
              state: .failed, message: error.localizedDescription,
              bootstrapToken: nil, serverInfo: nil)
            self.errorMessage =
              "Local server stopped: \(error.localizedDescription) Choose Try Again to restart it. Your saved account is unchanged."
            self.writeIsolatedHostResult(ready: false)
            self.hostPollTask = nil
            return
          }
        }
      }
    }
  }

  private func persistOperatingMode(explicit: Bool) {
    guard !Self.isTestProcess else { return }
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
    restart: Bool = true,
    expectedGeneration: UUID? = nil
  ) async throws {
    let generation = expectedGeneration ?? connectionGeneration
    if restart { try await serverHost.restart() }
    var inspected: InspectedServer?
    for _ in 0..<100 {
      inspected = try? await APIClient.inspect(
        baseURL: URL(string: "https://127.0.0.1:\(lanPort)")!)
      if inspected != nil { break }
      try await Task.sleep(for: .milliseconds(200))
    }
    guard let inspected else { throw NativeServerHostError.rendezvousTimedOut }
    guard connectionGeneration == generation, !Task.isCancelled else { throw CancellationError() }
    let connected = APIClient.profile(authentication: authentication, inspected: inspected)
    var snapshot = try await serverHost.status()
    for _ in 0..<120 {
      guard OperatingModePolicy.isAwaitingReadiness(snapshot.state) else { break }
      try await Task.sleep(for: .milliseconds(250))
      snapshot = try await serverHost.status()
    }
    try OperatingModePolicy.validateLocalHost(snapshot, profile: connected)
    guard connectionGeneration == generation, !Task.isCancelled else { throw CancellationError() }
    let localProfile = connected.retainingLocalHosting()
    try store.save(localProfile)
    profile = localProfile
    let authenticatedGeneration = connectionGeneration
    try await refresh()
    guard isCurrent(authenticatedGeneration) else { throw CancellationError() }
    await reloadAdministration()
    startSync()
  }

  private func startScanPolling() {
    guard !activeScans.isEmpty else { return }
    scanPollTask?.cancel()
    let run = UUID()
    scanPollingRun = run
    let generation = connectionGeneration
    scanPollTask = Task { [weak self] in
      guard let self, let profile = self.profile else { return }
      while self.isCurrent(generation) && !self.activeScans.isEmpty {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        let polledScans = self.activeScans
        let batch: ScanPollingBatch
        do {
          batch = try await ScanPollingBatch.load(scans: polledScans) {
            try await APIClient(profile: profile).scan(id: $0)
          }
        } catch { return }
        guard self.isCurrent(generation), self.scanPollingRun == run else { return }
        let reconciled = batch.reconciled(
          polledIDs: Set(polledScans.map(\.id)), current: self.activeScans)
        self.activeScans = Self.uniqueScans(reconciled.active)
        self.scanStatusUnavailable = reconciled.unavailable
        if let failure = batch.definitiveFailure {
          self.errorMessage = failure.localizedDescription
          self.scanPollTask = nil
          return
        }
        if !reconciled.completed.isEmpty {
          self.recentScans = Self.uniqueScans(reconciled.completed + self.recentScans)
            .sorted { $0.createdAt > $1.createdAt }
          try? await self.refresh()
          await self.reloadAdministrationAfterScan()
        }
        if !reconciled.unavailable.isEmpty {
          do { try await Task.sleep(for: .seconds(4)) } catch { return }
        }
      }
      if self.isCurrent(generation), self.scanPollingRun == run { self.scanPollTask = nil }
    }
  }

  private func startSync() {
    guard let profile else { return }
    let generation = connectionGeneration
    syncStartTask?.cancel()
    syncStartTask = Task { [weak self, profile] in
      guard let self, self.isCurrent(generation) else { return }
      await self.syncController.start(
        profile: profile, runID: generation,
        onFailure: { [weak self] error in
          guard let self, self.isCurrent(generation) else { return }
          self.errorMessage = error.localizedDescription
        }
      ) { [weak self] changes in
        guard let self, self.isCurrent(generation) else { throw CancellationError() }
        try await self.handleSyncChanges(changes)
      }
    }
  }

  private func handleSyncChanges(_ changes: SyncChangesResponse) async throws {
    let generation = connectionGeneration
    guard let profile, isCurrent(generation) else { throw CancellationError() }
    let plan = SyncRefreshPlan(changes)
    do {
      if plan.fullCatalog {
        try await refresh(requireCompleteSnapshot: true)
      } else if plan.home {
        let client = APIClient(profile: profile)
        let request = homeRefresher.beginRequest()
        // Stage all responses before publishing or acknowledging. A missing
        // title can indicate a concurrent removal/grant change: retry with an
        // authorized full snapshot, never retain hidden cached content.
        let refreshedHome = try await homeRefresher.load(request: request, profile: profile)
        var replacements: [UUID: CatalogItemSummary] = [:]
        for id in plan.mediaIDs {
          do { replacements[id] = try await client.catalogSummary(id: id) } catch let error
            as APIClientError where error.httpStatus == 404
          {
            try await refresh(requireCompleteSnapshot: true)
            guard isCurrent(generation) else { throw CancellationError() }
            return
          }
        }
        let refreshedCollections = plan.collections ? try await client.collections() : nil
        guard isCurrent(generation) else { throw CancellationError() }
        guard let refreshedHome, homeRefresher.isCurrent(request) else {
          throw APIClientError.invalidResponse
        }
        catalogItems = catalogItems.map { replacements[$0.id] ?? $0 }
        movies = movies.map { movie in
          guard let item = replacements[movie.id] else { return movie }
          return MovieSummary(
            id: movie.id, title: item.title, year: item.year, availability: item.availability)
        }
        series = series.map { show in
          guard let item = replacements[show.id] else { return show }
          return SeriesSummary(
            id: show.id, title: item.title, availability: item.availability,
            seasonCount: show.seasonCount, episodeCount: show.episodeCount)
        }
        collections = (refreshedCollections ?? collections).map { collection in
          CollectionSummary(
            id: collection.id, name: collection.name, poster: collection.poster,
            items: collection.items.map { replacements[$0.id] ?? $0 })
        }
        home = refreshedHome
        scheduleHomeRefresh()
      }
      guard isCurrent(generation) else { throw CancellationError() }
      if !Self.isTestProcess, !NativePreflightIsolation.isRequested {
        PlaybackProgressOutbox.shared.activate(profile: profile)
      }
      if changes.resetRequired || changes.changedAreas.contains(.libraries), canManageMedia {
        try await refreshLibraryAdministration()
        guard isCurrent(generation) else { throw CancellationError() }
      }
    } catch {
      if isCurrent(generation), !(error is CancellationError) {
        errorMessage = error.localizedDescription
      }
      throw error
    }
  }

  private func reloadAdministrationAfterScan() async {
    try? await refreshLibraryAdministration()
  }

  private func refreshLibraryAdministration() async throws {
    guard let profile else { throw CancellationError() }
    let generation = connectionGeneration
    let client = APIClient(profile: profile)
    let refreshedLibraries = try await client.libraries()
    async let discoveries = loadDiscoveries(client: client, libraries: refreshedLibraries)
    async let reviews = loadImportReviews(client: client, libraries: refreshedLibraries)
    let snapshot = try await (discoveries, reviews)
    guard isCurrent(generation) else { throw CancellationError() }
    libraries = refreshedLibraries
    libraryDiscoveries = snapshot.0
    libraryImportReviews = snapshot.1
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

  private func loadImportReviews(
    client: APIClient,
    libraries: [LibrarySummary]
  ) async throws -> [LibraryImportReviewSummary] {
    var reviews: [LibraryImportReviewSummary] = []
    for library in libraries {
      reviews.append(contentsOf: try await client.libraryImportReviews(id: library.id))
    }
    return reviews.sorted {
      $0.detectedTitle.localizedCaseInsensitiveCompare($1.detectedTitle) == .orderedAscending
    }
  }

  #if DEBUG
    static func serverSettingsRenderPreview() -> AppModel {
      let model = AppModel(store: InMemoryServerProfileStore())
      model.hasStarted = true
      model.operatingMode = .client
      let original = previewOwnerProfile
      model.profile = StoredServerProfile(
        serverId: original.serverId, name: original.name,
        baseURL: URL(string: "https://server-settings-preview.invalid")!,
        publicKeyFingerprint: original.publicKeyFingerprint, token: original.token,
        sessionId: original.sessionId, expiresAt: original.expiresAt, user: original.user)
      model.isStarting = false
      return model
    }

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
      if CinemaUITestFixture.enabled { return CinemaUITestFixture.detail(item) }
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
    if NativePreflightIsolation.isActive,
      ProcessInfo.processInfo.environment["AURELIA_PREFLIGHT_CONNECTION_TEST"] == "1"
    {
      return InMemoryServerProfileStore(profile: isolatedHostProfile)
    }
    if isTestProcess || NativePreflightIsolation.isRequested { return InMemoryServerProfileStore() }
    return KeychainServerStore()
  }

  private static var isolatedHostProfile: StoredServerProfile? {
    guard NativePreflightIsolation.isActive,
      let value = ProcessInfo.processInfo.environment["AURELIA_PREFLIGHT_PROFILE"],
      value.utf8.count <= 16_384
    else { return nil }
    return try? JSONDecoder().decode(StoredServerProfile.self, from: Data(value.utf8))
  }

  private func writeIsolatedHostResult(ready: Bool) {
    guard NativePreflightIsolation.isActive,
      ProcessInfo.processInfo.environment["AURELIA_PREFLIGHT_CONNECTION_TEST"] == "1"
    else { return }
    struct Result: Encodable {
      let ready: Bool
      let owned: Bool
      let catalogCount: Int
      let unchangedConnection: Bool
      let failureMessage: String?
    }
    let unchanged =
      profile?.retainingLocalHosting() == Self.isolatedHostProfile?.retainingLocalHosting()
    if var data = try? JSONEncoder().encode(
      Result(
        ready: ready, owned: profile?.locallyManaged == true,
        catalogCount: catalogItems.count, unchangedConnection: unchanged,
        failureMessage: ready
          ? nil
          : hostSnapshot.message.map {
            String($0.prefix(512)).replacingOccurrences(
              of: profile?.token ?? "no-session-token", with: "[redacted]")
          }))
    {
      data.append(0x0A)
      // Launch Services provides this test-only output handle. No sandbox escape
      // or direct access to the user's profile storage is required.
      try? FileHandle.standardOutput.write(contentsOf: data)
      if let result = String(data: data, encoding: .utf8) {
        Self.hostLogger.notice("IsolatedHostResult \(result, privacy: .public)")
      }
    }
  }

  private static var isTestProcess: Bool {
    if NativePreflightIsolation.isRequested { return true }
    #if DEBUG
      return uiTestMode != nil
        || ProcessInfo.processInfo.environment["AURELIA_RUNNING_TESTS"] == "1"
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    #else
      return false
    #endif
  }
}
