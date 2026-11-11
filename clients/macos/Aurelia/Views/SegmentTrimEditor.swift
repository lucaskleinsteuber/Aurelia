import AppKit
import SwiftUI

/// Which part of an episode the trim editor sets.
enum SegmentTrimPart: String, Identifiable, Sendable {
  case intro, credits

  var id: String { rawValue }

  var title: String { self == .intro ? "Intro" : "Credits" }
}

/// Pure rules of the trim editor: the stretch of the episode its film strip shows and how a
/// handle may move. Times are milliseconds.
enum SegmentTrimRange {
  /// The intro is looked for in the first 12 minutes (at most 40 %); the credits in the last ten.
  static func span(part: SegmentTrimPart, duration: Int64, start: Int64?, end: Int64?) -> ClosedRange<Int64> {
    guard duration > 0 else { return 0...1 }
    switch part {
    case .intro:
      let window = min(720_000, duration * 2 / 5)
      let upper = min(duration, max(window, (end ?? 0) + 60_000))
      return 0...max(upper, 1)
    case .credits:
      let lower = max(0, min(duration - 600_000, (start ?? duration) - 60_000))
      return lower...duration
    }
  }

  /// Where a new intro or credits begins when none is known yet.
  static func initial(part: SegmentTrimPart, span: ClosedRange<Int64>) -> (start: Int64, end: Int64) {
    switch part {
    case .intro: (span.lowerBound, min(span.upperBound, span.lowerBound + 30_000))
    case .credits: (max(span.lowerBound, span.upperBound - 60_000), span.upperBound)
    }
  }

  /// Keeps the start at least a second before the end and both inside the strip.
  static func clamp(start: Int64, end: Int64, span: ClosedRange<Int64>) -> (start: Int64, end: Int64) {
    let end = min(max(end, span.lowerBound + 1_000), span.upperBound)
    let start = min(max(start, span.lowerBound), end - 1_000)
    return (start, end)
  }

  /// "4:15.3"
  static func label(_ milliseconds: Int64) -> String {
    let tenths = max(0, milliseconds) / 100
    let seconds = tenths / 10
    let base =
      seconds >= 3_600
      ? String(format: "%lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
      : String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    return base + ".\(tenths % 10)"
  }
}

/// Plays the episode inside the trim editor: its own ticket, relay and engine, like the cinema
/// pre-show's trailers, so nothing here changes the episode's progress.
@MainActor
final class SegmentTrimPlayer: ObservableObject {
  @Published private(set) var ready = false
  @Published private(set) var failed = false
  @Published private(set) var isPlaying = false
  @Published private(set) var position: Int64 = 0
  @Published private(set) var duration: Int64 = 0
  @Published var isMuted = false { didSet { engine.isMuted = isMuted } }

  let engine = VLCPlaybackEngine()
  private let profile: StoredServerProfile
  private let mediaId: UUID
  private var relay: LoopbackStreamRelay?
  private var ticket: UUID?
  /// Playing stops here and returns to `loopStart`, so the selection plays as a loop.
  private var stopAt: Int64?
  private var loopStart: Int64 = 0

  init(profile: StoredServerProfile, mediaId: UUID) {
    self.profile = profile
    self.mediaId = mediaId
    engine.profileScope = profile.user?.id ?? profile.serverId
  }

  func open(at milliseconds: Int64) async {
    let api = APIClient(profile: profile)
    do {
      let source = try await api.createPlayback(mediaId: mediaId)
      ticket = source.id
      let relay = try LoopbackStreamRelay(
        sourceURL: try api.streamURL(path: source.streamPath),
        publicKeyFingerprint: profile.publicKeyFingerprint, authorizationToken: profile.token)
      self.relay = relay
      let local = try await relay.start()
      engine.onUpdate = { [weak self] in self?.update() }
      engine.onEnded = { [weak self] in self?.isPlaying = false }
      engine.onError = { [weak self] _ in self?.failed = true }
      engine.isMuted = isMuted
      engine.load(url: local, startAt: milliseconds)
      // Start briefly so the engine shows the picture and knows the length, then hold still.
      engine.play()
      for _ in 0..<100 where engine.durationMilliseconds <= 0 {
        try await Task.sleep(for: .milliseconds(100))
      }
      engine.pause()
      if !engine.opensAtStartPosition { engine.seek(to: milliseconds) }
      duration = engine.durationMilliseconds
      position = milliseconds
      ready = duration > 0
      failed = duration <= 0
    } catch {
      failed = true
    }
  }

