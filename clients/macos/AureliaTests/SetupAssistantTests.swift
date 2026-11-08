import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Aurelia

@MainActor
struct SetupAssistantTests {
  private func freshDefaults() -> UserDefaults {
    let name = "AureliaSetupAssistantTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func aMacThatWasSetUpNeverSeesTheAssistant() {
    let defaults = freshDefaults()
    let guide = SetupGuide(defaults: defaults, alreadySetUp: true)
    #expect(guide.introSeen)
    #expect(!guide.isGuiding)
    #expect(!guide.tourPending)
  }

  @Test func answersAndGuidanceSurviveARestartAndFinishingStartsTheTour() {
    let defaults = freshDefaults()
    let guide = SetupGuide(defaults: defaults, alreadySetUp: false)
    #expect(!guide.introSeen)
    guide.audience = .severalPeople
    guide.devices = [.appleTV, .webBrowser]
    guide.start()
    #expect(guide.isGuiding)
    #expect(guide.steps(hosting: true) == [.choose, .secure, .pin, .media, .people, .done])
    #expect(guide.steps(hosting: false) == [.choose, .connect, .profile, .done])

    let restarted = SetupGuide(defaults: defaults, alreadySetUp: false)
    #expect(restarted.introSeen)
    #expect(restarted.isGuiding)
    #expect(restarted.audience == .severalPeople)
    #expect(restarted.devices == [.appleTV, .webBrowser])
    restarted.finish()
    #expect(!restarted.isGuiding)
    #expect(restarted.tourPending)
    restarted.tourShown()
    #expect(!SetupGuide(defaults: defaults, alreadySetUp: false).tourPending)
  }

  @Test func justMeSkipsThePeopleStepAndSkippingDropsGuidanceAndTour() {
    let guide = SetupGuide(defaults: freshDefaults(), alreadySetUp: false)
    guide.audience = .justMe
    #expect(guide.steps(hosting: true) == [.choose, .secure, .pin, .media, .done])
    guide.start()
    guide.skip()
    #expect(guide.introSeen)
    #expect(!guide.isGuiding)
    #expect(!guide.tourPending)
    guide.requestTour()
    #expect(guide.tourPending)
  }

  @Test func iKnowAureliaLeadsToThePlainWelcomeChoice() {
    let guide = SetupGuide(defaults: freshDefaults(), alreadySetUp: false)
    guide.skipIntroduction()
    #expect(guide.introSeen)
    #expect(!guide.isGuiding)
  }

  @Test func theTourNoteStaysBesideTheLitPlaceAndInsideTheWindow() {
    let window = CGSize(width: 1200, height: 800)
    let right = TourBubblePlacement.origin(
      hole: CGRect(x: 20, y: 100, width: 200, height: 300), in: window)
    #expect(right == CGPoint(x: 236, y: 100))
    let below = TourBubblePlacement.origin(
      hole: CGRect(x: 900, y: 100, width: 280, height: 100), in: window)
    #expect(below.y == 216)
    #expect(below.x + TourBubblePlacement.width <= window.width - 16)
    let centered = TourBubblePlacement.origin(hole: nil, in: window)
    #expect(centered.x == CGFloat(440))
  }
}

