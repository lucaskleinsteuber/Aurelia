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
  /// "Mac" or "Linux PC" when the saved server runs inside the Aurelia app there: its owner starts
  /// it by opening Aurelia, and this device doesn't try to wake it.
  var savedServerAppHost: String? { connection.flatMap { IOSWakeOnLan.appHost(for: $0.serverID) } }
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
  var supportsCollections: Bool { capabilities?.supportsCollections ?? false }
  var supportsCollectionsV3: Bool { capabilities?.supportsCollectionsV3 ?? false }
  var supportsScrubPreviews: Bool { capabilities?.supportsScrubPreviews ?? false }
  var supportsMovieNight: Bool { capabilities?.supportsMovieNight ?? false }
  var supportsSuggestions: Bool { capabilities?.supportsSuggestions ?? false }
  var supportsWrapped: Bool { capabilities?.supportsWrapped ?? false }
  var supportsMonthlyWrapped: Bool { capabilities?.supportsMonthlyWrapped ?? false }
  var supportsAdaptiveStreaming: Bool { capabilities?.supportsAdaptiveStreaming ?? false }
  var supportsWishes: Bool { capabilities?.supportsWishes ?? false }
  var isWishAdmin: Bool { IOSWishPresentation.isAdministrator(session?.user) }
  @Published private(set) var wishSummary: IOSWishSummaryResponse?
  @Published var wishNotificationsEnabled: Bool = IOSWishNotificationCenter.shared
    .isEnabledInSettings
  @Published var wishesPresented = false
  let wishPosterBytes = IOSWishPosterByteCache()
  private var previousWishSummary: IOSWishSummaryResponse?
  private var wishSummaryTask: Task<Void, Never>?

  var wishBadgeCount: Int {
    guard supportsWishes else { return 0 }
    return IOSWishPresentation.badgeCount(summary: wishSummary, isAdmin: isWishAdmin)
  }
  @Published private(set) var homeLoading = false
  @Published private(set) var homeError: String?
  @Published private(set) var libraryRefresh = UUID()
  @Published private(set) var pendingProgress: [UUID: IOSProgressSnapshot] = [:]
  @Published private(set) var acknowledgedProgress: [UUID: IOSPlaybackProgress] = [:]
  @Published private var mutationSummaries: [UUID: IOSCatalogItem] = [:]
  @Published var remotePlaybackItem: IOSCatalogItem?
  /// Watch Now on a suggestion in the player: Home closes the player and plays this title.
  @Published var suggestedPlaybackItem: IOSCatalogItem?
  /// Counts Stop requests from another device; the screen showing the player closes it.
  @Published private(set) var remoteStopRequests = 0
  /// The player on screen, so the heartbeat can tell other devices what plays.
  private weak var openPlayer: IOSPlaybackController?
  /// The Watch Together party this device is in, if any.
  @Published private(set) var watchParty: IOSWatchTogetherSession?
  /// Parties others started on the server, offered on Home and title pages.
  @Published private(set) var watchParties: [IOSWatchPartySummary] = []
  /// Downloads on this device; the synthetic UI fixtures get an empty store of their own.
  let offline: IOSOfflineStore
  enum OfflineMode: Equatable {
    case choosing
    case open(IOSOfflineSession)
  }
  /// Aurelia without the server, showing only this device's downloads.
  @Published private(set) var offlineMode: OfflineMode?
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
  /// The name the Mac and other devices show for this one.
  var deviceName: String {
    IOSDeviceName.display(
      systemName: UIDevice.current.name, model: UIDevice.current.model,
      tag: UIDevice.current.identifierForVendor)
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
  /// The setup assistant: introduction, guided connection and the tour.
  let setupGuide: IOSSetupGuide
  private var setupGuideObservation: AnyCancellable?

  init() {
    #if DEBUG
      let fixture = IOSUITestScenario.current != nil
      let assistantFixture = ProcessInfo.processInfo.environment["AURELIA_IOS_ASSISTANT"] == "1"
    #else
      let fixture = false
      let assistantFixture = false
    #endif
    offline = Self.offlineStore(fixture: fixture)
    if !fixture { IOSTestEdition.forgetLeftoversAfterReinstall() }
    let alreadyConnected = !fixture && (try? IOSCredentialStore().load()) != nil
    setupGuide = IOSSetupGuide(
      defaults: fixture
        ? (UserDefaults(suiteName: "Aurelia.IOS.SetupGuide.\(UUID().uuidString)") ?? .standard)
        : .standard,
      alreadySetUp: alreadyConnected || (fixture && !assistantFixture))
    setupGuideObservation = setupGuide.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    IOSProfilePhotoCache.shared.loader = { [weak self] id, revision in
      guard let self, let connection = self.connection else { throw IOSCoreError.profileRequired }
      return try await self.makeClient(connection: connection).profilePhoto(
        id: id, revision: revision)
    }
  }

  /// The synthetic UI fixtures never see or start real downloads.
  private static func offlineStore(fixture: Bool) -> IOSOfflineStore {
    guard fixture else { return .shared }
    return IOSOfflineStore(
      root: FileManager.default.temporaryDirectory.appendingPathComponent(
        "AureliaIOSFixtureDownloads-\(UUID().uuidString)", isDirectory: true),
      transfers: false)
  }

  var supportsProfilePersonalization: Bool {
    capabilities?.supportsProfilePersonalization ?? false
  }

  /// The signed-in profile was renamed or got a new picture.
  func updateProfileUser(_ user: IOSUser) {
    if let session, session.user.id == user.id {
      self.session = IOSProfileSession(
        user: user, sessionId: session.sessionId, token: session.token,
        expiresAt: session.expiresAt)
    }
    if let index = profiles.firstIndex(where: { $0.id == user.id }) {
      let old = profiles[index]
      profiles[index] = IOSWatchingProfile(
        id: old.id, name: user.shownName, role: old.role, needsPinSetup: old.needsPinSetup,
        pinProtectionEnabled: old.pinProtectionEnabled, pictureKey: user.pictureKey,
        pictureRevision: user.pictureRevision ?? 0, ageLimit: user.ageLimit)
    }
  }

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
          ] + (scenario == .admin ? ["security-v1", "automation-v1"] : []))
        if scenario == .profiles {
          phase = .profiles
          await refreshProfiles()
        } else {
          let fixture =
            scenario == .showcase
            ? IOSShowcaseTransport.session
            : scenario == .admin ? IOSUITestFixtures.ownerSession : IOSUITestFixtures.session
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
            message: "Set up this server in Aurelia on the Mac or Linux computer that runs it first.", retryAfter: nil)
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
      IOSWakeOnLan.rememberResolving(
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

  /// What Settings shows about waking the saved server.
  var wakeOnLanStatus: IOSWakeOnLan.Status {
    connection.map { IOSWakeOnLan.status(for: $0.serverID) }
      ?? IOSWakeOnLan.Status(cards: 0, addresses: 0, appHost: nil)
  }
  /// Whether Wake Server is waiting for the server it woke.
  @Published private(set) var isWakingServer = false

  /// Sends the Wake-on-LAN packet once, when someone asks for it.
  func sendWakeSignal() {
    guard let saved = connection else { return }
    IOSWakeOnLan.wake(serverID: saved.serverID)
  }

  /// Wake Server on the "server is off" screen: sends the packet now and again every ten seconds,
  /// and connects as soon as the server answers, for up to two minutes.
  func wakeServerNow() async {
    guard let saved = connection, !isWakingServer, wakeOnLanStatus.canWake else { return }
    isWakingServer = true
    defer { isWakingServer = false }
    allowWaking()
    let deadline = Date().addingTimeInterval(TimeInterval(IOSWakeOnLan.Plan.totalSeconds))
    while Date() < deadline, phase == .connection, connection?.serverID == saved.serverID {
      IOSWakeOnLan.wake(serverID: saved.serverID)
      do { try await Task.sleep(for: .seconds(IOSWakeOnLan.Plan.resendSeconds)) } catch { return }
      if !isBusy { await reconnect() }
    }
  }

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

  /// After the server's fingerprint is trusted: asks for the 8-digit code that the main device
  /// (Aurelia on a Mac, the Linux app, or `aurelia pair` on a Linux server) shows. Every
  /// device pairs this way, so nobody has to work out which side shows the code.
  func beginPairing() {
    guard !isBusy, inspected != nil else { return }
    retireWork()
    error = nil
    pairing = nil
    phase = .pairing
  }

  /// Pairs this device with the code from the main device.
  func pair(code: String) {
    guard !isBusy, let inspected else { return }
    let digits = code.filter(\.isNumber)
    guard digits.count == 8 else {
      error = "Enter the 8-digit code shown on your Mac or Linux computer."
      return
    }
    let run = beginWork()
    task = Task {
      defer { finish(run) }
      do {
        let auth = try await makeClient(inspected: inspected).redeemPairingCode(
          digits, deviceName: deviceName)
        guard current(run) else { return }
        let paired = try inspected.connection(authentication: auth)
        IOSWakeOnLan.rememberResolving(
          serverID: inspected.info.serverId, info: inspected.info,
          hosts: [inspected.baseURL.host].compactMap { $0 })
        try saveCredentials(paired)
        connection = paired
        try await loadProfiles(run: run)
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
        rememberForOffline(profile, pin: pin, serverID: connection.serverID)
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
    // Nothing of this server stays behind: stored artwork and its wake address go too.
    await artwork.removeStored()
    guard let stored else { return }
    IOSWakeOnLan.forget(serverID: stored.serverID)
    offline.forget(serverID: stored.serverID)
    do {
      try await makeClient(connection: stored).disconnectDevice()
    } catch let failure as IOSCoreError where failure.isAuthenticationFailure {
      // The server had already removed this device.
    } catch {
      if self.error == nil {
        self.error =
          "This device is disconnected, but the server could not be told. Remove it in Aurelia on your Mac."
      }
    }
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
          // An address found on the network may be a stale entry or another computer; only the
          // saved address itself proves that the server's identity changed.
          if address != saved.baseURL, (error as? IOSCoreError) == .identityMismatch { continue }
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
    try IOSProtocolVersion.check(result.formatVersion)
    if result.managementSetupRequired {
      throw IOSCoreError.server(
        status: 409, code: "setup_required",
        message: "Finish profile setup in Aurelia on the Mac or Linux computer that runs the server.", retryAfter: nil)
    }
    profiles = result.profiles
    error = nil
    phase = .profiles
    browser.stop()
  }

  private func validate(_ capabilities: IOSCapabilities) throws {
    try IOSProtocolVersion.check(capabilities.formatVersion)
    guard Set(["device-authorization-v1", "library-state-v1"]).isSubset(
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
    let joined = IOSWatchTogetherSession(api: api, deviceName: deviceName)
    watchParty = joined
    guard await joined.join(party), let state = joined.state,
      let item = try? await api.summary(id: state.mediaId)
    else {
      // Usually the party ended meanwhile: drop it and show the parties that are left.
      if watchParty === joined { await leaveWatchTogether() }
      await refreshWatchParties()
      return
    }
    remotePlaybackItem = item
  }

  /// Starts a party for the title the player shows.
  func startWatchTogether(with controller: IOSPlaybackController) async {
    await leaveWatchTogether()
    guard let api = watchClient() else { return }
    let started = IOSWatchTogetherSession(api: api, deviceName: deviceName)
    watchParty = started
    if await started.start(
      mediaID: controller.currentMediaID, position: controller.position,
      playing: controller.isPlaying)
    {
      attachWatchParty(to: controller)
    }
  }

  /// A player opened: a party this device is in follows it.
  func attachWatchParty(to controller: IOSPlaybackController) {
    openPlayer = controller
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
    if openPlayer === controller { openPlayer = nil }
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
    wishSummaryTask?.cancel()
    wishSummaryTask = nil
    wishSummary = nil
    previousWishSummary = nil
    wishesPresented = false
    wishPosterBytes.clear()
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
      if supportsWishes && wishSummary == nil {
        Task { [weak self] in await self?.refreshWishSummary(notify: false) }
      }
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

  func openWishesFromNotification() {
    guard session != nil, supportsWishes else { return }
    wishesPresented = true
  }

  func setWishNotificationsEnabled(_ enabled: Bool) async {
    wishNotificationsEnabled = enabled
    IOSWishNotificationCenter.shared.isEnabledInSettings = enabled
    if enabled {
      await IOSWishNotificationCenter.shared.requestPermissionOnFirstVisitIfNeeded()
    }
  }

  func updateWishSummaryFromPage(_ summary: IOSWishSummaryResponse) {
    wishSummary = summary
    previousWishSummary = summary
  }

  func refreshWishSummary(notify: Bool) async {
    guard let api = client, let sessionID = session?.sessionId, supportsWishes else { return }
    wishSummaryTask?.cancel()
    let task = Task { [weak self] in
      guard let summary = try? await api.wishSummary() else { return }
      guard let self, !Task.isCancelled, self.session?.sessionId == sessionID else { return }
      let previous = self.previousWishSummary
      self.wishSummary = summary
      self.previousWishSummary = summary

      guard notify,
        let baseEvent = IOSWishPresentation.notificationEvent(
          previous: previous, current: summary, isAdmin: self.isWishAdmin)
      else { return }

      var latestWish: IOSWishSummary?
      if baseEvent.kind == .wishFulfilled,
        let fulfilled = try? await api.wishes(state: .fulfilled, offset: 0, limit: 5),
        !Task.isCancelled
      {
        latestWish = fulfilled.wishes.first {
          $0.userId == self.session?.user.id || $0.seenByWisherAt == nil
        } ?? fulfilled.wishes.first
      } else if baseEvent.kind == .newWishes,
        let opened = try? await api.wishes(state: .open, offset: 0, limit: 5),
        !Task.isCancelled
      {
        latestWish = opened.wishes.first
      }
      if let event = IOSWishPresentation.notificationEvent(
        previous: previous, current: summary, isAdmin: self.isWishAdmin, latestWish: latestWish)
      {
        await IOSWishNotificationCenter.shared.notify(event)
      }
    }
    wishSummaryTask = task
    await task.value
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

  /// Closes the open player, wherever it shows. Closing it saves the progress as usual.
  func stopPlayer() { remoteStopRequests += 1 }

  private func observePersonalState(connection: IOSStoredConnection, session: IOSProfileSession) {
    syncTask?.cancel()
    progressObserver?.cancel()
    remoteDeviceHeartbeatTask?.cancel()
    remoteDeviceCommandTask?.cancel()
    let api = makeClient(connection: connection, session: session)
    let sessionID = session.sessionId
    let scope = IOSProgressScope(connection: connection, session: session)
    let deviceId = tvDeviceId
    let deviceName = self.deviceName

    remoteDeviceHeartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.session?.sessionId == sessionID else { return }
        _ = try? await api.sendPlayerHeartbeat(
          deviceId: deviceId,
          deviceName: deviceName,
          clientType: "ios",
          isPlaying: self.openPlayer != nil || self.playerPresented,
          mediaId: self.openPlayer?.currentMediaID,
          title: self.openPlayer?.title,
          positionSeconds: self.openPlayer.map { Double($0.position) / 1_000 },
          durationSeconds: self.openPlayer.flatMap {
            $0.duration > 0 ? Double($0.duration) / 1_000 : nil
          },
          isPaused: self.openPlayer.map { !$0.isPlaying } ?? false
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
                self?.stopPlayer()
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
          if supportsWishes,
            result.resetRequired
              || result.changedAreas.contains(where: {
                let area = $0.lowercased()
                return area == "userstate" || area == "catalog"
              })
          {
            Task { [weak self] in await self?.refreshWishSummary(notify: true) }
          }
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
      // Progress watched offline goes to the server, and downloads take over the server's.
      await offline.syncProgress(api: makeClient(connection: connection, session: session))
    }
  }

  // MARK: Downloads

  /// The open profile, as the offline mode would show it.
  var currentOfflineSession: IOSOfflineSession? {
    guard let connection, let session else { return nil }
    return IOSOfflineSession(
      serverID: connection.serverID, profileID: session.user.id, name: session.user.shownName,
      pictureKey: session.user.pictureKey, pictureRevision: session.user.pictureRevision ?? 0)
  }

  /// Downloads a movie or episode for the open profile.
  func download(_ item: IOSCatalogItem) {
    guard let client, IOSOfflineRules.canDownload(item) else { return }
    Task {
      let series: IOSCatalogItem? =
        if item.kind == .episode, let parent = item.parentId {
          try? await client.summary(id: parent)
        } else { nil }
      await offline.download(item, series: series, api: client)
    }
  }

  /// Downloads every episode of a season that isn't on this device yet, one after another.
  func download(episodes: [IOSCatalogItem]) {
    guard let client else { return }
    let wanted = episodes.filter {
      IOSOfflineRules.canDownload($0) && offline.title($0.id) == nil && offline.pending($0.id) == nil
    }
    guard let first = wanted.first else { return }
    Task {
      let series: IOSCatalogItem? =
        if let parent = first.parentId { try? await client.summary(id: parent) } else { nil }
      for episode in wanted {
        guard self.session?.sessionId == client.session?.sessionId else { return }
        await offline.download(episode, series: series, api: client)
      }
    }
  }

  func retryDownload(_ id: UUID) {
    Task { await offline.retry(id, api: client) }
  }

  /// Whether the offline mode has anything to show for the saved server.
  var canWatchOffline: Bool {
    connection.map { offline.hasDownloads(serverID: $0.serverID) } ?? false
  }

  func enterOfflineMode() {
    guard let connection, canWatchOffline else { return }
    let cards = offline.offlineProfiles(serverID: connection.serverID)
    if cards.count == 1, let only = cards.first, !only.pinProtected {
      _ = openOffline(only, pin: "")
    } else {
      offlineMode = .choosing
    }
  }

  /// Opens a profile's downloads offline; false when its PIN is wrong.
  func openOffline(_ card: IOSOfflineProfileCard, pin: String) -> Bool {
    guard card.serverID == connection?.serverID, card.accepts(pin) else { return false }
    offlineMode = .open(
      IOSOfflineSession(
        serverID: card.serverID, profileID: card.profileID, name: card.name,
        pictureKey: card.pictureKey, pictureRevision: card.pictureRevision))
    return true
  }

  func chooseOfflineProfile() { offlineMode = .choosing }

  func leaveOfflineMode() {
    offlineMode = nil
    Task { await reconnect(userInitiated: true) }
  }

  func offlinePlayback(
    title: IOSOfflineTitle, profile: IOSOfflineSession, connection: IOSStoredConnection
  ) -> IOSOfflinePlayback {
    IOSOfflinePlayback(
      title: title, profile: profile, connection: connection, store: offline,
      base: environment.makePlaybackRuntime())
  }

  /// A download played while the server answers: its progress goes there right away.
  func offlinePlayerClosed() {
    guard let client else { return }
    Task {
      await offline.syncProgress(api: client)
      scheduleLibraryRefresh()
    }
  }

  /// Remembers a profile that opened while the server answered, for the offline mode.
  private func rememberForOffline(_ profile: IOSWatchingProfile, pin: String?, serverID: UUID) {
    let store = offline
    // Deriving the PIN check takes a moment; keep it off the main actor.
    Task.detached(priority: .utility) {
      guard let card = IOSOfflineProfileCard.make(serverID: serverID, profile: profile, pin: pin)
      else { return }
      await store.remember(card)
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
