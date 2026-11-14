import Foundation

/// Smart Home ("automation-v1") on Apple TV: the player tells the server at once that a title
/// plays, pauses, buffers or ended, so a light in the living room follows the picture. Copied
/// from the iPhone app, not shared. The TV has no Smart Home settings; those are on the owner's
/// Mac, iPhone, Linux app or in the browser.
enum TVAutomationPlaybackState {
  static func state(wantsPlayback: Bool, isPlaying: Bool, finished: Bool) -> String {
    if finished { return "finished" }
    if !wantsPlayback { return "paused" }
    return isPlaying ? "playing" : "buffering"
  }

  /// Equal states in a row are sent once; after the end only playing again counts.
  static func shouldReport(last: String?, next: String) -> Bool {
    guard next != last else { return false }
    if last == "finished", next != "playing" { return false }
    return true
  }
}

extension TVAPIClient {
  /// The player's state, the moment it changes (server 2.16.0). Playback never waits for it.
  func reportPlaybackState(ticket: UUID, state: String, positionSeconds: Double) async throws {
    struct Body: Encodable {
      let state: String
      let positionSeconds: Double
    }
    try await sendPlaybackState(
      path: "/api/v1/playback/\(ticket.uuidString.lowercased())/state",
      body: JSONEncoder().encode(Body(state: state, positionSeconds: positionSeconds)))
  }
}

/// What a command from another device or Siri does to the open player.
enum TVRemoteCommandEffect: Equatable {
  case play(UUID)
  case stop
  case togglePlayPause
  case seek(by: Int64)
  case nothing

  /// `position` and `isPlaying` describe the open player; without one only play and stop matter.
  static func of(
    action: String, mediaId: UUID?, positionSeconds: Double?, skipSeconds: Double?,
    position: Int64?, isPlaying: Bool?
  ) -> TVRemoteCommandEffect {
    switch action.lowercased() {
    case "play": return mediaId.map(TVRemoteCommandEffect.play) ?? (isPlaying == false ? .togglePlayPause : .nothing)
    case "stop": return .stop
    case "pause": return isPlaying == true ? .togglePlayPause : .nothing
    case "resume": return isPlaying == false ? .togglePlayPause : .nothing
    case "seek":
      guard let position, let target = positionSeconds, target.isFinite, target >= 0 else { return .nothing }
      return .seek(by: Int64(target * 1_000) - position)
    case "skip":
      guard position != nil, let skip = skipSeconds, skip.isFinite, abs(skip) <= 3_600 else { return .nothing }
      return .seek(by: Int64(skip * 1_000))
    default: return .nothing
    }
  }
}
