import SwiftUI
import UIKit

@MainActor
struct TVPlayerView: View {
  @StateObject private var controller: TVPlaybackController
  @Environment(\.scenePhase) private var scenePhase
  @FocusState private var focus: Control?

  private enum Control: Hashable {
    case surface, close, backward, play, forward, timeline, audio, subtitles, retry, closeMenu
    case audioTrack(Int32)
    case subtitleTrack(Int32)
  }

  init(
    connection: TVStoredConnection, session: TVProfileSession, mediaID: UUID, title: String,
    onClose: @escaping @MainActor () -> Void,
    onSessionFailure: @escaping @MainActor (Error) -> Void = { _ in }
  ) {
    _controller = StateObject(
      wrappedValue: TVPlaybackController(
        connection: connection, session: session, mediaID: mediaID, title: title,
        onClose: onClose, onSessionFailure: onSessionFailure))
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      TVVideoSurface(engine: controller.engine).ignoresSafeArea()
      if !controller.controlsVisible {
        Button {
          controller.userInteracted()
        } label: {
          Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focus, equals: .surface)
        .accessibilityLabel("Show playback controls")
      }
      if controller.controlsVisible || controller.errorMessage != nil {
        controls
      }
      if controller.isLoading && controller.errorMessage == nil {
        ProgressView().scaleEffect(1.5).tint(.white)
          .accessibilityLabel("Loading playback")
      }
      if let menu = controller.trackMenu { tracks(menu) }
    }
    .preferredColorScheme(.dark)
    .onAppear {
      controller.start()
      focus = .play
    }
    .onDisappear { controller.close() }
    .onPlayPauseCommand { controller.togglePlayPause() }
    .onExitCommand { controller.back() }
    .onMoveCommand { _ in controller.userInteracted() }
    .onChange(of: focus) { _, _ in
      if controller.controlsVisible { controller.userInteracted() }
    }
    .onChange(of: controller.controlsVisible) { _, visible in
      if controller.trackMenu == nil { focus = visible ? .play : .surface }
    }
    .onChange(of: controller.errorMessage) { _, message in
      if message != nil { focus = .retry }
    }
    .onChange(of: controller.trackMenu) { _, menu in
      switch menu {
      case .audio:
        focus =
          controller.audioTracks.first(where: { $0.id == controller.selectedAudio })
          .map { .audioTrack($0.id) } ?? controller.audioTracks.first.map { .audioTrack($0.id) }
          ?? .closeMenu
      case .subtitles:
        focus = .subtitleTrack(controller.selectedSubtitle)
      case nil:
        focus = .play
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { controller.background() }
    }
  }

  private var controls: some View {
    VStack {
      Spacer()
      VStack(alignment: .leading, spacing: 26) {
        Text(controller.title).font(.title2.weight(.semibold)).lineLimit(2)
        if let message = controller.errorMessage {
          Text(message).font(.body).foregroundStyle(.white.opacity(0.85))
          HStack(spacing: 24) {
            Button("Try Again") { controller.retry() }
              .focused($focus, equals: .retry)
            Button("Back to Library") { controller.close() }
              .focused($focus, equals: .close)
          }
        } else {
          timeline
          HStack(spacing: 22) {
            control("Close", symbol: "xmark", id: .close) { controller.close() }
            Spacer(minLength: 22)
            control("Back 10 Seconds", symbol: "gobackward.10", id: .backward) {
              controller.seek(by: -10_000)
            }
            .disabled(!controller.canSeek)
            control(
              controller.isPlaying ? "Pause" : "Play",
              symbol: controller.isPlaying ? "pause.fill" : "play.fill", id: .play
            ) { controller.togglePlayPause() }
            .disabled(controller.isLoading)
            control("Forward 10 Seconds", symbol: "goforward.10", id: .forward) {
              controller.seek(by: 10_000)
            }
            .disabled(!controller.canSeek)
            Spacer(minLength: 22)
            control("Audio", symbol: "speaker.wave.2", id: .audio) { controller.trackMenu = .audio }
              .disabled(controller.audioTracks.isEmpty)
            control("Subtitles", symbol: "captions.bubble", id: .subtitles) {
              controller.trackMenu = .subtitles
            }
            .disabled(controller.subtitleTracks.isEmpty)
          }
          if let message = controller.progressMessage {
            Text(message).font(.footnote).foregroundStyle(.white.opacity(0.75))
          }
        }
      }
      .padding(.horizontal, 90)
      .padding(.top, 90)
      .padding(.bottom, 64)
      .background(
        LinearGradient(
          colors: [.clear, .black.opacity(0.85), .black], startPoint: .top, endPoint: .bottom)
      )
      .focusSection()
    }
    .ignoresSafeArea(edges: .bottom)
    .disabled(controller.trackMenu != nil)
  }

