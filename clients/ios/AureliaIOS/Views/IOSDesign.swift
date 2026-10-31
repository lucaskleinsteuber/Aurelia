import SwiftUI
import UIKit

/// Visual tokens for iPhone and iPad: the neutral canvas the Mac and Apple TV apps share, iOS's
/// own sizes and text styles, white capsules for the main action. Artwork carries the color.
@MainActor
enum IOSDesign {
  static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

  static let canvas = Color(red: 20 / 255, green: 22 / 255, blue: 25 / 255)
  static let surface = Color(red: 38 / 255, green: 41 / 255, blue: 45 / 255)
  static let raised = Color.white.opacity(0.1)

  /// The side margin of every screen, like Apple's own apps.
  static var margin: CGFloat { isPad ? 28 : 16 }
  static let cardRadius: CGFloat = 10
  static var posterWidth: CGFloat { isPad ? 150 : 112 }
  static var landscapeWidth: CGFloat { isPad ? 340 : 272 }
  static var shelfSpacing: CGFloat { isPad ? 16 : 12 }
  /// Poster grids: three columns on an iPhone in portrait, more where there is room.
  static var gridColumns: [GridItem] {
    [GridItem(.adaptive(minimum: isPad ? 140 : 100), spacing: 12, alignment: .top)]
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
  let title: String
  var count: Int?
  let destination: Destination?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).font(.title3.weight(.bold))
      if let count {
        Text("\(count)").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
      }
      Spacer(minLength: 8)
      if let destination {
        NavigationLink {
          destination
        } label: {
          HStack(spacing: 3) {
            Text("See All")
            Image(systemName: "chevron.right").font(.caption.weight(.bold))
          }.font(.subheadline.weight(.semibold))
        }.tint(.white.opacity(0.7))
      }
    }
    .padding(.horizontal, IOSDesign.margin)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
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
  @ViewBuilder let content: Content
  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(alignment: .top, spacing: IOSDesign.shelfSpacing) { content }
        .padding(.horizontal, IOSDesign.margin)
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
  var kindLabel: String {
    switch kind {
    case .series: "TV Show"
    case .episode: "Episode"
    case .movie: "Movie"
    default: "Video"
    }
  }
}

/// Cards dim slightly while pressed, like iOS's own artwork buttons.
struct IOSContentButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.7 : 1)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/// iOS buttons in Aurelia's look: `primary` is the white capsule for the main action,
/// `secondary` a translucent capsule, `icon` a round translucent button, `row` a full-width cell.
struct IOSButtonStyle: ButtonStyle {
  enum Kind { case primary, secondary, icon, row }
  var kind: Kind = .secondary
  var fullWidth = false
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(kind == .row ? .body : .body.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, kind == .icon || kind == .row ? 0 : 20)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .frame(width: kind == .icon ? 44 : nil, height: kind == .icon ? 44 : nil)
      .frame(minHeight: kind == .icon || kind == .row ? nil : 48)
      .foregroundStyle(kind == .primary ? Color.black : Color.white)
      .background {
        switch kind {
        case .primary: Capsule().fill(.white)
        case .secondary: Capsule().fill(IOSDesign.raised)
        case .icon: Circle().fill(IOSDesign.raised)
        case .row: Color.clear
        }
      }
      .contentShape(kind == .icon ? AnyShape(Circle()) : AnyShape(Rectangle()))
      .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
      .scaleEffect(configuration.isPressed && kind != .row ? 0.97 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
