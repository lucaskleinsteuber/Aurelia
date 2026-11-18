import SwiftUI
import UIKit

/// Visual tokens for iPhone and iPad: the neutral canvas the Mac and Apple TV apps share, iOS's
/// own sizes and text styles, white capsules for the main action. Artwork carries the color.
@MainActor
enum IOSDesign {
  static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
  /// "iPad" or "iPhone", for text that names this device.
  static var deviceName: String { isPad ? "iPad" : "iPhone" }

  static let canvas = Color(red: 20 / 255, green: 22 / 255, blue: 25 / 255)
  static let surface = Color(red: 38 / 255, green: 41 / 255, blue: 45 / 255)
  static let raised = Color.white.opacity(0.1)

  /// The side margin of every screen, adapting to compact iPad Slide Over / Split View.
  static var margin: CGFloat { isPad ? 28 : 16 }
  static func margin(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
    IOSLayoutMetrics.margin(isRegularWidth: sizeClass == .regular)
  }

  static let cardRadius: CGFloat = 10
  static var posterWidth: CGFloat { isPad ? 150 : 112 }
  static func posterWidth(
    for sizeClass: UserInterfaceSizeClass?, typeSize: DynamicTypeSize
  ) -> CGFloat {
    IOSLayoutMetrics.posterWidth(
      isRegularWidth: sizeClass == .regular, isAccessibilitySize: typeSize.isAccessibilitySize)
  }

  static var landscapeWidth: CGFloat { isPad ? 340 : 272 }
  static func landscapeWidth(
    for sizeClass: UserInterfaceSizeClass?, availableWidth: CGFloat? = nil
  ) -> CGFloat {
    IOSLayoutMetrics.landscapeCardWidth(
      isRegularWidth: sizeClass == .regular, availableWidth: availableWidth)
  }

  static func wideCardWidth(
    for sizeClass: UserInterfaceSizeClass?, availableWidth: CGFloat? = nil
  ) -> CGFloat {
    IOSLayoutMetrics.wideCardWidth(
      isRegularWidth: sizeClass == .regular, availableWidth: availableWidth)
  }

  static var shelfSpacing: CGFloat { isPad ? 16 : 12 }
  static func shelfSpacing(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
    sizeClass == .regular ? 16 : 12
  }

  /// Poster grids: three columns on an iPhone in portrait, more where there is room, and wider
  /// columns at accessibility text sizes so titles do not break into narrow fragments.
  static var gridColumns: [GridItem] {
    [GridItem(.adaptive(minimum: isPad ? 140 : 100), spacing: 12, alignment: .top)]
  }

  static func gridColumns(
    for sizeClass: UserInterfaceSizeClass?, typeSize: DynamicTypeSize
  ) -> [GridItem] {
    let minimum = IOSLayoutMetrics.posterGridMinimum(
      isRegularWidth: sizeClass == .regular, isAccessibilitySize: typeSize.isAccessibilitySize)
    return [GridItem(.adaptive(minimum: minimum), spacing: 12, alignment: .top)]
  }
}

/// Adds a Done button above number pads, which have no Return key on iPhone.
struct IOSNumberPadDoneToolbar: ViewModifier {
  let action: () -> Void
  func body(content: Content) -> some View {
    content.toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done", action: action)
      }
    }
  }
}

extension View {
  func iosNumberPadDone(_ action: @escaping () -> Void) -> some View {
    modifier(IOSNumberPadDoneToolbar(action: action))
  }
}

/// Uppercase tracked caption above titles, such as "TV SHOW · 2008".
struct IOSEyebrow: View {
  let text: String
  var body: some View {
    Text(text.uppercased()).font(.caption.weight(.bold)).tracking(0.8)
      .foregroundStyle(.white.opacity(0.7))
  }
}

