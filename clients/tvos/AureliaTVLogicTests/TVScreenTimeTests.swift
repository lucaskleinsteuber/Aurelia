import Foundation
import Testing

@Suite("Apple TV screen time of children's profiles")
struct TVScreenTimeTests {
  private let utc = TimeZone(identifier: "UTC")!

  private func status(_ state: TVScreenTimeState, _ reason: TVScreenTimeReason = .bedtime)
    -> TVScreenTimeStatus
  {
    TVScreenTimeStatus(
      state: state, reason: reason, watchedMinutesToday: 60, limitMinutes: 60,
      opensAt: "2027-11-10T07:00:00+00:00", lockScope: "wholeProfile", oneMoreTitleAvailable: false)
  }

  @Test func goodNightNamesTheProfileAndWhenAureliaOpens() {
    let night = TVScreenTimeText.goodNight(status(.closed), name: "Robin", timeZone: utc)
    #expect(night.title == "Good night, Robin")
    #expect(night.text == "See you at 07:00.")
    let limit = TVScreenTimeText.goodNight(status(.closed, .limit), name: "Robin", timeZone: utc)
    #expect(limit.title == "That's all for today, Robin")
    #expect(limit.text == "See you tomorrow at 07:00.")
  }

  @Test func onlyAnOpenProfileGetsTheNextTitle() {
    #expect(!status(.open).noMoreTitles)
    #expect(status(.lastTitle).noMoreTitles)
    #expect(status(.closed).noMoreTitles)
    #expect(status(.closed).closesWholeProfile)
    #expect(TVScreenTimeText.refusesTitle("screen_time_bedtime"))
    #expect(!TVScreenTimeText.refusesTitle("profile_screen_time_closed"))
  }

  @Test func aClosedProfileEndsTheSessionAndShowsInThePicker() {
    let closed = TVCoreError.server(
      status: 403, code: "profile_screen_time_closed", message: nil, retryAfter: nil)
    #expect(closed.endsSession)
    let bedtime = TVCoreError.server(
      status: 403, code: "screen_time_bedtime", message: nil, retryAfter: nil)
    #expect(!bedtime.endsSession)
    #expect(
      TVScreenTimeText.closedLabel("2027-11-10T07:30:00Z", timeZone: utc)
        == "Good night · back at 07:30")
    #expect(TVScreenTimeText.closedLabel(nil) == nil)
  }

  @Test func ticketsAndProfilesFromANewerServerStillDecode() throws {
    let json = """
      {"state":"somethingNew","reason":"other","watchedMinutesToday":3,"lockScope":"elsewhere",
       "oneMoreTitleAvailable":true}
      """
    let decoded = try JSONDecoder().decode(TVScreenTimeStatus.self, from: Data(json.utf8))
    #expect(decoded.state == .open)
    #expect(!decoded.closesWholeProfile)
    let profile = try JSONDecoder().decode(
      TVWatchingProfile.self,
      from: Data(
        """
        {"id":"7a1d2c3b-0000-4000-8000-0000000000aa","name":"Robin","role":"user",
         "needsPinSetup":false,"closedUntil":"2027-11-10T07:00:00Z"}
        """.utf8))
    #expect(profile.closedUntil == "2027-11-10T07:00:00Z")
  }
}
