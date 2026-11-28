import SwiftUI

extension Color {
  /// A color from 0xRRGGBB, for Wrapped's fixed palette.
  init(wrappedHex hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

/// Pure presentation state for Wrapped so loading, empty slides, error, and active slide are all
/// explicit and always closable.
enum WrappedDisplayState: Equatable {
  case loading
  case empty
  case failed(String)
  case slide(Int)

  static func resolve(wrapped: YearWrapped?, index: Int, error: String?) -> Self {
    if let error { return .failed(error) }
    guard let wrapped else { return .loading }
    guard !wrapped.slides.isEmpty else { return .empty }
    let clamped = min(max(0, index), wrapped.slides.count - 1)
    return .slide(clamped)
  }
}

/// Wrapped: a year, or one month, as slides over the whole window, like a story. Each slide runs
/// for six seconds; a click on the right or the right arrow moves on, on the left goes back,
/// holding or Space pauses, and Escape closes. In a wide window the poster stands beside the
/// words. With Reduce Motion the slides wait for a click and numbers do not count up.
struct WrappedStoryView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.tarvenReduceMotion) private var reduceMotion
  let launch: WrappedLaunch
  @State private var wrapped: YearWrapped?
  @State private var error: String?
  @State private var index = 0
  @State private var progress: Double = 0
  @State private var held = false
  @State private var shownNumber: String?
  @FocusState private var focused: Bool

