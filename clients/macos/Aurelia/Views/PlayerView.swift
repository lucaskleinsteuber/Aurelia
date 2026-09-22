import AppKit
import SwiftUI

struct PlayerView: View {
  @EnvironmentObject private var model: AppModel
  @StateObject private var controller: PlaybackController
  @ObservedObject private var preferencesStore = PlaybackPreferencesStore.shared
  @State private var controlsVisible = true
  @State private var isScrubbing = false
  @State private var scrubPosition: Double = 0
  @State private var hideTask: Task<Void, Never>?
  @State private var windowPresentation = PlayerWindowPresentation()
  @State private var isNativeFullScreen = false
  @State private var isPictureInPicture = false
  @State private var isAdjustingVolume = false
  @State private var lastHideScheduleRefresh = 0.0
  @State private var cursorHidden = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  init(profile: StoredServerProfile, presentation: PlaybackPresentation) {
    _controller = StateObject(
      wrappedValue: PlaybackController(profile: profile, presentation: presentation))
  }

  var body: some View {
    GeometryReader { geometry in
      let viewport = geometry.size

      ZStack {
        Color.black
          .frame(width: viewport.width, height: viewport.height)

        PlayerVideoSurface(
          controller: controller,
          onInteraction: { revealControls() },
          onKeyDown: handleKey
        )
        .frame(width: viewport.width, height: viewport.height)

        if controlsVisible || controller.isPreparing || controller.errorMessage != nil {
          controls(in: viewport)
            .frame(width: viewport.width, height: viewport.height)
            .transition(.opacity)
        }

        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement()
          .accessibilityLabel("Native Player · \(controller.presentation.title)")
          .accessibilityIdentifier("native-player")
      }
      .frame(width: viewport.width, height: viewport.height)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ignoresSafeArea()
    .background(PlayerWindowAccessor { window in windowPresentation.apply(to: window) })
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
      revealControls(scheduleHide: !controller.isPreparing)
    }
    .onChange(of: controller.errorMessage) {
      revealControls(scheduleHide: controller.errorMessage == nil)
    }
    .onChange(of: preferencesStore.preferences.controlsAutoHideDelay) {
      revealControls()
    }
  }

