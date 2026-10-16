import Combine
import Foundation
import UIKit

@MainActor
final class TVAppModel: ObservableObject {
  enum Phase { case connection, trust, pairing, profiles, library }
  @Published private(set) var phase: Phase = .connection
  @Published private(set) var connection: TVStoredConnection?
  @Published private(set) var session: TVProfileSession?
  @Published private(set) var inspected: TVInspectedServer?
  @Published private(set) var pairing: TVPairingStart?
  @Published private(set) var profiles: [TVWatchingProfile] = []
  @Published private(set) var isBusy = false
  @Published private(set) var error: String?
  @Published var selectedProfile: TVWatchingProfile?
  @Published private(set) var detailRefresh = UUID()
  let browser = TVBonjourBrowser()
  let movies = TVLibraryListing(kind: .movie)
  let shows = TVLibraryListing(kind: .series)
  let artwork = TVArtworkPipeline()
  @Published var progressWarning: String?
  @Published private(set) var home: TVHome?
  @Published private(set) var homeLoading = false
  @Published private(set) var homeError: String?
  @Published private(set) var libraryRefresh = UUID()
  @Published private(set) var pendingProgress: [UUID: TVProgressSnapshot] = [:]
  @Published private(set) var acknowledgedProgress: [UUID: TVPlaybackProgress] = [:]
  @Published private var mutationSummaries: [UUID: TVCatalogItem] = [:]
  private var syncTask: Task<Void, Never>?
  private var progressObserver: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var deferredRefresh = false
  private var homeRequest = UUID()
  var playerPresented = false {
    didSet { if !playerPresented && deferredRefresh { scheduleLibraryRefresh() } }
  }
  private let credentials = TVCredentialStore()
  let environment = TVAppEnvironment.current()
  private var generation = UUID()
  private var task: Task<Void, Never>?
  private var expiry: Task<Void, Never>?
  private var started = false
  private var isForeground = true
  private var outboxTransition: Task<Void, Never>?

  var client: TVAPIClient? {
    guard let connection, let session else { return nil }
    return makeClient(connection: connection, session: session)
  }

  var browsePreferences: TVBrowsePreferenceStore { environment.browsePreferences }
  init() {}

  func start() async {
    guard !started else { return }
    started = true
    #if DEBUG
      if let scenario = TVUITestScenario.current {
        connection = TVUITestFixtures.connection
        if scenario == .profiles {
          phase = .profiles
          await refreshProfiles()
        } else {
          session = TVUITestFixtures.session
          phase = .library
          activateProgress(
            connection: TVUITestFixtures.connection, session: TVUITestFixtures.session)
        }
        return
      }
    #endif
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
    do { url = try TVServerAddress.normalize(address) } catch {
      self.error = error.localizedDescription
      return
    }
    let run = beginWork()
    task = Task {
      defer { finish(run) }
      do {
        let candidate = try await TVAPIClient.inspect(
          baseURL: url, transport: environment.transport)
        let capabilities = try await makeClient(inspected: candidate).capabilities()
        try validate(capabilities)
        guard current(run) else { return }
        guard candidate.info.isSetup else {
          throw TVCoreError.server(
            status: 409, code: "setup_required",
            message: "Set up this server in Aurelia on your Mac first.", retryAfter: nil)
        }
        inspected = candidate
        phase = .trust
        browser.stop()
      } catch { show(error, run: run) }
    }
  }

