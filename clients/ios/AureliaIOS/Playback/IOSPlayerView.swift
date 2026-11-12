import SwiftUI
import UIKit

/// The touch player: plain white transport symbols over the picture, small glass buttons at the
/// top and a short sheet for tracks, speed and the sleep timer, like Apple's own player.
/// A hardware keyboard works too: Space plays or pauses, the arrows skip, Escape goes back.
@MainActor
struct IOSPlayerView: View {
  @StateObject private var controller: IOSPlaybackController
  @StateObject private var previews = IOSScrubPreviews()
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.scenePhase) private var scenePhase
  @FocusState private var keyboard: Bool
  /// Brief indicator for skips made while the controls are hidden.
  @State private var skip: IOSSkipIndicator?
  /// Cinema mode's ad, trailers and curtain before a film.
  @State private var preShow: IOSCinemaPreShow?
  /// The playing title's scene notes; nil for downloads played without the server.
  @State private var notes: IOSSceneNotesModel?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(makeController: @escaping @MainActor () -> IOSPlaybackController) {
    _controller = StateObject(wrappedValue: makeController())
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      IOSVideoSurface(engine: controller.engine).ignoresSafeArea().accessibilityIdentifier(
        "player-surface")
      // Receives hardware keyboard presses; it lies beneath everything a finger touches.
      Color.clear.focusable().focusEffectDisabled().focused($keyboard)
        .iosPlayPauseCommand { controller.togglePlayPause() }
        .iosBackCommand { controller.back() }
        .iosMoveCommand { direction in
          switch direction {
          case .left where controller.canSeek: skip(by: -controller.seekInterval)
          case .right where controller.canSeek: skip(by: controller.seekInterval)
          default: controller.userInteracted()
          }
        }
        .accessibilityHidden(true)
      if controller.isStarting && controller.errorMessage == nil {
        startScreen.transition(.opacity)
      }
      if !controller.controlsVisible || controller.isStarting {
        Color.clear.contentShape(Rectangle()).ignoresSafeArea()
          .onTapGesture { controller.userInteracted() }
          .accessibilityAddTraits(.isButton)
          .accessibilityLabel("Show playback controls").accessibilityIdentifier(
            "player-wake-surface")
      }
      if (controller.controlsVisible && !controller.isStarting) || controller.errorMessage != nil {
        controls
      }
      if let skip, !controller.controlsVisible { skipIndicator(skip) }
      // With controls shown, loading is drawn in place of Play instead of behind it.
      if controller.isLoading && controller.errorMessage == nil && !controller.controlsVisible
        && !controller.isStarting
      {
        ProgressView().tint(.white).controlSize(.large).accessibilityIdentifier("player-loading")
      }
      if let upNext = controller.upNext, !controller.controlsVisible, controller.trackMenu == nil {
        upNextCard(upNext)
      }
      // Skip Intro while the intro plays; above the bottom controls while they show.
      if controller.showsSkipIntro, controller.upNext == nil, controller.trackMenu == nil,
        controller.errorMessage == nil, !controller.isStarting
      {
        skipIntroButton
      }
      if !controller.isOffline, let party = model.watchParty {
        IOSWatchTogetherNotice(session: party)
      }
      if let preShow {
        IOSCinemaPreShowView(show: preShow, reduceMotion: reduceMotion)
          .ignoresSafeArea()
          .transition(.opacity)
          .overlay(alignment: .topLeading) {
            Button {
              preShow.stop()
              controller.close()
            } label: {
              Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
            }
            .buttonStyle(.glass).padding(16)
            .accessibilityLabel("Close")
          }
      }
    }
    .animation(.easeInOut(duration: 0.45), value: controller.isStarting)
    .persistentSystemOverlays(controller.controlsVisible ? .automatic : .hidden)
    // The iPad keeps the status bar in every orientation; time and date stay out of the picture.
    .statusBarHidden(true)
    .preferredColorScheme(.dark)
    .sheet(item: $controller.trackMenu) { menu in
      if menu == .notes, let notes {
        IOSSceneNotesSheet(notes: notes, position: controller.position) { target in
          controller.trackMenu = nil
          controller.seek(to: target)
        }
      } else {
        menuSheet(menu)
      }
    }
    .overlay(alignment: .topTrailing) {
      if let notes, preShow == nil, controller.errorMessage == nil {
        IOSSceneNoteCue(notes: notes, position: controller.position)
          .padding(.top, controller.controlsVisible ? 64 : 16).padding(.trailing, 16)
      }
    }
    .task(id: controller.currentMediaID) {
      if notes == nil { notes = controller.makeSceneNotes() }
      await notes?.show(mediaID: controller.currentMediaID)
    }
    .onAppear {
      keyboard = true
      // A party this device is in follows into the player before it starts.
      if !controller.isOffline { model.attachWatchParty(to: controller) }
      configurePreviews()
    }
    .task { await startWithPreShow() }
    .onChange(of: controller.isStarting) { _, starting in
      if !starting { preShow?.filmStarted() }
    }
    .onDisappear {
      preShow?.stop()
      previews.reset()
      model.playerClosed(controller)
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
    .onChange(of: scenePhase) { _, phase in if phase == .background { controller.background() } }
  }

  private var controls: some View {
    ZStack {
      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.55), location: 0),
          .init(color: .clear, location: 0.3),
          .init(color: .clear, location: 0.55),
          .init(color: .black.opacity(0.75), location: 1),
        ], startPoint: .top, endPoint: .bottom
      ).ignoresSafeArea()
        // A tap on the picture hides the controls again.
        .contentShape(Rectangle()).onTapGesture { controller.hideControls() }
        .accessibilityHidden(true)
      VStack(spacing: 0) {
        topBar
        Spacer(minLength: 12)
        if controller.errorMessage == nil { transport }
        Spacer(minLength: 12)
        bottomBar
      }
      .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
    }
    .disabled(controller.isClosing)
  }

  private var topBar: some View {
    HStack(spacing: 10) {
      glassButton("Close", symbol: "xmark", id: "close") { controller.close() }
      Spacer()
      GlassEffectContainer(spacing: 10) {
        HStack(spacing: 10) {
          Button {
            open(.rate)
          } label: {
            Text(rateTitle(controller.playbackRate)).font(.footnote.weight(.semibold))
              .monospacedDigit().padding(.horizontal, 12).frame(height: 36)
          }
          .buttonStyle(.plain)
          .glassEffect(.regular.interactive(), in: Capsule())
          .accessibilityIdentifier("player-rate").accessibilityLabel("Playback Rate")
          glassButton(
            "Audio and Subtitles",
            symbol: controller.selectedSubtitle < 0 ? "captions.bubble" : "captions.bubble.fill",
            id: "audio"
          ) { open(.audio) }
          .disabled(controller.audioTracks.isEmpty && controller.subtitleTracks.isEmpty)
          glassButton(
            "Sleep Timer", symbol: controller.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill",
            id: "sleep"
          ) { open(.sleep) }
          if !controller.chapters.isEmpty {
            glassButton("Chapters", symbol: "list.bullet", id: "chapters") { open(.chapters) }
          }
          if notes != nil {
            glassButton("Scene Notes", symbol: "bookmark", id: "notes") { open(.notes) }
          }
          // Watch Together: start a party for this title, or leave the one this device is in.
          if !controller.isOffline {
            watchTogetherButton
          }
        }
      }
    }
  }

  private var watchTogetherButton: some View {
    glassButton(
      model.watchParty?.state != nil ? "Leave Watch Together" : "Start Watch Together",
      symbol: model.watchParty?.state != nil ? "person.2.fill" : "person.2",
      id: "watch-together"
    ) {
      Task {
        if model.watchParty?.state != nil {
          await model.leaveWatchTogether()
        } else {
          await model.startWatchTogether(with: controller)
        }
      }
    }
  }

  private var transport: some View {
    HStack(spacing: 48) {
      transportButton(
        "Back \(controller.seekInterval / 1_000) Seconds", symbol: skipSymbol("gobackward"),
        size: 26, id: "backward"
      ) { controller.seek(by: -controller.seekInterval) }.disabled(!controller.canSeek)
      Button {
        controller.togglePlayPause()
      } label: {
        Group {
          if controller.isLoading {
            ProgressView().tint(.white).controlSize(.large)
              .accessibilityIdentifier("player-loading")
          } else {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 40, weight: .semibold))
              .contentTransition(.symbolEffect(.replace))
          }
        }
        .frame(width: 64, height: 64).contentShape(Rectangle())
      }
      .buttonStyle(IOSPlayerSymbolStyle())
      .disabled(controller.isLoading).accessibilityIdentifier("player-play")
      .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
      transportButton(
        "Forward \(controller.seekInterval / 1_000) Seconds", symbol: skipSymbol("goforward"),
        size: 26, id: "forward"
      ) { controller.seek(by: controller.seekInterval) }.disabled(!controller.canSeek)
    }
  }

  private var bottomBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(controller.title).font(.subheadline.weight(.semibold)).lineLimit(1)
      if let error = controller.errorMessage {
        Text(error).font(.footnote).foregroundStyle(.secondary)
        HStack(spacing: 10) {
          if controller.canRetry {
            Button("Try Again") { controller.retry() }
          }
          Button("Back to Library") { controller.close() }
        }.buttonStyle(.glass).padding(.top, 4)
      } else {
        timeline
      }
      if controller.audioSelectionPending || controller.subtitleSelectionPending {
        Label(
          controller.audioSelectionPending ? "Switching audio…" : "Switching subtitles…",
          systemImage: "arrow.triangle.2.circlepath"
        ).font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("player-track-pending")
      }
      if let message = controller.progressMessage {
        Text(message).font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("player-progress-status")
      }
    }
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
    VStack(alignment: .leading, spacing: 6) {
      Label(
        "\(indicator.offset > 0 ? "+" : "−")\(abs(indicator.offset) / 1_000) s",
        systemImage: indicator.offset > 0 ? "goforward" : "gobackward"
      ).font(.footnote.weight(.semibold))
      IOSProgressBar(fraction: fraction)
      HStack {
        Text(IOSPlayerPolicy.timeLabel(milliseconds: controller.position))
        Spacer()
        Text(IOSPlayerPolicy.timeLabel(milliseconds: controller.duration))
      }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .frame(maxWidth: 420)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .padding(.horizontal, 16).padding(.bottom, 12)
    .frame(maxHeight: .infinity, alignment: .bottom)
    .accessibilityElement(children: .ignore).accessibilityIdentifier("player-skip")
    .accessibilityValue(
      "\(IOSPlayerPolicy.timeLabel(milliseconds: controller.position)) of \(IOSPlayerPolicy.timeLabel(milliseconds: controller.duration))"
    )
    .allowsHitTesting(false)
  }

  private var timeline: some View {
    VStack(spacing: 6) {
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.25))
          Capsule().fill(.white).frame(width: geometry.size.width * fraction)
          // Where each chapter begins.
          ForEach(
            IOSChapterPolicy.markers(controller.chapters, duration: controller.duration), id: \.self
          ) { marker in
            Rectangle().fill(.black.opacity(0.6)).frame(width: 2, height: 8)
              .offset(x: geometry.size.width * marker - 1)
              .accessibilityHidden(true)
          }
          if controller.scrubPosition != nil {
            // Where playback is now, while the bar shows where lifting the finger would jump.
            Capsule().fill(.white.opacity(0.45))
              .frame(width: 2, height: 12)
              .offset(x: geometry.size.width * playedFraction - 1)
          }
        }
        .frame(height: controller.isScrubbing ? 8 : 4)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
          if let scrub = controller.scrubPosition {
            scrubPreview(at: scrub, width: geometry.size.width)
          }
        }
        // Drag along the bar (or tap a place) to choose a position; lifting jumps there.
        .contentShape(Rectangle())
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
      .frame(height: 24)
      .animation(.easeOut(duration: 0.15), value: controller.isScrubbing)
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
      }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
    .disabled(!controller.canSeek)
    .accessibilityElement(children: .ignore)
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
    let size = CGSize(width: 160, height: 90)
    let center =
      controller.duration > 0 ? width * Double(position) / Double(controller.duration) : 0
    let x = min(max(center - size.width / 2, 0), max(width - size.width, 0))
    return VStack(spacing: 4) {
      ZStack {
        Color.black
        if previews.imageBucket == previews.bucket(for: position), let image = previews.image {
          Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
        } else {
          ProgressView().tint(.white)
        }
      }
      .frame(width: size.width, height: size.height)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
          .white.opacity(0.3), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
      Text(IOSPlayerPolicy.timeLabel(milliseconds: position))
        .font(.footnote.weight(.semibold).monospacedDigit())
    }
    .offset(x: x, y: -22)
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier("player-scrub-preview")
    .accessibilityLabel("Jump to \(IOSPlayerPolicy.timeLabel(milliseconds: position))")
  }

  /// Black with a turning ring until the picture moves; reconnecting still explains itself.
  private var startScreen: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VStack(spacing: 14) {
        IOSStartRing().frame(width: 36, height: 36)
        if let message = controller.progressMessage {
          Text(message).font(.subheadline).foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(controller.progressMessage ?? "Loading")
    .accessibilityIdentifier("player-start-screen")
  }

  /// Cinema mode: the ad and trailers before a film, when it gets them. The film starts behind
  /// the curtain, which opens once its picture moves.
  private func startWithPreShow() async {
    guard
      let show = await controller.cinemaPreShow(
        capabilities: model.capabilities?.capabilities ?? [],
        watchingTogether: model.watchParty != nil),
      !Task.isCancelled
    else {
      controller.start()
      return
    }
    show.onFeature = { [controller] in controller.start() }
    preShow = show
    await show.run()
    controller.start()
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { preShow = nil }
  }

  private var skipIntroButton: some View {
    Button {
      controller.skipIntro()
    } label: {
      Label("Skip Intro", systemImage: "forward.end.fill")
        .font(.headline)
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
    }
    .buttonStyle(.glass)
    .accessibilityHint("Jumps to the end of the intro")
    .accessibilityIdentifier("player-skip-intro")
    .padding(.trailing, 16).padding(.bottom, controller.controlsVisible ? 120 : 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    .animation(.easeOut(duration: 0.2), value: controller.controlsVisible)
  }

  private func upNextCard(_ upNext: IOSUpNext) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("UP NEXT").font(.caption2.weight(.bold)).tracking(1)
        .foregroundStyle(.secondary)
      Text(upNext.title).font(.subheadline.weight(.semibold)).lineLimit(2)
      HStack(spacing: 8) {
        Button {
          controller.playNextNow()
        } label: {
          Label("Play · \(upNext.seconds)", systemImage: "play.fill").monospacedDigit()
        }
        .buttonStyle(.glassProminent).tint(.white).foregroundStyle(.black)
        .accessibilityIdentifier("player-up-next-play")
        Button(upNext.duringCredits ? "Watch Credits" : "Cancel") { controller.dismissUpNext() }
          .buttonStyle(.glass)
          .accessibilityHint(
            upNext.duringCredits
              ? "Keeps playing the credits; the next episode follows at the end"
              : "Stops at the end instead of playing the next episode"
          )
          .accessibilityIdentifier("player-up-next-cancel")
      }
      .font(.footnote.weight(.semibold))
    }
    .padding(14)
    .frame(width: 250, alignment: .leading)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .padding(.trailing, 16).padding(.bottom, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("player-up-next")
  }

  // MARK: Choices

  private func open(_ menu: IOSPlaybackController.TrackMenu) {
    controller.userInteracted()
    controller.trackMenu = menu
  }

  private struct MenuSection {
    let title: String?
    let rows: [MenuRow]
  }

  private struct MenuRow: Identifiable {
    let id: String
    let title: String
    let selected: Bool
    let action: @MainActor () -> Void
  }

  private func sections(_ menu: IOSPlaybackController.TrackMenu) -> [MenuSection] {
    switch menu {
    case .chapters:
      let current = IOSChapterPolicy.current(controller.chapters, position: controller.position)
      return [
        MenuSection(
          title: nil,
          rows: controller.chapters.map { chapter in
            MenuRow(
              id: "chapter-\(chapter.index)",
              title:
                "\(chapter.title)  ·  \(IOSPlayerPolicy.timeLabel(milliseconds: chapter.timeOffsetMilliseconds))",
              selected: current == chapter
            ) { controller.selectChapter(chapter) }
          })
      ]
    case .notes:
      return []
    case .audio:
      var result: [MenuSection] = []
      if !controller.audioTracks.isEmpty {
        result.append(
          MenuSection(
            title: "Audio",
            rows: controller.audioTracks.map { track in
              MenuRow(
                id: "audio-\(track.id)", title: track.title,
                selected: controller.selectedAudio == track.id
              ) { controller.selectAudio(track.id) }
            }))
      }
      result.append(
        MenuSection(
          title: "Subtitles",
          rows: [
            MenuRow(id: "subtitle--1", title: "Off", selected: controller.selectedSubtitle < 0) {
              controller.selectSubtitle(-1)
            }
          ]
            + controller.subtitleTracks.map { track in
              MenuRow(
                id: "subtitle-\(track.id)", title: track.title,
                selected: controller.selectedSubtitle == track.id
              ) { controller.selectSubtitle(track.id) }
            }))
      result.append(
        MenuSection(
          title: "Dialogue Boost",
          rows: DialogueBoost.allCases.map { mode in
            MenuRow(
              id: "dialogue-\(mode.rawValue)", title: mode.title,
              selected: controller.dialogueBoost == mode
            ) {
              controller.setDialogueBoost(mode)
            }
          }))
      result.append(
        MenuSection(
          title: "Volume Leveling",
          rows: VolumeLeveling.allCases.map { mode in
            MenuRow(
              id: "leveling-\(mode.rawValue)", title: mode.title,
              selected: controller.volumeLeveling == mode
            ) {
              controller.setVolumeLeveling(mode)
            }
          }))
      return result
    case .rate:
      return [
        MenuSection(
          title: nil,
          rows: IOSPlaybackPreferences.supportedRates.map { rate in
            MenuRow(
              id: "rate-\(rate)", title: rate == 1 ? "Normal" : rateTitle(rate),
              selected: controller.playbackRate == rate
            ) { controller.setPlaybackRate(rate) }
          })
      ]
    case .sleep:
      return [
        MenuSection(
          title: nil,
          rows: [0, -1, 15, 30, 45, 60, 90].map { value in
            let timer: IOSSleepTimer =
              value == 0 ? .off : value == -1 ? .endOfEpisode : .minutes(value)
            return MenuRow(
              id: "sleep-\(value)", title: timer.title, selected: controller.sleepTimer == timer
            ) { controller.setSleepTimer(timer) }
          })
      ]
    }
  }

  /// A short sheet with checkmarks, sized to its rows up to a scrolling limit. While it is open
  /// the controller keeps the controls shown.
  private func menuSheet(_ menu: IOSPlaybackController.TrackMenu) -> some View {
    let sections = sections(menu)
    let rows = sections.reduce(0) { $0 + $1.rows.count }
    let height = min(
      CGFloat(rows) * 44 + CGFloat(sections.filter { $0.title != nil }.count) * 34 + 72, 520)
    return VStack(spacing: 0) {
      HStack {
        Text(menuTitle(menu)).font(.headline)
        Spacer()
        Button {
          controller.trackMenu = nil
        } label: {
          Image(systemName: "xmark").font(.footnote.weight(.bold))
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle)
        .accessibilityLabel("Done").accessibilityIdentifier("player-tracks-done")
      }
      .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 2)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            if let title = section.title {
              Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).frame(height: 34, alignment: .bottomLeading)
            }
            ForEach(section.rows) { row in
              Button {
                row.action()
              } label: {
                HStack(spacing: 10) {
                  Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                    .opacity(row.selected ? 1 : 0).frame(width: 16)
                  Text(row.title).lineLimit(1).truncationMode(.middle)
                  Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).frame(height: 44).contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("player-option-\(row.id)")
              .accessibilityAddTraits(row.selected ? .isSelected : [])
            }
            if index < sections.count - 1 { Divider().padding(.top, 4) }
          }
        }
        .padding(.bottom, 8)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .presentationDetents([.height(height)])
    .presentationDragIndicator(.hidden)
    .accessibilityIdentifier("player-tracks")
  }

  private func menuTitle(_ menu: IOSPlaybackController.TrackMenu) -> String {
    switch menu {
    case .audio: "Audio and Subtitles"
    case .rate: "Playback Speed"
    case .sleep: "Sleep Timer"
    case .chapters: "Chapters"
    case .notes: "Scene Notes"
    }
  }

  private func rateTitle(_ rate: Double) -> String { String(format: "%gx", rate) }
  /// The skip arrows show their seconds where SF Symbols has that number.
  private func skipSymbol(_ base: String) -> String {
    let seconds = controller.seekInterval / 1_000
    return [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
  }

  private func glassButton(
    _ title: String, symbol: String, id: String, action: @escaping () -> Void
  ) -> some View {
    Button {
      controller.userInteracted()
      action()
    } label: {
      Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
        .frame(width: 36, height: 36).contentShape(Circle())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: Circle())
    .accessibilityLabel(title).accessibilityIdentifier("player-\(id)")
  }

  private func transportButton(
    _ title: String, symbol: String, size: CGFloat, id: String, action: @escaping () -> Void
  ) -> some View {
    Button {
      controller.userInteracted()
      action()
    } label: {
      Image(systemName: symbol).font(.system(size: size, weight: .medium))
        .frame(width: 52, height: 52).contentShape(Rectangle())
    }
    .buttonStyle(IOSPlayerSymbolStyle())
    .accessibilityLabel(title).accessibilityIdentifier("player-\(id)")
  }
}

