import Foundation
import Testing

@Suite("iPhone and iPad screen time of children's profiles")
struct IOSScreenTimeTests {
  private let utc = TimeZone(identifier: "UTC")!

  private func status(_ state: IOSScreenTimeState, _ reason: IOSScreenTimeReason = .bedtime)
    -> IOSScreenTimeStatus
  {
    IOSScreenTimeStatus(
      state: state, reason: reason, watchedMinutesToday: 60, limitMinutes: 60,
      opensAt: "2027-11-10T07:00:00+00:00", lockScope: "wholeProfile", oneMoreTitleAvailable: false)
  }

  @Test func goodNightNamesTheProfileAndWhenAureliaOpens() {
    let night = IOSScreenTimeText.goodNight(status(.closed), name: "Robin", timeZone: utc)
    #expect(night.title == "Good night, Robin")
    #expect(night.text == "See you at 07:00.")
    let limit = IOSScreenTimeText.goodNight(status(.closed, .limit), name: "Robin", timeZone: utc)
    #expect(limit.title == "That's all for today, Robin")
    #expect(limit.text == "See you tomorrow at 07:00.")
  }

  @Test func onlyAnOpenProfileGetsTheNextTitle() {
    #expect(!status(.open).noMoreTitles)
    #expect(status(.lastTitle).noMoreTitles)
    #expect(status(.closed).noMoreTitles)
    #expect(status(.closed).closesWholeProfile)
    #expect(IOSScreenTimeText.refusesTitle("screen_time_bedtime"))
    #expect(!IOSScreenTimeText.refusesTitle("profile_screen_time_closed"))
  }

  @Test func aClosedProfileEndsTheSessionAndShowsInThePicker() {
    let closed = IOSCoreError.server(
      status: 403, code: "profile_screen_time_closed", message: nil, retryAfter: nil)
    #expect(closed.endsSession)
    let bedtime = IOSCoreError.server(
      status: 403, code: "screen_time_bedtime", message: nil, retryAfter: nil)
    #expect(!bedtime.endsSession)
    #expect(
      IOSScreenTimeText.closedLabel("2027-11-10T07:30:00Z", timeZone: utc)
        == "Good night · back at 07:30")
    #expect(IOSScreenTimeText.closedLabel(nil) == nil)
  }

  @Test func ticketsAndProfilesFromANewerServerStillDecode() throws {
    let json = """
      {"state":"somethingNew","reason":"other","watchedMinutesToday":3,"lockScope":"elsewhere",
       "oneMoreTitleAvailable":true}
      """
    let decoded = try JSONDecoder().decode(IOSScreenTimeStatus.self, from: Data(json.utf8))
    #expect(decoded.state == .open)
    #expect(!decoded.closesWholeProfile)
    let profile = try JSONDecoder().decode(
      IOSWatchingProfile.self,
      from: Data(
        """
        {"id":"7a1d2c3b-0000-4000-8000-0000000000aa","name":"Robin","role":"user",
         "needsPinSetup":false,"closedUntil":"2027-11-10T07:00:00Z"}
        """.utf8))
    #expect(profile.closedUntil == "2027-11-10T07:00:00Z")
  }
}
