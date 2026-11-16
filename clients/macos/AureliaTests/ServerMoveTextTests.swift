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

/// What Set Up This Mac sends when it takes over another server.
@MainActor
struct SetupMovePlanTests {
  private func location(_ suggestions: [(String, Int)]) -> SetupMoveStatus.Location {
    SetupMoveStatus.Location(
      id: UUID(), name: "Movies", oldPath: "/media/usb/Movies", sampled: 200,
      suggestions: suggestions.map { StorageRelocationSuggestion(path: $0.0, matched: $0.1) })
  }

  @Test func theBestMatchingFolderIsPreselectedAndUnmatchedOnesWaitForLater() {
    let found = location([("/srv/other", 3), ("/mnt/ssd/Movies", 198)])
    let missing = location([("/home/someone", 0)])
    let choices = SetupMovePlan.initialChoices(for: [found, missing])
    #expect(choices[found.id] == "/mnt/ssd/Movies")
    #expect(choices[missing.id] == nil)
    let mappings = SetupMovePlan.mappings(
      for: [found, missing], choices: choices.merging([missing.id: "  "]) { $1 })
    #expect(
      mappings == [
        SetupMoveMapping(id: found.id, path: "/mnt/ssd/Movies"),
        SetupMoveMapping(id: missing.id, path: nil),
      ])
  }

  @Test func typedAddressesGetHTTPSAndTheServerPort() {
    #expect(SetupMovePlan.normalizedAddress("minipc.local") == "https://minipc.local:43111")
    #expect(SetupMovePlan.normalizedAddress(" 192.168.1.20 ") == "https://192.168.1.20:43111")
    #expect(
      SetupMovePlan.normalizedAddress("https://minipc.local:8443") == "https://minipc.local:8443")
  }

  @Test func statusDecodesWithoutLocationsAndFailuresReadPlainly() throws {
    let idle = try JSONDecoder().decode(SetupMoveStatus.self, from: Data(#"{"state":"idle"}"#.utf8))
    #expect(idle.locations == nil)
    #expect(!idle.isWorking)
    #expect(
      SetupMovePlan.failureText("move_file_invalid", message: nil)
        == "This is a backup, not a moving file. Make a moving file on the old server.")
    #expect(SetupMovePlan.failureText("other", message: "Server text") == "Server text")
    let progress = SetupMoveStatus.Progress(received: 50, expected: 200)
    #expect(progress.fraction == 0.25)
  }
}
