import SwiftUI
import UIKit

/// A title's intro and credits times in the editor (media-segments-v2): what the server found, a
/// trim editor over pictures of the title to correct them, and Look Again.
struct IOSTitleSegmentsView: View {
  @EnvironmentObject private var model: IOSAppModel
  let mediaID: UUID
  @ObservedObject var admin: IOSAdministrationModel

  @State private var segments: IOSMediaSegmentsDetail?
  @State private var duration: Int64 = 0
  @State private var editing: IOSSegmentPart?
  @State private var error: String?
  @State private var working = false

  var body: some View {
    Form {
      if let segments {
        Section {
          row(
            "Intro",
            value: segments.introStartMilliseconds.flatMap { start in
              segments.introEndMilliseconds.map {
                "\(IOSSegmentTrim.label(start)) – \(IOSSegmentTrim.label($0))"
              }
            }, source: segments.introSource)
          row(
            "Credits",
            value: segments.creditsStartMilliseconds.map { "from \(IOSSegmentTrim.label($0))" },
            source: segments.creditsSource)
        } footer: {
          if !segments.analyzed, segments.canAnalyze {
            Text("The server has not examined this title yet. It does so in the background.")
          }
        }
        Section {
          Button("Adjust Intro…", systemImage: "slider.horizontal.below.rectangle") {
            editing = .intro
          }
          .disabled(duration <= 0)
          .accessibilityIdentifier("segments-intro")
          Button("Adjust Credits…", systemImage: "slider.horizontal.below.rectangle") {
            editing = .credits
          }
          .disabled(duration <= 0)
          .accessibilityIdentifier("segments-credits")
          if segments.introSource == "manual" || segments.creditsSource == "manual" {
            Button("Use the Server's Times", systemImage: "arrow.uturn.backward") {
              Task { await change { try await $0.clearMediaSegments(id: mediaID) } }
            }
          }
          if segments.canAnalyze {
            Button("Look Again", systemImage: "arrow.clockwise") {
              Task { await reanalyze() }
            }
          }
        } footer: {
          Text(
            "Corrections apply on every device, for Skip Intro and Up Next. Only the times are stored."
          )
        }
      } else if error == nil {
        ProgressView().frame(maxWidth: .infinity)
      }
      if let error {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Intro and Credits")
    .disabled(working)
    .task { await load() }
    .sheet(item: $editing) { part in
      if let segments {
        IOSSegmentTrimSheet(
          mediaID: mediaID, part: part, duration: duration,
          start: part == .intro
            ? segments.introStartMilliseconds : segments.creditsStartMilliseconds,
          end: part == .intro ? segments.introEndMilliseconds : duration
        ) { start, end in
          let request =
            part == .intro
            ? IOSSetMediaSegmentsRequest(
              introStartMilliseconds: start, introEndMilliseconds: end,
              creditsStartMilliseconds: segments.creditsStartMilliseconds)
            : IOSSetMediaSegmentsRequest(
              introStartMilliseconds: segments.introStartMilliseconds,
              introEndMilliseconds: segments.introEndMilliseconds, creditsStartMilliseconds: start)
          Task { await change { try await $0.setMediaSegments(id: mediaID, request) } }
        }
      }
    }
  }

  private func row(_ label: String, value: String?, source: String) -> some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: 2) {
        Text(value ?? "None").monospacedDigit()
        Text(IOSMediaSegmentsDetail.sourceText(source)).font(.footnote).foregroundStyle(.secondary)
      }
    } label: {
      Text(label)
    }
  }

  private func load() async {
    let id = mediaID
    do {
      segments = try await admin.run { try await $0.mediaSegments(id: id) }
      if duration <= 0 {
        duration = (try? await admin.run { try await $0.mediaDuration(id: id) }) ?? 0
      }
      error = duration > 0 ? nil : "The title's length is unknown, so its times can't be adjusted."
    } catch is CancellationError {
    } catch {
      self.error = IOSAdministrationModel.message(error)
    }
  }

  private func change(
    _ work: @escaping @Sendable (IOSAPIClient) async throws -> IOSMediaSegmentsDetail
  ) async {
    working = true
    defer { working = false }
    do {
      segments = try await admin.run(work)
      error = nil
    } catch is CancellationError {
    } catch {
      self.error = IOSAdministrationModel.message(error)
    }
  }

  private func reanalyze() async {
    working = true
    defer { working = false }
    let id = mediaID
    do {
      try await admin.run { try await $0.reanalyzeMediaSegments(id: id) }
      segments = try? await admin.run { try await $0.mediaSegments(id: id) }
      error = nil
    } catch is CancellationError {
    } catch {
      self.error = IOSAdministrationModel.message(error)
    }
  }
}