  private func controls(in viewport: CGSize) -> some View {
    let controlWidth = min(max(viewport.width - 64, 0), 1_180)
    let topInset: CGFloat = isNativeFullScreen ? 16 : 42
    let bottomInset: CGFloat = isNativeFullScreen ? 34 : 24

    return ZStack {
      LinearGradient(
        colors: [.black.opacity(0.42), .clear, .black.opacity(0.78)],
        startPoint: .top,
        endPoint: .bottom
      )

      HStack {
        controlButton("Back", systemImage: "chevron.left") { closePlayer() }
          .accessibilityIdentifier("player-back")
        Spacer(minLength: 24)
        playerMenus
      }
      .padding(.horizontal, 18)
      .frame(width: viewport.width - 36, height: 52)
      .position(x: viewport.width / 2, y: topInset + 26)

      bottomControls
        .frame(width: controlWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .position(
          x: viewport.width / 2,
          y: viewport.height - bottomInset - 56)

      if !controller.isPreparing, controller.errorMessage == nil {
        HStack(spacing: 4) {
          seekButton(forward: false)
          Button {
            controller.togglePlayback()
            revealControls()
          } label: {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 21, weight: .bold))
              .offset(x: controller.isPlaying ? 0 : 1)
              .frame(width: 50, height: 50)
              .background(.white, in: Circle())
              .foregroundStyle(.black)
          }
          .buttonStyle(PlayerPressButtonStyle(reduceMotion: reduceMotion))
          .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
          .accessibilityIdentifier("player-play-pause")
          seekButton(forward: true)
        }
        .padding(6)
        .playerMaterial(reduceTransparency: reduceTransparency, shape: Capsule())
        .position(x: viewport.width / 2, y: viewport.height / 2)
      }

      if controller.isPreparing, controller.errorMessage == nil {
        ProgressView("Preparing playback…")
          .controlSize(.large)
          .padding(20)
          .playerMaterial(
            reduceTransparency: reduceTransparency,
            shape: RoundedRectangle(cornerRadius: 18, style: .continuous)
          )
          .accessibilityIdentifier("player-preparing")
      }

      if let error = controller.errorMessage {
        playbackError(error)
      }
    }
    .frame(width: viewport.width, height: viewport.height)
  }

  private var playerMenus: some View {
    HStack(spacing: 4) {
      Menu {
        ForEach(PlaybackPreferences.supportedRates, id: \.self) { rate in
          menuChoice(
            rate == 1 ? "Standard" : rateLabel(rate),
            selected: controller.playbackRate == rate
          ) {
            controller.setPlaybackRate(rate)
          }
        }
      } label: {
        PlayerControlLabel(height: 42, minWidth: 50) {
          Text(rateLabel(controller.playbackRate))
            .font(.callout.weight(.bold).monospacedDigit())
        }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .accessibilityLabel("Playback Rate")
      .accessibilityValue(rateLabel(controller.playbackRate))
      .accessibilityIdentifier("player-rate-menu")

      Menu {
        if controller.audioTracks.isEmpty {
          Button("No audio tracks available") {}
            .disabled(true)
        } else {
          ForEach(controller.audioTracks) { track in
            menuChoice(track.title, selected: controller.selectedAudioTrackID == track.id) {
              controller.selectAudioTrack(track.id)
            }
          }
        }
      } label: {
        PlayerControlLabel { Image(systemName: "waveform") }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .accessibilityLabel("Audio")
      .accessibilityIdentifier("player-audio-menu")

      Menu {
        menuChoice("Off", selected: controller.selectedSubtitleTrackID == nil) {
          controller.selectSubtitleTrack(nil)
        }
        if controller.subtitleTracks.isEmpty {
          Button("No subtitles available") {}
            .disabled(true)
        } else {
          Divider()
          ForEach(controller.subtitleTracks) { track in
            menuChoice(track.title, selected: controller.selectedSubtitleTrackID == track.id) {
              controller.selectSubtitleTrack(track.id)
            }
          }
        }
      } label: {
        PlayerControlLabel {
          Image(
            systemName: controller.selectedSubtitleTrackID == nil
              ? "captions.bubble" : "captions.bubble.fill")
        }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .accessibilityLabel("Subtitles")
      .accessibilityIdentifier("player-subtitle-menu")

      Menu {
        menuChoice("Off", selected: controller.sleepTimer == .off) {
          controller.setSleepTimer(.off)
        }
        Divider()
        menuChoice("At end of episode", selected: controller.sleepTimer == .endOfEpisode) {
          controller.setSleepTimer(.endOfEpisode)
        }
        ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
          menuChoice("\(minutes) minutes", selected: controller.sleepTimer == .minutes(minutes)) {
            controller.setSleepTimer(.minutes(minutes))
          }
        }
      } label: {
        PlayerControlLabel {
          Image(systemName: controller.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill")
        }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .accessibilityLabel("Sleep Timer")
      .accessibilityIdentifier("player-sleep-menu")
    }
    .padding(7)
    .playerMaterial(reduceTransparency: reduceTransparency, shape: Capsule())
  }

  private var bottomControls: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .bottom, spacing: 24) {
        VStack(alignment: .leading, spacing: 2) {
          Text(controller.presentation.subtitle ?? "NOW PLAYING")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.68))
          Text(controller.presentation.title)
            .font(.title3.weight(.semibold))
            .lineLimit(2)
            .accessibilityIdentifier("player-title")
        }
        Spacer(minLength: 30)
        trailingControls
      }

      HStack(spacing: 10) {
        Text(formatTime(displayedPosition)).monospacedDigit().frame(
          minWidth: 44, alignment: .trailing)
        PlayerTimeline(
          position: Binding(
            get: { displayedPosition },
            set: { scrubPosition = $0 }),
          duration: max(Double(controller.durationMilliseconds), 1),
          chapters: controller.chapters,
          onEditingChanged: timelineEditingChanged)
        Text(formatTime(Double(controller.durationMilliseconds)))
          .monospacedDigit().frame(minWidth: 44, alignment: .leading)
      }
      .font(.caption)
    }
    .frame(maxWidth: 1_180)
  }

  private var trailingControls: some View {
    HStack(spacing: 2) {
      if !controller.chapters.isEmpty {
        Menu {
          ForEach(controller.chapters) { chapter in
            menuChoice(
              "\(chapter.title)  \(formatTime(Double(chapter.timeOffsetMilliseconds)))",
              selected: controller.currentChapterIndex == chapter.index
            ) {
              controller.selectChapter(chapter)
            }
          }
        } label: {
          PlayerControlLabel { Image(systemName: "list.bullet.rectangle") }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Chapters")
        .accessibilityIdentifier("player-chapter-menu")
      }
      Button {
        controller.toggleMute()
        revealControls()
      } label: {
        Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .frame(width: 42, height: 42)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(controller.isMuted ? "Unmute" : "Mute")

      Slider(
        value: Binding(get: { controller.volume }, set: { controller.setVolume($0) }),
        in: 0...1,
        onEditingChanged: { editing in
          isAdjustingVolume = editing
          revealControls(scheduleHide: !editing)
        }
      )
      .frame(width: 96)
      .frame(minHeight: 42)
      .accessibilityLabel("Volume")
      .accessibilityValue("\(Int(controller.volume * 100)) percent")

      if !isNativeFullScreen {
        Button {
          togglePictureInPicture()
        } label: {
          Image(systemName: isPictureInPicture ? "pip.exit" : "pip.enter")
            .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          isPictureInPicture ? "Exit Picture in Picture" : "Enter Picture in Picture"
        )
        .accessibilityIdentifier("player-picture-in-picture")
      }

      Button {
        toggleFullScreen()
      } label: {
        Image(
          systemName: isNativeFullScreen
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        )
        .frame(width: 42, height: 42)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isNativeFullScreen ? "Exit Full Screen" : "Enter Full Screen")
      .accessibilityIdentifier("player-fullscreen")
    }
    .padding(7)
    .playerMaterial(reduceTransparency: reduceTransparency, shape: Capsule())
  }

  private func playbackError(_ error: String) -> some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.triangle").font(.largeTitle)
      Text("Playback Unavailable").font(.title2.bold())
      Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
      HStack {
        Button("Back") { closePlayer() }
        Button("Try Again") { Task { await controller.retry() } }
          .buttonStyle(AureliaPrimaryActionButtonStyle())
      }
    }
    .padding(26)
    .frame(maxWidth: 440)
    .playerMaterial(
      reduceTransparency: reduceTransparency,
      shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
  }

  private func menuChoice(
    _ title: String,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      action()
      revealControls()
    } label: {
      if selected {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }

  private func seekButton(forward: Bool) -> some View {
    let interval = preferencesStore.preferences.seekInterval
    return Button {
      controller.skip(seconds: Int64(forward ? interval : -interval))
      revealControls()
    } label: {
      ZStack {
        Image(systemName: forward ? "goforward" : "gobackward")
          .font(.system(size: 18, weight: .semibold))
        Text(String(interval))
          .font(.system(size: interval >= 10 ? 8 : 9, weight: .bold, design: .rounded))
      }
      .frame(width: 42, height: 42)
    }
    .buttonStyle(PlayerPressButtonStyle(reduceMotion: reduceMotion))
    .accessibilityLabel("\(forward ? "Forward" : "Back") \(interval) Seconds")
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
        .playerMaterial(reduceTransparency: reduceTransparency, shape: Circle())
    }
    .buttonStyle(PlayerPressButtonStyle(reduceMotion: reduceMotion))
    .accessibilityLabel(title)
  }

  private var displayedPosition: Double {
    isScrubbing ? scrubPosition : Double(controller.currentTimeMilliseconds)
  }

  private func timelineEditingChanged(_ editing: Bool) {
    isScrubbing = editing
    if editing {
      scrubPosition = Double(controller.currentTimeMilliseconds)
      revealControls(scheduleHide: false)
    } else {
      controller.seek(to: Int64(scrubPosition.rounded()))
      revealControls()
    }
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    revealControls()
    switch event.keyCode {
    case 49:
      controller.togglePlayback()
    case 123:
      controller.skip(seconds: -Int64(preferencesStore.preferences.seekInterval))
    case 124:
      controller.skip(seconds: Int64(preferencesStore.preferences.seekInterval))
    case 3:
      toggleFullScreen()
    case 46:
      controller.toggleMute()
    case 53:
      if isPictureInPicture {
        togglePictureInPicture()
      } else if isNativeFullScreen {
        toggleFullScreen()
      } else {
        return false
      }
    default:
      return false
    }
    revealControls()
    return true
  }

  private func toggleFullScreen() {
    guard let window = windowPresentation.window else { return }
    if isPictureInPicture {
      _ = windowPresentation.togglePictureInPicture()
      isPictureInPicture = false
    }
    window.toggleFullScreen(nil)
    revealControls()
  }

  private func togglePictureInPicture() {
    isPictureInPicture = windowPresentation.togglePictureInPicture()
    revealControls()
  }

  private func revealControls(scheduleHide: Bool = true) {
    showCursor()
    let controlsWereHidden = !controlsVisible
    if controlsWereHidden {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { controlsVisible = true }
    }
    guard scheduleHide, canAutoHide else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard controlsWereHidden || now - lastHideScheduleRefresh >= 0.2 else { return }
    lastHideScheduleRefresh = now
    hideTask?.cancel()
    let delay = preferencesStore.preferences.controlsAutoHideDelay
    hideTask = Task {
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, canAutoHide else { return }
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsVisible = false }
      hideCursor()
    }
  }

  private var canAutoHide: Bool {
    !controller.isPreparing && controller.errorMessage == nil && !isScrubbing
      && !isAdjustingVolume
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

  private func rateLabel(_ rate: Double) -> String {
    rate == rate.rounded()
      ? "\(Int(rate))x"
      : "\(String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), rate))x"
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

private struct PlayerTimeline: View {
  @Binding var position: Double
  let duration: Double
  let chapters: [PlaybackChapter]
  let onEditingChanged: (Bool) -> Void

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        ForEach(chapters) { chapter in
          Rectangle()
            .fill(.white.opacity(0.62))
            .frame(width: 1, height: 7)
            .position(
              x: proxy.size.width
                * min(max(Double(chapter.timeOffsetMilliseconds) / duration, 0), 1),
              y: proxy.size.height / 2)
        }
        Slider(value: $position, in: 0...duration, onEditingChanged: onEditingChanged)
      }
    }
    .frame(minHeight: 44)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Playback Position")
    .accessibilityIdentifier("player-timeline")
  }
}

