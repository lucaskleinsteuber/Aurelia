import CoreGraphics
import Foundation
import Testing

@Suite("Apple TV names, pictures and setup assistant")
@MainActor
struct TVPersonalizationTests {
  private func isolatedDefaults() -> UserDefaults {
    let name = "aurelia.tv.setup.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func aConnectedAppNeverSeesTheAssistant() {
    let guide = TVSetupGuide(defaults: isolatedDefaults(), alreadySetUp: true)
    #expect(guide.introSeen)
    #expect(!guide.isGuiding)
    #expect(!guide.tourPending)
  }

  @Test func guidanceSurvivesARestartAndFinishingStartsTheTour() {
    let defaults = isolatedDefaults()
    let guide = TVSetupGuide(defaults: defaults, alreadySetUp: false)
    #expect(!guide.introSeen)
    guide.start()
    let restarted = TVSetupGuide(defaults: defaults, alreadySetUp: false)
    #expect(restarted.introSeen)
    #expect(restarted.isGuiding)
    restarted.finish()
    #expect(!restarted.isGuiding)
    #expect(restarted.tourPending)
    restarted.tourShown()
    #expect(!TVSetupGuide(defaults: defaults, alreadySetUp: false).tourPending)
  }

  @Test func skippingDropsGuidanceAndTour() {
    let guide = TVSetupGuide(defaults: isolatedDefaults(), alreadySetUp: false)
    guide.start()
    guide.skip()
    #expect(guide.introSeen)
    #expect(!guide.isGuiding)
    #expect(!guide.tourPending)
    let other = TVSetupGuide(defaults: isolatedDefaults(), alreadySetUp: false)
    other.skipIntroduction()
    #expect(other.introSeen)
    #expect(!other.isGuiding)
  }

  @Test func eachConnectionScreenBelongsToAStep() {
    #expect(TVSetupGuide.step(connected: false, pairing: false, choosingProfile: false) == .connect)
    #expect(TVSetupGuide.step(connected: false, pairing: true, choosingProfile: false) == .approve)
    #expect(TVSetupGuide.step(connected: true, pairing: false, choosingProfile: true) == .profile)
    #expect(TVSetupGuide.step(connected: true, pairing: false, choosingProfile: false) == .done)
  }

  @Test func theDownloadPageBecomesAScannableQRCode() throws {
    let image = try #require(TVQRCode.image(for: TVQRCode.downloadPage.absoluteString))
    #expect(image.width == image.height)
    #expect(image.width >= 210)
    #expect(TVQRCode.downloadPage.host == "github.com")
  }

  @Test func builtInPicturesAreKnownSymbolsOnKnownPalettes() {
    #expect(TVProfilePictures.symbols.count == 12)
    #expect(TVProfilePictures.palettes.count == 8)
    #expect(TVProfilePictures.parse("moon:indigo")?.symbol == "moon")
    #expect(TVProfilePictures.parse("photo") == nil)
    #expect(TVProfilePictures.parse("moon:gold") == nil)
    #expect(TVProfilePictures.paletteIndex(named: "red") == 7)
    #expect(TVAgeLimit.summary(for: 6) == "Children's profile · up to FSK 6")
    #expect(TVAgeLimit.summary(for: nil) == nil)
  }

  @Test func namesAndPicturesDecodeAndOldServersStillWork() throws {
    let user = try JSONDecoder().decode(
      TVUser.self,
      from: Data(
        #"{"id":"00000000-0000-0000-0000-000000000001","username":"lucas","role":"owner","displayName":"Lucas","pictureKey":"star:blue","pictureRevision":3}"#
          .utf8))
    #expect(user.shownName == "Lucas")
    #expect(user.pictureRevision == 3)
    let old = try JSONDecoder().decode(
      TVUser.self,
      from: Data(
        #"{"id":"00000000-0000-0000-0000-000000000002","username":"mia","role":"user"}"#.utf8))
    #expect(old.shownName == "mia")
    #expect(old.pictureKey == nil)
    let profile = try JSONDecoder().decode(
      TVWatchingProfile.self,
      from: Data(
        #"{"id":"00000000-0000-0000-0000-000000000003","name":"Ben","role":"user","needsPinSetup":false,"pictureKey":"photo","pictureRevision":2,"ageLimit":0}"#
          .utf8))
    #expect(profile.pictureKey == "photo")
    #expect(profile.pictureRevision == 2)
    #expect(profile.ageLimit == 0)
  }
}
