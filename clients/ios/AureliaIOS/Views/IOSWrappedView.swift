import SwiftUI

extension Color {
  /// A color from 0xRRGGBB, for Wrapped's fixed palette.
  init(wrappedHex hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

/// Wrapped keeps its story colors and numbers, with a scrollable reading column and native
/// navigation. Accessibility text sizes, VoiceOver and Reduce Motion use manual slides.
struct IOSWrappedView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.scenePhase) private var scenePhase
  @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 38
  @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 150
  let launch: IOSWrappedLaunch
  @State private var wrapped: IOSYearWrapped?
  @State private var error: String?
  @State private var index = 0
  @State private var progress: Double = 0
  @State private var countProgress: Double = 0
  @State private var paused = false
  @State private var scrolling = false
  @AccessibilityFocusState(for: .voiceOver) private var titleFocused: Bool

  private var automaticMotion: Bool {
    !reduceMotion && !voiceOverEnabled && !dynamicTypeSize.isAccessibilitySize
  }

  private var timerKey: TimerKey {
    TimerKey(
      index: index, count: wrapped?.slides.count ?? 0,
      running: automaticMotion && scenePhase == .active && !paused && !scrolling)
  }

  var body: some View {
    let slide = wrapped?.slides.indices.contains(index) == true ? wrapped?.slides[index] : nil
    let accent = IOSWrapped.accent(slide?.accent ?? "night")
    ZStack {
      Color(wrappedHex: accent.field).ignoresSafeArea()
      if let poster = slide?.poster {
        IOSArtworkView(artwork: poster, width: 320, symbol: nil)
          .blur(radius: 40)
          .opacity(0.3)
          .ignoresSafeArea()
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      VStack(spacing: 0) {
        header(count: wrapped?.slides.count ?? 0, accent: accent)
        if let slide {
          ScrollView {
            content(slide, accent: accent)
              .padding(.vertical, 24)
              .frame(maxWidth: 600, alignment: .leading)
              .frame(maxWidth: .infinity)
              .padding(.horizontal, IOSDesign.margin)
          }
          .scrollBounceBehavior(.basedOnSize)
          .onScrollPhaseChange { _, phase in scrolling = phase != .idle }
          .id(index)
          .transition(.opacity)
          .accessibilityIdentifier("wrapped-content")
          footer(count: wrapped?.slides.count ?? 0, accent: accent)
        } else if let error {
          ScrollView {
            VStack(spacing: 16) {
              Text("Wrapped didn't load.").font(.title.weight(.black))
              Text(error).multilineTextAlignment(.center)
              Button("Close") { dismiss() }.buttonStyle(IOSButtonStyle(kind: .primary))
            }
            .padding(28)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
          }
        } else {
          ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .foregroundStyle(Color(wrappedHex: accent.ink))
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: index)
    .statusBarHidden()
    .task { await load() }
    .task(id: timerKey) { await run() }
    .onChange(of: automaticMotion) { _, enabled in
      // If accessibility is enabled during a count, immediately show the actual value.
      if !enabled { countProgress = 1 }
    }
    .onChange(of: paused) { _, paused in
      if paused { countProgress = 1 }
    }
  }

  private func content(_ slide: IOSWrappedSlide, accent: IOSWrapped.Accent) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(slide.eyebrow).font(.subheadline.weight(.bold)).opacity(0.8)
      if slide.kind != "summary", let poster = slide.poster {
        IOSArtworkView(artwork: poster, width: 200)
          .frame(width: 140, height: 210)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .rotationEffect(.degrees(reduceMotion ? 0 : -3))
          .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
      }
      Text(slide.headline)
        .font(.system(size: headlineSize, weight: .black))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($titleFocused)
        .onAppear { if voiceOverEnabled { titleFocused = true } }
      if slide.kind == "summary" {
        if let posters = slide.posters, !posters.isEmpty {
          LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
          ) {
            ForEach(Array(posters.prefix(4).enumerated()), id: \.offset) { _, poster in
              IOSArtworkView(artwork: poster, width: 160)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
          }
          .frame(maxWidth: 280)
        }
        if let facts = slide.facts { factsContent(facts) }
      } else {
        if let number = slide.bigNumber {
          VStack(alignment: .leading, spacing: 0) {
            Text(displayedNumber(number))
              .font(.system(size: numberSize, weight: .black).monospacedDigit())
              .minimumScaleFactor(0.1)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
            if let unit = slide.unit {
              Text(unit).font(.title.weight(.heavy)).fixedSize(horizontal: false, vertical: true)
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel([number, slide.unit].compactMap { $0 }.joined(separator: " "))
        }
        if let detail = slide.detail {
          Text(detail).font(.title3).fixedSize(horizontal: false, vertical: true)
        }
      }
      Text(slide.quip)
        .font(.title3.weight(.heavy))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Color(wrappedHex: accent.field))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(wrappedHex: accent.sticker), in: RoundedRectangle(cornerRadius: 6))
        .rotationEffect(.degrees(reduceMotion ? 0 : -2.5))
        .padding(.top, 8)
    }
  }

  @ViewBuilder
  private func factsContent(_ facts: [IOSWrappedFact]) -> some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 16) {
        ForEach(facts, id: \.label) { fact in
          VStack(alignment: .leading, spacing: 4) {
            Text(fact.label).opacity(0.72)
            Text(fact.value).fontWeight(.heavy)
          }
          .accessibilityElement(children: .combine)
        }
      }
    } else {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
        ForEach(facts, id: \.label) { fact in
          GridRow {
            Text(fact.label).opacity(0.72)
            Text(fact.value).fontWeight(.heavy)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func header(count: Int, accent: IOSWrapped.Accent) -> some View {
    VStack(spacing: 8) {
      if count > 0 {
        HStack(spacing: 4) {
          ForEach(0..<count, id: \.self) { at in
            GeometryReader { geometry in
              Capsule().fill(Color(wrappedHex: accent.ink).opacity(0.28))
                .overlay(alignment: .leading) {
                  Capsule().fill(Color(wrappedHex: accent.ink))
                    .frame(
                      width: geometry.size.width * (at < index ? 1 : at == index ? progress : 0))
                }
            }
            .frame(height: 3)
          }
        }
        .accessibilityHidden(true)
      }
      HStack(spacing: 12) {
        if count > 0 {
          Text("\(index + 1) of \(count)").font(.caption.monospacedDigit())
            .accessibilityLabel("Slide \(index + 1) of \(count)")
        }
        Spacer(minLength: 8)
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .background(Color(wrappedHex: accent.ink).opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Wrapped")
        .accessibilityIdentifier("wrapped-close")
      }
    }
    .padding(.top, 8).padding(.bottom, 4)
    .frame(maxWidth: 600)
    .padding(.horizontal, IOSDesign.margin)
    .frame(maxWidth: .infinity)
    .background(Color(wrappedHex: accent.field).opacity(0.94))
  }

  private func footer(count: Int, accent: IOSWrapped.Accent) -> some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
    return layout {
      Button {
        go(forward: false)
      } label: {
        Label("Previous", systemImage: "chevron.left")
          .frame(maxWidth: .infinity, minHeight: 32)
      }
      .disabled(index == 0)
      .accessibilityLabel("Previous slide")
      .accessibilityIdentifier("wrapped-previous")
      if automaticMotion {
        Button {
          paused.toggle()
        } label: {
          Image(systemName: paused ? "play.fill" : "pause.fill").frame(minWidth: 28, minHeight: 32)
        }
        .accessibilityLabel(paused ? "Resume automatic slides" : "Pause automatic slides")
        .accessibilityIdentifier("wrapped-pause")
      }
      Button {
        go(forward: true)
      } label: {
        Label(
          index + 1 < count ? "Next" : "Done",
          systemImage: index + 1 < count ? "chevron.right" : "checkmark"
        )
        .frame(maxWidth: .infinity, minHeight: 32)
      }
      .accessibilityLabel(index + 1 < count ? "Next slide" : "Close Wrapped")
      .accessibilityIdentifier("wrapped-next")
    }
    .font(.body.weight(.semibold))
    .buttonStyle(.bordered)
    .controlSize(.large)
    .tint(Color(wrappedHex: accent.ink))
    .padding(.vertical, 12)
    .frame(maxWidth: 600)
    .padding(.horizontal, IOSDesign.margin)
    .frame(maxWidth: .infinity)
    .background(Color(wrappedHex: accent.field).opacity(0.94))
  }

  private func displayedNumber(_ number: String) -> String {
    IOSWrapped.countPresentation(
      number, fraction: countProgress, automaticMotion: automaticMotion, paused: paused)
  }

  private func go(forward: Bool) {
    guard let count = wrapped?.slides.count else { return }
    guard let next = IOSWrapped.step(from: index, count: count, forward: forward) else {
      return dismiss()
    }
    progress = 0
    countProgress = automaticMotion && !paused ? 0 : 1
    scrolling = false
    titleFocused = false
    index = next
  }

  private struct TimerKey: Equatable {
    let index: Int
    let count: Int
    let running: Bool
  }

  /// Count and advance only while someone can see an active, unpaused story. Scroll gestures
  /// pause both loops; accessibility uses stable values and waits for the native Next button.
  private func run() async {
    guard timerKey.running, let slides = wrapped?.slides, slides.indices.contains(index) else {
      return
    }
    let slide = slides[index]
    do {
      if countProgress < 1, let target = IOSWrapped.countTarget(slide.bigNumber), target > 1 {
        let clock = ContinuousClock()
        let started = clock.now
        let initial = countProgress
        while countProgress < 1 {
          try Task.checkCancellation()
          countProgress = min(1, initial + elapsed(started.duration(to: clock.now)) / 1.1)
          if countProgress < 1 { try await Task.sleep(for: .milliseconds(30)) }
        }
      }
      let clock = ContinuousClock()
      let started = clock.now
      let initial = progress
      while progress < 1 {
        try await Task.sleep(for: .milliseconds(50))
        try Task.checkCancellation()
        progress = min(
          1, initial + elapsed(started.duration(to: clock.now)) / IOSWrapped.slideSeconds)
      }
      try Task.checkCancellation()
      go(forward: true)
    } catch {
      // Cancellation owns every exit; an old slide must never mutate the next slide's state.
      return
    }
  }

  private func elapsed(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

  private func load() async {
    guard wrapped == nil, let client = model.client else { return }
    let sessionID = model.session?.sessionId
    do {
      let loaded = try await client.wrapped(year: launch.year, month: launch.month)
      guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
      if loaded.slides.isEmpty {
        error = "No Wrapped slides are available for this period."
      } else {
        wrapped = loaded
      }
    } catch {
      guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
      self.error = error.localizedDescription
    }
  }
}
