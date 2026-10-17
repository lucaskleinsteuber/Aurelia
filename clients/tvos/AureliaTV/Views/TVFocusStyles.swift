import SwiftUI

/// Visual tokens shared with the Mac client's `AureliaDesign`: a measured neutral
/// canvas, artwork carries all strong color, white capsules for primary actions.
enum TVDesign {
  static let canvas = Color(red: 32 / 255, green: 35 / 255, blue: 38 / 255)
  static let canvasTop = Color(red: 27 / 255, green: 30 / 255, blue: 33 / 255)
  static let surface = Color(red: 40 / 255, green: 44 / 255, blue: 47 / 255)
  static let cardRadius: CGFloat = 18
  static let pagePadding: CGFloat = 80
  static let posterWidth: CGFloat = 250
  static let landscapeWidth: CGFloat = 470
}

/// Uppercase tracked caption above titles, such as "TV SHOW · 2008".
struct TVEyebrow: View {
  let text: String
  var size: CGFloat = 20
  var body: some View {
    Text(text.uppercased()).font(.system(size: size, weight: .bold)).tracking(1.6)
      .foregroundStyle(.white.opacity(0.74))
  }
}

/// Section title with the quiet item count used throughout the Mac library.
struct TVSectionHeader: View {
  let title: String
  var count: Int?
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title).font(.system(size: 34, weight: .bold))
      if let count {
        Text("\(count)").font(.system(size: 20, weight: .semibold)).foregroundStyle(.tertiary)
      }
    }
  }
}

/// Thin white progress capsule drawn inside artwork.
struct TVProgressBar: View {
  let fraction: Double
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.24))
        Capsule().fill(.white).frame(width: geometry.size.width * min(1, max(0, fraction)))
      }
    }.frame(height: 5).accessibilityHidden(true)
  }
}

extension TVCatalogItem {
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

/// Unfocused content stays quiet; focus is shown by the native card lift.
struct TVContentButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.82 : 1)
  }
}

/// tvOS focus language: the focused control turns white with dark text and lifts.
/// `primary` stays white like the Mac's primary capsule even without focus.
struct TVButtonStyle: ButtonStyle {
  enum Kind { case action, primary, icon, row }
  var kind: Kind = .action
  @Environment(\.isFocused) private var focused
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    let light = focused || kind == .primary
    return configuration.label
      .font(.system(size: kind == .row ? 26 : 24, weight: .semibold))
      .padding(.horizontal, kind == .action || kind == .primary ? 30 : 0)
      .frame(width: kind == .icon ? 66 : nil, height: kind == .icon ? 66 : nil)
      .frame(minHeight: kind == .action || kind == .primary ? 62 : nil)
      .foregroundStyle(light ? Color.black : Color.white)
      .background(background(light: light))
      .opacity(enabled ? 1 : 0.4)
      .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 10)
      .scaleEffect(configuration.isPressed ? 0.97 : focused ? (kind == .row ? 1.015 : 1.07) : 1)
      .animation(.easeOut(duration: 0.14), value: focused)
  }

  private func background(light: Bool) -> some View {
    let fill: Color =
      focused ? .white : kind == .primary ? .white.opacity(0.86) : .white.opacity(0.13)
    return Group {
      switch kind {
      case .icon: Circle().fill(fill)
      case .row: RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill)
      case .action, .primary: Capsule().fill(fill)
      }
    }
  }
}
