import Combine
import Foundation
import UIKit

@MainActor
final class IOSAppModel: ObservableObject {
  enum Phase { case connection, trust, pairing, profiles, library }
  @Published private(set) var phase: Phase = .connection
  @Published private(set) var connection: IOSStoredConnection?
  @Published private(set) var session: IOSProfileSession?
  @Published private(set) var inspected: IOSInspectedServer?
  @Published private(set) var pairing: IOSPairingStart?
  @Published private(set) var profiles: [IOSWatchingProfile] = []
  @Published private(set) var isBusy = false
  @Published private(set) var error: String?
  /// The saved server did not answer at all, probably asleep: shown as a hint, not as an error.
  @Published private(set) var savedServerUnreachable = false
  @Published var selectedProfile: IOSWatchingProfile?
  /// Counts rejected PINs, so the entry clears and shakes even when the message repeats.
  @Published private(set) var pinRejections = 0
  @Published private(set) var detailRefresh = UUID()
  let browser = IOSBonjourBrowser()
  /// Genre shelves for Home, built from the preloaded Movies and TV Shows pages.
  @Published private(set) var homeGenres: [IOSHomeGenreRow] = []
  let movies = IOSLibraryListing(kind: .movie)
  let shows = IOSLibraryListing(kind: .series)
  let artwork = IOSArtworkPipeline()
  @Published var progressWarning: String?
  @Published private(set) var capabilities: IOSCapabilities?
  @Published private(set) var watchlistItems: [IOSCatalogItem] = []
  @Published private(set) var watchlistIds: Set<UUID> = []
  @Published private(set) var home: IOSHome?

  var supportsWatchlist: Bool { capabilities?.supportsWatchlistAndPeople ?? false }
  var supportsScrubPreviews: Bool { capabilities?.supportsScrubPreviews ?? false }
  @Published private(set) var homeLoading = false
  @Published private(set) var homeError: String?
  @Published private(set) var libraryRefresh = UUID()
  @Published private(set) var pendingProgress: [UUID: IOSProgressSnapshot] = [:]
  @Published private(set) var acknowledgedProgress: [UUID: IOSPlaybackProgress] = [:]
  @Published private var mutationSummaries: [UUID: IOSCatalogItem] = [:]
  @Published var remotePlaybackItem: IOSCatalogItem?
  /// The Watch Together party this device is in, if any.
  @Published private(set) var watchParty: IOSWatchTogetherSession?
  /// Parties others started on the server, offered on Home and title pages.
  @Published private(set) var watchParties: [IOSWatchPartySummary] = []
  private var syncTask: Task<Void, Never>?
  private var progressObserver: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var remoteDeviceHeartbeatTask: Task<Void, Never>?
  private var remoteDeviceCommandTask: Task<Void, Never>?
  private var deferredRefresh = false
  private var homeRequest = UUID()
  var playerPresented = false {
    didSet { if !playerPresented && deferredRefresh { scheduleLibraryRefresh() } }
  }

  var tvDeviceId: String {
    if let saved = UserDefaults.standard.string(forKey: "AureliaIOSDeviceId") {
      return saved
    }
    let newId = UUID().uuidString
    UserDefaults.standard.set(newId, forKey: "AureliaIOSDeviceId")
    return newId
  }
  private let credentials = IOSCredentialStore()
  let environment = IOSAppEnvironment.current()
  private var generation = UUID()
  private var task: Task<Void, Never>?
  private var expiry: Task<Void, Never>?
  private var started = false
  /// Waking the server is for someone who just opened Aurelia or pressed Try Again, not for a
  /// screen left on for hours.
  private var wakeAllowedUntil: Date?
  private var isForeground = true
  private var outboxTransition: Task<Void, Never>?

  var client: IOSAPIClient? {
    guard let connection, let session else { return nil }
    return makeClient(connection: connection, session: session)
  }

  var browsePreferences: IOSBrowsePreferenceStore { environment.browsePreferences }
  init() {}

