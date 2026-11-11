import SwiftUI

/// Entering and showing intro and credits times as minutes:seconds.
enum MediaSegmentTimeText {
  static func text(_ milliseconds: Int64?) -> String {
    milliseconds.map { SceneNoteTime.format(($0 / 1_000) * 1_000) } ?? ""
  }

  /// An empty field means "none"; anything else must be a time like 1:24 or 1:02:30.
  static func parse(_ text: String) -> Int64?? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .some(nil) }
    return SceneNoteTime.parse(trimmed).map { .some($0) }
  }

  /// The request for the three fields, or nil when one of them is not a time. An intro without a
  /// start begins at the very beginning.
  static func request(introStart: String, introEnd: String, creditsStart: String)
    -> SetMediaSegmentsRequest?
  {
    guard let start = parse(introStart), let end = parse(introEnd),
      let credits = parse(creditsStart)
    else { return nil }
    return SetMediaSegmentsRequest(
      introStartMilliseconds: end == nil ? nil : (start ?? 0), introEndMilliseconds: end,
      creditsStartMilliseconds: credits)
  }

  static func origin(_ source: MediaSegmentSource, confidence: Double) -> String {
    switch source {
    case .detected: "Detected (\(Int((confidence * 100).rounded())) % sure)"
    default: source.title
    }
  }
}

