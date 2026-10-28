import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
  private let profile: StoredServerProfile
  @EnvironmentObject private var model: AppModel
  @StateObject private var controller: PlaybackController
  @StateObject private var sceneNotes: SceneNotesController
  @StateObject private var previews = ScrubPreviewController()
  @State private var hoverPosition: Double?
  @State private var notesPresented = false
  @State private var upNextMedia: CatalogItemSummary?
  @State private var notesNavigationRevision: UInt64 = 0
  @ObservedObject private var preferencesStore = PlaybackPreferencesStore.shared
  @State private var controlsVisible = true
  @State private var isScrubbing = false
  @State private var scrubPosition: Double = 0
  @State private var previewControlsHeight: CGFloat?
  @State private var hideTask: Task<Void, Never>?
  @State private var windowPresentation = PlayerWindowPresentation()
  @State private var fullScreenKeyboard = PlayerFullScreenKeyboard()
  @State private var isNativeFullScreen = false
  @State private var isPictureInPicture = false
  @State private var isAdjustingVolume = false
  @State private var controlsPolicy = PlayerControlsPolicy()
  @FocusState private var focusedControl: String?
  @StateObject private var cursor = PlayerCursorCoordinator()
  @State private var confirmProgressReplacement = false
  @Environment(\.aureliaReduceMotion) private var reduceMotion
  @Environment(\.aureliaReduceTransparency) private var reduceTransparency

  init(profile: StoredServerProfile, presentation: PlaybackPresentation) {
    self.profile = profile
    _sceneNotes = StateObject(
      wrappedValue: SceneNotesController(profile: profile, mediaId: presentation.mediaId))
    #if DEBUG
      if CinemaUITestFixture.enabled {
        _controller = StateObject(
          wrappedValue: CinemaUITestFixture.player(profile: profile, presentation: presentation))
        return
      }
    #endif
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
          onPointer: { inside, moved in
            updateCursorEnvironment()
            cursor.pointer(inside: inside, physicallyMoved: moved)
          },
          onKeyDown: handleKey
        )
        .frame(width: viewport.width, height: viewport.height)

        if startScreenVisible {
          PlayerStartScreen(reduceMotion: reduceMotion)
            .frame(width: viewport.width, height: viewport.height)
            .transition(.opacity)
        }

        if controlsVisible || controller.isPreparing || controller.errorMessage != nil {
          controls(in: viewport)
            .frame(width: viewport.width, height: viewport.height)
            .transition(.opacity)
        }

        if let upNext = controller.upNext, controller.errorMessage == nil {
          upNextCard(upNext)
            .padding(.trailing, 28)
            .padding(.bottom, controlsVisible ? 150 : 40)
            .frame(width: viewport.width, height: viewport.height, alignment: .bottomTrailing)
            .transition(.opacity)
        }

        if let note = sceneNotes.cueText {
          VStack {
            HStack {
              Spacer()
              Text(note).font(.callout).lineLimit(6).padding(12).frame(
                maxWidth: 320, alignment: .leading
              )
              .playerMaterial(
                reduceTransparency: reduceTransparency, shape: RoundedRectangle(cornerRadius: 14)
              )
              .accessibilityIdentifier("scene-note-hint")
            }
            Spacer()
          }
          .padding(.trailing, 26).padding(.top, controlsVisible ? 96 : 32)
          .allowsHitTesting(false)
        }

        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement()
          .accessibilityLabel("Native Player · \(controller.presentation.title)")
          .accessibilityIdentifier("native-player")
      }
      .frame(width: viewport.width, height: viewport.height)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: startScreenVisible)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: controller.upNext != nil)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ignoresSafeArea()
    .background(
      PlayerWindowAccessor { window in
        guard !cursor.isRetired else { return }
        windowPresentation.apply(to: window)
        isNativeFullScreen = window.styleMask.contains(.fullScreen)
        fullScreenKeyboard.install(
          on: window,
          isBlocked: {
            notesPresented || confirmProgressReplacement
              || controlsPolicy.holds.contains("diagnostics-export")
              || controlsPolicy.holds.contains { $0.hasPrefix("menu-") }
          }, onToggle: toggleFullScreen)
        updateCursorEnvironment()
      }
    )
    .preferredColorScheme(.dark)
    .focusedSceneObject(episodeShortcutController)
    .contextMenu {
      Button("Export Playback Diagnostics…") { exportPlaybackDiagnostics() }
        .accessibilityIdentifier("player-export-diagnostics")
    }
    .task {
      PlaybackShutdownCoordinator.shared.register(controller)
      if ProcessInfo.processInfo.environment["AURELIA_UI_TEST_MODE"] == nil {
        let loader = model.artworkLoader
        SystemMediaPlaybackCoordinator.shared.register(controller) { artwork in
          try await loader.image(for: artwork, profile: profile, width: 640)
        }
      }
      revealControls()
      sceneNotes.reload()
      await controller.start()
    }
    .onDisappear {
      hideTask?.cancel()
      sceneNotes.stop()
      previews.reset()
      cursor.retire()
      fullScreenKeyboard.retire()
      PlaybackShutdownCoordinator.shared.unregister(controller)
      SystemMediaPlaybackCoordinator.shared.unregister(controller)
      windowPresentation.restore()
      model.reportPlayerPlaying(false)
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
    .onChange(of: controller.sleepTimerFinished) { _, finished in
      if finished { closePlayer() }
    }
    .onChange(of: controller.isPlaying) {
      model.reportPlayerPlaying(controller.isPlaying)
      if !controller.isPlaying { cursor.show() }
      advanceSceneNotes()
    }
    .onChange(of: controller.currentTimeMilliseconds) { advanceSceneNotes() }
    .onChange(of: controller.navigationRevision) { advanceSceneNotes() }
    .onChange(of: controller.presentation.mediaId) {
      sceneNotes.changeMedia(controller.presentation.mediaId)
      configurePreviews()
    }
    .onAppear { configurePreviews() }
    .onChange(of: controller.previewSourceURL) { configurePreviews() }
    .onChange(of: controller.durationMilliseconds) { configurePreviews() }
    .onChange(of: model.libraryCapabilities) { configurePreviews() }
    .onChange(of: previewPosition.map { previews.bucket(for: Int64($0)) }) {
      if let position = previewPosition { previews.request(at: Int64(position)) }
    }
    .onReceive(model.$sceneNotesVersion.dropFirst()) { _ in sceneNotes.reload() }
    .onChange(of: model.catalogVisibilityRevision) { sceneNotes.reload() }
    .onChange(of: notesPresented) { interaction("scene-notes", active: notesPresented) }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
    { _ in
      suspendCursorHiding()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      updateCursorEnvironment()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
      notification in
      if notification.object as? NSWindow === windowPresentation.window { suspendCursorHiding() }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
      notification in
      if notification.object as? NSWindow === windowPresentation.window { cursor.retire() }
    }
    .onChange(of: preferencesStore.preferences.controlsAutoHideDelay) {
      revealControls()
    }
    .onChange(of: focusedControl) { interaction("keyboard", active: focusedControl != nil) }
    .onChange(of: confirmProgressReplacement) {
      interaction("progress-confirmation", active: confirmProgressReplacement)
    }
    .alert("Replace the server playback position?", isPresented: $confirmProgressReplacement) {
      Button("Use Current Position") { Task { await controller.useCurrentProgress() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Another device changed this title's progress. Use the position currently shown in this player instead? Your local draft remains saved if you cancel."
      )
    }
  }

  private func controls(in viewport: CGSize) -> some View {
    let controlWidth = max(viewport.width - 96, 0)
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
          .focused($focusedControl, equals: "back")
          .onHover { interaction("back-hover", active: $0) }
        Spacer(minLength: 24)
        playerMenus
      }
      .padding(.horizontal, 18)
      .frame(width: viewport.width - 36, height: 52)
      .position(x: viewport.width / 2, y: topInset + 26)

      if !startScreenVisible {
        bottomControls
          .frame(width: controlWidth, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .position(
            x: viewport.width / 2,
            y: viewport.height - bottomInset - 56)
      }

      if let message = controller.progressMessage {
        HStack(spacing: 10) {
          Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
          Text(message).font(.caption).lineLimit(2)
          if controller.hasProgressConflict {
            Button("Use Current Position…") { confirmProgressReplacement = true }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("player-resolve-progress-conflict")
          }
        }
        .padding(10)
        .playerMaterial(reduceTransparency: reduceTransparency, shape: Capsule())
        .frame(maxWidth: controlWidth)
        .onHover { interaction("progress-hover", active: $0) }
        .position(x: viewport.width / 2, y: viewport.height - bottomInset - 142)
      }

      if !controller.isPreparing, !startScreenVisible, controller.errorMessage == nil {
        HStack(spacing: 4) {
          Button {
            _ = controller.playPreviousFromSystemMedia()
            revealControls()
          } label: {
            Image(systemName: "backward.end.fill").frame(width: 36, height: 44)
          }
          .buttonStyle(.plain).disabled(!controller.canPlayPrevious)
          .accessibilityLabel("Previous Episode").help("Previous Episode (P)")
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
          .focused($focusedControl, equals: "play")
          seekButton(forward: true)
          Button {
            _ = controller.playNextFromSystemMedia()
            revealControls()
          } label: {
            Image(systemName: "forward.end.fill").frame(width: 36, height: 44)
          }
          .buttonStyle(.plain).disabled(!controller.canPlayNext)
          .accessibilityLabel("Next Episode").help("Next Episode (N)")
        }
        .padding(6)
        .playerMaterial(reduceTransparency: reduceTransparency, shape: Capsule())
        .onHover { interaction("transport-hover", active: $0) }
        .position(x: viewport.width / 2, y: viewport.height / 2)
      }

      // The start screen has its own ring; reconnecting still explains itself here.
      if controller.isPreparing, controller.errorMessage == nil,
        !startScreenVisible || controller.recoveryMessage != nil
      {
        VStack(spacing: 12) {
          ProgressView(controller.recoveryMessage ?? "Preparing playback…")
            .controlSize(.large)
          if controller.recoveryMessage != nil {
            Button("Stop Retrying") { controller.cancelRecovery() }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("player-stop-recovery")
          }
        }
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
      trackedMenu(
        "Playback Rate", id: "rate",
        options:
          PlaybackPreferences.supportedRates.map { rate in
            PlayerMenuOption(
              title:
                rate == 1 ? "Standard" : rateLabel(rate),
              selected: controller.playbackRate == rate
            ) {
              controller.setPlaybackRate(rate)
              revealControls()
            }
          }
      ) {
        PlayerControlLabel(height: 30, minWidth: 38) {
          Text(rateLabel(controller.playbackRate))
            .font(.system(size: 14, weight: .bold).monospacedDigit())
        }
      }
      .accessibilityValue(rateLabel(controller.playbackRate))

      trackedMenu(
        "Audio", id: "audio",
        options: (controller.audioTracks.isEmpty
          ? [PlayerMenuOption(title: "No audio tracks available", enabled: false)]
          : controller.audioTracks.map { track in
            PlayerMenuOption(
              title: track.title, selected: controller.selectedAudioTrackID == track.id
            ) {
              controller.selectAudioTrack(track.id)
              revealControls()
            }
          })
          + [
            .divider,
            PlayerMenuOption(
              title: "Night Mode", selected: preferencesStore.preferences.nightMode
            ) {
              preferencesStore.preferences.nightMode.toggle()
              controller.reopenForAudioChange()
              revealControls()
            },
          ]
      ) {
        PlayerControlLabel { Image(systemName: "waveform") }
      }

      trackedMenu("Subtitles", id: "subtitle", options: subtitleOptions) {
        PlayerControlLabel {
          Image(
            systemName: controller.selectedSubtitleTrackID == nil
              ? "captions.bubble" : "captions.bubble.fill")
        }
      }

      trackedMenu("Sleep Timer", id: "sleep", options: sleepOptions) {
        PlayerControlLabel {
          Image(systemName: controller.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill")
        }
      }

      Button {
        if !notesPresented { sceneNotes.create(at: controller.currentTimeMilliseconds) }
        notesPresented.toggle()
      } label: {
        PlayerControlLabel { Image(systemName: "bookmark") }
      }
      .buttonStyle(.plain).accessibilityLabel("Scene Notes")
      .accessibilityIdentifier("player-notes")
      .focused($focusedControl, equals: "notes")
      .popover(isPresented: $notesPresented, arrowEdge: .bottom) {
        SceneNotesPopover(
          notes: sceneNotes, currentPosition: { controller.currentTimeMilliseconds },
          seek: { controller.seek(to: $0) })
      }

    }
    .padding(4)
    .playerMaterial(reduceTransparency: reduceTransparency, shape: Capsule())
    .onHover { interaction("menus-hover", active: $0) }
  }

  private var subtitleOptions: [PlayerMenuOption] {
    [
      PlayerMenuOption(title: "Off", selected: controller.selectedSubtitleTrackID == nil) {
        controller.selectSubtitleTrack(nil)
        revealControls()
      }, .divider,
    ]
      + (controller.subtitleTracks.isEmpty
        ? [PlayerMenuOption(title: "No subtitles available", enabled: false)]
        : controller.subtitleTracks.map { track in
          PlayerMenuOption(
            title: track.title, selected: controller.selectedSubtitleTrackID == track.id
          ) {
            controller.selectSubtitleTrack(track.id)
            revealControls()
          }
        })
  }

  private var sleepOptions: [PlayerMenuOption] {
    [
      PlayerMenuOption(title: "Off", selected: controller.sleepTimer == .off) {
        controller.setSleepTimer(.off)
        revealControls()
      }, .divider,
      PlayerMenuOption(title: "At end of episode", selected: controller.sleepTimer == .endOfEpisode)
      {
        controller.setSleepTimer(.endOfEpisode)
        revealControls()
      },
    ]
      + [15, 30, 45, 60, 90].map { minutes in
        PlayerMenuOption(
          title: "\(minutes) minutes", selected: controller.sleepTimer == .minutes(minutes)
        ) {
          controller.setSleepTimer(.minutes(minutes))
          revealControls()
        }
      }
  }

  private func trackedMenu<Label: View>(
    _ title: String, id: String, options: [PlayerMenuOption],
    @ViewBuilder label: @escaping () -> Label
  ) -> some View {
    TrackedPlayerMenu(
      title: title, identifier: "player-\(id)-menu", options: options,
      onOpen: { interaction("menu-\(id)", active: $0) },
      onFocus: { interaction("focus-\(id)", active: $0) }, label: label)
  }

  private var bottomControls: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .bottom, spacing: 24) {
        VStack(alignment: .leading, spacing: 2) {
          Text(controller.presentation.subtitle ?? "NOW PLAYING")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.68))
            .accessibilityIdentifier("player-subtitle")
          Text(controller.presentation.title)
            .font(.title3.weight(.semibold))
            .lineLimit(2)
            .accessibilityIdentifier("player-title")
        }
        Spacer(minLength: 30)
        trailingControls
      }
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: { height in
        previewControlsHeight = height
      }

      HStack(spacing: 10) {
        Text(formatTime(displayedPosition)).monospacedDigit().frame(
          minWidth: 44, alignment: .trailing
        )
        .accessibilityIdentifier("player-elapsed")
        PlayerTimeline(
          position: Binding(
            get: { displayedPosition },
            set: { scrubPosition = $0 }),
          duration: max(Double(controller.durationMilliseconds), 1),
          chapters: controller.chapters,
          notes: sceneNotes.notes,
          hoverPosition: $hoverPosition,
          previewClearance: (previewControlsHeight ?? 0) + 9,
          preview: previewPosition.flatMap { position -> PlayerTimelinePreview? in
            guard previewControlsHeight != nil else { return nil }
            return PlayerTimelinePreview(
              position: position, label: formatTime(position),
              image: previews.imageBucket == previews.bucket(for: Int64(position))
                ? previews.image : nil)
          },
          onEditingChanged: timelineEditingChanged)
        Text(formatTime(Double(controller.durationMilliseconds)))
          .monospacedDigit().frame(minWidth: 44, alignment: .leading)
      }
      .font(.caption)

      if let endsAt = PlaybackEndTime.text(
        position: Int64(displayedPosition), duration: controller.durationMilliseconds,
        rate: controller.playbackRate, now: Date())
      {
        Text(endsAt)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.white.opacity(0.62))
          .monospacedDigit()
          .frame(maxWidth: .infinity, alignment: .trailing)
          .accessibilityIdentifier("player-ends-at")
      }
    }
    .frame(maxWidth: .infinity)
    .onHover { interaction("bottom-hover", active: $0) }
  }

  private var trailingControls: some View {
    HStack(spacing: 2) {
      if !controller.chapters.isEmpty {
        trackedMenu(
          "Chapters", id: "chapter",
          options:
            controller.chapters.map { chapter in
              PlayerMenuOption(
                title: "\(chapter.title)  \(formatTime(Double(chapter.timeOffsetMilliseconds)))",
                selected: controller.currentChapterIndex == chapter.index
              ) {
                controller.selectChapter(chapter)
                revealControls()
              }
            }
        ) {
          PlayerControlLabel { Image(systemName: "list.bullet.rectangle") }
        }
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
      .focused($focusedControl, equals: "mute")

      Slider(
        value: Binding(get: { controller.volume }, set: { controller.setVolume($0) }),
        in: 0...1,
        onEditingChanged: { editing in
          isAdjustingVolume = editing
          interaction("volume", active: editing)
        }
      )
      .frame(width: 96)
      .tint(.white)
      .frame(minHeight: 42)
      .accessibilityLabel("Volume")
      .accessibilityValue("\(Int(controller.volume * 100)) percent")
      .focused($focusedControl, equals: "volume")

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
        .focused($focusedControl, equals: "pip")
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
      .focused($focusedControl, equals: "fullscreen")
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
      Button("Export Playback Diagnostics…") { exportPlaybackDiagnostics() }
        .font(.caption).accessibilityIdentifier("player-error-diagnostics")
    }
    .padding(26)
    .frame(maxWidth: 440)
    .playerMaterial(
      reduceTransparency: reduceTransparency,
      shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
  }

  private func exportPlaybackDiagnostics() {
    interaction("diagnostics-export", active: true)
    defer { interaction("diagnostics-export", active: false) }
    let panel = NSSavePanel()
    panel.title = "Export Playback Diagnostics"
    panel.nameFieldStringValue = "Aurelia Playback Diagnostics.json"
    panel.allowedContentTypes = [.json]
    panel.message =
      "Includes bounded playback events and positions, without media paths, titles, server addresses or credentials."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try controller.diagnostics.export().write(to: url, options: .atomic) } catch {
      let alert = NSAlert()
      alert.messageText = "Diagnostics could not be exported"
      alert.informativeText = "Check the destination and available disk space, then try again."
      alert.runModal()
    }
  }

  private func seekButton(forward: Bool) -> some View {
    let interval = preferencesStore.preferences.seekInterval
    return Button {
      controller.skip(seconds: Int64(forward ? interval : -interval))
      revealControls()
    } label: {
      PlayerSeekGlyph(interval: interval, forward: forward)
        .frame(width: 42, height: 42)
    }
    .buttonStyle(PlayerPressButtonStyle(reduceMotion: reduceMotion))
    .accessibilityLabel("\(forward ? "Forward" : "Back") \(interval) Seconds")
    .focused($focusedControl, equals: forward ? "forward" : "backward")
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

  /// The next episode with a countdown in this title's last seconds.
  private func upNextCard(_ upNext: PlaybackUpNext) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("UP NEXT").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
      Text(upNext.title).font(.title3.weight(.semibold)).lineLimit(2)
      if let subtitle = upNext.subtitle {
        Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
      }
      HStack(spacing: 10) {
        Button {
          controller.playNextNow()
        } label: {
          Label("Play Now · \(upNext.seconds)", systemImage: "play.fill")
            .monospacedDigit()
            .frame(minWidth: 120)
        }
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .foregroundStyle(.black)
        .accessibilityIdentifier("player-up-next-play")
        Button("Cancel") { controller.dismissUpNext() }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("player-up-next-cancel")
      }
      .controlSize(.large)
      .padding(.top, 4)
    }
    .padding(18)
    .frame(width: 320, alignment: .leading)
    .playerMaterial(
      reduceTransparency: reduceTransparency,
      shape: RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
    .onHover { interaction("up-next-hover", active: $0) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("player-up-next")
    .modifier(
      PlayerUpNextActions(
        item: upNextMedia?.id == controller.nextQueueItem?.mediaId ? upNextMedia : nil,
        nextID: controller.nextQueueItem?.mediaId, seriesID: controller.presentation.trackScope,
        onPlay: { id in
          guard controller.nextQueueItem?.mediaId == id else { return }
          controller.playNextNow()
        },
        onResume: { id in
          guard controller.nextQueueItem?.mediaId == id else { return }
          _ = controller.resumeNextNow()
        },
        onGoToSeries: { id in
          closePlayer()
          model.requestedMediaDetail = id
        })
    )
    .task(id: controller.nextQueueItem?.mediaId) {
      upNextMedia = nil
      guard let next = controller.nextQueueItem,
        model.profile?.sessionId == profile.sessionId
      else { return }
      if let listed = model.listedItem(id: next.mediaId) {
        upNextMedia = listed
        return
      }
      do {
        let detail = try await model.catalogDetail(id: next.mediaId)
        guard !Task.isCancelled, model.profile?.sessionId == profile.sessionId,
          controller.nextQueueItem?.mediaId == next.mediaId
        else { return }
        upNextMedia = detail.item
      } catch {
        // Do not invent favorite/progress/permission state if the catalog request fails.
      }
    }
  }

  private var startScreenVisible: Bool {
    controller.showsStartScreen && controller.errorMessage == nil
  }

  /// Previews belong to the open title; the next one discards them from memory.
  private func configurePreviews() {
    previews.configure(
      mediaID: controller.presentation.mediaId, source: controller.previewSourceURL,
      duration: controller.durationMilliseconds,
      parallel: model.libraryCapabilities.contains(ScrubPreviewController.serverFeature))
  }

  private var displayedPosition: Double {
    isScrubbing ? scrubPosition : Double(controller.currentTimeMilliseconds)
  }

  /// Where a live preview frame is wanted: the dragged knob, else the pointer over the timeline.
  private var previewPosition: Double? {
    guard controller.previewSourceURL != nil, controller.durationMilliseconds > 0 else {
      return nil
    }
    return isScrubbing ? scrubPosition : hoverPosition
  }

  private func advanceSceneNotes() {
    if notesNavigationRevision != controller.navigationRevision {
      notesNavigationRevision = controller.navigationRevision
      sceneNotes.seek()
    }
    sceneNotes.advance(
      position: controller.currentTimeMilliseconds, playing: controller.isPlaying,
      preparing: controller.isPreparing)
  }

  private func timelineEditingChanged(_ editing: Bool) {
    isScrubbing = editing
    controlsPolicy.hold("scrubbing", active: editing)
    if editing {
      scrubPosition = Double(controller.currentTimeMilliseconds)
      revealControls(scheduleHide: false)
    } else {
      controller.seek(to: Int64(scrubPosition.rounded()))
      revealControls()
    }
  }

  private var episodeShortcutController: PlaybackController? {
    let blocked =
      notesPresented || confirmProgressReplacement
      || controlsPolicy.holds.contains("diagnostics-export")
      || controlsPolicy.holds.contains { $0.hasPrefix("menu-") }
    return blocked ? nil : controller
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    revealControls()
    guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
      return false
    }
    // Only the video surface calls this handler, so text fields keep their normal typing behavior.
    if let command = SystemMediaCommand.episodeShortcut(
      characters: event.charactersIgnoringModifiers, modified: false, isRepeat: event.isARepeat)
    {
      if command == .previousEpisode {
        _ = controller.playPreviousFromSystemMedia()
      } else {
        _ = controller.playNextFromSystemMedia()
      }
      return true
    }
    switch event.keyCode {
    case 49:
      controller.togglePlayback()
    case 123:
      controller.skip(seconds: -Int64(preferencesStore.preferences.seekInterval))
    case 124:
      controller.skip(seconds: Int64(preferencesStore.preferences.seekInterval))
    case 46:
      controller.toggleMute()
    case 53:
      if isPictureInPicture {
        togglePictureInPicture()
      } else if isNativeFullScreen {
        toggleFullScreen()
      } else {
        closePlayer()
      }
    default:
      return false
    }
    revealControls()
    return true
  }

  private func toggleFullScreen() {
    guard let window = windowPresentation.window, fullScreenKeyboard.beginToggle(on: window)
    else { return }
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
    guard !cursor.isRetired else { return }
    hideTask?.cancel()
    let generation = controlsPolicy.invalidate()
    showCursor()
    let controlsWereHidden = !controlsVisible
    if controlsWereHidden {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { controlsVisible = true }
    }
    guard scheduleHide, canAutoHide else { return }
    let delay = preferencesStore.preferences.controlsAutoHideDelay
    hideTask = Task {
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, canAutoHide,
        controlsPolicy.permitsHide(
          generation, preparing: controller.isPreparing, error: controller.errorMessage != nil)
      else { return }
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsVisible = false }
      updateCursorEnvironment()
      cursor.hideIfPermitted(playing: controller.isPlaying, blocked: !canAutoHide)
    }
  }

  private var canAutoHide: Bool {
    !cursor.isRetired && !controller.isPreparing && controller.errorMessage == nil && !isScrubbing
      && !isAdjustingVolume
      && controlsPolicy.holds.isEmpty
  }

  private func interaction(_ reason: String, active: Bool) {
    // Dismantled native menu buttons report focus-end even without prior focus.
    // Cleanup must not resurrect the overlay that just removed those buttons.
    guard controlsPolicy.hold(reason, active: active), active || controlsVisible else { return }
    revealControls(scheduleHide: !active)
  }

  private func updateCursorEnvironment() {
    cursor.environment(
      active: NSApplication.shared.isActive,
      keyWindow: windowPresentation.window?.isKeyWindow == true)
  }

  private func suspendCursorHiding() {
    hideTask?.cancel()
    controlsPolicy.invalidate()
    cursor.environment(active: false, keyWindow: false)
  }

  private func showCursor() {
    cursor.show()
  }

  private func closePlayer() {
    guard !cursor.isRetired else { return }
    hideTask?.cancel()
    controlsPolicy.invalidate()
    cursor.retire()
    fullScreenKeyboard.retire()
    let retiringProfile = model.profile
    model.dismissPlayback()
    Task {
      await controller.shutdown()
      if model.profile?.sessionId == retiringProfile?.sessionId { await model.refreshHome() }
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

struct PlayerTimelinePreview: Equatable {
  let position: Double
  let label: String
  let image: CGImage?
}

private struct PlayerTimeline: View {
  @Binding var position: Double
  let duration: Double
  let chapters: [PlaybackChapter]
  let notes: [SceneNote]
  @Binding var hoverPosition: Double?
  let previewClearance: CGFloat
  let preview: PlayerTimelinePreview?
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
          .tint(.white)
        ForEach(notes) { note in
          let start = min(max(Double(note.startMilliseconds) / duration, 0), 1) * proxy.size.width
          let end =
            min(max(Double(note.endMilliseconds ?? note.startMilliseconds) / duration, 0), 1)
            * proxy.size.width
          Capsule().fill(.white.opacity(0.65)).frame(width: max(3, end - start), height: 3)
            .position(x: (start + end) / 2, y: proxy.size.height / 2 + 9)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
      }
      .onContinuousHover { phase in
        switch phase {
        case .active(let location):
          let fraction = min(max(location.x / max(proxy.size.width, 1), 0), 1)
          hoverPosition = fraction * duration
        case .ended:
          hoverPosition = nil
        }
      }
      .overlay(alignment: .topLeading) {
        if let preview {
          let width = PlayerPreviewPlacement.width(in: proxy.size.width)
          let x = PlayerPreviewPlacement.leading(
            timelineWidth: proxy.size.width, position: preview.position, duration: duration,
            previewWidth: width)
          PlayerPreviewBubble(preview: preview, width: width)
            .alignmentGuide(.top) { dimensions in
              PlayerPreviewPlacement.topAlignment(
                previewHeight: dimensions.height, controlsHeight: previewClearance)
            }
            .offset(x: x)
            .allowsHitTesting(false)
        }
      }
    }
    .frame(minHeight: 44)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Playback Position")
    .accessibilityIdentifier("player-timeline")
  }
}

