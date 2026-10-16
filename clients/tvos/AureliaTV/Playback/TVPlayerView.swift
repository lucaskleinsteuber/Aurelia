import SwiftUI
import UIKit

@MainActor
struct TVPlayerView: View {
  @StateObject private var controller: TVPlaybackController
  @Environment(\.scenePhase) private var scenePhase
  @FocusState private var focus: Control?
  @State private var lastTransport: Control = .play

  private enum Control: Hashable {
    case surface, close, backward, play, forward, timeline, audio, subtitles, rate, sleep, retry,
      closeMenu
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
      if !controller.controlsVisible {
        Color.clear.contentShape(Rectangle()).focusable().focusEffectDisabled()
          .focused($focus, equals: .surface)
          .onTapGesture { controller.userInteracted() }
          .onMoveCommand { _ in controller.userInteracted() }
          .accessibilityLabel("Show playback controls").accessibilityIdentifier(
            "player-wake-surface")
      }
      if controller.controlsVisible || controller.errorMessage != nil { controls }
      if controller.isLoading && controller.errorMessage == nil {
        ProgressView().tint(.white).scaleEffect(1.4).accessibilityIdentifier("player-loading")
      }
      if let menu = controller.trackMenu { menuView(menu) }
    }
    .preferredColorScheme(.dark)
    .onAppear { controller.start() }.onDisappear { controller.close() }
    .onPlayPauseCommand { controller.togglePlayPause() }.onExitCommand { controller.back() }
    .onChange(of: focus) { _, value in
      if let value, value.isTransport { lastTransport = value }
      if controller.controlsVisible, value != .surface {
        controller.setScrubbing(value == .timeline)
      }
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
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").font(
              .system(size: 30, weight: .bold)
            ).frame(width: 78, height: 78)
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

  private var timeline: some View {
    Button {
      controller.togglePlayPause()
    } label: {
      VStack(spacing: 12) {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.25))
            Capsule().fill(.white.opacity(focus == .timeline ? 1 : 0.75)).frame(
              width: geometry.size.width * fraction)
          }
        }.frame(height: focus == .timeline ? 8 : 5)
        HStack {
          Text(TVPlayerPolicy.timeLabel(milliseconds: controller.position))
          Spacer()
          Text(TVPlayerPolicy.timeLabel(milliseconds: controller.duration))
        }.font(.system(size: 22).monospacedDigit()).foregroundStyle(.secondary)
      }.padding(.vertical, 16).contentShape(Rectangle())
    }.buttonStyle(TVContentButtonStyle()).focusEffectDisabled().focused($focus, equals: .timeline)
      .disabled(!controller.canSeek)
      .onMoveCommand { direction in
        switch direction {
        case .left: controller.seek(by: -controller.seekInterval)
        case .right: controller.seek(by: controller.seekInterval)
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
      ? min(1, max(0, Double(controller.position) / Double(controller.duration))) : 0
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
      }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.horizontal, 16)
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
