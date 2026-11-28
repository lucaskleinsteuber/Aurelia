import SwiftUI
import Testing
import UIKit

@testable import TarvenIOS

/// Renders real SwiftUI iPhone and iPad screens inside UIHostingController across compact iPhones,
/// Landscape, iPad Slide Over (320 pt), iPad Split View, iPad Pro 13-inch, and Dynamic Type AX5 to
/// catch horizontal overflow, crushed columns, and clipped controls automatically.
@Suite("iOS & iPad Rendered Screen Layout")
@MainActor
struct IOSRenderedLayoutTests {
  struct Viewport: Sendable {
    let name: String
    let size: CGSize
    let horizontal: UserInterfaceSizeClass
    let vertical: UserInterfaceSizeClass
    let dynamicType: DynamicTypeSize
    let contentSizeCategory: UIContentSizeCategory

    static let phoneMatrix: [Viewport] = [
      .init(
        name: "iPhone SE Portrait",
        size: CGSize(width: 375, height: 667),
        horizontal: .compact, vertical: .regular,
        dynamicType: .large, contentSizeCategory: .large),
      .init(
        name: "iPhone SE Landscape",
        size: CGSize(width: 667, height: 375),
        horizontal: .compact, vertical: .compact,
        dynamicType: .large, contentSizeCategory: .large),
      .init(
        name: "iPhone 17 Pro Portrait",
        size: CGSize(width: 402, height: 874),
        horizontal: .compact, vertical: .regular,
        dynamicType: .large, contentSizeCategory: .large),
      .init(
        name: "iPhone SE AX5",
        size: CGSize(width: 375, height: 667),
        horizontal: .compact, vertical: .regular,
        dynamicType: .accessibility5,
        contentSizeCategory: .accessibilityExtraExtraExtraLarge),
    ]

    static let padMatrix: [Viewport] = [
      .init(
        name: "iPad Slide Over 320pt",
        size: CGSize(width: 320, height: 744),
        horizontal: .compact, vertical: .regular,
        dynamicType: .large, contentSizeCategory: .large),
      .init(
        name: "iPad Split View Compact xxxLarge",
        size: CGSize(width: 375, height: 1024),
        horizontal: .compact, vertical: .regular,
        dynamicType: .xxxLarge, contentSizeCategory: .extraExtraExtraLarge),
      .init(
        name: "iPad Pro 13-inch Portrait",
        size: CGSize(width: 1032, height: 1376),
        horizontal: .regular, vertical: .regular,
        dynamicType: .large, contentSizeCategory: .large),
      .init(
        name: "iPad Pro 13-inch AX3",
        size: CGSize(width: 1032, height: 1376),
        horizontal: .regular, vertical: .regular,
        dynamicType: .accessibility3,
        contentSizeCategory: .accessibilityExtraLarge),
    ]

    static let all: [Viewport] = phoneMatrix + padMatrix
  }

  private struct LayoutAuditResult {
    var renderedViewCount = 0
    var verticalScrollOverflows: [String] = []
    var outOfBoundsControls: [String] = []
    var crushedTextViews: [String] = []
  }

