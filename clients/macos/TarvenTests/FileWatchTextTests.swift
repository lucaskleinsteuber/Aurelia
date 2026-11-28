import Foundation
import XCTest

@testable import Tarven

/// The file watch on the Mac ("file-checks-v1"): the words the settings and Library Health show.
final class FileWatchTextTests: XCTestCase {
  private func settings(
    enabled: Bool = true, total: Int = 120, pending: Int = 0, problems: Int = 0,
    paused: Bool = false,
    remaining: Int? = nil
  ) -> FileCheckSettings {
    FileCheckSettings(
      enabled: enabled, depth: "container", recheckDays: 90, canInspect: true, totalCount: total,
      checkedCount: total - pending, pendingCount: pending, problemCount: problems,
      running: pending > 0,
      pausedForPlayback: paused, estimatedSecondsRemaining: remaining)
  }

  func testTheStatusSaysOffDoneOrHowFarTheWatchIs() {
    XCTAssertEqual(FileWatchText.status(settings(enabled: false, pending: 120)), "Off")
    XCTAssertEqual(FileWatchText.status(settings()), "All 120 files examined")
    XCTAssertEqual(
      FileWatchText.status(settings(total: 1, problems: 1)), "All 1 file examined · 1 problem")
    XCTAssertEqual(
      FileWatchText.status(settings(pending: 80, problems: 2, paused: true, remaining: 12_000)),
      "40 of 120 files · 2 problems · paused while someone watches · About 3 h 20 min left")
    XCTAssertEqual(FileWatchText.remaining(3 * 86_400), "About 3 days left")
    XCTAssertEqual(settings(pending: 30).progress, 0.75)
  }

  func testAProblemSaysWhatItIsAndWhere() throws {
    XCTAssertEqual(FileWatchText.problemTitle("changedUnexpectedly"), "Changed by Itself")
    XCTAssertEqual(FileWatchText.clock(3730), "1:02:10")
    XCTAssertEqual(FileWatchText.clock(245), "4:05")
    let json = """
      {"mediaId":"6f9619ff-8b86-d011-b42d-00c04fc964ff","title":"Invented","kind":"movie","fileName":"Invented.mkv",
      "libraryName":"Movies","state":"damaged","errorCount":3,"problemAtSeconds":3730,"durationSeconds":6300,
      "detail":"3 errors","depth":"container","checkedAt":"2026-11-15T20:00:00Z","ignored":false}
      """
    let problem = try JSONDecoder().decode(FileProblemSummary.self, from: Data(json.utf8))
    XCTAssertEqual(FileWatchText.facts(problem), "At about 1:02:10 of 1:45:00 · 3 errors · Movies")
  }

  func testADriveShowsWhatItMeasured() throws {
    let json = """
      {"drives":[{"name":"WD Red","libraries":["Movies"],"state":"warning","temperatureCelsius":35.4,
      "powerOnHours":10000,"badSectors":12,"detail":null}],"checkedAt":null}
      """
    let answer = try JSONDecoder().decode(DriveHealthResponse.self, from: Data(json.utf8))
    XCTAssertEqual(FileWatchText.driveTitle(answer.drives[0].state), "Warning")
    XCTAssertEqual(
      FileWatchText.driveFacts(answer.drives[0]), "35 °C · 10,000 hours · 12 bad sectors")
  }

  func testOnlyAServerWithTheWatchOffersItsTabs() {
    XCTAssertFalse(LibraryHealthTab.available(fileChecks: false).contains(.files))
    XCTAssertEqual(LibraryHealthTab.available(fileChecks: true).suffix(2), [.files, .drives])
  }

  func testSavingLeavesOutWhatStaysTheSame() throws {
    // Sorted keys: JSONEncoder's order of keys is not fixed, so the text alone was a flaky check.
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let body = try encoder.encode(UpdateFileCheckSettingsRequest(enabled: true, recheckDays: 30))
    XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"enabled":true,"recheckDays":30}"#)
  }
}