  func start() async {
    guard !started else { return }
    started = true
    #if DEBUG
      if let scenario = IOSUITestScenario.current {
        connection = IOSUITestFixtures.connection
        capabilities = IOSCapabilities(
          formatVersion: 2, minimumClientVersion: "1.0",
          capabilities: [
            "device-authorization-v1", "library-state-v1", "watchlist-people-v1",
            "scrub-previews-v1",
          ])
        if scenario == .profiles {
          phase = .profiles
          await refreshProfiles()
        } else {
          let fixture =
            scenario == .showcase ? IOSShowcaseTransport.session : IOSUITestFixtures.session
          session = fixture
          phase = .library
          activateProgress(connection: IOSUITestFixtures.connection, session: fixture)
        }
        return
      }
    #endif
    allowWaking()
    do {
      connection = environment.allowsPersistentCredentials ? try credentials.load() : nil
      if connection != nil { await reconnect() } else { startDiscovery() }
    } catch {
      self.error = "The saved connection could not be read. Try connecting again."
      startDiscovery()
    }
  }

  func inspect(address: String) {
    guard !isBusy else { return }
    let url: URL
    do { url = try IOSServerAddress.normalize(address) } catch {
      self.error = error.localizedDescription
      return
    }
    let run = beginWork()
    task = Task {
      defer { finish(run) }
      do {
        let candidate = try await IOSAPIClient.inspect(
          baseURL: url, transport: environment.transport)
        let capabilities = try await makeClient(inspected: candidate).capabilities()
        try validate(capabilities)
        guard current(run) else { return }
        self.capabilities = capabilities
        guard candidate.info.isSetup else {
          throw IOSCoreError.server(
            status: 409, code: "setup_required",
            message: "Set up this server in Aurelia on your Mac first.", retryAfter: nil)
        }
        inspected = candidate
        phase = .trust
        browser.stop()
      } catch { show(error, run: run) }
    }
  }