  private func assertScreenFits<Content: View>(
    screenName: String,
    viewport: Viewport,
    model: IOSAppModel,
    @ViewBuilder content: () -> Content
  ) async throws {
    let root = content()
      .environmentObject(model)
      .preferredColorScheme(.dark)
      .tint(.white)
      .environment(\.horizontalSizeClass, viewport.horizontal)
      .environment(\.verticalSizeClass, viewport.vertical)
      .environment(\.dynamicTypeSize, viewport.dynamicType)

    let controller = UIHostingController(rootView: root)
    controller.traitOverrides.userInterfaceStyle = .dark
    controller.traitOverrides.horizontalSizeClass =
      viewport.horizontal == .regular ? .regular : .compact
    controller.traitOverrides.verticalSizeClass =
      viewport.vertical == .compact ? .compact : .regular
    controller.traitOverrides.preferredContentSizeCategory = viewport.contentSizeCategory

    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
      "Expected an active UIWindowScene in hosted iOS Simulator test runner")
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: viewport.size)
    window.overrideUserInterfaceStyle = .dark
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }

    controller.view.frame = window.bounds
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(80))
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()

    var audit = LayoutAuditResult()
    inspect(
      view: controller.view,
      in: window,
      viewportWidth: viewport.size.width,
      insideHorizontalCarousel: false,
      result: &audit)

    #expect(
      audit.renderedViewCount > 1,
      "\(screenName) on \(viewport.name) rendered an empty view hierarchy")
    #expect(
      audit.verticalScrollOverflows.isEmpty,
      "\(screenName) on \(viewport.name) overflows horizontally in vertical ScrollView: \(audit.verticalScrollOverflows)"
    )
    #expect(
      audit.outOfBoundsControls.isEmpty,
      "\(screenName) on \(viewport.name) places controls/text outside viewport [0, \(viewport.size.width)]: \(audit.outOfBoundsControls)"
    )
    #expect(
      audit.crushedTextViews.isEmpty,
      "\(screenName) on \(viewport.name) crushes text into ultra-narrow column: \(audit.crushedTextViews)"
    )
  }

  private func inspect(
    view: UIView,
    in window: UIWindow,
    viewportWidth: CGFloat,
    insideHorizontalCarousel: Bool,
    result: inout LayoutAuditResult
  ) {
    guard !view.isHidden, view.alpha > 0.01 else { return }
    if view.bounds.width > 0, view.bounds.height > 0 {
      result.renderedViewCount += 1
    }

    var inCarousel = insideHorizontalCarousel
    if let scrollView = view as? UIScrollView {
      let boundsW = scrollView.bounds.width
      let contentW = scrollView.contentSize.width
      let contentH = scrollView.contentSize.height
      let isHorizontalShelf =
        !scrollView.alwaysBounceVertical && contentW > boundsW + 2
        && contentH <= scrollView.bounds.height + 2
      if isHorizontalShelf {
        inCarousel = true
      } else if boundsW > 0, contentW > boundsW + 2 {
        result.verticalScrollOverflows.append(
          "\(type(of: scrollView)) contentWidth=\(Int(contentW)) > boundsWidth=\(Int(boundsW))")
      }
    }

    if !inCarousel, view.bounds.width > 0, view.bounds.height > 0 {
      let frame = view.convert(view.bounds, to: window)
      let isCheckedControl =
        view is UILabel || view is UIControl || view is UITextField || view is UITextView
      if isCheckedControl {
        if frame.minX < -2 || frame.maxX > viewportWidth + 2 {
          result.outOfBoundsControls.append(
            "\(type(of: view)) frame=(\(Int(frame.minX))..\(Int(frame.maxX)))")
        }
        if view is UILabel, frame.width < 16, frame.height > 44 {
          result.crushedTextViews.append(
            "\(type(of: view)) size=\(Int(frame.width))x\(Int(frame.height))")
        }
      }
    }

    for subview in view.subviews {
      inspect(
        view: subview,
        in: window,
        viewportWidth: viewportWidth,
        insideHorizontalCarousel: inCarousel,
        result: &result)
    }
  }

  @Test func onboardingConnectionAndPairingScreensFitEveryViewport() async throws {
    for viewport in Viewport.all {
      let connectionModel = await IOSAppModel.layoutFixture(
        scenario: .library, phase: .connection)
      try await assertScreenFits(
        screenName: "SetupIntroduction", viewport: viewport, model: connectionModel
      ) {
        IOSSetupIntroductionView(guide: connectionModel.setupGuide)
      }
      try await assertScreenFits(
        screenName: "Connection", viewport: viewport, model: connectionModel
      ) {
        NavigationStack { IOSConnectionView(browser: connectionModel.browser) }
      }

      let pairingModel = await IOSAppModel.layoutFixture(scenario: .library, phase: .pairing)
      try await assertScreenFits(
        screenName: "Pairing", viewport: viewport, model: pairingModel
      ) {
        IOSPairingView()
      }
    }
  }

  @Test func profilePickerAndPinKeypadFitEveryViewportIncludingSlideOverAndLandscape() async throws
  {
    let profilesModel = await IOSAppModel.layoutFixture(scenario: .profiles, phase: .profiles)
    #expect(!profilesModel.profiles.isEmpty)

    for viewport in Viewport.all {
      profilesModel.selectedProfile = nil
      try await assertScreenFits(
        screenName: "ProfilePicker", viewport: viewport, model: profilesModel
      ) {
        IOSProfilesView()
      }

      profilesModel.selectedProfile = profilesModel.profiles.first
      try await assertScreenFits(
        screenName: "PINKeypad", viewport: viewport, model: profilesModel
      ) {
        IOSProfilesView()
      }
    }
  }

  @Test func homeDetailWishesDownloadsAndSettingsFitPhonePadSlideOverAndAX5() async throws {
    let libraryModel = await IOSAppModel.layoutFixture(scenario: .library, phase: .library)
    let adminModel = await IOSAppModel.layoutFixture(scenario: .admin, phase: .library)
    let initialSeries = try #require(
      libraryModel.home?.recentlyAdded.first(where: { $0.kind == .series })
        ?? libraryModel.home?.continueWatching.first)

    for viewport in Viewport.all {
      try await assertScreenFits(
        screenName: "Home", viewport: viewport, model: libraryModel
      ) {
        NavigationStack { IOSHomeView() }
      }

      try await assertScreenFits(
        screenName: "SeriesDetail", viewport: viewport, model: libraryModel
      ) {
        NavigationStack {
          IOSDetailView(id: initialSeries.detailID, initial: initialSeries)
        }
      }

      try await assertScreenFits(
        screenName: "FamilyWishes", viewport: viewport, model: adminModel
      ) {
        NavigationStack { IOSWishesView() }
      }

      try await assertScreenFits(
        screenName: "Downloads", viewport: viewport, model: libraryModel
      ) {
        NavigationStack { IOSDownloadsView(store: libraryModel.offline) }
      }

      try await assertScreenFits(
        screenName: "AdminSettings", viewport: viewport, model: adminModel
      ) {
        IOSSettingsTab()
      }
    }
  }
}