  func reconnect() async {
    guard let saved = connection, !isBusy else { return }
    let run = beginWork()
    defer { finish(run) }
    do {
      let candidate = try await inspectKnownServer(saved, run: run)
      guard current(run) else { return }
      var relocated = saved.relocating(to: candidate.baseURL)
      try validate(try await makeClient(connection: relocated).capabilities())
      if let pending = relocated.pendingAcknowledgement {
        let receipt = try await makeClient(connection: relocated).acknowledgePairing(
          id: pending.id, secret: pending.secret)
        guard receipt.acknowledged else { throw TVCoreError.invalidResponse }
        relocated.pendingAcknowledgement = nil
      }
      guard current(run) else { return }
      try saveCredentials(relocated)
      connection = relocated
      try await loadProfiles(run: run)
    } catch {
      show(error, run: run)
      if current(run) {
        phase = .connection
        startDiscovery()
      }
    }
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
          if let date = TVServerDate.parse(created.expiresAt), date <= Date() {
            throw TVCoreError.server(
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
              guard let auth = result.authentication else { throw TVCoreError.invalidResponse }
              var paired = try inspected.connection(authentication: auth)
              paired.pendingAcknowledgement = TVPendingPairingAcknowledgement(
                id: created.id, secret: created.secret, expiresAt: created.expiresAt)
              try saveCredentials(paired)
              connection = paired
              let receipt = try await api.acknowledgePairing(id: created.id, secret: created.secret)
              guard current(run) else {
                Task { try? await makeClient(connection: paired).disconnectDevice() }
                return
              }
              guard receipt.acknowledged else { throw TVCoreError.invalidResponse }
              paired.pendingAcknowledgement = nil
              try saveCredentials(paired)
              guard current(run) else { return }
              connection = paired
              pairing = nil
              try await loadProfiles(run: run)
              return
            case .denied:
              throw TVCoreError.server(
                status: 403, code: "pairing_denied",
                message: "This device was not approved on your Mac.", retryAfter: nil)
            case .expired, .cancelled, .unknown:
              throw TVCoreError.server(
                status: 409, code: "pairing_expired",
                message: "This code is no longer available. Start a new pairing.", retryAfter: nil)
            }
          } catch let failure as TVCoreError where failure.statusCode == 429 || failure.isTransient
          {
            delay = max(5, Int(ceil(failure.retryAfter ?? 5)))
            if let date = TVServerDate.parse(created.expiresAt), date <= Date() { throw failure }
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
    let unclaimed: TVStoredConnection?
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

  func openProfile(_ profile: TVWatchingProfile, pin: String? = nil) {
    guard !isBusy, !profile.needsPinSetup, let connection else { return }
    if profile.pinProtectionEnabled && pin == nil {
      selectedProfile = profile
      error = nil
      return
    }
    if let pin, !TVProfilePIN.isValid(pin) {
      error = "Enter a 4–8 digit PIN."
      return
    }
    let run = beginWork()
    task = Task { [self] in
      defer { finish(run) }
      do {
        let opened = try await makeClient(connection: connection).unlockProfile(
          id: profile.id, pin: pin)
        guard current(run) else { return }
        guard opened.user.id == profile.id, let end = TVServerDate.parse(opened.expiresAt),
          end > Date()
        else { throw TVCoreError.invalidResponse }
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
    guard let core = failure as? TVCoreError else { return }
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
        error = "Pair this Apple TV with your server again."
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
    scheduleLibraryRefresh()
    if phase == .connection { startDiscovery() }
    if phase == .profiles, selectedProfile == nil { Task { await refreshProfiles() } }
    if let session, let date = TVServerDate.parse(session.expiresAt), date <= Date() {
      Task { await switchProfile() }
    } else if let connection, let session {
      activateProgress(connection: connection, session: session)
    }
  }

  func updateSummary(_ item: TVCatalogItem) {
    mutationSummaries[item.id] = nil
    movies.update(item)
    shows.update(item)
  }

  func applyMutationSummary(_ item: TVCatalogItem) {
    updateSummary(item)
    mutationSummaries[item.id] = item
    if mutationSummaries.count > 256,
      let oldest = mutationSummaries.keys.first(where: { $0 != item.id })
    {
      mutationSummaries.removeValue(forKey: oldest)
    }
  }

  func makeClient(connection: TVStoredConnection, session: TVProfileSession? = nil) -> TVAPIClient {
    TVAPIClient(connection: connection, session: session, transport: environment.transport)
  }

  private func makeClient(inspected: TVInspectedServer) -> TVAPIClient {
    TVAPIClient(inspected: inspected, transport: environment.transport)
  }

  private func saveCredentials(_ connection: TVStoredConnection) throws {
    if environment.allowsPersistentCredentials { try credentials.save(connection) }
  }

  private func deleteCredentials() throws {
    if environment.allowsPersistentCredentials { try credentials.delete() }
  }

  private func startDiscovery() {
    if environment.allowsDiscovery { browser.start() }
  }

  private func inspectKnownServer(_ saved: TVStoredConnection, run: UUID) async throws
    -> TVInspectedServer
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
          let candidate = try await TVAPIClient.inspect(
            baseURL: address, transport: environment.transport)
          guard current(run) else { throw CancellationError() }
          try candidate.validate(against: saved)
          return candidate
        } catch {
          guard current(run) else { throw CancellationError() }
          guard (error as? TVCoreError)?.isTransient == true || error is URLError else {
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
      throw TVCoreError.unsupportedServer
    }
    if result.managementSetupRequired {
      throw TVCoreError.server(
        status: 409, code: "setup_required",
        message: "Finish profile setup in Aurelia on your Mac first.", retryAfter: nil)
    }
    profiles = result.profiles
    error = nil
    phase = .profiles
    browser.stop()
  }

  private func validate(_ capabilities: TVCapabilities) throws {
    guard [1, 2].contains(capabilities.formatVersion),
      Set(["device-authorization-v1", "library-state-v1"]).isSubset(
        of: Set(capabilities.capabilities ?? []))
    else { throw TVCoreError.unsupportedServer }
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
    error = failure.localizedDescription
    handleSessionFailure(failure)
  }
  private func retireWork() {
    generation = UUID()
    task?.cancel()
    task = nil
    isBusy = false
  }
  private func clearPersonalState() {
    expiry?.cancel()
    expiry = nil
    session = nil
    selectedProfile = nil
    profiles = []
    movies.clear()
    shows.clear()
    home = nil
    homeError = nil
    homeLoading = false
    homeRequest = UUID()
    progressWarning = nil
    pendingProgress.removeAll()
    acknowledgedProgress.removeAll()
    mutationSummaries.removeAll()
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

  func overlay(_ original: TVCatalogItem) -> TVCatalogItem {
    let item = mutationSummaries[original.id] ?? original
    if let pending = pendingProgress[item.id] {
      return item.replacing(
        progress: TVPlaybackProgress(
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
    } catch {
      guard !Task.isCancelled, session?.sessionId == sessionID, homeRequest == request else {
        return
      }
      homeError = error.localizedDescription
      handleSessionFailure(error)
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

  private func observePersonalState(connection: TVStoredConnection, session: TVProfileSession) {
    syncTask?.cancel()
    progressObserver?.cancel()
    let api = makeClient(connection: connection, session: session)
    let sessionID = session.sessionId
    let scope = TVProgressScope(connection: connection, session: session)
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
          "Playback progress could not be saved on this Apple TV. Free storage and try again."
      }
      for await change in stream {
        guard !Task.isCancelled, self.session?.sessionId == sessionID else { return }
        let snapshots = await environment.outbox.pendingSnapshots(scope: scope)
        guard !Task.isCancelled, self.session?.sessionId == sessionID else { return }
        pendingProgress = snapshots
        if change.storageFailed {
          progressWarning =
            "Playback progress could not be saved on this Apple TV. Free storage and try again."
        } else if change.state == .conflict {
          progressWarning = "Progress changed on another device. Its newer position has been kept."
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
          if (error as? TVCoreError)?.isAuthenticationFailure == true { return }
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
    let previous = outboxTransition
    outboxTransition = Task {
      await previous?.value
      await environment.outbox.deactivate()
    }
  }

  private func activateProgress(connection: TVStoredConnection, session: TVProfileSession) {
    observePersonalState(connection: connection, session: session)
    let previous = outboxTransition
    let run = generation
    outboxTransition = Task { [weak self] in
      await previous?.value
      guard let self, self.current(run), self.isForeground,
        self.session?.sessionId == session.sessionId
      else { return }
      await environment.outbox.activate(
        scope: TVProgressScope(connection: connection, session: session),
        client: makeClient(connection: connection, session: session),
        sessionID: session.sessionId,
        onAuthenticationFailure: { [weak self] failure in
          await self?.handleProgressFailure(failure, sessionID: session.sessionId)
        })
    }
  }

  private func handleProgressFailure(_ failure: TVCoreError, sessionID: UUID) {
    guard session?.sessionId == sessionID else { return }
    handleSessionFailure(failure)
  }
}
