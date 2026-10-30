import Foundation
import SwiftUI

@MainActor
public final class IOSAppModel: ObservableObject {
  // Connection & Auth
  @Published public var storedConnection: IOSStoredConnection?
  @Published public var isConnecting = false
  @Published public var isOffline = false
  @Published public var serverInfo: IOSServerInfo?
  @Published public var profiles: [IOSUserProfile] = []
  @Published public var currentProfile: IOSUserProfile?
  @Published public var pinPromptProfile: IOSUserProfile?

  // Catalog
  @Published public var homeCatalog = IOSCatalogIndexResponse()
  @Published public var movies: [IOSCatalogItemSummary] = []
  @Published public var shows: [IOSCatalogItemSummary] = []
  @Published public var collections: [IOSCollectionSummary] = []
  @Published public var franchises: [IOSFranchiseSummary] = []
  @Published public var searchResults: [IOSCatalogItemSummary] = []
  @Published public var activeDetailItem: IOSCatalogDetailResponse?

  // Playback
  @Published public var isPlayingMedia = false
  @Published public var playbackItem: IOSCatalogItemSummary?
  @Published public var playbackPlan: IOSStreamPlanResponse?
  public let playbackController = IOSPlaybackController()

  // Remote Playback
  @Published public var activePlayers: [IOSRemotePlayerDevice] = []

  // Pairing
  @Published public var isPairing = false
  @Published public var pairingCode: String?
  @Published public var discoveredServers: [IOSDiscoveredServer] = []

  public private(set) var apiClient: IOSAPIClient
  private let credentialStore = IOSCredentialStore()
  private let bonjourBrowser = IOSBonjourBrowser()
  private var pairingTask: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?

  public init(apiClient: IOSAPIClient = IOSAPIClient()) {
    self.apiClient = apiClient
    bonjourBrowser.start { [weak self] servers in
      Task { @MainActor [weak self] in
        self?.discoveredServers = servers
      }
    }
  }

  public func bootstrap() async {
    isConnecting = true
    defer { isConnecting = false }

    do {
      if let stored = try credentialStore.load() {
        self.storedConnection = stored
        self.apiClient = apiClient.configured(
          baseURL: stored.baseURL,
          fingerprint: stored.fingerprint,
          sessionToken: stored.sessionToken,
          profileToken: stored.profileToken
        )

        // Wake on LAN attempt opportunistically in case server sleeps
        IOSWakeOnLan.wake(serverID: stored.serverId)

        // Validate server info
        let (info, _) = try await apiClient.getServerInfo(at: stored.baseURL)
        self.serverInfo = info

        // Fetch profiles
        let profiles = try await apiClient.getProfiles()
        self.profiles = profiles

        if let activeId = stored.activeProfileId,
          let matching = profiles.first(where: { $0.id == activeId })
        {
          self.currentProfile = matching
          await refreshCatalog()
        } else if let first = profiles.first {
          _ = try await switchProfile(first)
        }

        isOffline = false
        startHeartbeat()
      }
    } catch {
      isOffline = true
    }
  }

  public func switchProfile(_ profile: IOSUserProfile, pin: String? = nil) async throws -> Bool {
    guard let stored = storedConnection else { return false }
    do {
      let resp = try await apiClient.switchProfile(profileId: profile.id, pin: pin)
      var updated = stored
      updated.profileToken = resp.token
      updated.activeProfileId = profile.id
      try credentialStore.save(updated)
      self.storedConnection = updated
      self.apiClient = apiClient.withTokens(
        sessionToken: stored.sessionToken, profileToken: resp.token)
      self.currentProfile = resp.profile
      self.pinPromptProfile = nil
      await refreshCatalog()
      return true
    } catch IOSError.profilePinRequired {
      self.pinPromptProfile = profile
      return false
    }
  }

  public func refreshCatalog() async {
    guard currentProfile != nil else { return }
    do {
      async let homeReq = apiClient.getHomeCatalog()
      async let moviesReq = apiClient.getMovies()
      async let showsReq = apiClient.getShows()
      async let collReq = apiClient.getCollections()
      async let franReq = apiClient.getFranchises()

      let (home, mov, shw, coll, fran) = try await (homeReq, moviesReq, showsReq, collReq, franReq)
      self.homeCatalog = home
      self.movies = mov
      self.shows = shw
      self.collections = coll
      self.franchises = fran
      self.isOffline = false
    } catch {
      self.isOffline = true
    }
  }

  public func performSearch(query: String) async {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
      searchResults = []
      return
    }
    do {
      searchResults = try await apiClient.search(query: query)
    } catch {
      searchResults = []
    }
  }

  public func loadItemDetail(itemId: String) async {
    do {
      activeDetailItem = try await apiClient.getCatalogDetail(itemId: itemId)
    } catch {
      activeDetailItem = nil
    }
  }

  public func playItem(_ item: IOSCatalogItemSummary) async {
    guard let stored = storedConnection else { return }
    do {
      let plan = try await apiClient.getPlaybackPlan(itemId: item.id)
      self.playbackItem = item
      self.playbackPlan = plan
      self.isPlayingMedia = true

      await playbackController.play(
        item: item,
        plan: plan,
        fingerprint: stored.fingerprint,
        authorizationToken: stored.profileToken ?? stored.sessionToken,
        apiClient: apiClient
      )
    } catch {
      // Ignored
    }
  }

  public func playOnDevice(targetDevice: IOSRemotePlayerDevice, item: IOSCatalogItemSummary) async {
    let cmd = IOSRemotePlaybackCommand(
      action: "play",
      titleId: item.id,
      title: item.title,
      positionSeconds: item.positionSeconds ?? 0
    )
    try? await apiClient.sendRemotePlaybackCommand(
      targetDeviceId: targetDevice.deviceId, command: cmd)
  }

  public func refreshActivePlayers() async {
    activePlayers = (try? await apiClient.getActivePlayers()) ?? []
  }

  private func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        await refreshActivePlayers()
      }
    }
  }
}
