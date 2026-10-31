import SwiftUI
import UIKit

@MainActor
struct IOSPlayerView: View {
  @StateObject private var controller: IOSPlaybackController
  @StateObject private var previews = IOSScrubPreviews()
  @Environment(\.scenePhase) private var scenePhase
  @FocusState private var focus: Control?
  @State private var lastTransport: Control = .play
  /// Brief indicator for skips made while the controls are hidden.
  @State private var skip: IOSSkipIndicator?

  private enum Control: Hashable {
    case surface, close, backward, play, forward, timeline, audio, subtitles, rate, sleep, retry,
      closeMenu, nightMode, upNextPlay, upNextCancel
    case audioTrack(Int32)
    case subtitleTrack(Int32)
    case rateOption(Double)
    case sleepOption(Int)
    var isTransport: Bool { self == .backward || self == .play || self == .forward }
  }

  init(makeController: @escaping @MainActor () -> IOSPlaybackController) {
    _controller = StateObject(wrappedValue: makeController())
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      IOSVideoSurface(engine: controller.engine).ignoresSafeArea().accessibilityIdentifier(
        "player-surface")
      if controller.isStarting && controller.errorMessage == nil {
        startScreen.transition(.opacity)
      }
      if !controller.controlsVisible || controller.isStarting {
        Color.clear.contentShape(Rectangle()).focusable().focusEffectDisabled()
          .focused($focus, equals: .surface)
          .onTapGesture { controller.userInteracted() }
          // Left and right skip like the Apple TV player; up and down only reveal.
          .iosMoveCommand { direction in
            switch direction {
            case .left where controller.canSeek: skip(by: -controller.seekInterval)
            case .right where controller.canSeek: skip(by: controller.seekInterval)
            default: controller.userInteracted()
            }
          }
          .accessibilityLabel("Show playback controls").accessibilityIdentifier(
            "player-wake-surface")
      }
      if (controller.controlsVisible && !controller.isStarting) || controller.errorMessage != nil {
        controls
      }
      if let skip, !controller.controlsVisible { skipIndicator(skip) }
      // With controls shown, loading is drawn inside Play instead of behind it.
      if controller.isLoading && controller.errorMessage == nil && !controller.controlsVisible
        && !controller.isStarting
      {
        ProgressView().tint(.white).scaleEffect(1.4).accessibilityIdentifier("player-loading")
      }
      if let upNext = controller.upNext, !controller.controlsVisible, controller.trackMenu == nil {
        upNextCard(upNext)
      }
      if let menu = controller.trackMenu { menuView(menu) }
    }
    .animation(.easeInOut(duration: 0.45), value: controller.isStarting)
    .preferredColorScheme(.dark)
    .onAppear {
      controller.start()
      configurePreviews()
    }
    .onDisappear {
      previews.reset()
      controller.close()
    }
    .onChange(of: controller.previewSourceURL) { _, _ in configurePreviews() }
    .onChange(of: controller.duration) { _, _ in configurePreviews() }
    .onChange(of: controller.currentMediaID) { _, _ in configurePreviews() }
    .onChange(of: controller.previewsParallel) { _, _ in configurePreviews() }
    .onChange(of: controller.supportsServerScrubPreviews) { _, _ in configurePreviews() }
    .onChange(of: controller.scrubPosition) { _, position in
      if let position { previews.request(at: position) }
    }
    .onChange(of: controller.upNext != nil) { _, shown in
      if shown, !controller.controlsVisible, controller.trackMenu == nil { focus = .upNextPlay }
    }
    .iosPlayPauseCommand { controller.togglePlayPause() }.iosBackCommand { controller.back() }
    .onChange(of: focus) { _, value in
      if let value, value.isTransport { lastTransport = value }
      if controller.controlsVisible, value != .surface {
        controller.setScrubbing(value == .timeline)
      }
      if value != .timeline { controller.cancelScrub() }
    }
    .task(id: "\(controller.controlsVisible)-\(controller.isStarting)") {
      let visible = controller.controlsVisible && !controller.isStarting
      await Task.yield()
      await Task.yield()
      guard !Task.isCancelled, (controller.controlsVisible && !controller.isStarting) == visible,
        controller.trackMenu == nil
      else { return }
      focus = visible ? .play : .surface
    }
    .task(id: "\(controller.isLoading)-\(controller.isStarting)") {
      guard !controller.isLoading, controller.controlsVisible, !controller.isStarting,
        controller.trackMenu == nil
      else {
        return
      }
      await Task.yield()
      if !Task.isCancelled { focus = .play }
    }
    .onChange(of: controller.errorMessage) { _, message in
      if message != nil { focus = controller.canRetry ? .retry : .close }
    }
    .onChange(of: controller.trackMenu) { previous, menu in
      switch menu {
      case .audio:
        focus = .audioTrack(
          controller.audioTracks.first(where: { $0.id == controller.selectedAudio })?.id
            ?? controller.audioTracks.first?.id ?? -1)
      case .subtitles: focus = .subtitleTrack(controller.selectedSubtitle)
      case .rate: focus = .rateOption(controller.playbackRate)
      case .sleep: focus = .sleepOption(sleepValue)
      case nil:
        switch previous {
        case .audio: focus = .audio
        case .subtitles: focus = .subtitles
        case .rate: focus = .rate
        case .sleep: focus = .sleep
        case nil: focus = .play
        }
      }
    }
    .onChange(of: scenePhase) { _, phase in if phase == .background { controller.background() } }
  }

  private var controls: some View {
    ZStack {
      LinearGradient(
        colors: [.black.opacity(0.60), .clear, .black.opacity(0.85)], startPoint: .top,
        endPoint: .bottom
      ).ignoresSafeArea()
        // A tap on the picture hides the controls again.
        .contentShape(Rectangle()).onTapGesture { controller.hideControls() }
        .accessibilityHidden(true)
      VStack(spacing: IOSDesign.s(0)) {
        HStack(spacing: IOSDesign.s(18)) {
          icon("Close", symbol: "chevron.left", id: .close) { controller.close() }
          Spacer()
          Button {
            controller.trackMenu = .rate
          } label: {
            Text(rateTitle(controller.playbackRate)).monospacedDigit()
          }
          .buttonStyle(IOSButtonStyle()).focusEffectDisabled().focused($focus, equals: .rate)
          .accessibilityIdentifier("player-rate").accessibilityLabel("Playback Rate")
          icon("Audio", symbol: "waveform", id: .audio) { controller.trackMenu = .audio }.disabled(
            controller.audioTracks.isEmpty)
          icon(
            "Subtitles",
            symbol: controller.selectedSubtitle < 0 ? "captions.bubble" : "captions.bubble.fill",
            id: .subtitles
          ) { controller.trackMenu = .subtitles }.disabled(controller.subtitleTracks.isEmpty)
          icon(
            "Sleep Timer", symbol: controller.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill",
            id: .sleep
          ) { controller.trackMenu = .sleep }
        }.iosMoveCommand { if $0 == .down { focus = .play } }
        Spacer()
        HStack(spacing: IOSDesign.s(22)) {
          icon(
            "Back \(controller.seekInterval / 1_000) Seconds", symbol: "gobackward", id: .backward
          ) { controller.seek(by: -controller.seekInterval) }.disabled(!controller.canSeek)
          Button {
            controller.togglePlayPause()
          } label: {
            Group {
              if controller.isLoading && controller.errorMessage == nil {
                ProgressView().tint(.black).accessibilityIdentifier("player-loading")
              } else {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").font(
                  .system(size: IOSDesign.s(30), weight: .bold))
              }
            }.frame(width: IOSDesign.s(78), height: IOSDesign.s(78))
          }.buttonStyle(IOSPlayerPrimaryStyle()).focusEffectDisabled().focused(
            $focus, equals: .play
          )
          .disabled(controller.isLoading).accessibilityIdentifier("player-play")
          .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
          icon(
            "Forward \(controller.seekInterval / 1_000) Seconds", symbol: "goforward", id: .forward
          ) { controller.seek(by: controller.seekInterval) }.disabled(!controller.canSeek)
        }.padding(.horizontal, IOSDesign.s(24)).padding(.vertical, IOSDesign.s(16))
          .background(.ultraThinMaterial, in: Capsule())
          .iosMoveCommand { direction in
            if direction == .up { focus = .rate }
            if direction == .down { focus = .timeline }
          }
        Spacer()
        VStack(alignment: .leading, spacing: IOSDesign.s(18)) {
          Text(controller.title).font(.system(size: IOSDesign.s(30), weight: .semibold)).lineLimit(
            2)
          if let error = controller.errorMessage {
            Text(error).font(.system(size: IOSDesign.s(24))).foregroundStyle(.secondary)
            HStack(spacing: IOSDesign.s(20)) {
              if controller.canRetry {
                Button("Try Again") { controller.retry() }.focused($focus, equals: .retry)
              }
              Button("Back to Library") { controller.close() }.focused($focus, equals: .close)
            }.buttonStyle(IOSButtonStyle())
          } else {
            timeline
          }
          if controller.audioSelectionPending || controller.subtitleSelectionPending {
            Label(
              controller.audioSelectionPending ? "Switching audio…" : "Switching subtitles…",
              systemImage: "arrow.triangle.2.circlepath"
            ).font(.system(size: IOSDesign.s(20))).foregroundStyle(.secondary)
              .accessibilityIdentifier(
                "player-track-pending")
          }
          if let message = controller.progressMessage {
            Text(message).font(.system(size: IOSDesign.s(20))).foregroundStyle(.secondary)
              .accessibilityIdentifier("player-progress-status")
          }
        }
      }.padding(.horizontal, IOSDesign.s(80)).padding(.vertical, IOSDesign.s(54))
    }.defaultFocus($focus, .play, priority: .userInitiated).disabled(
      controller.trackMenu != nil || controller.isClosing)
  }

  /// Skips with hidden controls: the picture stays clear, so further presses
  /// keep skipping. Only a slim position bar appears for a moment.
  private func skip(by offset: Int64) {
    controller.seek(by: offset, revealControls: false)
    let indicator = IOSSkipIndicator(offset: offset)
    skip = indicator
    Task {
      try? await Task.sleep(for: .seconds(2))
      if skip?.id == indicator.id { skip = nil }
    }
  }

  private func skipIndicator(_ indicator: IOSSkipIndicator) -> some View {
    VStack(alignment: .leading, spacing: IOSDesign.s(12)) {
      Label(
        "\(indicator.offset > 0 ? "+" : "−")\(abs(indicator.offset) / 1_000) s",
        systemImage: indicator.offset > 0 ? "goforward" : "gobackward"
      ).font(.system(size: IOSDesign.s(26), weight: .semibold))
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.25))
          Capsule().fill(.white).frame(width: geometry.size.width * fraction)
        }
      }.frame(height: IOSDesign.s(6))
      HStack {
        Text(IOSPlayerPolicy.timeLabel(milliseconds: controller.position))
        Spacer()
        Text(IOSPlayerPolicy.timeLabel(milliseconds: controller.duration))
      }.font(.system(size: IOSDesign.s(22)).monospacedDigit()).foregroundStyle(.secondary)
    }
    .padding(.horizontal, IOSDesign.s(30)).padding(.vertical, IOSDesign.s(22))
    .background(
      .ultraThinMaterial, in: RoundedRectangle(cornerRadius: IOSDesign.s(24), style: .continuous)
    )
    .padding(.horizontal, IOSDesign.s(80)).padding(.bottom, IOSDesign.s(60))
    .frame(maxHeight: .infinity, alignment: .bottom)
    .accessibilityElement(children: .ignore).accessibilityIdentifier("player-skip")
    .accessibilityValue(
      "\(IOSPlayerPolicy.timeLabel(milliseconds: controller.position)) of \(IOSPlayerPolicy.timeLabel(milliseconds: controller.duration))"
    )
    .allowsHitTesting(false)
  }

  private var timeline: some View {
    Button {
      // Select jumps to a scrubbed position; otherwise it plays or pauses.
      if !controller.commitScrub() { controller.togglePlayPause() }
    } label: {
      VStack(spacing: IOSDesign.s(12)) {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.25))
            Capsule().fill(.white.opacity(focus == .timeline ? 1 : 0.75)).frame(
              width: geometry.size.width * fraction)
            if controller.scrubPosition != nil {
              // Where playback is now, while the bar shows where Select would jump.
              Capsule().fill(.white.opacity(0.45))
                .frame(width: IOSDesign.s(4), height: IOSDesign.s(18))
                .offset(x: geometry.size.width * playedFraction - 2)
            }
          }
          .overlay(alignment: .bottomLeading) {
            if let scrub = controller.scrubPosition {
              scrubPreview(at: scrub, width: geometry.size.width)
            }
          }
        }.frame(height: focus == .timeline ? 8 : 5)
        HStack {
          Text(
            IOSPlayerPolicy.timeLabel(milliseconds: controller.scrubPosition ?? controller.position)
          )
          Spacer()
          if let endsAt = IOSPlayerPolicy.endTimeLabel(
            position: controller.position, duration: controller.duration,
            rate: controller.playbackRate, now: Date())
          {
            Text(endsAt).accessibilityIdentifier("player-ends-at")
            Spacer()
          }
          Text(IOSPlayerPolicy.timeLabel(milliseconds: controller.duration))
        }.font(.system(size: IOSDesign.s(22)).monospacedDigit()).foregroundStyle(.secondary)
      }.padding(.vertical, IOSDesign.s(16)).contentShape(Rectangle())
        // Touch: drag along the bar (or tap a place) to choose a position; lifting jumps there.
        .overlay {
          GeometryReader { geometry in
            Color.clear.contentShape(Rectangle())
              .gesture(
                DragGesture(minimumDistance: 0)
                  .onChanged { value in
                    controller.scrub(toFraction: value.location.x / max(geometry.size.width, 1))
                  }
                  .onEnded { _ in
                    controller.commitScrub()
                    controller.setScrubbing(false)
                  })
          }
        }
    }.buttonStyle(IOSContentButtonStyle()).focusEffectDisabled().focused($focus, equals: .timeline)
      .disabled(!controller.canSeek)
      .iosMoveCommand { direction in
        switch direction {
        case .left: controller.scrub(forward: false)
        case .right: controller.scrub(forward: true)
        case .up, .down: focus = lastTransport
        }
      }
      .accessibilityIdentifier("player-timeline").accessibilityLabel("Playback position")
      .accessibilityValue(
        "\(IOSPlayerPolicy.timeLabel(milliseconds: controller.scrubPosition ?? controller.position)) of \(IOSPlayerPolicy.timeLabel(milliseconds: controller.duration))"
      )
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: controller.seek(by: controller.seekInterval)
        case .decrement: controller.seek(by: -controller.seekInterval)
        @unknown default: break
        }
      }
  }

  private var fraction: Double {
    controller.duration > 0
      ? min(
        1,
        max(
          0, Double(controller.scrubPosition ?? controller.position) / Double(controller.duration)))
      : 0
  }

  private var playedFraction: Double {
    controller.duration > 0
      ? min(1, max(0, Double(controller.position) / Double(controller.duration))) : 0
  }

  private func configurePreviews() {
    let fetcher: (@MainActor (UUID, Int64) async -> Data?)?
    if controller.supportsServerScrubPreviews {
      fetcher = { [weak controller] id, sec in
        await controller?.fetchScrubPreviewFrame(mediaID: id, seconds: Int(sec))
      }
    } else {
      fetcher = nil
    }
    previews.configure(
      mediaID: controller.currentMediaID, source: controller.previewSourceURL,
      duration: controller.duration, parallel: controller.previewsParallel,
      serverFrameFetcher: fetcher)
  }

  /// The frame at the scrub position above the timeline; it never leaves memory.
  private func scrubPreview(at position: Int64, width: CGFloat) -> some View {
    let size = CGSize(width: IOSDesign.s(384), height: IOSDesign.s(216))
    let center =
      controller.duration > 0 ? width * Double(position) / Double(controller.duration) : 0
    let x = min(max(center - size.width / 2, 0), max(width - size.width, 0))
    return VStack(spacing: IOSDesign.s(10)) {
      ZStack {
        Color.black
        if previews.imageBucket == previews.bucket(for: position), let image = previews.image {
          Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
        } else {
          ProgressView().tint(.white)
        }
      }
      .frame(width: size.width, height: size.height)
      .clipShape(RoundedRectangle(cornerRadius: IOSDesign.s(14), style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: IOSDesign.s(14), style: .continuous).stroke(
          .white.opacity(0.35), lineWidth: 2)
      }
      .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
      Text(IOSPlayerPolicy.timeLabel(milliseconds: position))
        .font(.system(size: IOSDesign.s(24), weight: .semibold).monospacedDigit())
    }
    .offset(x: x, y: -40)
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier("player-scrub-preview")
    .accessibilityLabel("Jump to \(IOSPlayerPolicy.timeLabel(milliseconds: position))")
  }

  /// Black with a turning ring until the picture moves; reconnecting still explains itself.
  private var startScreen: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VStack(spacing: IOSDesign.s(28)) {
        IOSStartRing().frame(width: IOSDesign.s(72), height: IOSDesign.s(72))
        if let message = controller.progressMessage {
          Text(message).font(.system(size: IOSDesign.s(24))).foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(controller.progressMessage ?? "Loading")
    .accessibilityIdentifier("player-start-screen")
  }

  private func upNextCard(_ upNext: IOSUpNext) -> some View {
    VStack(alignment: .leading, spacing: IOSDesign.s(18)) {
      Text("UP NEXT").font(.system(size: IOSDesign.s(20), weight: .bold)).tracking(1.2)
        .foregroundStyle(.secondary)
      Text(upNext.title).font(.system(size: IOSDesign.s(28), weight: .semibold)).lineLimit(2)
      HStack(spacing: IOSDesign.s(18)) {
        Button {
          controller.playNextNow()
        } label: {
          Label("Play Now · \(upNext.seconds)", systemImage: "play.fill").monospacedDigit()
        }
        .buttonStyle(IOSButtonStyle()).focusEffectDisabled().focused($focus, equals: .upNextPlay)
        .accessibilityIdentifier("player-up-next-play")
        Button("Cancel") { controller.dismissUpNext() }
          .buttonStyle(IOSButtonStyle()).focusEffectDisabled().focused(
            $focus, equals: .upNextCancel
          )
          .accessibilityIdentifier("player-up-next-cancel")
      }
    }
    .padding(IOSDesign.s(30))
    .frame(width: IOSDesign.s(620), alignment: .leading)
    .background(
      .ultraThinMaterial, in: RoundedRectangle(cornerRadius: IOSDesign.s(28), style: .continuous)
    )
    .padding(.trailing, IOSDesign.s(80)).padding(.bottom, IOSDesign.s(70))
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

    .accessibilityIdentifier("player-up-next")
  }
  private var sleepValue: Int {
    switch controller.sleepTimer {
    case .off: 0
    case .endOfEpisode: -1
    case .minutes(let minutes): minutes
    }
  }
  private func rateTitle(_ rate: Double) -> String { String(format: "%gx", rate) }

  private func icon(_ title: String, symbol: String, id: Control, action: @escaping () -> Void)
    -> some View
  {
    Button {
      controller.userInteracted()
      action()
    } label: {
      Image(systemName: symbol).font(.system(size: IOSDesign.s(24), weight: .semibold))
    }
    .buttonStyle(IOSButtonStyle(kind: .icon)).focusEffectDisabled().focused($focus, equals: id)
    .accessibilityLabel(title).accessibilityIdentifier("player-\(id)")
  }

  private func menuView(_ menu: IOSPlaybackController.TrackMenu) -> some View {
    ZStack {
      Color.black.opacity(0.55).ignoresSafeArea()
      VStack(alignment: .leading, spacing: IOSDesign.s(22)) {
        Text(menuTitle(menu)).font(.title2.weight(.semibold))
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: IOSDesign.s(14)) {
              switch menu {
              case .audio:
                ForEach(controller.audioTracks) { track in
                  option(
                    track.title, selected: controller.selectedAudio == track.id,
                    id: .audioTrack(track.id)
                  ) { controller.selectAudio(track.id) }.id(track.id)
                }
                option("Night Mode", selected: controller.nightMode, id: .nightMode) {
                  controller.setNightMode(!controller.nightMode)
                }
              case .subtitles:
                option("Off", selected: controller.selectedSubtitle < 0, id: .subtitleTrack(-1)) {
                  controller.selectSubtitle(-1)
                }.id(Int32(-1))
                ForEach(controller.subtitleTracks) { track in
                  option(
                    track.title, selected: controller.selectedSubtitle == track.id,
                    id: .subtitleTrack(track.id)
                  ) { controller.selectSubtitle(track.id) }.id(track.id)
                }
              case .rate:
                ForEach(IOSPlaybackPreferences.supportedRates, id: \.self) { rate in
                  option(
                    rate == 1 ? "Standard · 1x" : rateTitle(rate),
                    selected: controller.playbackRate == rate, id: .rateOption(rate)
                  ) { controller.setPlaybackRate(rate) }.id(rate)
                }
              case .sleep:
                ForEach([0, -1, 15, 30, 45, 60, 90], id: \.self) { value in
                  let timer: IOSSleepTimer =
                    value == 0 ? .off : value == -1 ? .endOfEpisode : .minutes(value)
                  option(
                    timer.title, selected: controller.sleepTimer == timer, id: .sleepOption(value)
                  ) { controller.setSleepTimer(timer) }.id(value)
                }
              }
            }.padding(IOSDesign.s(10))
          }.frame(maxHeight: IOSDesign.s(460))
            .task {
              switch menu {
              case .audio: proxy.scrollTo(controller.selectedAudio, anchor: .center)
              case .subtitles: proxy.scrollTo(controller.selectedSubtitle, anchor: .center)
              case .rate: proxy.scrollTo(controller.playbackRate, anchor: .center)
              case .sleep: proxy.scrollTo(sleepValue, anchor: .center)
              }
            }
        }
        Button("Done") { controller.trackMenu = nil }.buttonStyle(IOSButtonStyle()).focused(
          $focus, equals: .closeMenu
        ).accessibilityIdentifier("player-tracks-done")
      }.padding(IOSDesign.s(36)).frame(width: IOSDesign.s(740)).background(
        .regularMaterial, in: RoundedRectangle(cornerRadius: IOSDesign.s(30), style: .continuous)
      )
    }.accessibilityIdentifier("player-tracks")
  }
  private func menuTitle(_ menu: IOSPlaybackController.TrackMenu) -> String {
    switch menu {
    case .audio: "Audio"
    case .subtitles: "Subtitles"
    case .rate: "Playback Rate"
    case .sleep: "Sleep Timer"
    }
  }
  private func option(_ title: String, selected: Bool, id: Control, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(spacing: IOSDesign.s(16)) {
        Text(title).font(.system(size: IOSDesign.s(24))).lineLimit(2)
        Spacer()
        if selected { Image(systemName: "checkmark") }
      }.frame(maxWidth: .infinity, minHeight: IOSDesign.s(56), alignment: .leading).padding(
        .horizontal, IOSDesign.s(22)
      )
      .padding(.vertical, IOSDesign.s(8))
    }.buttonStyle(IOSButtonStyle(kind: .row)).focusEffectDisabled().focused($focus, equals: id)
      .accessibilityIdentifier("player-\(id)").accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct IOSPlayerPrimaryStyle: ButtonStyle {
  @Environment(\.isFocused) private var focused
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.foregroundStyle(.black).background(.white, in: Circle())
      .overlay(Circle().stroke(.white.opacity(focused ? 1 : 0), lineWidth: 3))
      .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.025 : 1)
  }
}

private struct IOSVideoSurface: UIViewRepresentable {
  let engine: any IOSPlaybackEngine
  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .black
    view.isUserInteractionEnabled = false
    engine.attach(to: view)
    return view
  }
  func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct IOSSkipIndicator {
  let id = UUID()
  let offset: Int64
}

/// A white arc that turns and gently grows and shrinks while a title starts.
private struct IOSStartRing: View {
  var body: some View {
    TimelineView(.animation) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      let rotation = time.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
      let length = 0.42 + 0.26 * sin(time * 2 * .pi / 1.8)
      ZStack {
        Circle().stroke(.white.opacity(0.12), lineWidth: 5)
        Circle()
          .trim(from: 0, to: length)
          .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
          .rotationEffect(.degrees(rotation - 90))
      }
    }
  }
}