  var body: some View {
    let display = WrappedDisplayState.resolve(wrapped: wrapped, index: index, error: error)
    let activeSlide: WrappedSlide? =
      if case .slide(let at) = display, wrapped?.slides.indices.contains(at) == true {
        wrapped?.slides[at]
      } else {
        nil
      }
    let accent = WrappedStory.accent(activeSlide?.accent ?? "night")
    GeometryReader { geometry in
      ZStack {
        Color(wrappedHex: accent.field)
        if let poster = activeSlide?.poster {
          AuthenticatedArtwork(artwork: poster, symbol: "photo")
            .blur(radius: 60)
            .opacity(0.28)
            .allowsHitTesting(false)
            .id("backdrop-\(index)")
            .transition(.opacity)
        }
        switch display {
        case .slide:
          if let activeSlide {
            content(activeSlide, accent: accent, size: geometry.size)
            controls(count: wrapped?.slides.count ?? 0, accent: accent)
          }
        case .failed(let message):
          TarvenUnavailableView(
            title: "Wrapped Couldn't Load",
            systemImage: "exclamationmark.triangle",
            message: message,
            primaryAction: TarvenUnavailableAction(title: "Try Again") {
              Task { await load(force: true) }
            },
            secondaryAction: TarvenUnavailableAction(title: "Close", prominent: false) {
              close()
            }
          )
          .padding(28)
        case .empty:
          TarvenUnavailableView(
            title: "Nothing to Wrap Yet",
            systemImage: "sparkles",
            message: "Watch a few movies or episodes first, then come back for your story.",
            primaryAction: TarvenUnavailableAction(title: "Close") { close() }
          )
          .padding(28)
        case .loading:
          ProgressView().controlSize(.large).tint(.white)
            .accessibilityLabel("Loading Wrapped")
        }
      }
      .overlay(alignment: .topTrailing) {
        closeButton
          .padding(.trailing, 10)
          .padding(.top, 4)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .ignoresSafeArea()
    .foregroundStyle(Color(wrappedHex: accent.ink))
    .tarvenAnimation(TarvenMotion.page, value: index)
    .tarvenAnimation(TarvenMotion.standard, value: wrapped != nil)
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onAppear { focused = true }
    .onKeyPress(.rightArrow) {
      go(forward: true)
      return .handled
    }
    .onKeyPress(.leftArrow) {
      go(forward: false)
      return .handled
    }
    .onKeyPress(.space) {
      held.toggle()
      return .handled
    }
    .task { await load(force: false) }
    .task(id: "\(index)-\(held)-\(wrapped != nil)") { await run() }
  }

  private var closeButton: some View {
    Button {
      close()
    } label: {
      Image(systemName: "xmark")
        .font(.headline)
        .frame(width: TarvenDesign.minimumControlSize, height: TarvenDesign.minimumControlSize)
        .contentShape(Rectangle())
    }
    .buttonStyle(TarvenPressableButtonStyle())
    .keyboardShortcut(.cancelAction)
    .accessibilityLabel("Close Wrapped")
    .accessibilityIdentifier("wrapped-close")
  }

  private func content(_ slide: WrappedSlide, accent: WrappedStory.Accent, size: CGSize)
    -> some View
  {
    let wide = size.width >= 900
    // Type grows with the window, within limits that keep a slide on one screen.
    let scale = min(max(size.height / 800, 0.85), 1.5)
    let poster = slide.kind == "summary" ? nil : slide.poster
    return HStack(alignment: .center, spacing: 56) {
      VStack(alignment: .leading, spacing: 14 * scale) {
        Text(slide.eyebrow).font(.system(size: 17 * scale, weight: .bold)).opacity(0.8)
        if slide.kind == "summary" {
          Text(slide.headline).font(.system(size: 44 * scale, weight: .black)).tracking(-1)
          if !wide { posterGrid(slide, width: 240) }
          if let facts = slide.facts {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
              ForEach(facts, id: \.label) { fact in
                GridRow {
                  Text(fact.label).opacity(0.72)
                  Text(fact.value).fontWeight(.heavy)
                }
              }
            }
            .font(.system(size: 17 * scale))
          }
        } else {
          if !wide, let poster {
            posterView(poster, width: 140)
          }
          Text(slide.headline).font(.system(size: 40 * scale, weight: .black)).tracking(-1)
            .lineLimit(3)
            .minimumScaleFactor(0.6)
          if let number = slide.bigNumber {
            VStack(alignment: .leading, spacing: 0) {
              Text(shownNumber ?? number)
                .font(.system(size: 160 * scale, weight: .black).monospacedDigit())
                .tracking(-8 * scale)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
              if let unit = slide.unit {
                Text(unit).font(.system(size: 28 * scale, weight: .heavy))
              }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([number, slide.unit].compactMap { $0 }.joined(separator: " "))
          }
          if let detail = slide.detail { Text(detail).font(.system(size: 20 * scale)) }
        }
        Text(slide.quip)
          .font(.system(size: 20 * scale, weight: .heavy))
          .foregroundStyle(Color(wrappedHex: accent.field))
          .padding(.horizontal, 16 * scale)
          .padding(.vertical, 10 * scale)
          .background(Color(wrappedHex: accent.sticker), in: RoundedRectangle(cornerRadius: 6))
          .rotationEffect(.degrees(-2.5))
          .padding(.top, 8)
      }
      .frame(maxWidth: wide ? 640 : 480, alignment: .leading)
      if wide {
        if slide.kind == "summary" {
          posterGrid(slide, width: min(size.width * 0.3, 420)).rotationEffect(.degrees(2))
        } else if let poster {
          posterView(poster, width: min(size.width * 0.26, size.height * 0.42, 380))
            .rotationEffect(.degrees(3))
        }
      }
    }
    .padding(.horizontal, wide ? 72 : 28)
    .padding(.vertical, 60)
    .frame(maxWidth: wide ? 1240 : .infinity, alignment: .leading)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .id(index)
    .transition(
      reduceMotion
        ? .opacity
        : .asymmetric(
          insertion: .opacity.combined(with: .offset(x: 28)),
          removal: .opacity.combined(with: .offset(x: -18))))
  }

  private func posterView(_ poster: ArtworkSummary, width: CGFloat) -> some View {
    AuthenticatedArtwork(artwork: poster, symbol: "film")
      .frame(width: width, height: width * 1.5)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .shadow(color: .black.opacity(0.35), radius: 24, y: 16)
  }

  @ViewBuilder
  private func posterGrid(_ slide: WrappedSlide, width: CGFloat) -> some View {
    if let posters = slide.posters, !posters.isEmpty {
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(), spacing: 10), count: posters.count == 1 ? 1 : 2),
        spacing: 10
      ) {
        ForEach(Array(posters.prefix(4).enumerated()), id: \.offset) { _, poster in
          AuthenticatedArtwork(artwork: poster, symbol: "film")
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
      }
      .frame(maxWidth: posters.count == 1 ? width * 0.6 : width)
    }
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
      // Room on the left for the window's own buttons and on the right for the persistent close button.
      .frame(height: TarvenDesign.minimumControlSize)
      .padding(.leading, 84)
      .padding(.trailing, 60)
      .padding(.top, 4)
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

  private func close() {
    model.wrappedLaunch = nil
  }

  private func go(forward: Bool) {
    guard let count = wrapped?.slides.count else { return }
    guard let next = WrappedStory.step(from: index, count: count, forward: forward) else {
      return close()
    }
    progress = 0
    index = next
  }

  /// Counts the number up, then runs the bar; holding stops it where it is.
  private func run() async {
    guard let slides = wrapped?.slides, slides.indices.contains(index) else { return }
    let slide = slides[index]
    if progress == 0, !reduceMotion, let target = WrappedStory.countTarget(slide.bigNumber),
      target > 1
    {
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

  private func load(force: Bool = false) async {
    if !force && wrapped != nil { return }
    error = nil
    guard let client = model.profileClient() else {
      error = "Sign in to a profile to view Wrapped."
      return
    }
    do {
      wrapped = try await client.wrapped(year: launch.year, month: launch.month)
      index = 0
      progress = 0
    } catch is CancellationError {
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// "Your October Wrapped is here": the newest ready month, in Statistics and, in its first week,
/// on Home.
struct MonthlyWrappedButton: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    let ready = WrappedStory.readyMonth()
    Button {
      model.wrappedLaunch = WrappedLaunch(year: ready.year, month: ready.month)
    } label: {
      HStack(spacing: 14) {
        Text(String(ready.name.prefix(3))).font(.system(size: 26, weight: .black)).tracking(-1)
          .foregroundStyle(.white)
        VStack(alignment: .leading, spacing: 2) {
          Text("Your \(ready.name) Wrapped is here").font(.headline)
          Text("Last month in slides. It's worse than you think.").font(.callout).opacity(0.85)
        }
        Spacer()
        Image(systemName: "play.fill")
      }
      .foregroundStyle(Color(wrappedHex: 0x22000F))
      .padding(14)
      .background(
        Color(wrappedHex: 0xFF4D88), in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(TarvenPressableButtonStyle())
    .accessibilityIdentifier("monthly-wrapped")
  }
}

/// Every month's Wrapped, not only the newest: a year to choose and its ready months to play.
struct MonthlyWrappedArchive: View {
  @EnvironmentObject private var model: AppModel
  let activityYears: [Int]
  @State private var year: Int?

  var body: some View {
    let years = WrappedStory.wrappedYears(activityYears: activityYears)
    let shownYear = year.flatMap { years.contains($0) ? $0 : nil } ?? years.first ?? 0
    let months = WrappedStory.readyMonths(year: shownYear).reversed()
    TarvenSettingsSection(
      "Monthly Wrapped", symbol: "calendar",
      description: "Play any month again. A month is ready from the 2nd of the next month."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        Picker("Year", selection: Binding(get: { shownYear }, set: { year = $0 })) {
          ForEach(years, id: \.self) { Text(String($0)).tag($0) }
        }
        .frame(width: 160)
        .accessibilityIdentifier("wrapped-archive-year")
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 116, maximum: 160), spacing: 10)],
          alignment: .leading, spacing: 10
        ) {
          ForEach(Array(months), id: \.self) { month in
            Button {
              model.wrappedLaunch = WrappedLaunch(year: shownYear, month: month)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(String(WrappedStory.monthName(month).prefix(3)))
                  .font(.system(size: 22, weight: .black)).tracking(-0.8)
                Text(WrappedStory.monthName(month)).font(.caption.weight(.semibold)).opacity(0.85)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(12)
              .foregroundStyle(Color(wrappedHex: 0x22000F))
              .background(
                Color(wrappedHex: 0xFF4D88).opacity(0.92),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
              )
              .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(TarvenPressableButtonStyle())
            .accessibilityLabel(
              "Play \(WrappedStory.monthName(month)) \(String(shownYear)) Wrapped"
            )
            .accessibilityIdentifier("wrapped-month-\(month)")
          }
        }
      }
    }
    .accessibilityIdentifier("monthly-wrapped-archive")
  }
}
