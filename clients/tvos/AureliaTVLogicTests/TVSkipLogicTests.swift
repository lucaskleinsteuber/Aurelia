import Foundation
import Testing

@Suite("TV intro and credits skipping")
struct TVSkipLogicTests {
  private func segments(intro: (Int64, Int64)?, credits: Int64?, analyzed: Bool = true)
    -> TVMediaSegments
  {
    TVMediaSegments(
      mediaId: UUID(), analyzed: analyzed, introStartMilliseconds: intro?.0,
      introEndMilliseconds: intro?.1, creditsStartMilliseconds: credits)
  }

  @Test func introButtonShowsOnlyDuringTheIntro() {
    let value = segments(intro: (60_000, 90_000), credits: nil)
    #expect(TVSkipLogic.prompt(position: 30_000, duration: 2_700_000, segments: value) == nil)
    #expect(
      TVSkipLogic.prompt(position: 70_000, duration: 2_700_000, segments: value)
        == .intro(target: 90_000))
    #expect(TVSkipLogic.prompt(position: 89_000, duration: 2_700_000, segments: value) == nil)
  }

  @Test func creditsButtonSkipsToTheEndAndNeedsRealCredits() {
    let value = segments(intro: nil, credits: 2_600_000)
    #expect(
      TVSkipLogic.prompt(position: 2_610_000, duration: 2_700_000, segments: value)
        == .credits(target: 2_699_500))
    // Credits shorter than five seconds are not worth a button.
    let short = segments(intro: nil, credits: 2_697_000)
    #expect(TVSkipLogic.prompt(position: 2_697_500, duration: 2_700_000, segments: short) == nil)
  }

  @Test func missingOrUnanalyzedTimesOfferNothing() {
    #expect(TVSkipLogic.prompt(position: 70_000, duration: 2_700_000, segments: nil) == nil)
    let pending = segments(intro: (60_000, 90_000), credits: nil, analyzed: false)
    #expect(TVSkipLogic.prompt(position: 70_000, duration: 2_700_000, segments: pending) == nil)
  }

  @Test func serverResponseDecodes() throws {
    let id = UUID()
    let json = Data(
      """
      {"mediaId":"\(id.uuidString)","analyzed":true,"introStartMilliseconds":161000,
      "introEndMilliseconds":182000,"creditsStartMilliseconds":null,"source":"detected",
      "analysisVersion":1}
      """.utf8)
    let value = try JSONDecoder().decode(TVMediaSegments.self, from: json)
    #expect(value.mediaId == id && value.introEndMilliseconds == 182_000)
  }
}
