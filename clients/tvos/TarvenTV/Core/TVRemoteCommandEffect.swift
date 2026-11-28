import Foundation

/// What a command from another device (Play On) does to the open player.
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
    case "play":
      return mediaId.map(TVRemoteCommandEffect.play)
        ?? (isPlaying == false ? .togglePlayPause : .nothing)
    case "stop": return .stop
    case "pause": return isPlaying == true ? .togglePlayPause : .nothing
    case "resume": return isPlaying == false ? .togglePlayPause : .nothing
    case "seek":
      guard let position, let target = positionSeconds, target.isFinite, target >= 0 else {
        return .nothing
      }
      return .seek(by: Int64(target * 1_000) - position)
    case "skip":
      guard position != nil, let skip = skipSeconds, skip.isFinite, abs(skip) <= 3_600 else {
        return .nothing
      }
      return .seek(by: Int64(skip * 1_000))
    default: return .nothing
    }
  }
}
