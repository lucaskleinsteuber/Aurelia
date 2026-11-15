import Foundation
import Testing

/// The file watch on iPhone and iPad ("file-checks-v1"): the same words as on the Mac.
struct IOSFileWatchTests {
  private func settings(
    enabled: Bool = true, total: Int = 120, pending: Int = 0, problems: Int = 0, paused: Bool = false,
    remaining: Int? = nil
  ) -> IOSFileCheckSettings {
    IOSFileCheckSettings(
      enabled: enabled, depth: "container", recheckDays: 90, canInspect: true, totalCount: total,
      checkedCount: total - pending, pendingCount: pending, problemCount: problems, running: pending > 0,
      pausedForPlayback: paused, estimatedSecondsRemaining: remaining)
  }

  @Test func theStatusSaysOffDoneOrHowFarTheWatchIs() {
    #expect(IOSFileWatchText.status(settings(enabled: false, pending: 120)) == "Off")
    #expect(IOSFileWatchText.status(settings()) == "All 120 files examined")
    #expect(
      IOSFileWatchText.status(settings(pending: 80, problems: 2, paused: true, remaining: 12_000))
        == "40 of 120 files · 2 problems · paused while someone watches · About 3 h 20 min left")
    #expect(settings(pending: 30).progress == 0.75)
  }

  @Test func problemsAndDrivesDecodeAndSayWhatTheyAre() throws {
    let problem = try JSONDecoder().decode(
      IOSFileProblem.self,
      from: Data(
        """
        {"mediaId":"6f9619ff-8b86-d011-b42d-00c04fc964ff","title":"Invented","kind":"movie","fileName":"Invented.mkv",
        "libraryName":"Movies","state":"unreadable","errorCount":1,"problemAtSeconds":245,"durationSeconds":null,
        "detail":"The drive could not read the file","depth":"read","checkedAt":"2026-11-15T20:00:00Z","ignored":false}
        """.utf8))
    #expect(IOSFileWatchText.problemTitle(problem.state) == "Unreadable")
    #expect(IOSFileWatchText.facts(problem) == "At about 4:05 · Movies")
    let answer = try JSONDecoder().decode(
      IOSDriveHealthResponse.self,
      from: Data(
        #"{"drives":[{"name":"SSD","libraries":["Series"],"state":"good","temperatureCelsius":null,"powerOnHours":900,"badSectors":0,"detail":null}],"checkedAt":"2026-11-15T20:00:00Z"}"#
          .utf8))
    #expect(IOSFileWatchText.driveFacts(answer.drives[0]) == "900 hours")
    #expect(IOSFileWatchText.driveTitle(answer.drives[0].state) == "Good")
  }
}
