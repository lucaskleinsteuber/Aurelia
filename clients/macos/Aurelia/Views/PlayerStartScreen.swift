import SwiftUI

/// The short wait between Play and the first moving picture: black with a turning ring, like
/// streaming apps. The picture fades in over it.
struct PlayerStartScreen: View {
  let reduceMotion: Bool

  var body: some View {
    ZStack {
      Color.black
      PlayerStartRing(reduceMotion: reduceMotion)
        .frame(width: 46, height: 46)
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading")
    .accessibilityIdentifier("player-start-screen")
  }
}

/// A white arc that turns and gently grows and shrinks; it stands still with Reduce Motion.
private struct PlayerStartRing: View {
  let reduceMotion: Bool

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      let rotation = reduceMotion ? 0 : time.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
      let length = reduceMotion ? 0.3 : 0.42 + 0.26 * sin(time * 2 * .pi / 1.8)
      ZStack {
        Circle().stroke(.white.opacity(0.12), lineWidth: 3)
        Circle()
          .trim(from: 0, to: length)
          .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
          .rotationEffect(.degrees(rotation - 90))
      }
    }
  }
}