/// A shelf title with its quiet item count and, when the shelf continues, "See All".
struct IOSSectionHeader<Destination: View>: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dynamicTypeSize) private var typeSize
  let title: String
  var count: Int?
  let destination: Destination?

  var body: some View {
    let margin = IOSDesign.margin(for: sizeClass)
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          heading
          seeAll
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          heading
          Spacer(minLength: 8)
          seeAll
        }
      }
    }
    .padding(.horizontal, margin)
    .accessibilityElement(children: .contain)
  }

  private var heading: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
      if let count {
        Text("\(count)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var seeAll: some View {
    if let destination {
      NavigationLink {
        destination
      } label: {
        HStack(spacing: 3) {
          Text("See All")
          Image(systemName: "chevron.right").font(.caption.weight(.bold)).accessibilityHidden(true)
        }
        .font(.subheadline.weight(.semibold))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .tint(.white.opacity(0.8))
      .accessibilityLabel("See all \(title)")
    }
  }
}

extension IOSSectionHeader where Destination == EmptyView {
  init(title: String, count: Int? = nil) {
    self.init(title: title, count: count, destination: nil)
  }
}

/// Thin white progress capsule drawn inside artwork.
struct IOSProgressBar: View {
  let fraction: Double
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.28))
        Capsule().fill(.white).frame(width: geometry.size.width * min(1, max(0, fraction)))
      }
    }.frame(height: 3).accessibilityHidden(true)
  }
}

/// A horizontal shelf with the screen margin on both ends.
struct IOSShelf<Content: View>: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  @ViewBuilder let content: Content
  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(alignment: .top, spacing: IOSDesign.shelfSpacing(for: sizeClass)) { content }
        .padding(.horizontal, IOSDesign.margin(for: sizeClass))
    }
    .scrollIndicators(.hidden)
    .scrollClipDisabled()
  }
}

extension IOSCatalogItem {
  var progressFraction: Double? {
    guard let progress, progress.durationMilliseconds > 0, !progress.isCompleted,
      progress.positionMilliseconds > 0
    else { return nil }
    return Double(progress.positionMilliseconds) / Double(progress.durationMilliseconds)
  }
  var isWatched: Bool { watchState == "completed" || progress?.isCompleted == true }
}

/// Cards dim slightly while pressed, like iOS's own artwork buttons.
struct IOSContentButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.7 : 1)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/// iOS buttons in Aurelia's look: `primary` is the white capsule for the main action,
/// `secondary` a translucent capsule, `icon` a round translucent button, `row` a full-width cell.
struct IOSButtonStyle: ButtonStyle {
  enum Kind { case primary, secondary, icon, row }
  var kind: Kind = .secondary
  var fullWidth = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    // Allow labels to wrap on narrow widths and larger text sizes instead of ending in "…".
    let wraps = kind != .icon && (typeSize.isAccessibilitySize || typeSize >= .xLarge)
    let secondaryFill = reduceTransparency ? IOSDesign.surface : IOSDesign.raised
    let showsBorder =
      (contrast == .increased || reduceTransparency) && (kind == .secondary || kind == .icon)
    configuration.label
      .font(kind == .row ? .body : .body.weight(.semibold))
      .dynamicTypeSize(
        kind == .icon ? (...DynamicTypeSize.xxxLarge) : (...DynamicTypeSize.accessibility5)
      )
      .lineLimit(kind == .icon ? 1 : (typeSize.isAccessibilitySize ? nil : (wraps ? 2 : 1)))
      .multilineTextAlignment(kind == .row ? .leading : .center)
      .padding(.horizontal, kind == .icon || kind == .row ? 0 : 20)
      .padding(.vertical, wraps && kind != .row ? 10 : 0)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .frame(width: kind == .icon ? 48 : nil, height: kind == .icon ? 48 : nil)
      .frame(minHeight: kind == .icon ? nil : (kind == .row ? 44 : 48))
      .foregroundStyle(kind == .primary ? Color.black : Color.white)
      .background {
        switch kind {
        case .primary: Capsule().fill(.white)
        case .secondary:
          Capsule().fill(secondaryFill)
            .overlay {
              if showsBorder { Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
            }
        case .icon:
          Circle().fill(secondaryFill)
            .overlay {
              if showsBorder { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
            }
        case .row: Color.clear
        }
      }
      .contentShape(kind == .icon ? AnyShape(Circle()) : AnyShape(Rectangle()))
      .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
      .scaleEffect(configuration.isPressed && kind != .row && !reduceMotion ? 0.97 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/// A scroll view whose content sits in the middle while it fits, and scrolls from the top when it
/// doesn't (large text sizes), instead of being squeezed to one screen and ending in "…".
struct IOSCenteredScrollView<Content: View>: View {
  @ViewBuilder var content: Content
  @State private var visibleHeight: CGFloat = 0

  var body: some View {
    ScrollView {
      content.frame(maxWidth: .infinity, minHeight: visibleHeight)
    }
    .onScrollGeometryChange(for: CGFloat.self) { geometry in
      geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
    } action: { _, height in
      visibleHeight = max(0, height)
    }
    .scrollBounceBehavior(.basedOnSize)
  }
}
