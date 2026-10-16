import SwiftUI
import UIKit

@MainActor
struct TVPlayerView: View {
  @StateObject private var controller: TVPlaybackController
  @Environment(\.scenePhase) private var scenePhase
  @FocusState private var focus: Control?
  @State private var lastTransport: Control = .play

  private enum Control: Hashable {
    case surface, close, backward, play, forward, timeline, audio, subtitles, retry, closeMenu
    case audioTrack(Int32)
    case subtitleTrack(Int32)
    var isTransport: Bool {
      switch self {
      case .close, .backward, .play, .forward, .audio, .subtitles: true
      default: false
      }
    }
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
        Color.clear.contentShape(Rectangle())
          .focusable().focusEffectDisabled().focused($focus, equals: .surface)
          .onTapGesture { revealControls() }
          .onMoveCommand { _ in revealControls() }
          .accessibilityLabel("Show playback controls")
          .accessibilityIdentifier("player-wake-surface")
      }
      if controller.controlsVisible || controller.errorMessage != nil { controls }
      if controller.isLoading && controller.errorMessage == nil {
        ProgressView().scaleEffect(1.5).tint(.white).accessibilityLabel("Loading playback")
      }
      if let menu = controller.trackMenu { tracks(menu) }
    }
    .preferredColorScheme(.dark)
    .onAppear { controller.start() }
    .onDisappear { controller.close() }
    .onPlayPauseCommand { controller.togglePlayPause() }
    .onExitCommand { controller.back() }
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
    .onChange(of: controller.errorMessage) { _, message in if message != nil { focus = .retry } }
    .onChange(of: controller.trackMenu) { previous, menu in
      switch menu {
      case .audio:
        focus = .audioTrack(
          controller.audioTracks.first(where: { $0.id == controller.selectedAudio })?.id
            ?? controller.audioTracks.first?.id ?? -1)
      case .subtitles:
        focus = .subtitleTrack(
          controller.subtitleTracks.contains(where: { $0.id == controller.selectedSubtitle })
            ? controller.selectedSubtitle : -1)
      case nil: focus = previous == .audio ? .audio : .subtitles
      }
    }
    .onChange(of: scenePhase) { _, phase in if phase == .background { controller.background() } }
  }

  private func revealControls() {
    controller.userInteracted()
  }

  private var controls: some View {
    VStack {
      Spacer()
      VStack(alignment: .leading, spacing: 22) {
        Text(controller.title).font(.system(size: 30, weight: .semibold)).lineLimit(2)
        if let message = controller.errorMessage {
          Text(message).foregroundStyle(.secondary)
          HStack(spacing: 24) {
            Button("Try Again") { controller.retry() }.focused($focus, equals: .retry)
            Button("Back to Library") { controller.close() }.focused($focus, equals: .close)
          }.buttonStyle(TVButtonStyle())
        } else {
          timeline
          HStack(spacing: 18) {
            control("Close", symbol: "xmark", id: .close) { controller.close() }
            control("Back 10 Seconds", symbol: "gobackward.10", id: .backward) {
              controller.seek(by: -10_000)
            }
            .disabled(!controller.canSeek)
            control(
              controller.isPlaying ? "Pause" : "Play",
              symbol: controller.isPlaying ? "pause.fill" : "play.fill",
              id: .play
            ) { controller.togglePlayPause() }.disabled(controller.isLoading)
            control("Forward 10 Seconds", symbol: "goforward.10", id: .forward) {
              controller.seek(by: 10_000)
            }
            .disabled(!controller.canSeek)
            control("Audio", symbol: "speaker.wave.2", id: .audio) { controller.trackMenu = .audio }
              .disabled(controller.audioTracks.isEmpty)
            control("Subtitles", symbol: "captions.bubble", id: .subtitles) {
              controller.trackMenu = .subtitles
            }
            .disabled(controller.subtitleTracks.isEmpty)
          }
          .frame(maxWidth: .infinity)
          .focusSection()
          if let message = controller.progressMessage {
            Text(message).font(.footnote).foregroundStyle(.secondary)
          }
        }
      }
      .padding(.horizontal, 90).padding(.top, 70).padding(.bottom, 58)
      .background(
        LinearGradient(
          colors: [.clear, .black.opacity(0.85), .black], startPoint: .top, endPoint: .bottom))
    }
    .ignoresSafeArea(edges: .bottom)
    .defaultFocus($focus, .play, priority: .userInitiated)
    .disabled(controller.trackMenu != nil)
  }

  private var timeline: some View {
    Button {
      controller.togglePlayPause()
    } label: {
      VStack(spacing: 12) {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.22))
            Capsule().fill(.white.opacity(focus == .timeline ? 1 : 0.72))
              .frame(width: geometry.size.width * fraction)
          }
        }.frame(height: focus == .timeline ? 8 : 5)
        HStack {
          Text(TVPlayerPolicy.timeLabel(milliseconds: controller.position))
          Spacer()
          Text(TVPlayerPolicy.timeLabel(milliseconds: controller.duration))
        }.font(.system(size: 22).monospacedDigit()).foregroundStyle(.secondary)
      }.padding(.vertical, 14).contentShape(Rectangle())
    }
    .buttonStyle(TVContentButtonStyle()).focusEffectDisabled()
    .focused($focus, equals: .timeline).disabled(!controller.canSeek)
    .onMoveCommand { direction in
      switch direction {
      case .left: controller.seek(by: -10_000)
      case .right: controller.seek(by: 10_000)
      case .down: focus = lastTransport
      default: break
      }
    }
    .accessibilityIdentifier("player-timeline").accessibilityLabel("Playback position")
    .accessibilityValue(
      "\(TVPlayerPolicy.timeLabel(milliseconds: controller.position)) of \(TVPlayerPolicy.timeLabel(milliseconds: controller.duration))"
    )
    .accessibilityHint("Press left or right to seek ten seconds.")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: controller.seek(by: 10_000)
      case .decrement: controller.seek(by: -10_000)
      @unknown default: break
      }
    }
  }

  private var fraction: Double {
    controller.duration > 0
      ? min(1, max(0, Double(controller.position) / Double(controller.duration))) : 0
  }

  private func control(_ title: String, symbol: String, id: Control, action: @escaping () -> Void)
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

  private func tracks(_ menu: TVPlaybackController.TrackMenu) -> some View {
    ZStack {
      Color.black.opacity(0.65).ignoresSafeArea()
      VStack(alignment: .leading, spacing: 22) {
        Text(menu == .audio ? "Audio" : "Subtitles").font(.title2.weight(.semibold))
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 14) {
              if menu == .subtitles {
                trackButton(
                  "Off", selected: controller.selectedSubtitle < 0, focusID: .subtitleTrack(-1)
                ) {
                  controller.selectSubtitle(-1)
                }.id(Int32(-1))
              }
              ForEach(menu == .audio ? controller.audioTracks : controller.subtitleTracks) {
                track in
                trackButton(
                  track.title,
                  selected: menu == .audio
                    ? controller.selectedAudio == track.id
                    : controller.selectedSubtitle == track.id,
                  focusID: menu == .audio ? .audioTrack(track.id) : .subtitleTrack(track.id)
                ) {
                  if menu == .audio {
                    controller.selectAudio(track.id)
                  } else {
                    controller.selectSubtitle(track.id)
                  }
                }.id(track.id)
              }
            }.padding(8)
          }.frame(maxHeight: 460)
            .task {
              proxy.scrollTo(
                menu == .audio ? controller.selectedAudio : controller.selectedSubtitle,
                anchor: .center)
            }
        }
        Button("Done") { controller.trackMenu = nil }.buttonStyle(TVButtonStyle())
          .focused($focus, equals: .closeMenu).accessibilityIdentifier("player-tracks-done")
      }
      .padding(32).frame(width: 740)
      .background(TVDesign.canvas, in: RoundedRectangle(cornerRadius: 20)).focusSection()
    }.accessibilityIdentifier("player-tracks")
  }

  private func trackButton(
    _ title: String, selected: Bool, focusID: Control, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 16) {
        Text(title).font(.system(size: 24)).lineLimit(2)
        Spacer()
        if selected { Image(systemName: "checkmark") }
      }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    .buttonStyle(TVButtonStyle(kind: .row)).focusEffectDisabled().focused($focus, equals: focusID)
    .accessibilityIdentifier("player-\(focusID)").accessibilityAddTraits(
      selected ? .isSelected : [])
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