  private var timeline: some View {
    Button {
      controller.togglePlayPause()
    } label: {
      VStack(spacing: 16) {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.25))
            Capsule().fill(focus == .timeline ? .white : .white.opacity(0.8))
              .frame(width: geometry.size.width * fraction)
          }
        }
        .frame(height: focus == .timeline ? 10 : 6)
        HStack {
          Text(TVPlayerPolicy.timeLabel(milliseconds: controller.position))
          Spacer()
          Text(TVPlayerPolicy.timeLabel(milliseconds: controller.duration))
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.white.opacity(0.8))
      }
      .padding(.vertical, 14)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .focused($focus, equals: .timeline)
    .disabled(!controller.canSeek)
    .onMoveCommand { direction in
      if direction == .left { controller.seek(by: -10_000) }
      if direction == .right { controller.seek(by: 10_000) }
    }
    .accessibilityLabel("Playback position")
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
    guard controller.duration > 0 else { return 0 }
    return min(1, max(0, Double(controller.position) / Double(controller.duration)))
  }

  private func control(_ title: String, symbol: String, id: Control, action: @escaping () -> Void)
    -> some View
  {
    Button {
      controller.userInteracted()
      action()
    } label: {
      Image(systemName: symbol)
        .font(.title3.weight(.semibold))
        .frame(width: 86, height: 66)
        .foregroundStyle(focus == id ? .black : .white)
        .background(
          focus == id ? .white : .white.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .focused($focus, equals: id)
    .accessibilityLabel(title)
  }

  private func tracks(_ menu: TVPlaybackController.TrackMenu) -> some View {
    ZStack {
      Color.black.opacity(0.65).ignoresSafeArea()
      VStack(alignment: .leading, spacing: 22) {
        Text(menu == .audio ? "Audio" : "Subtitles").font(.title2.weight(.semibold))
        ScrollView {
          VStack(spacing: 18) {
            if menu == .subtitles {
              trackButton(
                "Off", selected: controller.selectedSubtitle < 0, focusID: .subtitleTrack(-1)
              ) {
                controller.selectSubtitle(-1)
              }
            }
            ForEach(menu == .audio ? controller.audioTracks : controller.subtitleTracks) { track in
              trackButton(
                track.title,
                selected: menu == .audio
                  ? controller.selectedAudio == track.id : controller.selectedSubtitle == track.id,
                focusID: menu == .audio ? .audioTrack(track.id) : .subtitleTrack(track.id)
              ) {
                if menu == .audio {
                  controller.selectAudio(track.id)
                } else {
                  controller.selectSubtitle(track.id)
                }
              }
            }
          }
          .padding(12)
        }
        .frame(maxHeight: 460)
        Button("Done") { controller.trackMenu = nil }.focused($focus, equals: .closeMenu)
      }
      .padding(44)
      .frame(width: 720)
      .background(
        Color(red: 32 / 255, green: 35 / 255, blue: 38 / 255),
        in: RoundedRectangle(cornerRadius: 24)
      )
      .focusSection()
    }
  }

  private func trackButton(
    _ title: String, selected: Bool, focusID: Control, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack {
        Text(title).lineLimit(2)
        Spacer()
        if selected { Image(systemName: "checkmark") }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 22).padding(.vertical, 18)
      .foregroundStyle(focus == focusID ? .black : .white)
      .background(
        focus == focusID ? .white : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .focused($focus, equals: focusID)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct TVVideoSurface: UIViewRepresentable {
  let engine: TVVideoEngine

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .black
    view.isUserInteractionEnabled = false
    engine.attach(to: view)
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {}
}