/// Edit Metadata › Intro and Credits: the times the server found for an episode, corrections by
/// hand, and a new analysis of the season. For a series it only offers the new analysis.
struct MediaSegmentsPanel: View {
  @EnvironmentObject private var model: AppModel
  let mediaId: UUID
  let isSeries: Bool
  @State private var times: MediaSegmentTimes?
  @State private var introStart = ""
  @State private var introEnd = ""
  @State private var creditsStart = ""
  @State private var working = false
  @State private var message: String?
  @State private var errorText: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if isSeries {
        Text(
          "The server compares the sound of a season's episodes to find the intro and the credits. Times set by hand stay."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(
          "Times as minutes:seconds, for example 1:24. Leave a field empty when there is nothing to skip."
        )
        .font(.callout).foregroundStyle(.secondary)
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
          GridRow {
            Text("Intro Starts")
            TextField("0:00", text: $introStart).textFieldStyle(.roundedBorder).frame(width: 110)
              .accessibilityIdentifier("segments-intro-start")
            Text(times.map { MediaSegmentTimeText.origin($0.introSource, confidence: $0.introConfidence) } ?? "")
              .font(.caption).foregroundStyle(.secondary)
              .accessibilityIdentifier("segments-intro-source")
          }
          GridRow {
            Text("Intro Ends")
            TextField("1:30", text: $introEnd).textFieldStyle(.roundedBorder).frame(width: 110)
              .accessibilityIdentifier("segments-intro-end")
            Text("")
          }
          GridRow {
            Text("Credits Start")
            TextField("42:10", text: $creditsStart).textFieldStyle(.roundedBorder)
              .frame(width: 110)
              .accessibilityIdentifier("segments-credits-start")
            Text(
              times.map { MediaSegmentTimeText.origin($0.creditsSource, confidence: $0.creditsConfidence) }
                ?? ""
            )
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("segments-credits-source")
          }
        }
        if let times, !times.analyzed, times.canAnalyze {
          Text("The server has not examined this episode yet.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 10) {
        if !isSeries {
          Button("Save Times") { Task { await save() } }
            .disabled(!hasChanges)
            .accessibilityIdentifier("segments-save")
          Button("Reset to Detected") { Task { await reset() } }
            .disabled(times?.hasManualPart != true)
            .help("Removes the times set by hand; the server examines the episode again")
            .accessibilityIdentifier("segments-reset")
        }
        if isSeries || times?.canAnalyze == true {
          Button(isSeries ? "Re-analyze All Seasons" : "Re-analyze Season") {
            Task { await reanalyze() }
          }
          .accessibilityIdentifier("segments-reanalyze")
        }
        if working { ProgressView().controlSize(.small) }
      }
      if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
      if let errorText {
        Label(errorText, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange).font(.callout)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .disabled(working)
    .task(id: mediaId) { await load() }
  }

  private var client: APIClient? { model.profile.map(APIClient.init(profile:)) }

  private var hasChanges: Bool {
    guard let times,
      let request = MediaSegmentTimeText.request(
        introStart: introStart, introEnd: introEnd, creditsStart: creditsStart)
    else { return !introStart.isEmpty || !introEnd.isEmpty || !creditsStart.isEmpty }
    return request.introStartMilliseconds != shown(times.introStartMilliseconds)
      || request.introEndMilliseconds != shown(times.introEndMilliseconds)
      || request.creditsStartMilliseconds != shown(times.creditsStartMilliseconds)
  }

  /// Fields show whole seconds, so an unchanged field compares against the rounded time.
  private func shown(_ milliseconds: Int64?) -> Int64? { milliseconds.map { ($0 / 1_000) * 1_000 } }

  private func apply(_ value: MediaSegmentTimes) {
    times = value
    introStart = MediaSegmentTimeText.text(value.introStartMilliseconds)
    introEnd = MediaSegmentTimeText.text(value.introEndMilliseconds)
    creditsStart = MediaSegmentTimeText.text(value.creditsStartMilliseconds)
  }

  private func load() async {
    guard !isSeries, let client else { return }
    do {
      apply(try await client.mediaSegments(mediaId: mediaId))
    } catch {
      errorText = error.localizedDescription
    }
  }

  private func save() async {
    guard let client, let times else { return }
    guard
      var request = MediaSegmentTimeText.request(
        introStart: introStart, introEnd: introEnd, creditsStart: creditsStart)
    else {
      errorText = "Enter times like 1:24 or 1:02:30."
      return
    }
    // A field that still shows the stored time keeps its exact value, so only what was really
    // changed becomes a correction.
    if request.introStartMilliseconds == shown(times.introStartMilliseconds) {
      request.introStartMilliseconds = times.introStartMilliseconds
    }
    if request.introEndMilliseconds == shown(times.introEndMilliseconds) {
      request.introEndMilliseconds = times.introEndMilliseconds
    }
    if request.creditsStartMilliseconds == shown(times.creditsStartMilliseconds) {
      request.creditsStartMilliseconds = times.creditsStartMilliseconds
    }
    await perform {
      apply(try await client.saveMediaSegments(mediaId: mediaId, request))
      message = "Saved. These times are used the next time the episode starts."
    }
  }

  private func reset() async {
    guard let client else { return }
    await perform {
      apply(try await client.resetMediaSegments(mediaId: mediaId))
      message = "The server examines the episode again; its times appear here shortly."
    }
  }

  private func reanalyze() async {
    guard let client else { return }
    await perform {
      try await client.reanalyzeMediaSegments(mediaId: mediaId)
      message = "The server examines the episodes again in the background."
    }
  }

  private func perform(_ action: @MainActor () async throws -> Void) async {
    working = true
    defer { working = false }
    do {
      message = nil
      try await action()
      errorText = nil
    } catch {
      errorText = error.localizedDescription
    }
  }
}

/// Server settings: whether the server finds intros and credits, and how far it is.
struct ServerMediaSegmentsEditor: View {
  @EnvironmentObject private var model: AppModel
  let client: APIClient
  @State private var stored: MediaSegmentSettings?
  @State private var working = false
  @State private var message: String?

  var body: some View {
    Group {
      if let stored {
        AureliaSettingsSection(
          "Intros and Credits",
          symbol: "forward.end",
          description:
            "The server compares the sound of a season's episodes to find the intro and the credits. Only the times are stored."
        ) {
          VStack(alignment: .leading, spacing: 12) {
            if !stored.available {
              Text("FFmpeg is not installed on this server, so intros and credits cannot be found.")
                .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(
              "Find Intros and Credits",
              isOn: Binding(get: { stored.enabled }, set: { save(enabled: $0) })
            )
            .accessibilityIdentifier("server-media-segments-enabled")
            Text(Self.summary(stored))
              .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("server-media-segments-status")
            HStack(spacing: 10) {
              Button("Re-analyze Everything") { reanalyze() }
                .disabled(!stored.enabled || !stored.available)
                .help("Examines every episode again; times set by hand stay")
                .accessibilityIdentifier("server-media-segments-reanalyze")
              if working { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
          }
          .frame(maxWidth: .infinity, alignment: .leading).disabled(working)
        }
        .accessibilityIdentifier("server-media-segments")
      }
    }
    .task(id: model.administrationGeneration) { await load() }
  }

  static func summary(_ settings: MediaSegmentSettings) -> String {
    var parts = [
      "\(settings.analyzedCount) episodes with times",
      "\(settings.noResultCount) without a certain result",
    ]
    if settings.pendingCount > 0 { parts.append("\(settings.pendingCount) still to examine") }
    var text = parts.joined(separator: " · ")
    if !settings.enabled {
      text += ". Turned off: only times set by hand are used."
    } else if settings.pausedForPlayback {
      text += ". Waiting while someone is watching."
    } else if settings.running {
      text += ". Working in the background."
    }
    return text
  }

  private func load() async {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    do {
      stored = try await model.currentAdministration {
        try await scope.request { try await client.serverMediaSegments() }
      }
    } catch let failure as APIClientError where failure.httpStatus == 404 {
      // A server before 2.8.0 has no detection.
      stored = nil
    } catch {
      message = scope.message(for: error)
    }
  }

  private func save(enabled: Bool) {
    run { try await client.saveServerMediaSegments(enabled: enabled) }
  }

  private func reanalyze() {
    run { try await client.reanalyzeAllMediaSegments() }
  }

  private func run(_ action: @escaping @Sendable () async throws -> MediaSegmentSettings) {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    message = nil
    Task {
      defer { working = false }
      do {
        stored = try await model.currentAdministration { try await scope.request(action) }
      } catch {
        message = scope.message(for: error)
      }
    }
  }
}