private struct PlayerPressButtonStyle: ButtonStyle {
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .opacity(configuration.isPressed ? 0.82 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
  }
}

/// Stable hit target for a control inside one shared glass capsule. Hover only
/// changes opacity, so the pointer can never move in and out because the
/// control scaled underneath it.
private struct PlayerControlLabel<Content: View>: View {
  @State private var isHovering = false
  let height: CGFloat
  let minWidth: CGFloat
  private let content: Content

  init(
    height: CGFloat = 42,
    minWidth: CGFloat = 42,
    @ViewBuilder content: () -> Content
  ) {
    self.height = height
    self.minWidth = minWidth
    self.content = content()
  }

  var body: some View {
    content
      .font(.system(size: 17, weight: .semibold))
      .frame(minWidth: minWidth, minHeight: height)
      .background(.white.opacity(isHovering ? 0.12 : 0), in: Capsule())
      .contentShape(Capsule())
      .onHover { isHovering = $0 }
      .animation(.easeOut(duration: 0.12), value: isHovering)
  }
}

extension View {
  fileprivate func playerMaterial<S: Shape>(reduceTransparency: Bool, shape: S) -> some View {
    background {
      if reduceTransparency {
        shape.fill(Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.98))
      } else {
        shape.fill(.ultraThinMaterial)
      }
    }
    .overlay { shape.stroke(.white.opacity(0.12), lineWidth: 1) }
  }
}

