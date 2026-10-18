import SwiftUI
import UIKit

@MainActor
struct TVPlayerView: View {
  @StateObject private var controller: TVPlaybackController
  @StateObject private var previews = TVScrubPreviews()
  @Environment(\.scenePhase) private var scenePhase
  @FocusState private var focus: Control?
  @State private var lastTransport: Control = .play
  /// Brief indicator for skips made while the controls are hidden.
  @State private var skip: TVSkipIndicator?

  private enum Control: Hashable {
    case surface, close, backward, play, forward, timeline, audio, subtitles, rate, sleep, retry,
      closeMenu, nightMode, upNextPlay, upNextCancel
    case audioTrack(Int32)
    case subtitleTrack(Int32)
    case rateOption(Double)
    case sleepOption(Int)
    var isTransport: Bool { self == .backward || self == .play || self == .forward }
  }

  init(makeController: @escaping @MainActor () -> TVPlaybackController) {
    _controller = StateObject(wrappedValue: makeController())
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      TVVideoSurface(engine: controller.engine).ignoresSafeArea().accessibilityIdentifier(
        "player-surface")
      if controller.isStarting && controller.errorMessage == nil {
        startScreen.transition(.opacity)
      }
      if !controller.controlsVisible || controller.isStarting {
        Color.clear.contentShape(Rectangle()).focusable().focusEffectDisabled()
          .focused($focus, equals: .surface)
          .onTapGesture { controller.userInteracted() }
          // Left and right skip like the Apple TV player; up and down only reveal.
          .onMoveCommand { direction in
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
    .onChange(of: controller.scrubPosition) { _, position in
      if let position { previews.request(at: position) }
    }
    .onChange(of: controller.upNext != nil) { _, shown in
      if shown, !controller.controlsVisible, controller.trackMenu == nil { focus = .upNextPlay }
    }
    .onPlayPauseCommand { controller.togglePlayPause() }.onExitCommand { controller.back() }
    .onChange(of: focus) { _, value in
      if let value, value.isTransport { lastTransport = value }
      if controller.controlsVisible, value != .surface {
        controller.setScrubbing(value == .timeline)
      }
      if value != .timeline { controller.cancelScrub() }
    }
    .task(id: controller.controlsVisible) {
      let visible = controller.controlsVisible
      await Task.yield()
      await Task.yield()
      guard !Task.isCancelled, controller.controlsVisible == visible, controller.trackMenu == nil
      else { return }
      focus = visible ? .play : .surface
    }
    .task(id: controller.isLoading) {
      guard !controller.isLoading, controller.controlsVisible, controller.trackMenu == nil else {
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
      VStack(spacing: 0) {
        HStack(spacing: 18) {
          icon("Close", symbol: "chevron.left", id: .close) { controller.close() }
          Spacer()
          Button {
            controller.trackMenu = .rate
          } label: {
            Text(rateTitle(controller.playbackRate)).monospacedDigit()
          }
          .buttonStyle(TVButtonStyle()).focusEffectDisabled().focused($focus, equals: .rate)
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
        }.focusSection().onMoveCommand { if $0 == .down { focus = .play } }
        Spacer()
        HStack(spacing: 22) {
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
                  .system(size: 30, weight: .bold))
              }
            }.frame(width: 78, height: 78)
          }.buttonStyle(TVPlayerPrimaryStyle()).focusEffectDisabled().focused($focus, equals: .play)
            .disabled(controller.isLoading).accessibilityIdentifier("player-play")
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
          icon(
            "Forward \(controller.seekInterval / 1_000) Seconds", symbol: "goforward", id: .forward
          ) { controller.seek(by: controller.seekInterval) }.disabled(!controller.canSeek)
        }.padding(.horizontal, 24).padding(.vertical, 16)
          .background(.ultraThinMaterial, in: Capsule())
          .focusSection().onMoveCommand { direction in
            if direction == .up { focus = .rate }
            if direction == .down { focus = .timeline }
          }
        Spacer()
        VStack(alignment: .leading, spacing: 18) {
          Text(controller.title).font(.system(size: 30, weight: .semibold)).lineLimit(2)
          if let error = controller.errorMessage {
            Text(error).font(.system(size: 24)).foregroundStyle(.secondary)
            HStack(spacing: 20) {
              if controller.canRetry {
                Button("Try Again") { controller.retry() }.focused($focus, equals: .retry)
              }
              Button("Back to Library") { controller.close() }.focused($focus, equals: .close)
            }.buttonStyle(TVButtonStyle())
          } else {
            timeline
          }
          if controller.audioSelectionPending || controller.subtitleSelectionPending {
            Label(
              controller.audioSelectionPending ? "Switching audio…" : "Switching subtitles…",
              systemImage: "arrow.triangle.2.circlepath"
            ).font(.system(size: 20)).foregroundStyle(.secondary).accessibilityIdentifier(
              "player-track-pending")
          }
          if let message = controller.progressMessage {
            Text(message).font(.system(size: 20)).foregroundStyle(.secondary)
              .accessibilityIdentifier("player-progress-status")
          }
        }.focusSection()
      }.padding(.horizontal, 80).padding(.vertical, 54)
    }.defaultFocus($focus, .play, priority: .userInitiated).disabled(
      controller.trackMenu != nil || controller.isClosing)
  }

  /// Skips with hidden controls: the picture stays clear, so further presses
  /// keep skipping. Only a slim position bar appears for a moment.
  private func skip(by offset: Int64) {
    controller.seek(by: offset, revealControls: false)
    let indicator = TVSkipIndicator(offset: offset)
    skip = indicator
    Task {
      try? await Task.sleep(for: .seconds(2))
      if skip?.id == indicator.id { skip = nil }
    }
  }

  private func skipIndicator(_ indicator: TVSkipIndicator) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(
        "\(indicator.offset > 0 ? "+" : "−")\(abs(indicator.offset) / 1_000) s",
        systemImage: indicator.offset > 0 ? "goforward" : "gobackward"
      ).font(.system(size: 26, weight: .semibold))
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.25))
          Capsule().fill(.white).frame(width: geometry.size.width * fraction)
        }
      }.frame(height: 6)
      HStack {
        Text(TVPlayerPolicy.timeLabel(milliseconds: controller.position))
        Spacer()
        Text(TVPlayerPolicy.timeLabel(milliseconds: controller.duration))
      }.font(.system(size: 22).monospacedDigit()).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 30).padding(.vertical, 22)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .padding(.horizontal, 80).padding(.bottom, 60)
    .frame(maxHeight: .infinity, alignment: .bottom)
    .accessibilityElement(children: .ignore).accessibilityIdentifier("player-skip")
    .accessibilityValue(
      "\(TVPlayerPolicy.timeLabel(milliseconds: controller.position)) of \(TVPlayerPolicy.timeLabel(milliseconds: controller.duration))"
    )
    .allowsHitTesting(false)
  }

  private var timeline: some View {
    Button {
      // Select jumps to a scrubbed position; otherwise it plays or pauses.
      if !controller.commitScrub() { controller.togglePlayPause() }
    } label: {
      VStack(spacing: 12) {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.25))
            Capsule().fill(.white.opacity(focus == .timeline ? 1 : 0.75)).frame(
              width: geometry.size.width * fraction)
            if controller.scrubPosition != nil {
              // Where playback is now, while the bar shows where Select would jump.
              Capsule().fill(.white.opacity(0.45))
                .frame(width: 4, height: 18)
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
            TVPlayerPolicy.timeLabel(milliseconds: controller.scrubPosition ?? controller.position))
          Spacer()
          if let endsAt = TVPlayerPolicy.endTimeLabel(
            position: controller.position, duration: controller.duration,
            rate: controller.playbackRate, now: Date())
          {
            Text(endsAt).accessibilityIdentifier("player-ends-at")
            Spacer()
          }
          Text(TVPlayerPolicy.timeLabel(milliseconds: controller.duration))
        }.font(.system(size: 22).monospacedDigit()).foregroundStyle(.secondary)
      }.padding(.vertical, 16).contentShape(Rectangle())
    }.buttonStyle(TVContentButtonStyle()).focusEffectDisabled().focused($focus, equals: .timeline)
      .disabled(!controller.canSeek)
      .onMoveCommand { direction in
        switch direction {
        case .left: controller.scrub(forward: false)
        case .right: controller.scrub(forward: true)
        case .up, .down: focus = lastTransport
        default: break
        }
      }
      .accessibilityIdentifier("player-timeline").accessibilityLabel("Playback position")
      .accessibilityValue(
        "\(TVPlayerPolicy.timeLabel(milliseconds: controller.position)) of \(TVPlayerPolicy.timeLabel(milliseconds: controller.duration))"
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
    previews.configure(
      mediaID: controller.currentMediaID, source: controller.previewSourceURL,
      duration: controller.duration, parallel: controller.previewsParallel)
  }

  /// The frame at the scrub position above the timeline; it never leaves memory.
  private func scrubPreview(at position: Int64, width: CGFloat) -> some View {
    let size = CGSize(width: 384, height: 216)
    let center =
      controller.duration > 0 ? width * Double(position) / Double(controller.duration) : 0
    let x = min(max(center - size.width / 2, 0), max(width - size.width, 0))
    return VStack(spacing: 10) {
      ZStack {
        Color.black
        if previews.imageBucket == previews.bucket(for: position), let image = previews.image {
          Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
        } else {
          ProgressView().tint(.white)
        }
      }
      .frame(width: size.width, height: size.height)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(
          .white.opacity(0.35), lineWidth: 2)
      }
      .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
      Text(TVPlayerPolicy.timeLabel(milliseconds: position))
        .font(.system(size: 24, weight: .semibold).monospacedDigit())
    }
    .offset(x: x, y: -40)
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier("player-scrub-preview")
    .accessibilityLabel("Jump to \(TVPlayerPolicy.timeLabel(milliseconds: position))")
  }

  /// Black with a turning ring until the picture moves; reconnecting still explains itself.
  private var startScreen: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VStack(spacing: 28) {
        TVStartRing().frame(width: 72, height: 72)
        if let message = controller.progressMessage {
          Text(message).font(.system(size: 24)).foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(controller.progressMessage ?? "Loading")
    .accessibilityIdentifier("player-start-screen")
  }

  private func upNextCard(_ upNext: TVUpNext) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("UP NEXT").font(.system(size: 20, weight: .bold)).tracking(1.2)
        .foregroundStyle(.secondary)
      Text(upNext.title).font(.system(size: 28, weight: .semibold)).lineLimit(2)
      HStack(spacing: 18) {
        Button {
          controller.playNextNow()
        } label: {
          Label("Play Now · \(upNext.seconds)", systemImage: "play.fill").monospacedDigit()
        }
        .buttonStyle(TVButtonStyle()).focusEffectDisabled().focused($focus, equals: .upNextPlay)
        .accessibilityIdentifier("player-up-next-play")
        Button("Cancel") { controller.dismissUpNext() }
          .buttonStyle(TVButtonStyle()).focusEffectDisabled().focused($focus, equals: .upNextCancel)
          .accessibilityIdentifier("player-up-next-cancel")
      }
    }
    .padding(30)
    .frame(width: 620, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    .padding(.trailing, 80).padding(.bottom, 70)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    .focusSection()
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
      Image(systemName: symbol).font(.system(size: 24, weight: .semibold))
    }
    .buttonStyle(TVButtonStyle(kind: .icon)).focusEffectDisabled().focused($focus, equals: id)
    .accessibilityLabel(title).accessibilityIdentifier("player-\(id)")
  }

  private func menuView(_ menu: TVPlaybackController.TrackMenu) -> some View {
    ZStack {
      Color.black.opacity(0.55).ignoresSafeArea()
      VStack(alignment: .leading, spacing: 22) {
        Text(menuTitle(menu)).font(.title2.weight(.semibold))
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 14) {
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
                ForEach(TVPlaybackPreferences.supportedRates, id: \.self) { rate in
                  option(
                    rate == 1 ? "Standard · 1x" : rateTitle(rate),
                    selected: controller.playbackRate == rate, id: .rateOption(rate)
                  ) { controller.setPlaybackRate(rate) }.id(rate)
                }
              case .sleep:
                ForEach([0, -1, 15, 30, 45, 60, 90], id: \.self) { value in
                  let timer: TVSleepTimer =
                    value == 0 ? .off : value == -1 ? .endOfEpisode : .minutes(value)
                  option(
                    timer.title, selected: controller.sleepTimer == timer, id: .sleepOption(value)
                  ) { controller.setSleepTimer(timer) }.id(value)
                }
              }
            }.padding(10)
          }.frame(maxHeight: 460)
            .task {
              switch menu {
              case .audio: proxy.scrollTo(controller.selectedAudio, anchor: .center)
              case .subtitles: proxy.scrollTo(controller.selectedSubtitle, anchor: .center)
              case .rate: proxy.scrollTo(controller.playbackRate, anchor: .center)
              case .sleep: proxy.scrollTo(sleepValue, anchor: .center)
              }
            }
        }
        Button("Done") { controller.trackMenu = nil }.buttonStyle(TVButtonStyle()).focused(
          $focus, equals: .closeMenu
        ).accessibilityIdentifier("player-tracks-done")
      }.padding(36).frame(width: 740).background(
        .regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous)
      ).focusSection()
    }.accessibilityIdentifier("player-tracks")
  }
  private func menuTitle(_ menu: TVPlaybackController.TrackMenu) -> String {
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
      HStack(spacing: 16) {
        Text(title).font(.system(size: 24)).lineLimit(2)
        Spacer()
        if selected { Image(systemName: "checkmark") }
      }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.horizontal, 22)
        .padding(.vertical, 8)
    }.buttonStyle(TVButtonStyle(kind: .row)).focusEffectDisabled().focused($focus, equals: id)
      .accessibilityIdentifier("player-\(id)").accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct TVPlayerPrimaryStyle: ButtonStyle {
  @Environment(\.isFocused) private var focused
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.foregroundStyle(.black).background(.white, in: Circle())
      .overlay(Circle().stroke(.white.opacity(focused ? 1 : 0), lineWidth: 3))
      .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.025 : 1)
  }
}

private struct TVVideoSurface: UIViewRepresentable {
  let engine: any TVPlaybackEngine
  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .black
    view.isUserInteractionEnabled = false
    engine.attach(to: view)
    return view
  }
  func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct TVSkipIndicator {
  let id = UUID()
  let offset: Int64
}

/// A white arc that turns and gently grows and shrinks while a title starts.
private struct TVStartRing: View {
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
