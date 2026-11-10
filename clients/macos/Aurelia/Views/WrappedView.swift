import SwiftUI

extension Color {
  /// A color from 0xRRGGBB, for Wrapped's fixed palette.
  init(wrappedHex hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

/// Wrapped: the year as full-screen slides, like a story. Each slide runs for six seconds; a tap
/// on the right or the right arrow moves on, on the left goes back, holding or Space pauses, and
/// Escape closes. With Reduce Motion the slides wait for a click and numbers do not count up.
struct WrappedStoryView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.aureliaReduceMotion) private var reduceMotion
  let year: Int
  @State private var wrapped: YearWrapped?
  @State private var error: String?
  @State private var index = 0
  @State private var progress: Double = 0
  @State private var held = false
  @State private var shownNumber: String?
  @FocusState private var focused: Bool

  var body: some View {
    let slide = wrapped?.slides.indices.contains(index) == true ? wrapped?.slides[index] : nil
    let accent = WrappedStory.accent(slide?.accent ?? "night")
    ZStack {
      Color(wrappedHex: accent.field).ignoresSafeArea()
      if let poster = slide?.poster {
        AuthenticatedArtwork(artwork: poster, symbol: "photo")
          .blur(radius: 40)
          .opacity(0.3)
          .ignoresSafeArea()
          .allowsHitTesting(false)
      }
      if let slide {
        content(slide, accent: accent)
        controls(count: wrapped?.slides.count ?? 0, accent: accent)
      } else if let error {
        VStack(spacing: 16) {
          Text("Wrapped didn't load.").font(.title.weight(.black))
          Text(error).multilineTextAlignment(.center)
          Button("Close") { dismiss() }.buttonStyle(AureliaPrimaryActionButtonStyle())
        }
        .padding(28)
      } else {
        ProgressView().tint(.white)
      }
    }
    .foregroundStyle(Color(wrappedHex: accent.ink))
    .animation(.easeInOut(duration: 0.3), value: index)
    .frame(width: 440, height: 800)
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onAppear { focused = true }
    .onKeyPress(.rightArrow) { go(forward: true); return .handled }
    .onKeyPress(.leftArrow) { go(forward: false); return .handled }
    .onKeyPress(.space) { held.toggle(); return .handled }
    .task { await load() }
    .task(id: "\(index)-\(held)-\(wrapped != nil)") { await run() }
  }

  private func content(_ slide: WrappedSlide, accent: WrappedStory.Accent) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Spacer(minLength: 60)
      Text(slide.eyebrow).font(.headline.weight(.bold)).opacity(0.8)
      if slide.kind == "summary" {
        Text(slide.headline).font(.system(size: 40, weight: .black)).tracking(-1)
        if let posters = slide.posters, !posters.isEmpty {
          LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(Array(posters.prefix(4).enumerated()), id: \.offset) { _, poster in
              AuthenticatedArtwork(artwork: poster, symbol: "film")
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
          }
          .frame(maxWidth: 240)
        }
        if let facts = slide.facts {
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(facts, id: \.label) { fact in
              GridRow {
                Text(fact.label).opacity(0.72)
                Text(fact.value).fontWeight(.heavy)
              }
            }
          }
        }
      } else {
        if let poster = slide.poster {
          AuthenticatedArtwork(artwork: poster, symbol: "film")
            .frame(width: 140, height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .rotationEffect(.degrees(-3))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
        }
        Text(slide.headline).font(.system(size: 38, weight: .black)).tracking(-1).lineLimit(3)
          .minimumScaleFactor(0.6)
        if let number = slide.bigNumber {
          VStack(alignment: .leading, spacing: 0) {
            Text(shownNumber ?? number)
              .font(.system(size: 150, weight: .black).monospacedDigit())
              .tracking(-8)
              .minimumScaleFactor(0.4)
              .lineLimit(1)
            if let unit = slide.unit { Text(unit).font(.title.weight(.heavy)) }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel([number, slide.unit].compactMap { $0 }.joined(separator: " "))
        }
        if let detail = slide.detail { Text(detail).font(.title3) }
      }
      Text(slide.quip)
        .font(.title3.weight(.heavy))
        .foregroundStyle(Color(wrappedHex: accent.field))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(wrappedHex: accent.sticker), in: RoundedRectangle(cornerRadius: 6))
        .rotationEffect(.degrees(-2.5))
        .padding(.top, 8)
      Spacer(minLength: 40)
    }
    .frame(maxWidth: 480, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 28)
    .id(index)
    .transition(.opacity)
  }

  private func controls(count: Int, accent: WrappedStory.Accent) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 4) {
        ForEach(0..<count, id: \.self) { at in
          GeometryReader { geometry in
            Capsule().fill(Color(wrappedHex: accent.ink).opacity(0.28))
              .overlay(alignment: .leading) {
                Capsule().fill(Color(wrappedHex: accent.ink))
                  .frame(width: geometry.size.width * (at < index ? 1 : at == index ? progress : 0))
              }
          }
          .frame(height: 3)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .accessibilityHidden(true)
      HStack {
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44) }
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel("Close Wrapped")
      }
      .padding(.horizontal, 8)
      HStack(spacing: 0) {
        Color.clear.contentShape(Rectangle())
          .onTapGesture { go(forward: false) }
          .accessibilityLabel("Previous slide")
          .accessibilityAddTraits(.isButton)
        Color.clear.contentShape(Rectangle())
          .frame(maxWidth: .infinity)
          .layoutPriority(1)
          .onTapGesture { go(forward: true) }
          .accessibilityLabel(index + 1 < count ? "Next slide" : "Close Wrapped")
          .accessibilityAddTraits(.isButton)
      }
      // A finger resting on the story holds it, like the stories people know.
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in if !held { held = true } }
          .onEnded { _ in held = false })
    }
  }

  private func go(forward: Bool) {
    guard let count = wrapped?.slides.count else { return }
    guard let next = WrappedStory.step(from: index, count: count, forward: forward) else { return dismiss() }
    progress = 0
    index = next
  }

  /// Counts the number up, then runs the bar; holding stops it where it is.
  private func run() async {
    guard let slides = wrapped?.slides, slides.indices.contains(index) else { return }
    let slide = slides[index]
    if progress == 0, !reduceMotion, let target = WrappedStory.countTarget(slide.bigNumber), target > 1 {
      let start = Date()
      while !Task.isCancelled {
        let fraction = Date().timeIntervalSince(start) / 1.1
        shownNumber = String(WrappedStory.countValue(target, fraction: fraction))
        if fraction >= 1 { break }
        try? await Task.sleep(for: .milliseconds(30))
      }
    }
    shownNumber = nil
    guard !reduceMotion, !held else { return }
    while !Task.isCancelled && progress < 1 {
      try? await Task.sleep(for: .milliseconds(50))
      if Task.isCancelled { return }
      progress = min(1, progress + 0.05 / WrappedStory.slideSeconds)
    }
    if !Task.isCancelled { go(forward: true) }
  }

  private func load() async {
    guard wrapped == nil, let client = model.profileClient() else { return }
    do {
      wrapped = try await client.wrapped(year: year)
    } catch {
      self.error = error.localizedDescription
    }
  }
}