private struct PlayerVideoSurface: NSViewRepresentable {
  let controller: PlaybackController
  let onInteraction: () -> Void
  let onKeyDown: (NSEvent) -> Bool

  func makeNSView(context: Context) -> PlayerTrackingView {
    let view = PlayerTrackingView()
    view.onInteraction = onInteraction
    view.onKeyDown = onKeyDown
    controller.attachVideoView(view)
    return view
  }

  func updateNSView(_ nsView: PlayerTrackingView, context: Context) {
    nsView.onInteraction = onInteraction
    nsView.onKeyDown = onKeyDown
  }
}

private final class PlayerTrackingView: NSView {
  var onInteraction: (() -> Void)?
  var onKeyDown: ((NSEvent) -> Bool)?
  private var trackingArea: NSTrackingArea?

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.window?.makeFirstResponder(self)
    }
  }

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
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onInteraction?()
    super.mouseDown(with: event)
  }
  override func keyDown(with event: NSEvent) {
    if onKeyDown?(event) != true { super.keyDown(with: event) }
  }
}

private struct PlayerWindowAccessor: NSViewRepresentable {
  let configure: (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { if let window = view.window { configure(window) } }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { if let window = nsView.window { configure(window) } }
  }
}

@MainActor
private final class PlayerWindowPresentation {
  weak var window: NSWindow?
  private var originalStyleMask: NSWindow.StyleMask?
  private var originalTitleVisibility: NSWindow.TitleVisibility?
  private var originalTitlebarAppearsTransparent: Bool?
  private var originalTitlebarSeparatorStyle: NSTitlebarSeparatorStyle?
  private var originalBackgroundColor: NSColor?
  private var originalTitle: String?
  private var originalToolbarVisibility: Bool?
  private var originalFrame: NSRect?
  private var originalLevel: NSWindow.Level?
  private var originalCollectionBehavior: NSWindow.CollectionBehavior?
  private var originalAspectRatio: NSSize?
  private var pictureInPictureFrame: NSRect?
  private var fullscreenExitObserver: NSObjectProtocol?
  private(set) var isPictureInPicture = false

