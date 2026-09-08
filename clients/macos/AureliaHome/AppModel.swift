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
  @Published private(set) var playback: PlaybackPresentation?
  @Published private(set) var hostSnapshot: NativeHostSnapshot = .stopped
  @Published private(set) var libraries: [LibrarySummary] = []
  @Published private(set) var activeScans: [LibraryScanSummary] = []
  @Published private(set) var pairingCode: PairingCodeResponse?
  @Published private(set) var sessions: [DeviceSessionSummary] = []
  @Published private(set) var needsInitialLibrarySetup = false
  @Published private(set) var isStarting = true
  @Published private(set) var isWorking = false
  @Published var errorMessage: String?

  private let store: any ServerProfileStore
  private let serverHost: NativeServerHost
  private var hasStarted = false
  private var hostPollTask: Task<Void, Never>?
  private var isTerminationProtectionActive = false
  private static let operatingModeKey = "AureliaHomeOperatingMode"

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
      if Self.uiTestMode == "library" {
        operatingMode = .client
        profile = Self.previewProfile
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
      if Self.uiTestMode == "library-setup" {
        operatingMode = .host
        profile = Self.previewOwnerProfile
        hostSnapshot = Self.previewHostSnapshot
        needsInitialLibrarySetup = true
        isStarting = false
        return
      }
    #endif

    do {
      profile = try store.load()
      if profile != nil, operatingMode == nil {
        operatingMode = .client
        UserDefaults.standard.set(OperatingMode.client.rawValue, forKey: Self.operatingModeKey)
      }
      if operatingMode == .host {
        await startNativeHost()
      } else if profile != nil {
        try await refresh()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    isStarting = false
  }

  func selectClientMode() {
    operatingMode = .client
    UserDefaults.standard.set(OperatingMode.client.rawValue, forKey: Self.operatingModeKey)
    errorMessage = nil
  }

  func selectHostMode() async {
    operatingMode = .host
    UserDefaults.standard.set(OperatingMode.host.rawValue, forKey: Self.operatingModeKey)
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
    UserDefaults.standard.set(OperatingMode.client.rawValue, forKey: Self.operatingModeKey)
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
    do { try await serverHost.restart() }
    catch { errorMessage = error.localizedDescription }
  }

  func completeInitialLibrarySetup() {
    needsInitialLibrarySetup = false
  }

  func createLibraries(_ drafts: [LibraryDraft]) async -> Bool {
    guard let profile else { return false }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let client = APIClient(profile: profile)
      for draft in drafts {
        _ = try await client.createLibrary(name: draft.name, path: draft.path, kind: draft.kind)
      }
      activeScans = drafts.isEmpty ? [] : try await client.startAllLibraryScans()
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
    } catch { errorMessage = error.localizedDescription }
  }

  func addLibrary(name: String, path: String, kind: LibraryKind) async -> Bool {
    guard let profile else { return false }
    do {
      let client = APIClient(profile: profile)
      let created = try await client.createLibrary(name: name, path: path, kind: kind)
      libraries.append(created)
      libraries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
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

  func generatePairingCode() async {
    guard let profile else { return }
    do { pairingCode = try await APIClient(profile: profile).createPairingCode() }
    catch { errorMessage = error.localizedDescription }
  }

  func revokeSession(id: UUID) async {
    guard let profile else { return }
    do {
      try await APIClient(profile: profile).revokeSession(id: id)
      sessions = try await APIClient(profile: profile).sessions()
    } catch { errorMessage = error.localizedDescription }
  }

  func shutdown() async {
    await PlaybackShutdownCoordinator.shared.shutdown()
    hostPollTask?.cancel()
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
    movies = try await loadedMovies
    series = try await loadedSeries
  }

  func refreshFromUI() async {
    errorMessage = nil
    do {
      try await refresh()
    } catch {
      errorMessage = error.localizedDescription
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
    movies = []
    series = []
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
        serverName: "Aurelia Home on \(Host.current().localizedName ?? "This Mac")")
      beginTerminationProtection()
      startHostPolling()
      if profile != nil, hostSnapshot.state == .running {
        try await refresh()
      }
    } catch {
      hostSnapshot = NativeHostSnapshot(
        state: .failed,
        message: error.localizedDescription,
        bootstrapToken: nil,
        serverInfo: nil)
    }
  }

  private func startHostPolling() {
    hostPollTask?.cancel()
    hostPollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(750))
        guard let self else { return }
        if let snapshot = try? await self.serverHost.status() {
          self.hostSnapshot = snapshot
        }
      }
    }
  }

  private func beginTerminationProtection() {
    guard !isTerminationProtectionActive else { return }
    ProcessInfo.processInfo.disableAutomaticTermination("Aurelia Home is hosting its server")
    ProcessInfo.processInfo.disableSuddenTermination()
    isTerminationProtectionActive = true
  }

  private func endTerminationProtection() {
    guard isTerminationProtectionActive else { return }
    ProcessInfo.processInfo.enableAutomaticTermination("Aurelia Home stopped hosting its server")
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
  }

  private func startScanPolling() {
    Task { [weak self] in
      guard let self, let profile = self.profile else { return }
      while !self.activeScans.isEmpty {
        try? await Task.sleep(for: .seconds(1))
        var updated: [LibraryScanSummary] = []
        for scan in self.activeScans {
          if let latest = try? await APIClient(profile: profile).scan(id: scan.id),
            latest.state == .queued || latest.state == .running
          {
            updated.append(latest)
          }
        }
        self.activeScans = updated
      }
      try? await self.refresh()
      await self.reloadAdministration()
    }
  }

  #if DEBUG
    private static let previewProfile = StoredServerProfile(
      serverId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
      name: "Aurelia Home",
      baseURL: URL(string: "https://aurelia-home.local:43111")!,
      publicKeyFingerprint: String(repeating: "A", count: 64),
      token: "ui-test-token",
      sessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
      expiresAt: "2099-01-01T00:00:00Z")

    private static let previewOwnerProfile = StoredServerProfile(
      serverId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
      name: "Aurelia Home on Test Mac",
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
        name: "Aurelia Home on Test Mac",
        version: "1.0.7",
        isSetup: true,
        lanAccessEnabled: true,
        lanHttpsPort: 43_111,
        publicKeyFingerprint: String(repeating: "A", count: 64),
        displayFingerprint: "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA"))
  #endif

  private static var uiTestMode: String? {
    #if DEBUG
      ProcessInfo.processInfo.environment["AURELIA_HOME_UI_TEST_MODE"]
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
        || ProcessInfo.processInfo.environment["AURELIA_HOME_RUNNING_TESTS"] == "1"
    #else
      false
    #endif
  }
}
