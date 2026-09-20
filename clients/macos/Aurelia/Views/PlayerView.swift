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
  @State private var showingRate = false
  @State private var showingAudioTracks = false
  @State private var showingSubtitleTracks = false
  @State private var showingSleepTimer = false
  @State private var showingChapters = false
  @State private var cursorHidden = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  init(profile: StoredServerProfile, presentation: PlaybackPresentation) {
    _controller = StateObject(
      wrappedValue: PlaybackController(profile: profile, presentation: presentation))
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      PlayerVideoSurface(
        controller: controller,
        onInteraction: { revealControls() },
        onKeyDown: handleKey
      )
      .ignoresSafeArea()

      if controlsVisible || controller.isPreparing || controller.errorMessage != nil {
        controls.transition(.opacity)
      }

      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement()
        .accessibilityLabel("Native Player · \(controller.presentation.title)")
        .accessibilityIdentifier("native-player")
    }
    .background(PlayerWindowAccessor { window in windowPresentation.apply(to: window) })
    .preferredColorScheme(.dark)
    .task {
      PlaybackShutdownCoordinator.shared.register(controller)
      revealControls()
      await controller.start()
    }
    .onDisappear {
      hideTask?.cancel()
      closeMenus()
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

  private var controls: some View {
    ZStack {
      LinearGradient(
        colors: [.black.opacity(0.72), .clear, .black.opacity(0.84)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack {
        HStack {
          controlButton("Back", systemImage: "chevron.left") { closePlayer() }
            .accessibilityIdentifier("player-back")
          Spacer()
          playerMenus
        }
        .padding(24)

        Spacer()

        HStack(spacing: 14) {
          seekButton(forward: false)
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
          .buttonStyle(PlayerPressButtonStyle(reduceMotion: reduceMotion))
          .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
          .accessibilityIdentifier("player-play-pause")
          seekButton(forward: true)
        }
        .padding(12)
        .playerMaterial(reduceTransparency: reduceTransparency, shape: Capsule())

        Spacer()

        bottomControls
          .padding(.horizontal, 30)
          .padding(.bottom, 24)
      }

      if controller.isPreparing, controller.errorMessage == nil {
        ProgressView("Preparing playback…")
          .controlSize(.large)
          .padding(20)
          .playerMaterial(
            reduceTransparency: reduceTransparency,
            shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
      }

      if let error = controller.errorMessage {
        playbackError(error)
      }
    }
  }

  private var playerMenus: some View {
    HStack(spacing: 4) {
      Button {
        showingRate.toggle()
        revealControls(scheduleHide: false)
      } label: {
        Text(rateLabel(controller.playbackRate))
          .font(.callout.weight(.semibold))
          .frame(
            minWidth: AureliaDesign.minimumControlSize,
            minHeight: AureliaDesign.minimumControlSize)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Playback Rate")
      .accessibilityValue(rateLabel(controller.playbackRate))
      .accessibilityIdentifier("player-rate-menu")
      .popover(isPresented: $showingRate, arrowEdge: .top) { ratePicker }

      playerMenuButton("Audio", systemImage: "waveform", isPresented: $showingAudioTracks)
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

      playerMenuButton(
        "Subtitles", systemImage: "captions.bubble", isPresented: $showingSubtitleTracks
      )
      .accessibilityIdentifier("player-subtitle-menu")
      .popover(isPresented: $showingSubtitleTracks, arrowEdge: .top) { subtitlePicker }

      playerMenuButton("Sleep Timer", systemImage: "moon.zzz", isPresented: $showingSleepTimer)
        .accessibilityIdentifier("player-sleep-menu")
        .popover(isPresented: $showingSleepTimer, arrowEdge: .top) { sleepTimerPicker }
    }
    .padding(6)
    .playerMaterial(reduceTransparency: reduceTransparency, shape: Capsule())
    .onChange(of: showingRate) { if !showingRate { revealControls() } }
    .onChange(of: showingAudioTracks) { if !showingAudioTracks { revealControls() } }
    .onChange(of: showingSubtitleTracks) { if !showingSubtitleTracks { revealControls() } }
    .onChange(of: showingSleepTimer) { if !showingSleepTimer { revealControls() } }
  }

  private var ratePicker: some View {
    playerPicker(title: "Playback Rate") {
      ForEach(PlaybackPreferences.supportedRates, id: \.self) { rate in
        trackChoice(rateLabel(rate), selected: controller.playbackRate == rate) {
          controller.setPlaybackRate(rate)
          showingRate = false
        }
      }
    }
  }

  private var subtitlePicker: some View {
    playerPicker(title: "Subtitles") {
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
  }

  private var sleepTimerPicker: some View {
    playerPicker(title: "Sleep Timer") {
      sleepChoice(.off)
      Divider()
      sleepChoice(.endOfEpisode)
      ForEach([15, 30, 45, 60, 90], id: \.self) { sleepChoice(.minutes($0)) }
    }
  }

  private func sleepChoice(_ value: PlaybackSleepTimer) -> some View {
    trackChoice(value.title, selected: controller.sleepTimer == value) {
      controller.setSleepTimer(value)
      showingSleepTimer = false
    }
  }

  private var bottomControls: some View {
    VStack(alignment: .leading, spacing: 12) {
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
  }

  private var trailingControls: some View {
    HStack(spacing: 8) {
      if !controller.chapters.isEmpty {
        playerMenuButton(
          "Chapters", systemImage: "list.bullet.rectangle", isPresented: $showingChapters
        )
        .accessibilityIdentifier("player-chapter-menu")
        .popover(isPresented: $showingChapters, arrowEdge: .bottom) { chapterPicker }
      }
      Button {
        controller.toggleMute()
        revealControls()
      } label: {
        Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .frame(
            width: AureliaDesign.minimumControlSize,
            height: AureliaDesign.minimumControlSize)
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
      .frame(width: 120)
      .frame(minHeight: 44)
      .accessibilityLabel("Volume")
      .accessibilityValue("\(Int(controller.volume * 100)) percent")

      if !isNativeFullScreen {
        Button {
          togglePictureInPicture()
        } label: {
          Image(systemName: isPictureInPicture ? "pip.exit" : "pip.enter")
            .frame(
              width: AureliaDesign.minimumControlSize,
              height: AureliaDesign.minimumControlSize)
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
        .frame(
          width: AureliaDesign.minimumControlSize,
          height: AureliaDesign.minimumControlSize)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isNativeFullScreen ? "Exit Full Screen" : "Enter Full Screen")
      .accessibilityIdentifier("player-fullscreen")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .playerMaterial(reduceTransparency: reduceTransparency, shape: Capsule())
    .onChange(of: showingChapters) { if !showingChapters { revealControls() } }
  }

  private var chapterPicker: some View {
    playerPicker(title: "Chapters") {
      ForEach(controller.chapters) { chapter in
        trackChoice(
          "\(chapter.title)  \(formatTime(Double(chapter.timeOffsetMilliseconds)))",
          selected: controller.currentChapterIndex == chapter.index
        ) {
          controller.selectChapter(chapter)
          showingChapters = false
        }
      }
    }
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

  private func trackPicker(
    title: String,
    emptyMessage: String,
    tracks: [PlaybackTrack],
    selectedID: Int32?,
    selection: @escaping (Int32) -> Void
  ) -> some View {
    playerPicker(title: title) {
      if tracks.isEmpty {
        Text(emptyMessage).foregroundStyle(.secondary).padding(.vertical, 6)
      } else {
        ForEach(tracks) { track in
          trackChoice(track.title, selected: selectedID == track.id) { selection(track.id) }
        }
      }
    }
  }

  private func playerPicker<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.headline).padding(.bottom, 6)
      content()
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
      .frame(minHeight: AureliaDesign.minimumControlSize)
    }
    .buttonStyle(.plain)
  }

  private func playerMenuButton(
    _ title: String,
    systemImage: String,
    isPresented: Binding<Bool>
  ) -> some View {
    Button {
      isPresented.wrappedValue.toggle()
      revealControls(scheduleHide: false)
    } label: {
      Image(systemName: systemImage)
        .frame(
          width: AureliaDesign.minimumControlSize,
          height: AureliaDesign.minimumControlSize)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
  }

  private func seekButton(forward: Bool) -> some View {
    let interval = preferencesStore.preferences.seekInterval
    return Button {
      controller.skip(seconds: Int64(forward ? interval : -interval))
      revealControls()
    } label: {
      ZStack {
        Image(systemName: forward ? "goforward" : "gobackward")
          .font(.system(size: 22, weight: .semibold))
        Text(String(interval))
          .font(.system(size: interval >= 10 ? 8 : 9, weight: .bold, design: .rounded))
      }
      .frame(width: 44, height: 44)
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
    revealControls(scheduleHide: false)
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
      if hasOpenMenu {
        closeMenus()
      } else if isPictureInPicture {
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

  private var hasOpenMenu: Bool {
    showingRate || showingAudioTracks || showingSubtitleTracks || showingSleepTimer
      || showingChapters
  }

  private func closeMenus() {
    showingRate = false
    showingAudioTracks = false
    showingSubtitleTracks = false
    showingSleepTimer = false
    showingChapters = false
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
    withAnimation(reduceMotion ? nil : AureliaDesign.responsiveSpring) { controlsVisible = true }
    hideTask?.cancel()
    guard scheduleHide, canAutoHide else { return }
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
      && !isAdjustingVolume && !hasOpenMenu
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
    closeMenus()
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
    controller.attachVideoView(nsView)
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
    originalToolbarVisibility = window.toolbar?.isVisible
    originalFrame = window.frame
    originalLevel = window.level
    originalCollectionBehavior = window.collectionBehavior
    originalAspectRatio = window.contentAspectRatio
    window.styleMask.insert(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
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
