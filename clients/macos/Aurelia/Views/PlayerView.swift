import AppKit
import SwiftUI

struct PlayerView: View {
  @EnvironmentObject private var model: AppModel
  @StateObject private var controller: PlaybackController
  @State private var controlsVisible = true
  @State private var isScrubbing = false
  @State private var scrubPosition: Double = 0
  @State private var hideTask: Task<Void, Never>?
  @State private var windowPresentation = PlayerWindowPresentation()
  @State private var isNativeFullScreen = false
  @State private var isAdjustingVolume = false
  @State private var showingAudioTracks = false
  @State private var showingSubtitleTracks = false
  @State private var cursorHidden = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(profile: StoredServerProfile, presentation: PlaybackPresentation) {
    _controller = StateObject(
      wrappedValue: PlaybackController(profile: profile, presentation: presentation))
  }

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      PlayerVideoSurface(controller: controller, onInteraction: { revealControls() })
        .ignoresSafeArea()

      if controlsVisible || controller.isPreparing || controller.errorMessage != nil {
        controls
          .transition(.opacity)
      }

      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityLabel("Native Player · \(controller.presentation.title)")
        .accessibilityIdentifier("native-player")
    }
    .background(
      PlayerWindowAccessor { window in
        windowPresentation.apply(to: window)
      }
    )
    .preferredColorScheme(.dark)
    .task {
      PlaybackShutdownCoordinator.shared.register(controller)
      revealControls()
      await controller.start()
    }
    .onDisappear {
      hideTask?.cancel()
      showCursor()
      PlaybackShutdownCoordinator.shared.unregister(controller)
      windowPresentation.restore()
      Task { await controller.shutdown() }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) {
      notification in
      guard let window = notification.object as? NSWindow,
        window === windowPresentation.window
      else { return }
      isNativeFullScreen = true
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) {
      notification in
      guard let window = notification.object as? NSWindow,
        window === windowPresentation.window
      else { return }
      isNativeFullScreen = false
    }
    .onChange(of: controller.isPreparing) {
      if controller.isPreparing {
        revealControls(scheduleHide: false)
      } else {
        revealControls()
      }
    }
    .onChange(of: controller.errorMessage) {
      revealControls(scheduleHide: controller.errorMessage == nil)
    }
  }

  private var controls: some View {
    ZStack {
      LinearGradient(
        colors: [.black.opacity(0.7), .clear, .black.opacity(0.82)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack {
        HStack {
          controlButton("Back", systemImage: "chevron.left") {
            closePlayer()
          }
          .accessibilityIdentifier("player-back")
          Spacer()
          trackMenus
        }
        .padding(24)

        Spacer()

        HStack(spacing: 14) {
          centerControlButton("Back 5 Seconds", systemImage: "gobackward.5") {
            controller.skip(seconds: -5)
          }
          Button {
            controller.togglePlayback()
            revealControls()
          } label: {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 29, weight: .semibold))
              .frame(width: 58, height: 58)
              .background(.white, in: Circle())
              .foregroundStyle(.black)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
          .accessibilityIdentifier("player-play-pause")
          centerControlButton("Forward 5 Seconds", systemImage: "goforward.5") {
            controller.skip(seconds: 5)
          }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.12), lineWidth: 1) }

        Spacer()

        bottomControls
          .padding(.horizontal, 30)
          .padding(.bottom, 24)
      }

      if controller.isPreparing, controller.errorMessage == nil {
        ProgressView("Preparing playback…")
          .controlSize(.large)
          .padding(20)
          .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
      }

      if let error = controller.errorMessage {
        VStack(spacing: 14) {
          Image(systemName: "exclamationmark.triangle")
            .font(.largeTitle)
          Text("Playback Unavailable")
            .font(.title2.bold())
          Text(error)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          HStack {
            Button("Back") { closePlayer() }
            Button("Try Again") {
              Task { await controller.retry() }
            }
            .buttonStyle(AureliaPrimaryActionButtonStyle())
          }
        }
        .padding(26)
        .frame(maxWidth: 440)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
      }
    }
  }

  private var trackMenus: some View {
    HStack(spacing: 8) {
      Button {
        showingAudioTracks.toggle()
        revealControls(scheduleHide: false)
      } label: {
        Image(systemName: "waveform").frame(width: 30, height: 30)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Audio")
      .accessibilityIdentifier("player-audio-menu")
      .popover(isPresented: $showingAudioTracks, arrowEdge: .top) {
        trackPicker(
          title: "Audio",
          emptyMessage: "No audio tracks available",
          tracks: controller.audioTracks,
          selectedID: controller.selectedAudioTrackID
        ) { id in
          controller.selectAudioTrack(id)
          showingAudioTracks = false
        }
      }

      Button {
        showingSubtitleTracks.toggle()
        revealControls(scheduleHide: false)
      } label: {
        Image(systemName: "captions.bubble").frame(width: 30, height: 30)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Subtitles")
      .accessibilityIdentifier("player-subtitle-menu")
      .popover(isPresented: $showingSubtitleTracks, arrowEdge: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Subtitles").font(.headline).padding(.bottom, 6)
          trackChoice("Off", selected: controller.selectedSubtitleTrackID == nil) {
            controller.selectSubtitleTrack(nil)
            showingSubtitleTracks = false
          }
          if !controller.subtitleTracks.isEmpty { Divider() }
          ForEach(controller.subtitleTracks) { track in
            trackChoice(track.title, selected: controller.selectedSubtitleTrackID == track.id) {
              controller.selectSubtitleTrack(track.id)
              showingSubtitleTracks = false
            }
          }
        }
        .padding(12)
        .frame(minWidth: 230, alignment: .leading)
      }
    }
    .padding(10)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay { Capsule().stroke(.white.opacity(0.12), lineWidth: 1) }
    .onChange(of: showingAudioTracks) { if !showingAudioTracks { revealControls() } }
    .onChange(of: showingSubtitleTracks) { if !showingSubtitleTracks { revealControls() } }
  }

  private var bottomControls: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .bottom, spacing: 24) {
        VStack(alignment: .leading, spacing: 2) {
          Text(controller.presentation.subtitle ?? "NOW PLAYING")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.66))
          Text(controller.presentation.title)
            .font(.title3.weight(.semibold))
            .accessibilityLabel(controller.presentation.title)
            .accessibilityIdentifier("player-title")
        }
        Spacer(minLength: 30)
        HStack(spacing: 12) {
          Button {
            controller.toggleMute()
            revealControls()
          } label: {
            Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
              .frame(width: 32, height: 32)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(controller.isMuted ? "Unmute" : "Mute")

          Slider(
            value: Binding(
              get: { controller.volume },
              set: { controller.setVolume($0) }),
            in: 0...1,
            onEditingChanged: { editing in
              isAdjustingVolume = editing
              revealControls(scheduleHide: !editing)
            }
          )
          .frame(width: 120)
          .accessibilityLabel("Volume")

          Button {
            guard let window = windowPresentation.window else { return }
            isNativeFullScreen.toggle()
            window.toggleFullScreen(nil)
            revealControls()
          } label: {
            Image(
              systemName: isNativeFullScreen
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right"
            )
            .frame(width: 32, height: 32)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(isNativeFullScreen ? "Exit Full Screen" : "Enter Full Screen")
          .accessibilityIdentifier("player-fullscreen")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.12), lineWidth: 1) }
      }

      HStack(spacing: 10) {
        Text(formatTime(displayedPosition)).monospacedDigit()
        Slider(
          value: Binding(
            get: { displayedPosition },
            set: { scrubPosition = $0 }),
          in: 0...max(Double(controller.durationMilliseconds), 1),
          onEditingChanged: { editing in
            isScrubbing = editing
            if editing {
              scrubPosition = Double(controller.currentTimeMilliseconds)
              revealControls(scheduleHide: false)
            } else {
              controller.seek(to: Int64(scrubPosition.rounded()))
              revealControls()
            }
          }
        )
        .accessibilityLabel("Playback Position")
        .accessibilityIdentifier("player-timeline")
        Text(formatTime(Double(controller.durationMilliseconds))).monospacedDigit()
      }
      .font(.caption)
    }
  }

  private func trackPicker(
    title: String,
    emptyMessage: String,
    tracks: [PlaybackTrack],
    selectedID: Int32?,
    selection: @escaping (Int32) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.headline).padding(.bottom, 6)
      if tracks.isEmpty {
        Text(emptyMessage).foregroundStyle(.secondary).padding(.vertical, 6)
      } else {
        ForEach(tracks) { track in
          trackChoice(track.title, selected: selectedID == track.id) { selection(track.id) }
        }
      }
    }
    .padding(12)
    .frame(minWidth: 230, alignment: .leading)
  }

  private func trackChoice(
    _ title: String,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack {
        Text(title).lineLimit(1)
        Spacer()
        if selected { Image(systemName: "checkmark") }
      }
      .contentShape(Rectangle())
      .frame(minHeight: 32)
    }
    .buttonStyle(.plain)
  }

  private var displayedPosition: Double {
    isScrubbing ? scrubPosition : Double(controller.currentTimeMilliseconds)
  }

  private func controlButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 18, weight: .semibold))
        .frame(width: AureliaDesign.minimumControlSize, height: AureliaDesign.minimumControlSize)
        .background(.ultraThinMaterial, in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  private func centerControlButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      action()
      revealControls()
    } label: {
      Image(systemName: systemImage)
        .font(.system(size: 18, weight: .semibold))
        .frame(width: 44, height: 44)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  private func revealControls(scheduleHide: Bool = true) {
    showCursor()
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { controlsVisible = true }
    hideTask?.cancel()
    guard scheduleHide, canAutoHide else { return }
    hideTask = Task {
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, canAutoHide else { return }
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { controlsVisible = false }
      hideCursor()
    }
  }

  private var canAutoHide: Bool {
    !controller.isPreparing && controller.errorMessage == nil && !isScrubbing
      && !isAdjustingVolume && !showingAudioTracks && !showingSubtitleTracks
  }

  private func hideCursor() {
    guard !cursorHidden else { return }
    NSCursor.hide()
    cursorHidden = true
  }

  private func showCursor() {
    guard cursorHidden else { return }
    NSCursor.unhide()
    cursorHidden = false
  }

  private func closePlayer() {
    hideTask?.cancel()
    showCursor()
    Task {
      await controller.shutdown()
      model.closePlayback()
    }
  }

  private func formatTime(_ milliseconds: Double) -> String {
    let seconds = max(0, Int(milliseconds / 1_000))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainder = seconds % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
      : String(format: "%d:%02d", minutes, remainder)
  }
}