  /// Plays from `start` until `end`, then starts over there.
  func play(from start: Int64, to end: Int64) {
    loopStart = start
    stopAt = end
    if position < start || position >= end - 250 { seek(to: start) }
    engine.play()
    isPlaying = true
  }

  func pause() {
    engine.pause()
    isPlaying = false
  }

  func seek(to milliseconds: Int64) {
    position = milliseconds
    engine.seek(to: milliseconds)
  }

  func close() {
    engine.onUpdate = nil
    engine.onEnded = nil
    engine.onError = nil
    engine.stop()
    relay?.stop()
    relay = nil
    if let ticket {
      let api = APIClient(profile: profile)
      Task { try? await api.revokePlayback(id: ticket) }
    }
    ticket = nil
  }

  private func update() {
    guard isPlaying else { return }
    let now = engine.currentTimeMilliseconds
    position = now
    if let stopAt, now >= stopAt {
      engine.seek(to: loopStart)
      position = loopStart
    }
  }
}

/// Sets an episode's intro or credits by eye: the picture, a film strip with a yellow selection
/// whose handles mark where the part begins and ends, a play button and a mute button.
struct SegmentTrimEditor: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let mediaId: UUID
  let part: SegmentTrimPart
  let times: MediaSegmentTimes
  let onSave: (MediaSegmentTimes) -> Void

  @StateObject private var player: SegmentTrimPlayer
  @State private var start: Int64 = 0
  @State private var end: Int64 = 0
  @State private var span: ClosedRange<Int64> = 0...1
  @State private var thumbnails: [Int: NSImage] = [:]
  @State private var saving = false
  @State private var errorText: String?

  private static let frames = 14

  init(
    profile: StoredServerProfile, mediaId: UUID, part: SegmentTrimPart, times: MediaSegmentTimes,
    onSave: @escaping (MediaSegmentTimes) -> Void
  ) {
    self.mediaId = mediaId
    self.part = part
    self.times = times
    self.onSave = onSave
    _player = StateObject(wrappedValue: SegmentTrimPlayer(profile: profile, mediaId: mediaId))
  }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        Color.black
        SegmentTrimVideo(engine: player.engine)
        if !player.ready {
          if player.failed {
            Label("The episode can't be played right now.", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
          } else {
            ProgressView().controlSize(.large)
          }
        }
      }
      .frame(minHeight: 320)
      .accessibilityLabel("Picture at \(SegmentTrimRange.label(player.position))")

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          Button {
            player.isMuted.toggle()
          } label: {
            Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
              .frame(width: 22, height: 22)
          }
          .help(player.isMuted ? "Turns the sound back on." : "Plays the selection without sound.")
          .accessibilityLabel(player.isMuted ? "Sound On" : "Mute")
          .accessibilityIdentifier("trim-mute")