/// White symbols with a soft shadow that read over any picture; pressing dims them briefly.
extension IOSPlaybackController.TrackMenu: Identifiable {
  var id: Self { self }
}

private struct IOSPlayerSymbolStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.foregroundStyle(.white)
      .shadow(color: .black.opacity(0.35), radius: 8)
      .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
      .scaleEffect(configuration.isPressed ? 0.9 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
        Circle().stroke(.white.opacity(0.12), lineWidth: 4)
        Circle()
          .trim(from: 0, to: length)
          .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
          .rotationEffect(.degrees(rotation - 90))
      }
    }
  }
}

/// A short notice at the top of the picture when someone in the party acts, such as "Mia paused".
private struct IOSWatchTogetherNotice: View {
  @ObservedObject var session: IOSWatchTogetherSession

  var body: some View {
    let text =
      session.notice ?? (session.state?.isWaiting == true ? "Waiting until everyone is ready…" : nil)
    VStack {
      if let text {
        Label(text, systemImage: "person.2.fill")
          .font(.subheadline.weight(.semibold))
          .padding(.horizontal, 16).padding(.vertical, 9)
          .glassEffect(.regular, in: Capsule())
          .transition(.opacity)
          .accessibilityIdentifier("watch-together-notice")
      }
      Spacer()
    }
    .padding(.top, 64)
    .animation(.easeInOut(duration: 0.3), value: text)
    .allowsHitTesting(false)
  }
}