/// Sets where the intro starts and ends, or where the credits start, over a strip of pictures from
/// the server (scrub previews). Nothing plays; drag the handles or nudge them a second at a time.
private struct IOSSegmentTrimSheet: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss
  let mediaID: UUID
  let part: IOSSegmentPart
  let duration: Int64
  let save: (Int64, Int64) -> Void

  @State private var start: Int64
  @State private var end: Int64
  @State private var frames: [Int: UIImage] = [:]
  private let span: ClosedRange<Int64>
  private static let frameCount = 10

  init(
    mediaID: UUID, part: IOSSegmentPart, duration: Int64, start: Int64?, end: Int64?,
    save: @escaping (Int64, Int64) -> Void
  ) {
    self.mediaID = mediaID
    self.part = part
    self.duration = duration
    self.save = save
    let span = IOSSegmentTrim.span(part: part, duration: duration, start: start, end: end)
    self.span = span
    let initial = IOSSegmentTrim.initial(part: part, span: span)
    let clamped = IOSSegmentTrim.clamp(
      start: start ?? initial.start, end: end ?? initial.end, span: span)
    _start = State(initialValue: clamped.start)
    _end = State(initialValue: part == .credits ? duration : clamped.end)
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 22) {
        strip
        handle(part == .intro ? "Intro Starts" : "Credits Start", value: $start, isStart: true)
        if part == .intro {
          handle("Intro Ends", value: $end, isStart: false)
        }
        Text(
          part == .intro
            ? "Skip Intro jumps from the start to the end."
            : "Up Next appears when the credits start."
        )
        .font(.footnote).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(20)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .navigationTitle("Adjust \(part.title)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            save(start, end)
            dismiss()
          }
          .accessibilityIdentifier("trim-save")
        }
      }
      .task { await loadFrames() }
    }
  }

  private var strip: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let length = Double(span.upperBound - span.lowerBound)
      let x = { (value: Int64) in CGFloat(Double(value - span.lowerBound) / length) * width }
      ZStack(alignment: .leading) {
        HStack(spacing: 1) {
          ForEach(IOSSegmentTrim.frames(in: span, count: Self.frameCount), id: \.self) { second in
            Group {
              if let image = frames[second] {
                Image(uiImage: image).resizable().scaledToFill()
              } else {
                Rectangle().fill(IOSDesign.raised)
              }
            }
            .frame(width: (width - CGFloat(Self.frameCount - 1)) / CGFloat(Self.frameCount))
            .clipped()
          }
        }
        Rectangle().fill(Color.accentColor.opacity(0.35))
          .frame(width: max(2, x(part == .intro ? end : span.upperBound) - x(start)))
          .offset(x: x(start))
        Rectangle().fill(.white).frame(width: 3).offset(x: x(start) - 1.5)
        if part == .intro {
          Rectangle().fill(.white).frame(width: 3).offset(x: x(end) - 1.5)
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { drag in
          let value =
            span.lowerBound + Int64(Double(min(max(drag.location.x, 0), width) / width) * length)
          // The nearer handle follows the finger.
          if part == .intro, abs(value - end) < abs(value - start) {
            end = IOSSegmentTrim.clamp(start: start, end: value, span: span).end
          } else {
            start = IOSSegmentTrim.clamp(start: value, end: end, span: span).start
          }
        }
      )
    }
    .frame(height: 64)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityHidden(true)
  }

  private func handle(_ label: String, value: Binding<Int64>, isStart: Bool) -> some View {
    HStack {
      Text(label)
      Spacer()
      Button {
        nudge(value, by: -1_000, isStart: isStart)
      } label: {
        Image(systemName: "minus").frame(width: 36, height: 36)
      }
      .buttonStyle(IOSButtonStyle(kind: .icon))
      .accessibilityLabel("\(label) one second earlier")
      Text(IOSSegmentTrim.label(value.wrappedValue)).monospacedDigit().frame(minWidth: 72)
      Button {
        nudge(value, by: 1_000, isStart: isStart)
      } label: {
        Image(systemName: "plus").frame(width: 36, height: 36)
      }
      .buttonStyle(IOSButtonStyle(kind: .icon))
      .accessibilityLabel("\(label) one second later")
    }
  }

  private func nudge(_ value: Binding<Int64>, by offset: Int64, isStart: Bool) {
    let clamped =
      isStart
      ? IOSSegmentTrim.clamp(start: start + offset, end: end, span: span)
      : IOSSegmentTrim.clamp(start: start, end: end + offset, span: span)
    start = clamped.start
    end = part == .credits ? duration : clamped.end
  }

  private func loadFrames() async {
    guard let client = model.client else { return }
    for second in IOSSegmentTrim.frames(in: span, count: Self.frameCount) {
      guard !Task.isCancelled else { return }
      if let data = try? await client.scrubPreviewFrame(mediaID: mediaID, seconds: second),
        let image = UIImage(data: data)
      {
        frames[second] = image
      }
    }
  }
}
