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
  @State private var editing: SegmentTrimPart?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !isSeries, let times {
        HStack(spacing: 10) {
          Button("Edit Intro…") { editing = .intro }
            .help("Opens the episode's beginning with a film strip: drag the yellow handles to where the intro begins and ends, play it to check, then save.")
            .accessibilityIdentifier("segments-edit-intro")
          Button("Edit Credits…") { editing = .credits }
            .help("Opens the episode's ending with a film strip: drag the handle to where the credits begin, play it to check, then save.")
            .accessibilityIdentifier("segments-edit-credits")
        }
        .disabled(working || model.profile == nil)
        .sheet(item: $editing) { part in
          if let profile = model.profile {
            SegmentTrimEditor(profile: profile, mediaId: mediaId, part: part, times: times) { saved in
              apply(saved)
              message = "Saved. These times are used the next time the episode starts."
            }
            .environmentObject(model)
          }
        }
      }
      if isSeries {
        Text(
          "The server compares the sound of a season's episodes to find the intro and the credits. Times set by hand stay."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(
          "Or type the times as minutes:seconds, for example 1:24. Leave a field empty when there is nothing to skip."
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
            .help("Saves the typed times as corrections; detection never replaces them.")
            .accessibilityIdentifier("segments-save")
          Button("Reset to Detected") { Task { await reset() } }
            .disabled(times?.hasManualPart != true)
            .help("Removes the times set by hand; the server examines the episode again and fills in what it finds.")
            .accessibilityIdentifier("segments-reset")
        }
        if isSeries || times?.canAnalyze == true {
          Button(isSeries ? "Re-analyze All Seasons" : "Re-analyze Season") {
            Task { await reanalyze() }
          }
          .help("Has the server compare this season's episodes again in the background. Times set by hand stay.")
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

/// Server settings: whether the server finds intros and credits, how far it is, and each series.
struct ServerMediaSegmentsEditor: View {
  @EnvironmentObject private var model: AppModel
  let client: APIClient
  @State private var stored: MediaSegmentSettings?
  @State private var series: [MediaSegmentSeriesStatus] = []
  @State private var showsSeries = false
  @State private var working = false
  @State private var message: String?

  var body: some View {
    Group {
      if let stored {
        AureliaSettingsSection(
          "Intros and Credits",
          symbol: "forward.end",
          description:
            "The server compares the sound and pictures of a season's episodes to find the intro and the credits. Only the times are stored; it waits while someone is watching."
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
            if stored.usePictures != nil {
              VStack(alignment: .leading, spacing: 2) {
                Toggle(
                  "Also Look at Pictures for Credits",
                  isOn: Binding(
                    get: { stored.usePictures ?? true },
                    set: { save(enabled: stored.enabled, usePictures: $0) })
                )
                .disabled(!stored.enabled)
                .accessibilityIdentifier("server-media-segments-pictures")
                Text(
                  "Finds credits whose music differs in every episode, such as names on black. It reads the last minutes of each episode's picture, which takes a few minutes per episode on a small server, but only once."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              }
            }
            progress(stored)
            HStack(spacing: 10) {
              Button("Re-analyze Everything") { reanalyze(nil) }
                .disabled(!stored.enabled || !stored.available)
                .help("Examines every episode again; times set by hand stay")
                .accessibilityIdentifier("server-media-segments-reanalyze")
              if working { ProgressView().controlSize(.small) }
            }
            if !series.isEmpty {
              DisclosureGroup("Series (\(series.count))", isExpanded: $showsSeries) {
                seriesList
              }
              .accessibilityIdentifier("server-media-segments-series")
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
          }
          .frame(maxWidth: .infinity, alignment: .leading).disabled(working)
        }
        .accessibilityIdentifier("server-media-segments")
      }
    }
    .task(id: model.administrationGeneration) { await refreshWhileWorking() }
  }

  @ViewBuilder
  private func progress(_ settings: MediaSegmentSettings) -> some View {
    let total = max(settings.totalCount ?? 0, settings.pendingCount + settings.analyzedCount + settings.noResultCount)
    VStack(alignment: .leading, spacing: 6) {
      if total > 0 {
        ProgressView(value: settings.progress) {
          Text("\(total - settings.pendingCount) of \(total) episodes examined")
            .font(.callout.monospacedDigit())
        }
        .accessibilityIdentifier("server-media-segments-progress")
      }
      Text(Self.summary(settings))
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("server-media-segments-status")
      if settings.running, let title = settings.currentTitle {
        Label(
          [title, settings.currentStep].compactMap { $0 }.joined(separator: " · "),
          systemImage: "waveform")
          .font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("server-media-segments-current")
      }
    }
  }

  private var seriesList: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(series) { item in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(item.title).lineLimit(1)
          Spacer()
          Text(Self.seriesSummary(item))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          Button("Re-analyze") { reanalyze(item.seriesId) }
            .controlSize(.small)
            .disabled(stored?.enabled != true)
            .accessibilityLabel("Re-analyze \(item.title)")
        }
        .padding(.vertical, 5)
        Divider()
      }
    }
    .padding(.top, 6)
  }

  static func seriesSummary(_ item: MediaSegmentSeriesStatus) -> String {
    var text = "Intro \(item.withIntro)/\(item.episodeCount) · Credits \(item.withCredits)/\(item.episodeCount)"
    if item.pendingCount > 0 { text += " · \(item.pendingCount) to examine" }
    return text
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
    } else if settings.pendingCount > 0, let seconds = settings.estimatedSecondsRemaining {
      text += ". About \(remaining(seconds)) left."
    } else if settings.running {
      text += ". Working in the background."
    }
    return text
  }

  /// "40 minutes", "3 hours", "1 day 4 hours".
  static func remaining(_ seconds: Int) -> String {
    let minutes = max(1, (seconds + 59) / 60)
    if minutes < 90 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
    let hours = (minutes + 30) / 60
    if hours < 36 { return "\(hours) hours" }
    let days = hours / 24
    let rest = hours % 24
    return (days == 1 ? "1 day" : "\(days) days") + (rest > 0 ? " \(rest) hours" : "")
  }

  /// Loads now, then refreshes every few seconds while the server is still examining episodes.
  private func refreshWhileWorking() async {
    await load()
    while !Task.isCancelled, let current = stored, current.enabled,
      current.pendingCount > 0 || current.running
    {
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      await load()
    }
  }

  private func load() async {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    do {
      stored = try await model.currentAdministration {
        try await scope.request { try await client.serverMediaSegments() }
      }
      if stored?.usePictures != nil {
        series = try await model.currentAdministration {
          try await scope.request { try await client.mediaSegmentSeries() }
        }
      }
    } catch let failure as APIClientError where failure.httpStatus == 404 {
      // A server before 2.8.0 has no detection.
      stored = nil
    } catch {
      message = scope.message(for: error)
    }
  }

  private func save(enabled: Bool, usePictures: Bool? = nil) {
    run { try await client.saveServerMediaSegments(enabled: enabled, usePictures: usePictures) }
  }

  private func reanalyze(_ seriesId: UUID?) {
    if let seriesId {
      run { try await client.reanalyzeMediaSegments(seriesId: seriesId) }
    } else {
      run { try await client.reanalyzeAllMediaSegments() }
    }
  }

  private func run(_ action: @escaping @Sendable () async throws -> MediaSegmentSettings) {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    message = nil
    Task {
      defer { working = false }
      do {
        stored = try await model.currentAdministration { try await scope.request(action) }
        await refreshWhileWorking()
      } catch {
        message = scope.message(for: error)
      }
    }
  }
}