/// A note's text at its moment, top right, while the title plays on.
private struct IOSSceneNoteCue: View {
  @ObservedObject var notes: IOSSceneNotesModel
  let position: Int64

  var body: some View {
    if let note = notes.cue(at: position) {
      Text(note.text).font(.callout).lineLimit(6).padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityIdentifier("scene-note-cue")
        .transition(.opacity)
    }
  }
}

/// Scene notes of this title: tap one to jump there, add one at the current moment or as a range
/// from it, edit the text, swipe to delete.
private struct IOSSceneNotesSheet: View {
  @ObservedObject var notes: IOSSceneNotesModel
  let position: Int64
  let jump: (Int64) -> Void
  @State private var draft = ""
  @State private var range = false
  @State private var rangeSeconds = 30
  @State private var editing: IOSSceneNote?
  @State private var editText = ""

  var body: some View {
    NavigationStack {
      List {
        Section {
          TextField("Note at \(IOSPlayerPolicy.timeLabel(milliseconds: position))", text: $draft, axis: .vertical)
            .lineLimit(1...4)
            .accessibilityIdentifier("scene-note-text")
          Toggle("Time Range", isOn: $range)
          if range {
            Stepper("Lasts \(rangeSeconds) seconds", value: $rangeSeconds, in: 5...600, step: 5)
          }
          Button("Add Note") {
            let end = range ? position + Int64(rangeSeconds) * 1_000 : nil
            Task { if await notes.add(text: draft, start: position, end: end) { draft = "" } }
          }
          .disabled(IOSSceneNotePolicy.cleaned(draft) == nil || notes.working)
          .accessibilityIdentifier("scene-note-add")
        } footer: {
          Text("Notes are private to your profile. A moment shows for six seconds, a range for as long as it lasts.")
        }
        Section {
          if notes.sorted.isEmpty {
            Text("No notes yet.").foregroundStyle(.secondary)
          }
          ForEach(notes.sorted) { note in
            Button {
              jump(note.startMilliseconds)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(IOSSceneNotePolicy.label(note)).font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
                Text(note.text).foregroundStyle(.primary).lineLimit(4)
              }
            }
            .swipeActions {
              Button("Delete", role: .destructive) { Task { await notes.delete(note) } }
              Button("Edit") {
                editText = note.text
                editing = note
              }
            }
            .accessibilityHint("Jumps to this note. Swipe to edit or delete.")
          }
        } footer: {
          if let message = notes.message { Text(message).foregroundStyle(.orange) }
        }
      }
      .navigationTitle("Scene Notes")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Reload") { Task { await notes.reload() } }
        }
      }
      .alert(
        "Edit Note",
        isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
      ) {
        TextField("Note", text: $editText)
        Button("Cancel", role: .cancel) { editing = nil }
        Button("Save") {
          if let note = editing { Task { _ = await notes.update(note, text: editText) } }
          editing = nil
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}