/// A live frame above the timeline while hovering or dragging; it never leaves memory.
private struct PlayerPreviewBubble: View {
  let preview: PlayerTimelinePreview
  let width: CGFloat

  var body: some View {
    VStack(spacing: 6) {
      ZStack {
        Color.black
        if let image = preview.image {
          Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
        } else {
          ProgressView().controlSize(.small)
        }
      }
      .frame(width: width, height: width * 9 / 16)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay { RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.35), lineWidth: 1) }
      .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
      Text(preview.label)
        .font(.caption.weight(.semibold)).monospacedDigit()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.black.opacity(0.6), in: Capsule())
    }
    .accessibilityHidden(true)
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
    height: CGFloat = 30,
    minWidth: CGFloat = 30,
    @ViewBuilder content: () -> Content
  ) {
    self.height = height
    self.minWidth = minWidth
    self.content = content()
  }

  var body: some View {
    content
      .font(.system(size: 14, weight: .semibold))
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
  let onPointer: (Bool, Bool) -> Void
  let onKeyDown: (NSEvent) -> Bool

  func makeNSView(context: Context) -> PlayerTrackingView {
    let view = PlayerTrackingView()
    view.onInteraction = onInteraction
    view.onPointer = onPointer
    view.onKeyDown = onKeyDown
    controller.attachVideoView(view)
    return view
  }

  func updateNSView(_ nsView: PlayerTrackingView, context: Context) {
    nsView.onInteraction = onInteraction
    nsView.onPointer = onPointer
    nsView.onKeyDown = onKeyDown
  }
}

