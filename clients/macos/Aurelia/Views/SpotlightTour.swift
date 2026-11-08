import SwiftUI

/// A place in the library window the tour can light up.
enum TourTarget: Hashable, Sendable {
  case firstTitle, sidebar, profile, settings
}

/// One stop of the library tour: the place to light up (none: a centered note), a title and one
/// sentence.
struct TourStop: Equatable, Sendable {
  let target: TourTarget?
  let title: String
  let text: String

  static let library: [TourStop] = [
    TourStop(
      target: .firstTitle, title: "Open a Title",
      text:
        "Click a poster to see its details. Play starts it, and the ••• button has everything else."
    ),
    TourStop(
      target: .sidebar, title: "Your Library",
      text: "Home, Movies, TV Shows, Collections and your Watchlist. Click any page to open it."),
    TourStop(
      target: .profile, title: "Switch Profiles",
      text: "Everyone has a profile with their own progress, favorites and watchlist."),
    TourStop(
      target: .settings, title: "Settings",
      text: "Playback, your profile, the server and About Aurelia are here."),
    TourStop(
      target: nil, title: "Enjoy Watching",
      text: "Search anytime with ⌘F, and press ⌃⌘F for full screen. Have fun!"),
  ]
}

struct TourAnchorKey: PreferenceKey {
  static let defaultValue: [TourTarget: Anchor<CGRect>] = [:]

  static func reduce(
    value: inout [TourTarget: Anchor<CGRect>], nextValue: () -> [TourTarget: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { current, _ in current }
  }
}

extension View {
  /// Marks this view as a place the library tour can light up.
  func aureliaTourTarget(_ target: TourTarget, isEnabled: Bool = true) -> some View {
    anchorPreference(key: TourAnchorKey.self, value: .bounds) {
      isEnabled ? [target: $0] : [:]
    }
  }
}

/// Where the tour's note goes beside the lit place: right of it, else below, else left, always
/// inside the window. Without a place, the note is centered.
enum TourBubblePlacement {
  static let width: CGFloat = 320
  static let estimatedHeight: CGFloat = 170

  static func origin(hole: CGRect?, in size: CGSize) -> CGPoint {
    guard let hole else {
      return CGPoint(
        x: (size.width - width) / 2, y: max(16, (size.height - estimatedHeight) / 2))
    }
    var x: CGFloat
    var y: CGFloat
    if hole.maxX + 16 + width <= size.width {
      x = hole.maxX + 16
      y = hole.minY
    } else if hole.maxY + 16 + estimatedHeight <= size.height {
      x = hole.minX
      y = hole.maxY + 16
    } else {
      x = hole.minX - 16 - width
      y = hole.minY
    }
    x = min(max(x, 16), max(16, size.width - width - 16))
    y = min(max(y, 16), max(16, size.height - estimatedHeight - 16))
    return CGPoint(x: x, y: y)
  }
}

/// The library tour after setup: the window dims, one place stays lit with a short note beside it.
/// Next or Return moves on, Skip Tour or Esc ends it. Clicks pass through the lit place to the app.
struct SpotlightTourOverlay: View {
  let stops: [TourStop]
  let anchors: [TourTarget: Anchor<CGRect>]
  let finished: () -> Void
  @State private var index = 0
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      let stop = stops[min(index, stops.count - 1)]
      let hole = stop.target.flatMap { anchors[$0] }.map {
        geometry[$0].insetBy(dx: -8, dy: -8)
          .intersection(CGRect(origin: .zero, size: geometry.size))
      }.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
      let origin = TourBubblePlacement.origin(hole: hole, in: geometry.size)
      ZStack(alignment: .topLeading) {
        TourDimShape(hole: hole)
          .fill(Color.black.opacity(0.72), style: FillStyle(eoFill: true))
          .contentShape(TourDimShape(hole: hole), eoFill: true)
          .onTapGesture {}
        if let hole {
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
            .frame(width: hole.width, height: hole.height)
            .offset(x: hole.minX, y: hole.minY)
            .allowsHitTesting(false)
        }
        bubble(stop)
          .frame(width: TourBubblePlacement.width)
          .offset(x: origin.x, y: origin.y)
          .id(index)
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: index)
    }
    .ignoresSafeArea()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("library-tour")
  }

  private func bubble(_ stop: TourStop) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(stop.title).font(.headline)
      Text(stop.text).font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Text("\(index + 1) of \(stops.count)").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Skip Tour") { finished() }
          .buttonStyle(.link)
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("tour-skip")
        Button(index == stops.count - 1 ? "Done" : "Next") { advance() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("tour-next")
      }
      .padding(.top, 4)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(red: 0.14, green: 0.15, blue: 0.17).opacity(0.97))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.white.opacity(0.2), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
  }

  private func advance() {
    if index + 1 >= stops.count {
      finished()
    } else {
      index += 1
    }
  }
}

/// The dimming with a rounded hole around the lit place.
struct TourDimShape: Shape {
  let hole: CGRect?

  func path(in rect: CGRect) -> Path {
    var path = Path(rect)
    if let hole { path.addRoundedRect(in: hole, cornerSize: CGSize(width: 12, height: 12)) }
    return path
  }
}

/// Shows the tour over the library while one is pending and nothing else covers the window.
struct LibraryTourHost: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var guide: SetupGuide
  let anchors: [TourTarget: Anchor<CGRect>]

  var body: some View {
    if guide.tourPending, !guide.isGuiding, model.playback == nil, !model.isSettingsPresented {
      SpotlightTourOverlay(stops: TourStop.library, anchors: anchors) { guide.tourShown() }
        .transition(.opacity)
    }
  }
}