struct ProfilePersonalizationTests {
  @Test func builtInPicturesAreKnownSymbolsOnKnownPalettes() {
    #expect(ProfilePictureCatalog.symbols.count == 12)
    #expect(ProfilePictureCatalog.palettes.count == 8)
    let key = ProfilePictureCatalog.builtin(symbol: "rocket", palette: "teal")
    #expect(key == "rocket:teal")
    #expect(ProfilePictureCatalog.parse(key)?.symbol == "rocket")
    #expect(ProfilePictureCatalog.parse(key)?.palette == "teal")
    #expect(ProfilePictureCatalog.parse("photo") == nil)
    #expect(ProfilePictureCatalog.parse("unicorn:teal") == nil)
    #expect(ProfilePictureCatalog.parse("star:gold") == nil)
    #expect(ProfilePictureCatalog.parse(nil) == nil)
    for symbol in ProfilePictureCatalog.symbols where symbol != "rocket" {
      #expect(
        NSImage(
          systemSymbolName: ProfilePictureCatalog.systemImage(for: symbol),
          accessibilityDescription: nil) != nil, "\(symbol)")
    }
  }

  @Test func photosAreScaledDownToUprightJPEGsAndOtherFilesAreRefused() throws {
    #expect(ProfilePictureCatalog.preparedPhoto(Data([1, 2, 3])) == nil)
    let image = NSImage(size: NSSize(width: 2400, height: 1600))
    image.lockFocus()
    NSColor.systemPink.setFill()
    NSRect(x: 0, y: 0, width: 2400, height: 1600).fill()
    image.unlockFocus()
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(
      NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    let prepared = try #require(ProfilePictureCatalog.preparedPhoto(png))
    #expect(prepared.starts(with: [0xFF, 0xD8]))
    let rep = try #require(NSBitmapImageRep(data: prepared))
    #expect(max(rep.pixelsWide, rep.pixelsHigh) <= ProfilePictureCatalog.uploadEdge)
  }

  @Test func childrenOfEveryAgeStepAreDescribed() {
    #expect(ProfileAgeSteps.all.map(\.value) == [0, 6, 12, 16])
    #expect(ProfileAgeSteps.summary(for: nil) == nil)
    #expect(ProfileAgeSteps.summary(for: 0) == "Children's profile · FSK 0")
    #expect(ProfileAgeSteps.summary(for: 12) == "Children's profile · up to FSK 12")
  }

  @Test func namesPicturesAndAgeLimitsDecodeAndOldServersStillWork() throws {
    let user = try JSONDecoder().decode(
      UserSummary.self,
      from: Data(
        #"{"id":"00000000-0000-0000-0000-000000000001","username":"lucas","role":"owner","createdAt":"2026-01-01T00:00:00Z","displayName":"Lucas","pictureKey":"cat:green","pictureRevision":4,"ageLimit":null}"#
          .utf8))
    #expect(user.shownName == "Lucas")
    #expect(user.pictureKey == "cat:green")
    #expect(user.pictureRevision == 4)
    let old = try JSONDecoder().decode(
      UserSummary.self,
      from: Data(
        #"{"id":"00000000-0000-0000-0000-000000000002","username":"mia","role":"user","createdAt":"2026-01-01T00:00:00Z"}"#
          .utf8))
    #expect(old.shownName == "mia")
    #expect(old.pictureKey == nil)
    #expect(old.ageLimit == nil)
    let profile = try JSONDecoder().decode(
      WatchingProfile.self,
      from: Data(
        #"{"id":"00000000-0000-0000-0000-000000000003","name":"Ben","role":"user","needsPinSetup":false,"pictureKey":"photo","pictureRevision":2,"ageLimit":6}"#
          .utf8))
    #expect(profile.pictureKey == "photo")
    #expect(profile.ageLimit == 6)
    let request = ProfileCreateRequest(
      username: "Ben", role: .user, isEnabled: true, pinProtectionEnabled: false, pin: nil,
      accessMode: .entireLibrary, titleIds: [], pictureKey: "star:blue", ageLimit: 0)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(object["ageLimit"] as? Int == 0)
    #expect(object["pictureKey"] as? String == "star:blue")
    #expect(object["displayName"] == nil)
    let limit = try JSONDecoder().decode(
      ProfileAgeLimit.self,
      from: Data(
        #"{"ageLimit":12,"allowedTitleIds":["00000000-0000-0000-0000-00000000000a"],"hiddenTitleIds":[],"revision":3}"#
          .utf8))
    #expect(limit.ageLimit == 12)
    #expect(limit.allowedTitleIds.count == 1)
  }
}

/// Lays out the setup assistant's pages offscreen. With AURELIA_SETUP_RENDER=1 it prints each page
/// as a base64 PNG line to the test log, since the sandboxed test host may not write elsewhere.
@MainActor
struct SetupAssistantRenderTests {
  @Test func everyAssistantPageLaysOut() async throws {
    let model = AppModel(store: InMemoryServerProfileStore())
    let defaults = UserDefaults(suiteName: "AureliaSetupRender.\(UUID().uuidString)")!
    let guide = SetupGuide(defaults: defaults, alreadySetUp: false)
    guide.audience = .severalPeople
    guide.devices = [.appleTV, .computer, .webBrowser]
    var pages: [(name: String, view: AnyView)] = SetupIntroductionView.Page.allCases.map { page in
      (
        "intro-\(page)",
        AnyView(SetupIntroductionView(guide: guide, startPage: page))
      )
    }
    guide.start()
    pages.append(("people", AnyView(SetupFinishView(guide: guide, offersPeople: true))))
    pages.append(("all-set", AnyView(SetupFinishView(guide: guide, offersPeople: false))))
    pages.append(
      (
        "tour",
        AnyView(
          ZStack {
            AureliaDesign.canvas
            SpotlightTourOverlay(stops: TourStop.library, anchors: [:]) {}
          })
      ))
    for page in pages {
      let host = NSHostingView(
        rootView: page.view.environmentObject(model)
          .frame(width: 1100, height: 760)
          .environment(\.colorScheme, .dark))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.contentView = host
      defer { window.orderOut(nil) }
      try await Task.sleep(for: .milliseconds(500))
      #expect(host.fittingSize.width > 0, "\(page.name) did not lay out")
      guard ProcessInfo.processInfo.environment["AURELIA_SETUP_RENDER"] == "1" else { continue }
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      print("AURELIA-SETUP-RENDER \(page.name) \(png.base64EncodedString())")
    }
  }
}