private final class PlayerTrackingView: NSView {
  var onInteraction: (() -> Void)?
  var onPointer: ((Bool, Bool) -> Void)?
  var onKeyDown: ((NSEvent) -> Bool)?
  private var trackingArea: NSTrackingArea?
  private var pointerActivity = PlayerPointerActivity(position: NSEvent.mouseLocation)

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.window?.makeFirstResponder(self)
    }
  }

  override func updateTrackingAreas() {
    // inVisibleRect follows the viewport; keep the area across overlay/layout changes.
    if trackingArea == nil {
      let trackingArea = NSTrackingArea(
        rect: .zero,
        options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
        owner: self)
      addTrackingArea(trackingArea)
      self.trackingArea = trackingArea
    }
    super.updateTrackingAreas()
  }

  override func mouseMoved(with event: NSEvent) {
    guard pointerActivity.moved(to: NSEvent.mouseLocation) else { return }
    onPointer?(bounds.contains(convert(event.locationInWindow, from: nil)), true)
    onInteraction?()
  }
  override func mouseEntered(with event: NSEvent) { onPointer?(true, false) }
  override func mouseExited(with event: NSEvent) { onPointer?(false, false) }
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
  private var originalMinSize: NSSize?
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
    originalFrame = window.styleMask.contains(.fullScreen) ? nil : window.frame
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
    AureliaWindowControls.revealIfWindowed(window)
  }

  @discardableResult
  func togglePictureInPicture() -> Bool {
    guard let window, !window.styleMask.contains(.fullScreen) else { return false }
    if isPictureInPicture {
      if let originalLevel { window.level = originalLevel }
      if let originalCollectionBehavior { window.collectionBehavior = originalCollectionBehavior }
      restoreAspectRatio(of: window)
      if let pictureInPictureFrame {
        window.setFrame(pictureInPictureFrame, display: true, animate: true)
      }
      if let originalMinSize { window.contentMinSize = originalMinSize }
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
    // The minimum must fit the 16:9 ratio, or resizing the small window has no valid size.
    originalMinSize = window.contentMinSize
    window.contentMinSize = NSSize(width: 320, height: 180)
    window.contentAspectRatio = NSSize(width: 16, height: 9)
    window.setFrame(frame, display: true, animate: true)
    isPictureInPicture = true
    return true
  }

  /// Undoes the 16:9 picture-in-picture ratio. A zero ratio is not "no ratio": assigning it made
  /// every later edge drag compute an invalid frame and abort, so free resizing is restored
  /// through the resize increments, as AppKit documents.
  private func restoreAspectRatio(of window: NSWindow) {
    if let originalAspectRatio, originalAspectRatio.width > 0, originalAspectRatio.height > 0 {
      window.contentAspectRatio = originalAspectRatio
    } else {
      window.contentResizeIncrements = NSSize(width: 1, height: 1)
    }
  }

  func restore() {
    guard let window else { return }
    if isPictureInPicture { _ = togglePictureInPicture() }
    if AureliaWindowRestorePolicy.shouldExitFullScreen(
      original: originalStyleMask, current: window.styleMask)
    {
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
    if let originalStyleMask {
      window.styleMask = AureliaWindowRestorePolicy.restoredStyle(
        original: originalStyleMask, current: window.styleMask)
    }
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
    AureliaWindowControls.revealIfWindowed(window)
    if let originalLevel { window.level = originalLevel }
    if let originalCollectionBehavior { window.collectionBehavior = originalCollectionBehavior }
    if let originalFrame, !window.styleMask.contains(.fullScreen) {
      window.setFrame(originalFrame, display: true)
      DispatchQueue.main.async { [weak window] in
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.setFrame(originalFrame, display: true)
      }
    }
    if let fullscreenExitObserver {
      NotificationCenter.default.removeObserver(fullscreenExitObserver)
      self.fullscreenExitObserver = nil
    }
    self.window = nil
  }
}

/// Up Next shares the catalog's real item menu without manufacturing state from a queue label.
private struct PlayerUpNextActions: ViewModifier {
  let item: CatalogItemSummary?
  let nextID: UUID?
  let seriesID: UUID?
  let onPlay: (UUID) -> Void
  let onResume: (UUID) -> Void
  let onGoToSeries: (UUID) -> Void

  @ViewBuilder func body(content: Content) -> some View {
    if let item {
      content.mediaActions(
        item: item, onPlay: { onPlay(item.id) }, onResume: { onResume(item.id) },
        onGoToSeries: onGoToSeries)
    } else {
      content.contextMenu {
        if let nextID { Button("Play", systemImage: "play.fill") { onPlay(nextID) } }
        if let seriesID { Button("Go to Series", systemImage: "tv") { onGoToSeries(seriesID) } }
      }
    }
  }
}
