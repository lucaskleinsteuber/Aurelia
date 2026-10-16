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
  let images = NSCache<NSString, NSData>()
  var playerPresented = false
  private let credentials = TVCredentialStore()
  private var generation = UUID()
  private var task: Task<Void, Never>?
  private var expiry: Task<Void, Never>?
  private var started = false
  private var isForeground = true
  private var outboxTransition: Task<Void, Never>?

  var client: TVAPIClient? {
    guard let connection, let session else { return nil }
    return TVAPIClient(connection: connection, session: session)
  }

  init() { images.totalCostLimit = 64 * 1024 * 1024 }

  func start() async {
    guard !started else { return }
    started = true
    do {
      connection = try credentials.load()
      if connection != nil { await reconnect() } else { browser.start() }
    } catch {
      self.error = "The saved connection could not be read. Try connecting again."
      browser.start()
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
        let candidate = try await TVAPIClient.inspect(baseURL: url)
        let capabilities = try await TVAPIClient(inspected: candidate).capabilities()
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
      try validate(try await TVAPIClient(connection: relocated).capabilities())
      if let pending = relocated.pendingAcknowledgement {
        let receipt = try await TVAPIClient(connection: relocated).acknowledgePairing(
          id: pending.id, secret: pending.secret)
        guard receipt.acknowledged else { throw TVCoreError.invalidResponse }
        relocated.pendingAcknowledgement = nil
      }
      guard current(run) else { return }
      try credentials.save(relocated)
      connection = relocated
      try await loadProfiles(run: run)
    } catch {
      show(error, run: run)
      if current(run) {
        phase = .connection
        browser.start()
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
        let api = TVAPIClient(inspected: inspected)
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
              try credentials.save(paired)
              connection = paired
              let receipt = try await api.acknowledgePairing(id: created.id, secret: created.secret)
              guard current(run) else {
                Task { try? await TVAPIClient(connection: paired).disconnectDevice() }
                return
              }
              guard receipt.acknowledged else { throw TVCoreError.invalidResponse }
              paired.pendingAcknowledgement = nil
              try credentials.save(paired)
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
      do { try credentials.delete() } catch { self.error = error.localizedDescription }
      connection = nil
    }
    pairing = nil
    inspected = nil
    phase = .connection
    browser.start()
    Task {
      // The receipt may have committed even when its response was lost. A
      // credential saved before acknowledgement lets cancellation revoke it.
      if let unclaimed { try? await TVAPIClient(connection: unclaimed).disconnectDevice() }
      if let pending, let server {
        _ = try? await TVAPIClient(inspected: server).cancelPairing(
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
        let opened = try await TVAPIClient(connection: connection).unlockProfile(
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
    do { try credentials.delete() } catch { self.error = error.localizedDescription }
    browser.start()
    if let stored { try? await TVAPIClient(connection: stored).disconnectDevice() }
  }

  func handleSessionFailure(_ failure: Error) {
    guard let core = failure as? TVCoreError else { return }
    if core.code == "invalid_profile_pin" || core.code == "invalid_pin_format" { return }
    if core == .identityMismatch {
      retireWork()
      clearPersonalState()
      phase = .connection
      error = core.localizedDescription
      browser.start()
    } else if core.statusCode == 401
      || ["profile_session_expired", "profile_session_revoked", "device_session_revoked"].contains(
        core.code ?? "")
    {
      let deviceRejected = core.code == "device_session_revoked" || session == nil
      retireWork()
      clearPersonalState()
      if deviceRejected {
        phase = .connection
        browser.start()
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
    detailRefresh = UUID()
    if phase == .connection { browser.start() }
    if phase == .profiles, selectedProfile == nil { Task { await refreshProfiles() } }
    if let session, let date = TVServerDate.parse(session.expiresAt), date <= Date() {
      Task { await switchProfile() }
    } else if let connection, let session {
      activateProgress(connection: connection, session: session)
    }
  }

  func updateSummary(_ item: TVCatalogItem) {
    movies.update(item)
    shows.update(item)
  }

  private func inspectKnownServer(_ saved: TVStoredConnection, run: UUID) async throws
    -> TVInspectedServer
  {
    var lastFailure: Error = URLError(.cannotConnectToHost)
    for delay in [0, 3, 6, 12] {
      guard current(run) else { throw CancellationError() }
      if delay > 0 {
        browser.start()
        try await Task.sleep(for: .seconds(delay))
      }
      guard current(run) else { throw CancellationError() }
      let discovered = browser.servers.filter { $0.serverID == saved.serverID }
        .flatMap { [$0.baseURL] + $0.alternativeURLs }
      var tried: Set<URL> = []
      for address in [saved.baseURL] + discovered where tried.insert(address).inserted {
        do {
          let candidate = try await TVAPIClient.inspect(baseURL: address)
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
    let result = try await TVAPIClient(connection: connection).profiles()
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
    images.removeAllObjects()
    playerPresented = false
    deactivateProgress()
  }

  private func deactivateProgress() {
    let previous = outboxTransition
    outboxTransition = Task {
      await previous?.value
      await TVProgressOutbox.shared.deactivate()
    }
  }

  private func activateProgress(connection: TVStoredConnection, session: TVProfileSession) {
    let previous = outboxTransition
    let run = generation
    outboxTransition = Task { [weak self] in
      await previous?.value
      guard let self, self.current(run), self.isForeground,
        self.session?.sessionId == session.sessionId
      else { return }
      await TVProgressOutbox.shared.activate(
        scope: TVProgressScope(connection: connection, session: session),
        client: TVAPIClient(connection: connection, session: session),
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

@MainActor
final class TVLibraryListing: ObservableObject {
  let kind: TVMediaKind
  @Published private(set) var items: [TVCatalogItem] = []
  @Published private(set) var loading = false
  @Published private(set) var error: String?
  private var total = 1
  private var revision: String?
  private var generation = UUID()

  init(kind: TVMediaKind) { self.kind = kind }
  func clear() {
    generation = UUID()
    items = []
    total = 1
    revision = nil
    error = nil
    loading = false
  }
  func update(_ item: TVCatalogItem) {
    if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item }
  }

  func loadNext(api: TVAPIClient, onFailure: (Error) -> Void) async {
    guard !loading, items.count < total else { return }
    let run = generation
    loading = true
    defer { if generation == run { loading = false } }
    var restarts = 0
    while restarts < 2 {
      do {
        let offset = items.count
        let page = try await api.catalogPage(kind: kind, offset: offset, revision: revision)
        guard generation == run, !Task.isCancelled else { return }
        guard page.offset == offset, page.limit > 0, page.total >= offset + page.items.count,
          !page.items.isEmpty || offset == page.total,
          offset == 0 || page.total == total,
          revision == nil || revision == page.revision,
          Set(items.map(\.id) + page.items.map(\.id)).count == items.count + page.items.count
        else { throw TVCoreError.invalidResponse }
        items.append(contentsOf: page.items)
        total = page.total
        revision = page.revision
        error = nil
        return
      } catch let failure as TVCoreError
        where failure.statusCode == 409 && failure.code == "catalog_changed"
      {
        guard generation == run, !Task.isCancelled else { return }
        items = []
        total = 1
        revision = nil
        restarts += 1
      } catch {
        guard generation == run, !Task.isCancelled, !(error is CancellationError) else { return }
        self.error = error.localizedDescription
        onFailure(error)
        return
      }
    }
    error = "The library changed while loading. Try again."
  }
}
