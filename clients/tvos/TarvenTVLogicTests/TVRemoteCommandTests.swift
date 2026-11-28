import Foundation
import Testing

struct TVRemoteCommandTests {
  @Test func commandsFromOtherDevicesControlTheOpenPlayer() {
    let media = UUID()
    #expect(
      TVRemoteCommandEffect.of(
        action: "Play", mediaId: media, positionSeconds: nil, skipSeconds: nil, position: nil,
        isPlaying: nil) == .play(media))
    #expect(
      TVRemoteCommandEffect.of(
        action: "pause", mediaId: nil, positionSeconds: nil, skipSeconds: nil, position: 1_000,
        isPlaying: true) == .togglePlayPause)
    #expect(
      TVRemoteCommandEffect.of(
        action: "pause", mediaId: nil, positionSeconds: nil, skipSeconds: nil, position: 1_000,
        isPlaying: false) == .nothing)
    #expect(
      TVRemoteCommandEffect.of(
        action: "resume", mediaId: nil, positionSeconds: nil, skipSeconds: nil, position: 1_000,
        isPlaying: false) == .togglePlayPause)
    #expect(
      TVRemoteCommandEffect.of(
        action: "seek", mediaId: nil, positionSeconds: 90, skipSeconds: nil, position: 30_000,
        isPlaying: true) == .seek(by: 60_000))
    #expect(
      TVRemoteCommandEffect.of(
        action: "skip", mediaId: nil, positionSeconds: nil, skipSeconds: -10, position: 30_000,
        isPlaying: true) == .seek(by: -10_000))
    #expect(
      TVRemoteCommandEffect.of(
        action: "skip", mediaId: nil, positionSeconds: nil, skipSeconds: 10, position: nil,
        isPlaying: nil) == .nothing)
    #expect(
      TVRemoteCommandEffect.of(
        action: "stop", mediaId: nil, positionSeconds: nil, skipSeconds: nil, position: nil,
        isPlaying: nil) == .stop)
    #expect(
      TVRemoteCommandEffect.of(
        action: "dance", mediaId: nil, positionSeconds: nil, skipSeconds: nil, position: nil,
        isPlaying: nil) == .nothing)
  }
}
