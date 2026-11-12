import XCTest

@testable import Aurelia

/// What the Mac shows for a children's profile's screen time (docs/SCREEN_TIME.md).
final class ScreenTimeTextTests: XCTestCase {
  private let utc = TimeZone(identifier: "UTC")!

  private func status(_ state: ScreenTimeState, _ reason: ScreenTimeReason = .bedtime)
    -> ScreenTimeStatus
  {
    ScreenTimeStatus(
      state: state, reason: reason, watchedMinutesToday: 60, limitMinutes: 60,
      remainingMinutes: 0, closesAt: "2027-11-09T19:30:00+00:00", titleEndsBy: nil,
      opensAt: "2027-11-10T07:00:00+00:00", lockScope: .wholeProfile, ending: .finishTitle,
      oneMoreTitleAvailable: false)
  }

  func testGoodNightNamesTheProfileAndWhenAureliaOpens() {
    let night = ScreenTimeText.goodNight(status(.closed), name: "Robin", timeZone: utc)
    XCTAssertEqual(night.title, "Good night, Robin")
    XCTAssertEqual(night.text, "See you at 07:00.")
    let limit = ScreenTimeText.goodNight(status(.closed, .limit), name: "Robin", timeZone: utc)
    XCTAssertEqual(limit.title, "That's all for today, Robin")
    XCTAssertEqual(limit.text, "See you tomorrow at 07:00.")
    XCTAssertEqual(ScreenTimeText.goodNight(nil, name: "").title, "Good night")
  }

  func testOnlyAnOpenProfileGetsTheNextTitle() {
    XCTAssertFalse(status(.open).noMoreTitles)
    XCTAssertTrue(status(.lastTitle).noMoreTitles)
    XCTAssertTrue(status(.closed).noMoreTitles)
    XCTAssertTrue(ScreenTimeText.isScreenTimeCode("screen_time_limit"))
    XCTAssertFalse(ScreenTimeText.isScreenTimeCode("media_not_found"))
    XCTAssertFalse(ScreenTimeText.isScreenTimeCode(nil))
  }

  func testPickerAndTodayLines() {
    XCTAssertEqual(
      ScreenTimeText.closedLabel("2027-11-10T07:30:00Z", timeZone: utc), "Good night · back at 07:30")
    XCTAssertNil(ScreenTimeText.closedLabel(nil))
    XCTAssertEqual(
      ScreenTimeText.todaySummary(status(.closed, .limit), timeZone: utc),
      "60 of 60 min watched today · Time is up, opens at 07:00")
  }

  func testStatusFromANewerServerStillDecodes() throws {
    let json = """
      {"state":"somethingNew","reason":"other","watchedMinutesToday":3,"lockScope":"elsewhere",
       "ending":"later","oneMoreTitleAvailable":true}
      """
    let decoded = try JSONDecoder().decode(ScreenTimeStatus.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.state, .open)
    XCTAssertEqual(decoded.lockScope, .playbackOnly)
    XCTAssertTrue(decoded.oneMoreTitleAvailable)
  }

  func testEditedRulesAreCheckedBeforeSaving() {
    var rules = ScreenTimeRules.default
    XCTAssertNil(ScreenTimeText.problem(rules))
    rules.schoolNight.bedtime = "25:00"
    XCTAssertEqual(ScreenTimeText.problem(rules), "Enter the school-night bedtime like 19:30.")
    rules.schoolNight.bedtime = nil
    rules.weekend.dailyLimitMinutes = 2
    XCTAssertEqual(ScreenTimeText.problem(rules), "The weekend daily limit is 5 to 1440 minutes.")
  }
}