private struct PlayerVideoSurface: NSViewRepresentable {
  let controller: PlaybackController
  let onInteraction: () -> Void

  func makeNSView(context: Context) -> PlayerTrackingView {
    let view = PlayerTrackingView()
    view.onInteraction = onInteraction
    controller.attachVideoView(view)
    return view
  }

  func updateNSView(_ nsView: PlayerTrackingView, context: Context) {
    nsView.onInteraction = onInteraction
    controller.attachVideoView(nsView)
  }
}

private final class PlayerTrackingView: NSView {
  var onInteraction: (() -> Void)?
  private var trackingArea: NSTrackingArea?

  override func updateTrackingAreas() {
    if let trackingArea { removeTrackingArea(trackingArea) }
    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
      owner: self)
    addTrackingArea(trackingArea)
    self.trackingArea = trackingArea
    super.updateTrackingAreas()
  }

  override func mouseMoved(with event: NSEvent) { onInteraction?() }
  override func mouseEntered(with event: NSEvent) { onInteraction?() }
  override func mouseDown(with event: NSEvent) { onInteraction?() }
}

private struct PlayerWindowAccessor: NSViewRepresentable {
  let configure: (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      if let window = view.window { configure(window) }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      if let window = nsView.window { configure(window) }
    }
  }
}

