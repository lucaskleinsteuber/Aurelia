import Foundation
import Testing

@testable import Aurelia

/// The words the move and Storage Location Moved sheets show.
@MainActor
struct ServerMoveTextTests {
  @Test func matchCountsReadAsSentences() {
    #expect(ServerMoveText.match(412, of: 415) == "412 of 415 sample files found")
    #expect(ServerMoveText.match(415, of: 415) == "All 415 sample files found")
    #expect(ServerMoveText.match(0, of: 200) == "None of the 200 sample files found")
    #expect(ServerMoveText.match(0, of: 0) == "No sample files to compare")
  }

  @Test func theCountdownStopsWhenTheCodeRunsOut() {
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(ServerMoveText.remaining(until: now.addingTimeInterval(872), now: now) == "14:32 left")
    #expect(ServerMoveText.remaining(until: now.addingTimeInterval(0.5), now: now) == nil)
    #expect(ServerMoveText.remaining(until: now.addingTimeInterval(-3), now: now) == nil)
  }

  @Test func codesAreGroupedForReading() {
    #expect(ServerMoveText.grouped("abcdefghjkmn") == "ABCD-EFGH-JKMN")
    #expect(ServerMoveText.grouped("ABCD-EFGH-JKMN") == "ABCD-EFGH-JKMN")
    #expect(ServerMoveText.grouped("abcdef") == "ABCD-EF")
  }

  @Test func statusDecodesAndSaysWhereTheServerWent() throws {
    let json = #"""
      {"state":"moved","method":"network","movedAt":"2026-11-16T10:00:00Z",
       "movedTo":{"serverId":"6e1b7a52-2d0a-4c3e-9b57-1f2a3c4d5e6f","name":"Mini PC",
                  "addresses":["https://192.168.1.40:43111"]}}
      """#
    let status = try JSONDecoder().decode(ServerMoveStatusResponse.self, from: Data(json.utf8))
    #expect(status.isMoved)
    #expect(!status.isWaiting)
    #expect(
      ServerMoveText.movedSummary(status)
        == "This server moved to “Mini PC” at 192.168.1.40. Devices follow it there by themselves.")
    let waiting = try JSONDecoder().decode(
      ServerMoveStatusResponse.self, from: Data(#"{"state":"transferring"}"#.utf8))
    #expect(waiting.isWaiting)
  }
}