  func apply(to window: NSWindow) {
    guard self.window == nil else { return }
    self.window = window
    originalStyleMask = window.styleMask
    originalTitleVisibility = window.titleVisibility
    originalTitlebarAppearsTransparent = window.titlebarAppearsTransparent
    originalTitlebarSeparatorStyle = window.titlebarSeparatorStyle
    originalBackgroundColor = window.backgroundColor
    originalTitle = window.title
    originalToolbarVisibility = window.toolbar?.isVisible
    originalFrame = window.frame
    originalLevel = window.level
    originalCollectionBehavior = window.collectionBehavior
    originalAspectRatio = window.contentAspectRatio
    window.styleMask.insert(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.backgroundColor = .black
    window.title = "\u{2060}"
    window.toolbar?.isVisible = false
  }

  @discardableResult
  func togglePictureInPicture() -> Bool {
    guard let window, !window.styleMask.contains(.fullScreen) else { return false }
    if isPictureInPicture {
      if let originalLevel { window.level = originalLevel }
      if let originalCollectionBehavior { window.collectionBehavior = originalCollectionBehavior }
      if let originalAspectRatio { window.contentAspectRatio = originalAspectRatio }
      if let pictureInPictureFrame {
        window.setFrame(pictureInPictureFrame, display: true, animate: true)
      }
      isPictureInPicture = false
      return false
    }

    pictureInPictureFrame = window.frame
    let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
    let width = min(max(visibleFrame.width * 0.3, 420), 560)
    let height = width * 9 / 16
    let frame = NSRect(
      x: visibleFrame.maxX - width - 24,
      y: visibleFrame.minY + 24,
      width: width,
      height: height)
    window.level = .floating
    window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    window.contentAspectRatio = NSSize(width: 16, height: 9)
    window.setFrame(frame, display: true, animate: true)
    isPictureInPicture = true
    return true
  }

  func restore() {
    guard let window else { return }
    if isPictureInPicture { _ = togglePictureInPicture() }
    if window.styleMask.contains(.fullScreen) {
      if fullscreenExitObserver == nil {
        fullscreenExitObserver = NotificationCenter.default.addObserver(
          forName: NSWindow.didExitFullScreenNotification,
          object: window,
          queue: .main
        ) { [self] _ in
          MainActor.assumeIsolated { restoreWindowPresentation() }
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
    if let originalTitlebarSeparatorStyle {
      window.titlebarSeparatorStyle = originalTitlebarSeparatorStyle
    }
    if let originalBackgroundColor { window.backgroundColor = originalBackgroundColor }
    if let originalTitle { window.title = originalTitle }
    if let originalToolbarVisibility { window.toolbar?.isVisible = originalToolbarVisibility }
    if let originalLevel { window.level = originalLevel }
    if let originalCollectionBehavior { window.collectionBehavior = originalCollectionBehavior }
    if let originalAspectRatio { window.contentAspectRatio = originalAspectRatio }
    if let originalFrame {
      window.setFrame(originalFrame, display: true)
      DispatchQueue.main.async { [weak window] in window?.setFrame(originalFrame, display: true) }
    }
    if let fullscreenExitObserver {
      NotificationCenter.default.removeObserver(fullscreenExitObserver)
      self.fullscreenExitObserver = nil
    }
    self.window = nil
  }
}