          Button {
            if player.isPlaying { player.pause() } else { player.play(from: start, to: end) }
          } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 22, height: 22)
          }
          .keyboardShortcut(.space, modifiers: [])
          .help(
            player.isPlaying
              ? "Pauses (Space)."
              : "Plays the yellow selection from its start; at its end it starts over (Space).")
          .accessibilityLabel(player.isPlaying ? "Pause" : "Play Selection")
          .accessibilityIdentifier("trim-play")

          SegmentTrimStrip(
            span: span, start: $start, end: $end, position: player.position,
            lockedEnd: part == .credits, thumbnails: thumbnails, frames: Self.frames,
            onMove: { time in
              player.pause()
              player.seek(to: time)
            })
          .frame(height: 56)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!player.ready)

        HStack(spacing: 18) {
          nudge("Starts", value: start, identifier: "trim-start") { start = clamped(start: $0, end: end).start }
          if part == .intro {
            nudge("Ends", value: end, identifier: "trim-end") { end = clamped(start: start, end: $0).end }
          } else {
            Text("Credits run to the end of the episode.").font(.callout).foregroundStyle(.secondary)
          }
          Spacer()
          Text("Length \(SegmentTrimRange.label(end - start))")
            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        Text(
          part == .intro
            ? "Drag the yellow handles to where the intro begins and ends; the picture shows the frame under the handle. Click the strip to look at any moment."
            : "Drag the left handle to where the credits begin; Up Next appears there. Click the strip to look at any moment."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let errorText {
          Label(errorText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        }
      }
      .padding(16)

      Divider()
      HStack {
        Button(part == .intro ? "No Intro" : "No Credits", role: .destructive) { Task { await save(remove: true) } }
          .help(
            part == .intro
              ? "Saves that this episode has no intro, so Skip Intro never appears in it."
              : "Saves that this episode has no credits, so Up Next appears only in its last seconds.")
          .accessibilityIdentifier("trim-remove")
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .help("Closes without changing anything.")
        Button("Save \(part.title)") { Task { await save(remove: false) } }
          .buttonStyle(AureliaPrimaryActionButtonStyle())
          .keyboardShortcut(.defaultAction)
          .help("Saves the yellow selection as this episode's \(part.title.lowercased()). Detection never replaces it.")
          .disabled(!player.ready || saving)
          .accessibilityIdentifier("trim-save")
      }
      .padding(16)
    }
    .frame(minWidth: 760, idealWidth: 900, minHeight: 600)
    .background(AureliaBackdrop())
    .task { await prepare() }
    .onDisappear { player.close() }
    .onChange(of: start) { _, value in if !player.isPlaying { player.seek(to: value) } }
    .onChange(of: end) { _, value in if !player.isPlaying, part == .intro { player.seek(to: value) } }
    .accessibilityIdentifier("trim-editor-\(part.rawValue)")
  }

  /// A time with buttons that move it by a tenth of a second.
  private func nudge(_ title: String, value: Int64, identifier: String, set: @escaping (Int64) -> Void) -> some View {
    HStack(spacing: 6) {
      Text(title).font(.callout)
      Button { set(value - 100) } label: { Image(systemName: "chevron.left") }
        .help("Moves it a tenth of a second earlier.")
        .accessibilityLabel("\(title) Earlier")
      Text(SegmentTrimRange.label(value)).font(.callout.monospacedDigit()).frame(minWidth: 64)
        .accessibilityIdentifier(identifier)
      Button { set(value + 100) } label: { Image(systemName: "chevron.right") }
        .help("Moves it a tenth of a second later.")
        .accessibilityLabel("\(title) Later")
    }
    .buttonStyle(.borderless)
  }

  private func clamped(start: Int64, end: Int64) -> (start: Int64, end: Int64) {
    SegmentTrimRange.clamp(start: start, end: end, span: span)
  }

  private func prepare() async {
    let known: (Int64?, Int64?) =
      part == .intro
      ? (times.introStartMilliseconds, times.introEndMilliseconds)
      : (times.creditsStartMilliseconds, nil)
    await player.open(at: known.0 ?? (part == .intro ? 0 : 0))
    guard player.ready else { return }
    let duration = player.duration
    span = SegmentTrimRange.span(part: part, duration: duration, start: known.0, end: known.1)
    let initial = SegmentTrimRange.initial(part: part, span: span)
    let chosen = clamped(
      start: known.0 ?? initial.start,
      end: part == .credits ? span.upperBound : (known.1 ?? initial.end))
    start = chosen.start
    end = chosen.end
    player.seek(to: start)
    await loadThumbnails()
  }

  /// Small pictures along the strip from the server's timeline previews.
  private func loadThumbnails() async {
    guard let profile = model.profile else { return }
    let client = APIClient(profile: profile)
    let span = span
    let step = Double(span.upperBound - span.lowerBound) / Double(Self.frames)
    await withTaskGroup(of: (Int, Data?).self) { group in
      for index in 0..<Self.frames {
        let seconds = Int((Double(span.lowerBound) + step * (Double(index) + 0.5)) / 1_000)
        group.addTask { (index, try? await client.scrubPreviewFrame(mediaId: mediaId, seconds: seconds)) }
      }
      for await (index, data) in group {
        if let data, let image = NSImage(data: data) { thumbnails[index] = image }
      }
    }
  }

  private func save(remove: Bool) async {
    guard let profile = model.profile else { return }
    saving = true
    defer { saving = false }
    var request = SetMediaSegmentsRequest(
      introStartMilliseconds: times.introStartMilliseconds, introEndMilliseconds: times.introEndMilliseconds,
      creditsStartMilliseconds: times.creditsStartMilliseconds)
    switch part {
    case .intro:
      request.introStartMilliseconds = remove ? nil : start
      request.introEndMilliseconds = remove ? nil : end
    case .credits:
      request.creditsStartMilliseconds = remove ? nil : start
    }
    do {
      let saved = try await APIClient(profile: profile).saveMediaSegments(mediaId: mediaId, request)
      onSave(saved)
      dismiss()
    } catch {
      errorText = error.localizedDescription
    }
  }
}