  func reconnect(userInitiated: Bool = false) async {
    guard let saved = connection, !isBusy else { return }
    if userInitiated { allowWaking() }
    let run = beginWork()
    defer { finish(run) }
    if savedServerUnreachable { wakeIfAllowed(saved.serverID) }
    // A sleeping server does not answer at all, and every try waits for a timeout. After a few
    // seconds the "server is off" hint shows while the tries go on.
    let hint = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      guard let self, self.current(run), self.phase == .connection else { return }
      self.savedServerUnreachable = true
      self.wakeIfAllowed(saved.serverID)
    }
    defer { hint.cancel() }
    do {
      let candidate = try await inspectKnownServer(saved, run: run)
      guard current(run) else { return }
      var relocated = saved.relocating(to: candidate.baseURL)
      let caps = try await makeClient(connection: relocated).capabilities()
      try validate(caps)
      self.capabilities = caps
      if let pending = relocated.pendingAcknowledgement {
        let receipt = try await makeClient(connection: relocated).acknowledgePairing(
          id: pending.id, secret: pending.secret)
        guard receipt.acknowledged else { throw IOSCoreError.invalidResponse }
        relocated.pendingAcknowledgement = nil
      }
      guard current(run) else { return }
      try saveCredentials(relocated)
      connection = relocated
      savedServerUnreachable = false
      let discovered = browser.servers.filter { $0.serverID == saved.serverID }
        .flatMap { [$0.baseURL] + $0.alternativeURLs }
      IOSWakeOnLan.remember(
        serverID: saved.serverID, info: candidate.info,
        hosts: ([candidate.baseURL] + discovered).compactMap(\.host))
      try await loadProfiles(run: run)
    } catch {
      if current(run), IOSServerReachability.isUnreachable(error) {
        savedServerUnreachable = true
        self.error = nil
      } else {
        savedServerUnreachable = false
        show(error, run: run)
      }
      if current(run) {
        phase = .connection
        startDiscovery()
      }
    }
  }

  private func allowWaking() { wakeAllowedUntil = Date().addingTimeInterval(600) }

  private func wakeIfAllowed(_ serverID: UUID) {
    guard isForeground, let until = wakeAllowedUntil, until > Date() else { return }
    IOSWakeOnLan.wake(serverID: serverID)
  }

  /// Stops trying the saved server, so another one can be chosen at once.
  func stopReconnecting() {
    guard phase == .connection, connection != nil else { return }
    retireWork()
    savedServerUnreachable = false
    error = nil
    startDiscovery()
  }

  func beginPairing() {
    guard !isBusy, let inspected else { return }
    let previous = pairing
    pairing = nil
    let run = beginWork()
    phase = .pairing
    task = Task {
      defer { finish(run) }
      do {
        let api = makeClient(inspected: inspected)
        if let previous {
          _ = try? await api.cancelPairing(id: previous.id, secret: previous.secret)
          guard current(run) else { return }
        }
        let created = try await api.startPairing(deviceName: UIDevice.current.name)
        guard current(run) else {
          Task { _ = try? await api.cancelPairing(id: created.id, secret: created.secret) }
          return
        }
        pairing = created
        var delay = max(5, created.pollIntervalSeconds)
        while current(run) {
          try await Task.sleep(for: .seconds(delay))
          guard current(run) else { return }
          if let date = IOSServerDate.parse(created.expiresAt), date <= Date() {
            throw IOSCoreError.server(
              status: 410, code: "pairing_expired",
              message: "This code has expired. Start a new pairing.", retryAfter: nil)
          }
          do {
            let result = try await api.pairingStatus(id: created.id, secret: created.secret)
            guard current(run) else { return }
            delay = max(5, result.pollIntervalSeconds)
            switch result.state {
            case .pending: continue
            case .approved:
              guard let auth = result.authentication else { throw IOSCoreError.invalidResponse }
              var paired = try inspected.connection(authentication: auth)
              IOSWakeOnLan.remember(
                serverID: inspected.info.serverId, info: inspected.info,
                hosts: [inspected.baseURL.host].compactMap { $0 })
              paired.pendingAcknowledgement = IOSPendingPairingAcknowledgement(
                id: created.id, secret: created.secret, expiresAt: created.expiresAt)
              try saveCredentials(paired)
              connection = paired
              let receipt = try await api.acknowledgePairing(id: created.id, secret: created.secret)
              guard current(run) else {
                Task { try? await makeClient(connection: paired).disconnectDevice() }
                return
              }
              guard receipt.acknowledged else { throw IOSCoreError.invalidResponse }
              paired.pendingAcknowledgement = nil
              try saveCredentials(paired)
              guard current(run) else { return }
              connection = paired
              pairing = nil
              try await loadProfiles(run: run)
              return
            case .denied:
              throw IOSCoreError.server(
                status: 403, code: "pairing_denied",
                message: "This device was not approved on your Mac.", retryAfter: nil)
            case .expired, .cancelled, .unknown:
              throw IOSCoreError.server(
                status: 409, code: "pairing_expired",
                message: "This code is no longer available. Start a new pairing.", retryAfter: nil)
            }
          } catch let failure as IOSCoreError where failure.statusCode == 429 || failure.isTransient
          {
            delay = max(5, Int(ceil(failure.retryAfter ?? 5)))
            if let date = IOSServerDate.parse(created.expiresAt), date <= Date() { throw failure }
          } catch let failure as URLError where failure.code != .cancelled {
            delay = 5
          }
        }
      } catch { show(error, run: run) }
    }
  }

  func cancelPairing() {
    let pending = pairing
    let server = inspected
    let unclaimed: IOSStoredConnection?
    if let pending, let saved = connection, saved.pendingAcknowledgement?.id == pending.id {
      unclaimed = saved
    } else {
      unclaimed = nil
    }
    retireWork()
    if unclaimed != nil {
      do { try deleteCredentials() } catch { self.error = error.localizedDescription }
      connection = nil
    }
    pairing = nil
    inspected = nil
    phase = .connection
    startDiscovery()
    Task {
      // The receipt may have committed even when its response was lost. A
      // credential saved before acknowledgement lets cancellation revoke it.
      if let unclaimed { try? await makeClient(connection: unclaimed).disconnectDevice() }
      if let pending, let server {
        _ = try? await makeClient(inspected: server).cancelPairing(
          id: pending.id, secret: pending.secret)
      }
    }
  }

  func openProfile(_ profile: IOSWatchingProfile, pin: String? = nil) {
    guard !isBusy, !profile.needsPinSetup, let connection else { return }
    if profile.pinProtectionEnabled && pin == nil {
      selectedProfile = profile
      error = nil
      return
    }
    if let pin, !IOSProfilePIN.isValid(pin) {
      // Answered like any wrong PIN, so the length rule gives nothing away.
      error = IOSProfilePIN.incorrect
      pinRejections += 1
      return
    }
    let run = beginWork()
    task = Task { [self] in
      defer { finish(run) }
      do {
        let opened = try await makeClient(connection: connection).unlockProfile(
          id: profile.id, pin: pin)
        guard current(run) else { return }
        guard opened.user.id == profile.id, let end = IOSServerDate.parse(opened.expiresAt),
          end > Date()
        else { throw IOSCoreError.invalidResponse }
        session = opened
        selectedProfile = nil
        phase = .library
        browser.stop()
        activateProgress(connection: connection, session: opened)
        expiry?.cancel()
        expiry = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) } catch {
            return
          }
          guard !Task.isCancelled, let self, self.session?.sessionId == opened.sessionId else {
            return
          }
          self.expiry = nil
          await self.switchProfile()
        }
      } catch { show(error, run: run) }
    }
  }

  func cancelProfileSelection() {
    retireWork()
    selectedProfile = nil
    error = nil
  }

  func switchProfile() async {
    let old = client
    retireWork()
    clearPersonalState()
    phase = .profiles
    isBusy = true
    let run = generation
    defer { finish(run) }
    if let old { try? await old.endProfile() }
    do { try await loadProfiles(run: run) } catch { show(error, run: run) }
  }

  func refreshProfiles() async {
    guard !isBusy, connection != nil, session == nil, selectedProfile == nil else { return }
    let run = beginWork()
    defer { finish(run) }
    do { try await loadProfiles(run: run) } catch { show(error, run: run) }
  }

  func disconnect() async {
    let stored = connection
    retireWork()
    clearPersonalState()
    connection = nil
    inspected = nil
    pairing = nil
    phase = .connection
    do { try deleteCredentials() } catch { self.error = error.localizedDescription }
    startDiscovery()
    if let stored { try? await makeClient(connection: stored).disconnectDevice() }
  }

  func handleSessionFailure(_ failure: Error) {
    guard let core = failure as? IOSCoreError else { return }
    if core.code == "invalid_profile_pin" || core.code == "invalid_pin_format" { return }
    if core == .identityMismatch {
      retireWork()
      clearPersonalState()
      phase = .connection
      error = core.localizedDescription
      startDiscovery()
    } else if core.statusCode == 401
      || ["profile_session_expired", "profile_session_revoked", "device_session_revoked"].contains(
        core.code ?? "")
    {
      let deviceRejected = core.code == "device_session_revoked" || session == nil
      retireWork()
      clearPersonalState()
      if deviceRejected {
        phase = .connection
        startDiscovery()
        error = "Pair this device with your server again."
      } else {
        phase = .profiles
        let run = generation
        isBusy = true
        task = Task {
          defer { finish(run) }
          do { try await loadProfiles(run: run) } catch { show(error, run: run) }
        }
      }
    }
  }

  func enterBackground() {
    isForeground = false
    deactivateProgress()
    browser.stop()
  }

  func enterForeground() {
    isForeground = true
    allowWaking()
    scheduleLibraryRefresh()
    if phase == .connection { startDiscovery() }
    // The server may have been woken meanwhile, for example by opening Aurelia on a Mac.
    if phase == .connection, savedServerUnreachable { Task { await reconnect() } }
    if phase == .profiles, selectedProfile == nil { Task { await refreshProfiles() } }
    if let session, let date = IOSServerDate.parse(session.expiresAt), date <= Date() {
      Task { await switchProfile() }
    } else if let connection, let session {
      activateProgress(connection: connection, session: session)
    }
  }

  func updateSummary(_ item: IOSCatalogItem) {
    mutationSummaries[item.id] = nil
    movies.update(item)
    shows.update(item)
  }

  func applyMutationSummary(_ item: IOSCatalogItem) {
    updateSummary(item)
    mutationSummaries[item.id] = item
    if mutationSummaries.count > 256,
      let oldest = mutationSummaries.keys.first(where: { $0 != item.id })
    {
      mutationSummaries.removeValue(forKey: oldest)
    }
  }

  func makeClient(connection: IOSStoredConnection, session: IOSProfileSession? = nil)
    -> IOSAPIClient
  {
    IOSAPIClient(connection: connection, session: session, transport: environment.transport)
  }

  private func makeClient(inspected: IOSInspectedServer) -> IOSAPIClient {
    IOSAPIClient(inspected: inspected, transport: environment.transport)
  }

  private func saveCredentials(_ connection: IOSStoredConnection) throws {
    if environment.allowsPersistentCredentials { try credentials.save(connection) }
  }

  private func deleteCredentials() throws {
    if environment.allowsPersistentCredentials { try credentials.delete() }
  }

  private func startDiscovery() {
    if environment.allowsDiscovery { browser.start() }
  }

  private func inspectKnownServer(_ saved: IOSStoredConnection, run: UUID) async throws
    -> IOSInspectedServer
  {
    var lastFailure: Error = URLError(.cannotConnectToHost)
    for delay in [0, 3, 6, 12] {
      guard current(run) else { throw CancellationError() }
      if delay > 0 {
        startDiscovery()
        try await Task.sleep(for: .seconds(delay))
      }
      guard current(run) else { throw CancellationError() }
      let discovered = browser.servers.filter { $0.serverID == saved.serverID }
        .flatMap { [$0.baseURL] + $0.alternativeURLs }
      var tried: Set<URL> = []
      for address in [saved.baseURL] + discovered where tried.insert(address).inserted {
        do {
          let candidate = try await IOSAPIClient.inspect(
            baseURL: address, transport: environment.transport)
          guard current(run) else { throw CancellationError() }
          try candidate.validate(against: saved)
          return candidate
        } catch {
          guard current(run) else { throw CancellationError() }
          guard (error as? IOSCoreError)?.isTransient == true || error is URLError else {
            throw error
          }
          lastFailure = error
        }
      }
    }
    throw lastFailure
  }

  private func loadProfiles(run: UUID) async throws {
    guard current(run), let connection else { return }
    phase = .profiles
    let result = try await makeClient(connection: connection).profiles()
    guard current(run) else { return }
    guard result.formatVersion == 1 || result.formatVersion == 2 else {
      throw IOSCoreError.unsupportedServer
    }
    if result.managementSetupRequired {
      throw IOSCoreError.server(
        status: 409, code: "setup_required",
        message: "Finish profile setup in Aurelia on your Mac first.", retryAfter: nil)
    }
    profiles = result.profiles
    error = nil
    phase = .profiles
    browser.stop()
  }

  private func validate(_ capabilities: IOSCapabilities) throws {
    guard [1, 2].contains(capabilities.formatVersion),
      Set(["device-authorization-v1", "library-state-v1"]).isSubset(
        of: Set(capabilities.capabilities ?? []))
    else { throw IOSCoreError.unsupportedServer }
  }

  private func beginWork() -> UUID {
    retireWork()
    isBusy = true
    error = nil
    return generation
  }
  private func finish(_ run: UUID) {
    if generation == run {
      isBusy = false
      task = nil
    }
  }
  private func current(_ run: UUID) -> Bool { generation == run && !Task.isCancelled }
  private func show(_ failure: Error, run: UUID) {
    guard current(run), !(failure is CancellationError) else { return }
    if (failure as? IOSCoreError)?.code == "invalid_profile_pin" {
      error = IOSProfilePIN.incorrect
      pinRejections += 1
    } else {
      error = failure.localizedDescription
    }
    handleSessionFailure(failure)
  }
  private func retireWork() {
    generation = UUID()
    task?.cancel()
    task = nil
    isBusy = false
  }
  // MARK: Watch Together

  private func watchClient() -> IOSAPIClient? {
    guard let connection, let session else { return nil }
    return makeClient(connection: connection, session: session)
  }

  /// Refreshes the parties others started, for Home and title pages.
  func refreshWatchParties() async {
    guard let api = watchClient() else {
      watchParties = []
      return
    }
    let all = (try? await api.watchParties()) ?? []
    watchParties = all.filter { $0.id != watchParty?.partyID }
  }

  /// Joins a party and opens its title; the player then follows the others.
  func joinWatchTogether(_ party: IOSWatchPartySummary) async {
    await leaveWatchTogether()
    guard let api = watchClient() else { return }
    let joined = IOSWatchTogetherSession(api: api, deviceName: UIDevice.current.name)
    watchParty = joined
    guard await joined.join(party), let state = joined.state,
      let item = try? await api.summary(id: state.mediaId)
    else { return }
    remotePlaybackItem = item
  }

  /// Starts a party for the title the player shows.
  func startWatchTogether(with controller: IOSPlaybackController) async {
    await leaveWatchTogether()
    guard let api = watchClient() else { return }
    let started = IOSWatchTogetherSession(api: api, deviceName: UIDevice.current.name)
    watchParty = started
    if await started.start(
      mediaID: controller.currentMediaID, position: controller.position, playing: controller.isPlaying)
    {
      attachWatchParty(to: controller)
    }
  }

  /// A player opened: a party this device is in follows it.
  func attachWatchParty(to controller: IOSPlaybackController) {
    guard let party = watchParty, let api = watchClient() else { return }
    party.openTitle = { [weak controller] mediaID in
      Task {
        guard let item = try? await api.summary(id: mediaID) else { return }
        controller?.switchTitle(to: item)
      }
    }
    controller.userActionObserver = { [weak party] action in party?.userAction(action) }
    controller.watchStateObserver = { [weak party] in party?.playerChanged() }
    party.attach(controller)
  }

  /// The player closed: closing it leaves the party.
  func playerClosed(_ controller: IOSPlaybackController) {
    controller.userActionObserver = nil
    controller.watchStateObserver = nil
    guard let party = watchParty, party.isFollowing(controller) else { return }
    Task { await leaveWatchTogether() }
  }

  func leaveWatchTogether() async {
    guard let party = watchParty else { return }
    watchParty = nil
    await party.leave()
  }

  private func clearPersonalState() {
    if let party = watchParty {
      watchParty = nil
      Task { await party.leave() }
    }
    watchParties = []
    expiry?.cancel()
    expiry = nil
    session = nil
    selectedProfile = nil
    profiles = []
    movies.clear()
    shows.clear()
    homeGenres = []
    home = nil
    homeError = nil
    homeLoading = false
    homeRequest = UUID()
    progressWarning = nil
    pendingProgress.removeAll()
    acknowledgedProgress.removeAll()
    mutationSummaries.removeAll()
    watchlistItems = []
    watchlistIds = []
    syncTask?.cancel()
    syncTask = nil
    progressObserver?.cancel()
    progressObserver = nil
    refreshTask?.cancel()
    refreshTask = nil
    deferredRefresh = false
    Task { await artwork.clear() }
    playerPresented = false
    deactivateProgress()
  }

  func overlay(_ original: IOSCatalogItem) -> IOSCatalogItem {
    let item = mutationSummaries[original.id] ?? original
    if let pending = pendingProgress[item.id] {
      return item.replacing(
        progress: IOSPlaybackProgress(
          mediaId: item.id, positionMilliseconds: pending.position,
          durationMilliseconds: pending.duration, isCompleted: pending.finished,
          lastPlayedAt: item.progress?.lastPlayedAt, updatedAt: nil,
          revision: item.progress?.revision ?? 0, lastMutationId: nil))
    }
    if let progress = acknowledgedProgress[item.id],
      progress.revision >= (item.progress?.revision ?? 0)
    {
      return item.replacing(progress: progress)
    }
    return item
  }

  func loadHome() async {
    guard let api = client, let sessionID = session?.sessionId else { return }
    let request = UUID()
    homeRequest = request
    homeLoading = true
    defer { if homeRequest == request { homeLoading = false } }
    do {
      let value = try await api.home()
      guard !Task.isCancelled, session?.sessionId == sessionID, homeRequest == request else {
        return
      }
      let refreshed = value.continueWatching + value.favorites + value.recentlyAdded
      for item in refreshed { mutationSummaries[item.id] = nil }
      if let item = value.recommendation { mutationSummaries[item.id] = nil }
      home = value
      homeError = nil
      if supportsWatchlist {
        await loadWatchlist()
      }
    } catch {
      guard !Task.isCancelled, session?.sessionId == sessionID, homeRequest == request else {
        return
      }
      homeError = error.localizedDescription
      handleSessionFailure(error)
    }
  }

  func isWatchlisted(_ mediaId: UUID) -> Bool {
    watchlistIds.contains(mediaId)
  }

  func loadWatchlist() async {
    guard let api = client, let sessionID = session?.sessionId, supportsWatchlist else { return }
    do {
      let response = try await api.watchlist()
      guard !Task.isCancelled, session?.sessionId == sessionID else { return }
      watchlistItems = response.items
      watchlistIds = Set(response.mediaIds)
    } catch {
      handleSessionFailure(error)
    }
  }

  func setWatchlist(mediaId: UUID, isWatchlisted: Bool) async -> Bool {
    guard let api = client, supportsWatchlist else { return false }
    do {
      let state = try await api.setWatchlist(mediaID: mediaId, isWatchlisted: isWatchlisted)
      if state.isWatchlisted {
        watchlistIds.insert(mediaId)
      } else {
        watchlistIds.remove(mediaId)
        watchlistItems.removeAll { $0.id == mediaId }
      }
      Task { await loadWatchlist() }
      return true
    } catch {
      handleSessionFailure(error)
      return false
    }
  }

  /// Loads the first Movies and TV Shows pages and their leading posters in the
  /// background, so the tabs are already filled when they are opened.
  func preloadLibrary() async {
    guard let api = client, let connection, let session else { return }
    for listing in [movies, shows] where listing.items.isEmpty && !listing.loading {
      let query = environment.browsePreferences.load(
        serverID: connection.serverID, profileID: session.user.id, section: listing.section)
      listing.configure(query: query, search: "", profileID: session.user.id)
      await listing.loadNext(api: api, onFailure: handleSessionFailure)
      guard self.session?.sessionId == session.sessionId else { return }
    }
    let genres = IOSDetailPresentation.genreRows(movies.items + shows.items).map {
      IOSHomeGenreRow(genre: $0.genre, items: $0.items)
    }
    if homeGenres != genres { homeGenres = genres }
    for listing in [movies, shows] {
      for item in listing.items.prefix(12) {
        guard self.session?.sessionId == session.sessionId else { return }
        if let poster = item.poster {
          _ = try? await artwork.image(artwork: poster, width: 640, api: api)
        }
      }
    }
  }

  func scheduleLibraryRefresh() {
    deferredRefresh = true
    guard !playerPresented, refreshTask == nil else { return }
    let sessionID = session?.sessionId
    refreshTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
      guard let self else { return }
      refreshTask = nil
      guard session?.sessionId == sessionID, !playerPresented else { return }
      deferredRefresh = false
      libraryRefresh = UUID()
      // Lists observe this revision and refresh in place without clearing.
      detailRefresh = UUID()
    }
  }

  private func observePersonalState(connection: IOSStoredConnection, session: IOSProfileSession) {
    syncTask?.cancel()
    progressObserver?.cancel()
    remoteDeviceHeartbeatTask?.cancel()
    remoteDeviceCommandTask?.cancel()
    let api = makeClient(connection: connection, session: session)
    let sessionID = session.sessionId
    let scope = IOSProgressScope(connection: connection, session: session)
    let deviceId = tvDeviceId
    let deviceName = UIDevice.current.name

    remoteDeviceHeartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.session?.sessionId == sessionID else { return }
        _ = try? await api.sendPlayerHeartbeat(
          deviceId: deviceId,
          deviceName: deviceName,
          clientType: "ios",
          isPlaying: self.playerPresented
        )
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
      }
    }

    remoteDeviceCommandTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.session?.sessionId == sessionID else { return }
        do {
          let commands = try await api.pollPlayerCommands(deviceId: deviceId, waitMs: 10000)
          guard !Task.isCancelled, self.session?.sessionId == sessionID else { return }
          for cmd in commands {
            if cmd.action.lowercased() == "play", let mediaId = cmd.mediaId {
              if let item = try? await api.summary(id: mediaId) {
                await MainActor.run { [weak self] in
                  self?.remotePlaybackItem = item
                }
              }
            } else if cmd.action.lowercased() == "stop" {
              await MainActor.run { [weak self] in
                self?.remotePlaybackItem = nil
                self?.playerPresented = false
              }
            }
          }
        } catch {
          do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
      }
    }
    progressObserver = Task { [weak self] in
      guard let self else { return }
      let stream = await environment.outbox.changes(scope: scope)
      guard !Task.isCancelled, self.session?.sessionId == sessionID else { return }
      let initialSnapshots = await environment.outbox.pendingSnapshots(scope: scope)
      guard !Task.isCancelled, self.session?.sessionId == sessionID else { return }
      pendingProgress = initialSnapshots
      let storageFailed = await environment.outbox.storageFailed
      guard !Task.isCancelled, self.session?.sessionId == sessionID else { return }
      if storageFailed {
        progressWarning =
          "Playback progress could not be saved on this device. Free storage and try again."
      }
      for await change in stream {
        guard !Task.isCancelled, self.session?.sessionId == sessionID else { return }
        let snapshots = await environment.outbox.pendingSnapshots(scope: scope)
        guard !Task.isCancelled, self.session?.sessionId == sessionID else { return }
        pendingProgress = snapshots
        if change.requiresUserAttention {
          progressWarning =
            "Playback progress could not be saved on this device. Free storage and try again."
        }
        if let progress = change.progress {
          acknowledgedProgress[progress.mediaId] = progress
          if acknowledgedProgress.count > 256 {
            acknowledgedProgress.removeValue(forKey: acknowledgedProgress.keys.first!)
          }
        }
        if change.reason != .enqueued { scheduleLibraryRefresh() }
      }
    }
    syncTask = Task { [weak self] in
      var cursor: Int64 = 0
      var generation: String?
      while !Task.isCancelled {
        do {
          let result = try await api.syncChanges(after: cursor, generation: generation)
          guard let self, !Task.isCancelled, self.session?.sessionId == sessionID else { return }
          cursor = result.cursor
          generation = result.generation
          if result.resetRequired {
            mutationSummaries.removeAll()
          } else {
            for id in result.changedMediaIds { mutationSummaries[id] = nil }
          }
          if result.resetRequired || !result.changedAreas.isEmpty { scheduleLibraryRefresh() }
          // A well-behaved server long-polls. This also bounds an immediate empty response.
          try await Task.sleep(for: .seconds(1))
        } catch {
          guard let self, !Task.isCancelled, self.session?.sessionId == sessionID else { return }
          handleSessionFailure(error)
          if (error as? IOSCoreError)?.isAuthenticationFailure == true { return }
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
      }
    }
  }

  private func deactivateProgress() {
    syncTask?.cancel()
    syncTask = nil
    progressObserver?.cancel()
    progressObserver = nil
    remoteDeviceHeartbeatTask?.cancel()
    remoteDeviceHeartbeatTask = nil
    remoteDeviceCommandTask?.cancel()
    remoteDeviceCommandTask = nil
    let previous = outboxTransition
    outboxTransition = Task {
      await previous?.value
      await environment.outbox.deactivate()
    }
  }

  private func activateProgress(connection: IOSStoredConnection, session: IOSProfileSession) {
    observePersonalState(connection: connection, session: session)
    let previous = outboxTransition
    let run = generation
    outboxTransition = Task { [weak self] in
      await previous?.value
      guard let self, self.current(run), self.isForeground,
        self.session?.sessionId == session.sessionId
      else { return }
      await environment.outbox.activate(
        scope: IOSProgressScope(connection: connection, session: session),
        client: makeClient(connection: connection, session: session),
        sessionID: session.sessionId,
        onAuthenticationFailure: { [weak self] failure in
          await self?.handleProgressFailure(failure, sessionID: session.sessionId)
        })
    }
  }

  private func handleProgressFailure(_ failure: IOSCoreError, sessionID: UUID) {
    guard session?.sessionId == sessionID else { return }
    handleSessionFailure(failure)
  }
}

struct IOSHomeGenreRow: Equatable, Identifiable {
  let genre: String
  let items: [IOSCatalogItem]
  var id: String { genre }
}
