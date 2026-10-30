import Foundation

public struct IOSPlaybackPreferences: Codable, Equatable, Sendable {
  public static let defaultValue = IOSPlaybackPreferences()

  public var automaticResume: Bool = true
  public var automaticallyPlayNextEpisode: Bool = true
  public var defaultPlaybackRate: Double = 1.0
  public var seekInterval: Int = 10
  public var upNextCountdownSeconds: Int = 15

  public init(
    automaticResume: Bool = true,
    automaticallyPlayNextEpisode: Bool = true,
    defaultPlaybackRate: Double = 1.0,
    seekInterval: Int = 10,
    upNextCountdownSeconds: Int = 15
  ) {
    self.automaticResume = automaticResume
    self.automaticallyPlayNextEpisode = automaticallyPlayNextEpisode
    self.defaultPlaybackRate = defaultPlaybackRate
    self.seekInterval = seekInterval
    self.upNextCountdownSeconds = upNextCountdownSeconds
  }
}

public actor IOSProgressOutbox {
  private let apiClient: IOSAPIClient
  private var pendingItemId: String?
  private var pendingPositionSeconds: Double = 0
  private var pendingDurationSeconds: Double = 0
  private var pendingWatched: Bool = false
  private var isSyncing = false

  public init(apiClient: IOSAPIClient) {
    self.apiClient = apiClient
  }

  public func record(
    itemId: String, positionSeconds: Double, durationSeconds: Double, watched: Bool
  ) {
    self.pendingItemId = itemId
    self.pendingPositionSeconds = positionSeconds
    self.pendingDurationSeconds = durationSeconds
    self.pendingWatched = watched
  }

  public func flush() async {
    guard let itemId = pendingItemId, !isSyncing else { return }
    isSyncing = true
    let pos = pendingPositionSeconds
    let dur = pendingDurationSeconds
    let watched = pendingWatched

    do {
      try await apiClient.updatePlaybackProgress(
        itemId: itemId,
        positionSeconds: pos,
        durationSeconds: dur,
        watched: watched
      )
      if pendingItemId == itemId && pendingPositionSeconds == pos {
        pendingItemId = nil
      }
    } catch {
      // Keep pending for next flush attempt
    }
    isSyncing = false
  }
}
