import SwiftUI

/// Covers the moment between Play and the first moving picture, like a streaming service: the
/// title's artwork drifts slowly closer behind its name while a light sweeps along a thin bar,
/// then the screen fades away to reveal the picture.
struct PlayerStartScreen: View {
  let title: String
  let subtitle: String?
  let artwork: ArtworkSummary?
  let resumeLabel: String?
  let reduceMotion: Bool
  @State private var drift = false
  @State private var appeared = false

  var body: some View {
    ZStack {
      Color.black
      if artwork != nil {
        AuthenticatedArtwork(artwork: artwork, symbol: "film", contentMode: .fill)
          .scaleEffect(drift ? 1.09 : 1.02)
          // Soft and dim, so the cut to the sharp picture feels like focusing in.
          .blur(radius: 8)
          .opacity(appeared ? 0.6 : 0)
      }
      LinearGradient(
        colors: [.black.opacity(0.25), .black.opacity(0.45), .black.opacity(0.85)],
        startPoint: .top, endPoint: .bottom)
      VStack(spacing: 10) {
        if let subtitle {
          Text(subtitle.uppercased())
            .font(.caption.weight(.bold))
            .tracking(1.4)
            .foregroundStyle(.white.opacity(0.68))
        }
        Text(title)
          .font(.system(size: 44, weight: .bold))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .minimumScaleFactor(0.6)
          .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        PlayerStartProgress(reduceMotion: reduceMotion)
          .frame(width: 220, height: 3)
          .padding(.top, 16)
        if let resumeLabel {
          Text(resumeLabel)
            .font(.callout.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.72))
            .padding(.top, 4)
        }
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 60)
      .scaleEffect(appeared || reduceMotion ? 1 : 0.96)
      .opacity(appeared ? 1 : 0)
    }
    .onAppear {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { appeared = true }
      guard !reduceMotion else { return }
      withAnimation(.easeOut(duration: 14)) { drift = true }
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(resumeLabel.map { "Starting \(title), \($0)" } ?? "Starting \(title)")
    .accessibilityIdentifier("player-start-screen")
  }
}

/// A light that sweeps along a thin track; it stands still with Reduce Motion.
private struct PlayerStartProgress: View {
  let reduceMotion: Bool

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      GeometryReader { proxy in
        let period = 1.4
        let phase =
          reduceMotion
          ? 0.5
          : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
            / period
        let sweep = proxy.size.width * 0.42
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.18))
          Capsule()
            .fill(
              LinearGradient(
                colors: [.white.opacity(0), .white, .white.opacity(0)],
                startPoint: .leading, endPoint: .trailing)
            )
            .frame(width: sweep)
            .offset(x: (proxy.size.width + sweep) * phase - sweep)
        }
        .clipShape(Capsule())
      }
    }
  }
}