@MainActor
private final class PlayerWindowPresentation {
  weak var window: NSWindow?
  private var originalStyleMask: NSWindow.StyleMask?
  private var originalTitleVisibility: NSWindow.TitleVisibility?
  private var originalTitlebarAppearsTransparent: Bool?
  private var originalToolbarVisibility: Bool?
  private var originalFrame: NSRect?
  private var fullscreenExitObserver: NSObjectProtocol?

  func apply(to window: NSWindow) {
    guard self.window == nil else { return }
    self.window = window
    originalStyleMask = window.styleMask
    originalTitleVisibility = window.titleVisibility
    originalTitlebarAppearsTransparent = window.titlebarAppearsTransparent
    originalToolbarVisibility = window.toolbar?.isVisible
    originalFrame = window.frame
    window.styleMask.insert(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar?.isVisible = false
  }

  func restore() {
    guard let window else { return }
    if window.styleMask.contains(.fullScreen) {
      if fullscreenExitObserver == nil {
        fullscreenExitObserver = NotificationCenter.default.addObserver(
          forName: NSWindow.didExitFullScreenNotification,
          object: window,
          queue: .main
        ) { [self] _ in
          MainActor.assumeIsolated {
            restoreWindowPresentation()
          }
        }
      }
      window.toggleFullScreen(nil)
      return
    }
    restoreWindowPresentation()
  }

  private func restoreWindowPresentation() {
    guard let window else { return }
    if let originalStyleMask { window.styleMask = originalStyleMask }
    if let originalTitleVisibility { window.titleVisibility = originalTitleVisibility }
    if let originalTitlebarAppearsTransparent {
      window.titlebarAppearsTransparent = originalTitlebarAppearsTransparent
    }
    if let originalToolbarVisibility { window.toolbar?.isVisible = originalToolbarVisibility }
    if let originalFrame {
      window.setFrame(originalFrame, display: true)
      DispatchQueue.main.async { [weak window] in
        window?.setFrame(originalFrame, display: true)
      }
    }
    if let fullscreenExitObserver {
      NotificationCenter.default.removeObserver(fullscreenExitObserver)
      self.fullscreenExitObserver = nil
    }
    self.window = nil
  }
}
