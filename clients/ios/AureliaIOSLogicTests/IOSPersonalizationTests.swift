import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("iOS names, pictures and setup assistant")
@MainActor
struct IOSPersonalizationTests {
  private func isolatedDefaults() -> UserDefaults {
    let name = "aurelia.ios.setup.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func aConnectedAppNeverSeesTheAssistant() {
    let guide = IOSSetupGuide(defaults: isolatedDefaults(), alreadySetUp: true)
    #expect(guide.introSeen)
    #expect(!guide.isGuiding)
    #expect(!guide.tourPending)
  }

  @Test func guidanceSurvivesARestartAndFinishingStartsTheTour() {
    let defaults = isolatedDefaults()
    let guide = IOSSetupGuide(defaults: defaults, alreadySetUp: false)
    #expect(!guide.introSeen)
    guide.start()
    let restarted = IOSSetupGuide(defaults: defaults, alreadySetUp: false)
    #expect(restarted.introSeen)
    #expect(restarted.isGuiding)
    restarted.finish()
    #expect(!restarted.isGuiding)
    #expect(restarted.tourPending)
    restarted.tourShown()
    #expect(!IOSSetupGuide(defaults: defaults, alreadySetUp: false).tourPending)
  }

  @Test func skippingDropsGuidanceAndTour() {
    let guide = IOSSetupGuide(defaults: isolatedDefaults(), alreadySetUp: false)
    guide.start()
    guide.skip()
    #expect(guide.introSeen)
    #expect(!guide.isGuiding)
    #expect(!guide.tourPending)
    let other = IOSSetupGuide(defaults: isolatedDefaults(), alreadySetUp: false)
    other.skipIntroduction()
    #expect(other.introSeen)
    #expect(!other.isGuiding)
  }

  @Test func eachConnectionScreenBelongsToAStep() {
    #expect(
      IOSSetupGuide.step(connected: false, pairing: false, choosingProfile: false) == .connect)
    #expect(IOSSetupGuide.step(connected: false, pairing: true, choosingProfile: false) == .approve)
    #expect(IOSSetupGuide.step(connected: true, pairing: false, choosingProfile: true) == .profile)
    #expect(IOSSetupGuide.step(connected: true, pairing: false, choosingProfile: false) == .done)
  }

  @Test func theDownloadPageBecomesAScannableQRCode() throws {
    let image = try #require(IOSQRCode.image(for: IOSQRCode.downloadPage.absoluteString))
    #expect(image.width == image.height)
    #expect(image.width >= 210)
    #expect(IOSQRCode.downloadPage.host == "github.com")
  }

  @Test func builtInPicturesAreKnownSymbolsOnKnownPalettes() {
    #expect(IOSProfilePictures.symbols.count == 12)
    #expect(IOSProfilePictures.palettes.count == 8)
    #expect(IOSProfilePictures.parse("moon:indigo")?.symbol == "moon")
    #expect(IOSProfilePictures.parse("photo") == nil)
    #expect(IOSProfilePictures.parse("moon:gold") == nil)
    #expect(IOSProfilePictures.paletteIndex(named: "red") == 7)
    #expect(IOSAgeLimit.summary(for: 6) == "Children's profile · up to FSK 6")
    #expect(IOSAgeLimit.summary(for: nil) == nil)
  }

  @Test func photosBecomeSmallUprightJPEGsAndOtherFilesAreRefused() throws {
    #expect(IOSProfilePictures.preparedPhoto(Data([0, 1, 2])) == nil)
    let width = 2000
    let height = 1400
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let png = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let prepared = try #require(IOSProfilePictures.preparedPhoto(png as Data))
    #expect(prepared.starts(with: [0xFF, 0xD8]))
    let source = try #require(CGImageSourceCreateWithData(prepared as CFData, nil))
    let result = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(max(result.width, result.height) <= IOSProfilePictures.uploadEdge)
  }

  @Test func namesAndPicturesDecodeAndOldServersStillWork() throws {
    let user = try JSONDecoder().decode(
      IOSUser.self,
      from: Data(
        #"{"id":"00000000-0000-0000-0000-000000000001","username":"lucas","role":"owner","displayName":"Lucas","pictureKey":"star:blue","pictureRevision":3}"#
          .utf8))
    #expect(user.shownName == "Lucas")
    #expect(user.pictureRevision == 3)
    let old = try JSONDecoder().decode(
      IOSUser.self,
      from: Data(
        #"{"id":"00000000-0000-0000-0000-000000000002","username":"mia","role":"user"}"#.utf8))
    #expect(old.shownName == "mia")
    #expect(old.pictureKey == nil)
    let profile = try JSONDecoder().decode(
      IOSWatchingProfile.self,
      from: Data(
        #"{"id":"00000000-0000-0000-0000-000000000003","name":"Ben","role":"user","needsPinSetup":false,"pictureKey":"photo","pictureRevision":2,"ageLimit":0}"#
          .utf8))
    #expect(profile.pictureKey == "photo")
    #expect(profile.pictureRevision == 2)
    #expect(profile.ageLimit == 0)
  }
}
