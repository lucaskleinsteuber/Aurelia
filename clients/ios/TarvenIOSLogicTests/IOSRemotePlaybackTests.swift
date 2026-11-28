import Foundation
import Testing

/// Play On from iPhone and iPad: the commands sent and received, and what the remote shows.
/// Invented devices and titles only.
@Suite struct IOSRemotePlaybackTests {
  private func command(
    _ action: String, media: UUID? = nil, position: Double? = nil, skip: Double? = nil
  ) -> IOSRemotePlaybackCommand {
    let json: [String: Any?] = [
      "commandId": UUID().uuidString, "action": action, "mediaId": media?.uuidString,
      "positionSeconds": position, "skipSeconds": skip, "createdAt": "2026-11-18T10:00:00Z",
    ]
    let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
    return try! JSONDecoder().decode(IOSRemotePlaybackCommand.self, from: data)
  }

  @Test func everyCommandTheServerSendsIsUnderstood() {
    let media = UUID()
    #expect(IOSRemoteAction(command("play", media: media)) == .play(media))
    #expect(IOSRemoteAction(command("play")) == nil)
    #expect(IOSRemoteAction(command("PAUSE")) == .pause)
    #expect(IOSRemoteAction(command("resume")) == .resume)
    #expect(IOSRemoteAction(command("stop")) == .stop)
    #expect(IOSRemoteAction(command("seek", position: 61.5)) == .seek(milliseconds: 61_500))
    #expect(IOSRemoteAction(command("seek", position: -3)) == nil)
    #expect(IOSRemoteAction(command("skip", skip: -10)) == .skip(milliseconds: -10_000))
    #expect(IOSRemoteAction(command("skip", skip: 90_000)) == nil)
    #expect(IOSRemoteAction(command("explode")) == nil)
  }

  @Test func sentCommandsCarryOnlyWhatTheirActionNeeds() throws {
    let media = UUID()
    let play =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(IOSRemoteAction.play(media).request)) as? [String: Any]
    #expect(play?["action"] as? String == "play")
    #expect(play?["mediaId"] as? String == media.uuidString)
    #expect(IOSRemoteAction.seek(milliseconds: 90_000).request.positionSeconds == 90)
    #expect(IOSRemoteAction.skip(milliseconds: 10_000).request.skipSeconds == 10)
    #expect(IOSRemoteAction.pause.request.mediaId == nil)
    #expect(IOSAPIClient.pathSegment("living/room?x") == "living%2Froom%3Fx")
  }

  @Test func theListAndRemoteSayWhatADeviceDoes() throws {
    let data = Data(
      #"{"deviceId":"tv-1","deviceName":"Living Room","clientType":"tvos","isPlaying":true,"mediaId":null,"title":"Invented Film","positionSeconds":724,"durationSeconds":5400,"isPaused":true,"lastSeen":"2026-11-18T10:00:00Z"}"#
        .utf8)
    let player = try JSONDecoder().decode(IOSRemotePlayer.self, from: data)
    #expect(player.kindTitle == "Apple TV")
    #expect(player.statusText == "Paused: Invented Film")
    #expect(IOSRemotePlaybackText.position(724, of: 5_400) == "12:04 / 1:30:00")
    #expect(IOSRemotePlaybackText.position(nil, of: nil) == nil)
  }
}
