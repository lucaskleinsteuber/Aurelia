import Foundation

struct TVPlaybackTrackPreference: Codable, Equatable, Sendable {
  let language: String?
  let title: String

  init(language: String?, title: String) {
    self.language = language.map {
      String($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(32))
    }.flatMap { $0.isEmpty ? nil : $0 }
    self.title = String(
      title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(256))
  }
}

struct TVPlaybackTrack: Identifiable, Equatable, Sendable {
  let id: Int32
  let title: String

  var preference: TVPlaybackTrackPreference {
    var language: String?
    if let open = title.lastIndex(of: "["), let close = title[open...].firstIndex(of: "]") {
      language = String(title[title.index(after: open)..<close])
    }
    return TVPlaybackTrackPreference(language: language, title: title)
  }

  static func matching(
    _ preference: TVPlaybackTrackPreference?, in tracks: [Self]
  ) -> Self? {
    guard let preference else { return nil }
    if let exact = tracks.first(where: { $0.preference.title == preference.title }) { return exact }
    guard let language = preference.language else { return nil }
    return tracks.first(where: { $0.preference.language == language })
  }
}

struct TVPlaybackPreferences: Codable, Equatable, Sendable {
  static let supportedRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
  static let defaultValue = Self()

  var automaticResume = true
  var automaticallyPlayNextEpisode = true
  var defaultPlaybackRate: Double = 1
  var controlsDelay: TimeInterval = 4
  var seekInterval = 10
  var preferredAudioTrack: TVPlaybackTrackPreference?
  // nil explicitly means Off, matching the default on the Mac.
  var preferredSubtitleTrack: TVPlaybackTrackPreference?

  var normalized: Self {
    var value = self
    if !Self.supportedRates.contains(value.defaultPlaybackRate) { value.defaultPlaybackRate = 1 }
    value.controlsDelay = value.controlsDelay.isFinite ? min(max(value.controlsDelay, 1), 10) : 4
    value.seekInterval = min(max(value.seekInterval, 5), 60)
    value.preferredAudioTrack = value.preferredAudioTrack.map {
      TVPlaybackTrackPreference(language: $0.language, title: $0.title)
    }
    value.preferredSubtitleTrack = value.preferredSubtitleTrack.map {
      TVPlaybackTrackPreference(language: $0.language, title: $0.title)
    }
    return value
  }

  init() {}

  private enum CodingKeys: String, CodingKey {
    case automaticResume, automaticallyPlayNextEpisode, defaultPlaybackRate, controlsDelay
    case seekInterval, preferredAudioTrack, preferredSubtitleTrack
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    automaticResume = try values.decodeIfPresent(Bool.self, forKey: .automaticResume) ?? true
    automaticallyPlayNextEpisode =
      try values.decodeIfPresent(Bool.self, forKey: .automaticallyPlayNextEpisode) ?? true
    defaultPlaybackRate = try values.decodeIfPresent(Double.self, forKey: .defaultPlaybackRate) ?? 1
    controlsDelay = try values.decodeIfPresent(Double.self, forKey: .controlsDelay) ?? 4
    seekInterval = try values.decodeIfPresent(Int.self, forKey: .seekInterval) ?? 10
    preferredAudioTrack = try values.decodeIfPresent(
      TVPlaybackTrackPreference.self, forKey: .preferredAudioTrack)
    preferredSubtitleTrack = try values.decodeIfPresent(
      TVPlaybackTrackPreference.self, forKey: .preferredSubtitleTrack)
  }
}

@MainActor
final class TVPlaybackPreferencesStore {
  static let shared = TVPlaybackPreferencesStore()
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func preferences(serverID: UUID, profileID: UUID) -> TVPlaybackPreferences {
    guard let data = defaults.data(forKey: key(serverID: serverID, profileID: profileID)),
      data.count <= 4_096,
      let value = try? JSONDecoder().decode(TVPlaybackPreferences.self, from: data)
    else { return .defaultValue }
    return value.normalized
  }

  @discardableResult
  func save(_ value: TVPlaybackPreferences, serverID: UUID, profileID: UUID) -> Bool {
    guard let data = try? JSONEncoder().encode(value.normalized), data.count <= 4_096 else {
      return false
    }
    let storageKey = key(serverID: serverID, profileID: profileID)
    defaults.set(data, forKey: storageKey)
    return defaults.data(forKey: storageKey) == data
  }

  private func key(serverID: UUID, profileID: UUID) -> String {
    "tv.playback.preferences.v1.\(serverID.uuidString).\(profileID.uuidString)"
  }
}