/// The film strip with the yellow selection, its two handles and the white playhead.
private struct SegmentTrimStrip: View {
  let span: ClosedRange<Int64>
  @Binding var start: Int64
  @Binding var end: Int64
  let position: Int64
  let lockedEnd: Bool
  let thumbnails: [Int: NSImage]
  let frames: Int
  let onMove: (Int64) -> Void

  private let handle: CGFloat = 16

  var body: some View {
    GeometryReader { geometry in
      let width = max(1, geometry.size.width - handle * 2)
      let x = { (time: Int64) -> CGFloat in
        handle + CGFloat(Double(time - span.lowerBound) / Double(max(1, span.upperBound - span.lowerBound))) * width
      }
      let time = { (point: CGFloat) -> Int64 in
        let share = min(max(0, (point - handle) / width), 1)
        return span.lowerBound + Int64(Double(share) * Double(span.upperBound - span.lowerBound))
      }
      ZStack(alignment: .leading) {
        HStack(spacing: 0) {
          ForEach(0..<frames, id: \.self) { index in
            Group {
              if let image = thumbnails[index] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
              } else {
                Color.gray.opacity(0.25)
              }
            }
            .frame(width: width / CGFloat(frames), height: geometry.size.height - 12)
            .clipped()
          }
        }
        .padding(.horizontal, handle)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { onMove(time($0.location.x)) })

        // Outside the selection is dimmed.
        Color.black.opacity(0.45).frame(width: max(0, x(start) - handle)).offset(x: handle)
          .allowsHitTesting(false)
        Color.black.opacity(0.45).frame(width: max(0, x(span.upperBound) - x(end))).offset(x: x(end))
          .allowsHitTesting(false)

        RoundedRectangle(cornerRadius: 6)
          .stroke(Color.yellow, lineWidth: 4)
          .frame(width: max(2, x(end) - x(start) + handle * 2), height: geometry.size.height - 6)
          .offset(x: x(start) - handle)
          .allowsHitTesting(false)

        Rectangle().fill(Color.white).frame(width: 2, height: geometry.size.height)
          .offset(x: x(position) - 1)
          .allowsHitTesting(false)

        handleView(edge: .leading)
          .offset(x: x(start) - handle)
          .gesture(
            DragGesture().onChanged { value in
              start = SegmentTrimRange.clamp(start: time(value.location.x + handle / 2), end: end, span: span).start
            })
          .accessibilityLabel("Start")
          .accessibilityValue(SegmentTrimRange.label(start))
          .accessibilityAdjustableAction { direction in
            let step: Int64 = direction == .increment ? 500 : -500
            start = SegmentTrimRange.clamp(start: start + step, end: end, span: span).start
          }
        if !lockedEnd {
          handleView(edge: .trailing)
            .offset(x: x(end))
            .gesture(
              DragGesture().onChanged { value in
                end = SegmentTrimRange.clamp(start: start, end: time(value.location.x - handle / 2), span: span).end
              })
            .accessibilityLabel("End")
            .accessibilityValue(SegmentTrimRange.label(end))
            .accessibilityAdjustableAction { direction in
              let step: Int64 = direction == .increment ? 500 : -500
              end = SegmentTrimRange.clamp(start: start, end: end + step, span: span).end
            }
        }
      }
      .frame(maxHeight: .infinity)
    }
    .accessibilityElement(children: .contain)
    .help("Drag the yellow handles; click anywhere to show that moment.")
  }

  private func handleView(edge: HorizontalEdge) -> some View {
    RoundedRectangle(cornerRadius: 5)
      .fill(Color.yellow)
      .frame(width: handle)
      .overlay(
        Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
          .font(.system(size: 14, weight: .bold)).foregroundStyle(.black))
      .contentShape(Rectangle())
  }
}

private struct SegmentTrimVideo: NSViewRepresentable {
  let engine: VLCPlaybackEngine

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    engine.attach(to: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}
