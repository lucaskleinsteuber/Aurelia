import SwiftUI

/// Settings › Metadata: the server's OpenSubtitles setup. The owner enters a free API key, picks
/// languages and may turn on automatic downloads; administrators see how it is set up.
struct SubtitleDownloadSettingsSection: View {
  @EnvironmentObject private var model: AppModel
  @State private var status: SubtitleProviderStatus?
  @State private var apiKey = ""
  @State private var accountName = ""
  @State private var accountPassword = ""
  @State private var working = false
  @State private var errorText: String?

  private var isOwner: Bool { model.profile?.user?.role == .owner }

  var body: some View {
    AureliaSettingsSection(
      "Subtitle Downloads",
      symbol: "captions.bubble",
      description:
        "Find subtitles on OpenSubtitles.com with your own free API key. Downloaded subtitles are kept in the server's data folder, never next to your media."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        if let status, status.hasApiKey {
          configured(status)
        } else if isOwner {
          setup
        } else {
          Text("An owner sets up subtitle downloads.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let errorText {
          Label(errorText, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange).font(.callout)
            .accessibilityIdentifier("subtitles-error")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .disabled(working)
    }
    .task(id: model.profile?.user?.id) { await load() }
  }

  private var setup: some View {
    VStack(alignment: .leading, spacing: 10) {
      SecureField("OpenSubtitles API Key", text: $apiKey)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("subtitles-api-key")
      Text(
        "Create a free account on opensubtitles.com, then add an API consumer under your profile to get a key."
      )
      .font(.caption).foregroundStyle(.secondary)
      Button("Turn On Subtitle Downloads") {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = ""
        Task {
          await save(
            UpdateSubtitleProviderRequest(
              enabled: true, languages: Self.defaultLanguages, automatic: false, apiKey: key))
        }
      }
      .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityIdentifier("subtitles-enable")
    }
  }

  @ViewBuilder
  private func configured(_ status: SubtitleProviderStatus) -> some View {
    LabeledContent("OpenSubtitles", value: status.enabled ? "On" : "Off")
    LabeledContent(
      "Languages", value: status.languages.map(SubtitleLanguages.name).joined(separator: ", "))
    if let remaining = status.remainingDownloads {
      LabeledContent("Downloads Left Today", value: "\(remaining)")
    }
    LabeledContent("Downloaded", value: "\(status.downloadedCount)")
    if isOwner {
      Toggle(
        "Subtitle downloads",
        isOn: Binding(
          get: { status.enabled },
          set: { on in Task { await save(request(status, enabled: on)) } })
      )
      .accessibilityIdentifier("subtitles-enabled")
      Menu("Languages: \(status.languages.map(SubtitleLanguages.name).joined(separator: ", "))") {
        ForEach(SubtitleLanguages.choices, id: \.self) { code in
          let chosen = status.languages.contains(code)
          Button {
            var languages = status.languages
            if chosen { languages.removeAll { $0 == code } } else { languages.append(code) }
            guard !languages.isEmpty, languages.count <= 5 else { return }
            Task { await save(request(status, languages: languages)) }
          } label: {
            if chosen {
              Label(SubtitleLanguages.name(code), systemImage: "checkmark")
            } else {
              Text(SubtitleLanguages.name(code))
            }
          }
        }
      }
      .fixedSize()
      .accessibilityIdentifier("subtitles-languages")
      Toggle(
        "Download missing subtitles automatically",
        isOn: Binding(
          get: { status.automatic },
          set: { on in Task { await save(request(status, automatic: on)) } })
      )
      .disabled(!status.enabled)
      .accessibilityIdentifier("subtitles-automatic")
      Text(
        "Every six hours the server looks for matched movies and episodes without subtitles in these languages, in the file or beside it. Each title is checked at most once a week."
      )
      .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Divider()
      account(status)
      Divider()
      Button("Remove API Key", role: .destructive) {
        Task { await run { try await $0.removeSubtitleKey() } }
      }
      .accessibilityIdentifier("subtitles-remove-key")
    }
    Text(status.attribution).font(.caption2).foregroundStyle(.secondary)
  }

  @ViewBuilder
  private func account(_ status: SubtitleProviderStatus) -> some View {
    if status.hasAccount {
      HStack {
        LabeledContent("Account", value: status.accountName ?? "Signed in")
        Spacer()
        Button("Remove Account") { Task { await run { try await $0.removeSubtitleAccount() } } }
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Text("OpenSubtitles Account (optional)").font(.headline)
        Text(
          "Without an account OpenSubtitles allows only a few downloads a day. The password stays on the server."
        )
        .font(.caption).foregroundStyle(.secondary)
        HStack {
          TextField("User Name", text: $accountName).textFieldStyle(.roundedBorder)
          SecureField("Password", text: $accountPassword).textFieldStyle(.roundedBorder)
          Button("Save Account") {
            var update = request(status)
            update.accountName = accountName.trimmingCharacters(in: .whitespaces)
            update.accountPassword = accountPassword
            accountPassword = ""
            Task { await save(update) }
          }
          .disabled(accountName.trimmingCharacters(in: .whitespaces).isEmpty || accountPassword.isEmpty)
        }
      }
    }
  }

  static var defaultLanguages: [String] {
    let preferred = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
    var languages = Array(NSOrderedSet(array: preferred).compactMap { $0 as? String }.prefix(2))
    if !languages.contains("en") { languages.append("en") }
    return Array(languages.prefix(3))
  }

  private func request(
    _ status: SubtitleProviderStatus, enabled: Bool? = nil, languages: [String]? = nil,
    automatic: Bool? = nil
  ) -> UpdateSubtitleProviderRequest {
    UpdateSubtitleProviderRequest(
      enabled: enabled ?? status.enabled, languages: languages ?? status.languages,
      automatic: automatic ?? status.automatic)
  }

  private func load() async {
    guard model.canManageMedia, let profile = model.profile else { return }
    status = try? await APIClient(profile: profile).subtitleProviderStatus()
  }

  private func save(_ request: UpdateSubtitleProviderRequest) async {
    await run { try await $0.configureSubtitles(request) }
  }

  private func run(_ action: @escaping @MainActor (APIClient) async throws -> SubtitleProviderStatus)
    async
  {
    guard let profile = model.profile else { return }
    working = true
    defer { working = false }
    do {
      let client = APIClient(profile: profile)
      status = try await model.currentAdministration { try await action(client) }
      errorText = nil
    } catch is CancellationError {
    } catch {
      errorText = error.localizedDescription
    }
  }
}

/// Edit Metadata › Subtitles: the subtitles downloaded for this movie or episode, and a search on
/// OpenSubtitles to add one. Players list them with the title's other subtitles.
struct SubtitleDownloadPanel: View {
  @EnvironmentObject private var model: AppModel
  let mediaId: UUID
  @State private var status: SubtitleProviderStatus?
  @State private var downloaded: [DownloadedSubtitle] = []
  @State private var language = "en"
  @State private var results: [SubtitleCandidate]?
  @State private var working: String?
  @State private var errorText: String?
  @ObservedObject private var speech = SpeechSubtitleJobs.shared
  @State private var speechTracks: [SpeechAudioTrack]?
  @State private var speechTrack = 0
  @State private var speechLanguage = "en"
  @State private var speechLanguages: [String] = []
  @State private var syncTracks: [LiveSubtitleTrack] = []
  @State private var syncTrack = -1
  /// The server's own speech recognition for this title ("server-speech-v1"), when it has one.
  @State private var serverSpeech: MediaSpeechInfo?

  /// The server listens when it has whisper.cpp and a model; this Mac's recognizer is the fallback.
  private var serverListens: Bool { serverSpeech?.available == true && serverSpeech?.modelReady == true }

  private var syncPossible: Bool {
    serverListens || model.libraryCapabilities.contains("subtitle-sync-v1")
  }

  private var speechPossible: Bool {
    serverListens
      || (model.libraryCapabilities.contains("speech-subtitles-v1") && SpeechRecognizer.isAvailable)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if downloaded.isEmpty {
        Text("No subtitles downloaded for this title.")
          .font(.callout).foregroundStyle(.secondary)
      } else {
        ForEach(downloaded) { subtitle in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(subtitle.title)
              if let release = subtitle.release {
                Text(release).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
            }
            Spacer()
            if subtitle.automatic {
              Text("Automatic").font(.caption).foregroundStyle(.secondary)
            }
            Button("Remove", role: .destructive) { Task { await remove(subtitle) } }
              .accessibilityIdentifier("subtitle-remove")
          }
        }
      }
      if let status, status.enabled {
        Divider()
        HStack {
          Picker("Language", selection: $language) {
            ForEach(languages(status), id: \.self) { code in
              Text(SubtitleLanguages.name(code)).tag(code)
            }
          }
          .fixedSize()
          Button("Search OpenSubtitles") { Task { await search() } }
            .accessibilityIdentifier("subtitle-search")
          if working != nil { ProgressView().controlSize(.small) }
        }
        if let results {
          if results.isEmpty {
            Text("No subtitles found in \(SubtitleLanguages.name(language)).")
              .font(.callout).foregroundStyle(.secondary)
          }
          ForEach(results.prefix(15)) { candidate in
            HStack(alignment: .firstTextBaseline) {
              VStack(alignment: .leading, spacing: 2) {
                Text(candidate.release ?? SubtitleLanguages.name(candidate.language)).lineLimit(1)
                Text(candidate.details).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Download") { Task { await download(candidate) } }
                .disabled(working != nil)
            }
          }
        }
        Text(status.attribution).font(.caption2).foregroundStyle(.secondary)
      } else if status != nil {
        Text("Set up subtitle downloads in Settings › Metadata to search for subtitles.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if speechPossible {
        Divider()
        speechSection
      }
      if let errorText {
        Label(errorText, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange).font(.callout)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: mediaId) { await load() }
    .onChange(of: speech.job(mediaId)?.phase) { _, phase in
      if case .saved = phase { Task { await load() } }
    }
    .task(id: serverSpeech?.job?.isRunning == true) {
      // Follows the server's job while it runs; its subtitles appear in the list when it is done.
      while serverSpeech?.job?.isRunning == true, !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard let client, !Task.isCancelled else { return }
        serverSpeech = try? await client.mediaSpeech(mediaId: mediaId)
        if serverSpeech?.job?.isRunning != true { await load() }
      }
    }
  }

  /// Subtitles written by this Mac from what is said in a sound track.
  private var speechSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Subtitles from Speech").font(.headline)
      Text(
        syncPossible
          ? "This Mac listens to a sound track and writes subtitles from what is said, or moves existing subtitles so they fit the speech. The sound is read from the server and never stored; the results are kept on the server for every device, and the original subtitles stay as they are."
          : "This Mac listens to a sound track and writes subtitles from what is said. The sound is read from the server and never stored; the subtitles are kept on the server for every device."
      )
      .font(.caption).foregroundStyle(.secondary)
      if serverListens {
        Text("The server listens, in the background; this window can be closed meanwhile.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let job = serverSpeech?.job, job.isRunning {
        ServerSpeechJobRow(job: job) { Task { await cancelServer() } }
      } else if let job = serverSpeech?.job, speechTracks == nil, job.state != .cancelled {
        HStack {
          Label(
            job.message ?? (job.state == .done ? "Saved." : "Stopped."),
            systemImage: job.state == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
            .foregroundStyle(job.state == .failed ? .orange : .primary)
          Spacer()
          Button("Done") { Task { await cancelServer() } }
        }
        Button(
          syncPossible ? "Create or Sync Subtitles from Speech…" : "Create Subtitles from Speech…"
        ) { Task { await loadSpeechTracks() } }
          .disabled(working != nil)
      } else if let job = speech.job(mediaId) {
        speechJob(job)
      } else if let tracks = speechTracks {
        if tracks.isEmpty {
          Text("This title has no sound track.").font(.callout).foregroundStyle(.secondary)
        } else {
          HStack {
            Picker("Sound Track", selection: $speechTrack) {
              ForEach(tracks) { track in Text(track.label).tag(track.index) }
            }
            .fixedSize()
            .onChange(of: speechTrack) { _, index in
              if let code = SpeechLanguages.code(
                forTrack: tracks.first { $0.index == index }?.language),
                speechLanguages.contains(code)
              {
                speechLanguage = code
              }
            }
            Picker("Spoken Language", selection: $speechLanguage) {
              ForEach(speechLanguages, id: \.self) { code in
                Text(SubtitleLanguages.name(code)).tag(code)
              }
            }
            .fixedSize()
          }
          HStack {
            Button("Create Subtitles") { startSpeech() }
              .accessibilityIdentifier("subtitle-speech-start")
            Button("Cancel") { speechTracks = nil }
          }
          if syncPossible, !syncTracks.isEmpty {
            HStack {
              Picker("Subtitles", selection: $syncTrack) {
                ForEach(syncTracks) { track in Text(track.title).tag(track.index) }
              }
              .fixedSize()
              Button("Sync to Speech") { startSync() }
                .disabled(!syncTracks.contains { $0.index == syncTrack })
                .accessibilityIdentifier("subtitle-sync-start")
            }
            Text(
              "Syncing moves the chosen subtitles so they appear when the words are said, also when they were made for another frame rate or cut. The result is saved as a synced copy."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
      } else {
        Button(
          syncPossible ? "Create or Sync Subtitles from Speech…" : "Create Subtitles from Speech…"
        ) { Task { await loadSpeechTracks() } }
          .disabled(working != nil)
          .accessibilityIdentifier("subtitle-speech")
      }
    }
  }

  @ViewBuilder
  private func speechJob(_ job: SpeechSubtitleJobs.Job) -> some View {
    let language = SubtitleLanguages.name(job.language)
    if case .sync(let name) = job.kind {
      Text("Syncing “\(name)”").font(.callout.weight(.semibold))
    }
    switch job.phase {
    case .preparing:
      HStack {
        ProgressView().controlSize(.small)
        Text("Getting ready…").foregroundStyle(.secondary)
        Button("Cancel") { speech.cancel(mediaId) }
      }
    case .loadingModel:
      HStack {
        ProgressView().controlSize(.small)
        Text("Loading the speech model for \(language). This happens once.")
          .foregroundStyle(.secondary)
        Button("Cancel") { speech.cancel(mediaId) }
      }
    case .listening(let share):
      HStack {
        if share > 0 {
          ProgressView(value: share).frame(maxWidth: 260)
          Text("Listening… \(Int(share * 100)) %").monospacedDigit().foregroundStyle(.secondary)
        } else {
          ProgressView().controlSize(.small)
          Text("Listening…").foregroundStyle(.secondary)
        }
        Button("Cancel") { speech.cancel(mediaId) }
      }
      Text("You can close this window; the subtitles are saved when they are done.")
        .font(.caption).foregroundStyle(.secondary)
    case .saving:
      HStack {
        ProgressView().controlSize(.small)
        Text("Saving…").foregroundStyle(.secondary)
      }
    case .saved(let subtitle):
      HStack {
        Label("\(subtitle.title) is ready on every device.", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Button("Done") { speech.dismiss(mediaId) }
      }
      if let summary = job.summary {
        Text(summary).font(.caption).foregroundStyle(.secondary)
      }
    case .alreadyInSync:
      HStack {
        Label(
          "These subtitles already fit the speech; nothing was changed.",
          systemImage: "checkmark.circle")
        Button("Done") { speech.dismiss(mediaId) }
      }
    case .unsaved(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      HStack {
        Button("Save Subtitles") {
          speech.saveAgain(
            mediaId,
            save: job.kind == .create
              ? saver(language: job.language) : syncSaver(language: job.language))
        }
        Button("Discard", role: .destructive) { speech.cancel(mediaId) }
      }
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Button("OK") { speech.dismiss(mediaId) }
    }
  }

  private func loadSpeechTracks() async {
    guard let client else { return }
    await perform("speech") {
      let ticket = try await client.createPlayback(mediaId: mediaId)
      defer { Task { try? await client.revokePlayback(id: ticket.id) } }
      let tracks = try await client.speechAudioTracks(streamPath: ticket.streamPath).tracks
      if syncPossible {
        syncTracks = ((try? await client.streamSubtitles(ticket: ticket.id)) ?? [])
          .filter(\.supported)
        syncTrack = syncTracks.first?.index ?? -1
      }
      speechLanguages =
        serverListens
        ? SubtitleLanguages.choices : SpeechLanguages.choices(await SpeechRecognizer.supportedLocales())
      let chosen = tracks.first(where: \.isDefault) ?? tracks.first
      speechTrack = chosen?.index ?? 0
      let preferred = SpeechLanguages.code(forTrack: chosen?.language)
        ?? Locale.current.language.languageCode?.identifier ?? "en"
      speechLanguage =
        speechLanguages.contains(preferred) ? preferred : speechLanguages.first ?? "en"
      speechTracks = tracks
    }
  }

  private func startSpeech() {
    if serverListens {
      startOnServer(StartServerSpeechRequest(kind: .create, language: speechLanguage, audioIndex: speechTrack))
      return
    }
    guard let profile = model.profile else { return }
    speech.start(
      mediaId: mediaId, track: speechTrack, language: speechLanguage, profile: profile,
      save: saver(language: speechLanguage))
    speechTracks = nil
  }

  private func startSync() {
    guard let track = syncTracks.first(where: { $0.index == syncTrack }) else { return }
    // Saved in the subtitles' own language; when they don't say, in the spoken one.
    let language = SpeechLanguages.code(forTrack: track.language) ?? speechLanguage
    if serverListens {
      startOnServer(
        StartServerSpeechRequest(
          kind: .sync, language: language, audioIndex: speechTrack, subtitleIndex: track.index))
      return
    }
    guard let profile = model.profile else { return }
    speech.sync(
      mediaId: mediaId, subtitles: track, language: language, track: speechTrack,
      spoken: speechLanguage, profile: profile, save: syncSaver(language: language))
    speechTracks = nil
  }

  private func startOnServer(_ request: StartServerSpeechRequest) {
    guard let client else { return }
    speechTracks = nil
    Task {
      await perform("speech") {
        serverSpeech = try await model.currentAdministration {
          try await client.startServerSpeech(mediaId: mediaId, request)
        }
      }
    }
  }

  /// Stops a running server job, or clears a finished one's message.
  private func cancelServer() async {
    guard let client else { return }
    await perform("speech") {
      try await model.currentAdministration { try await client.cancelServerSpeech(mediaId: mediaId) }
      serverSpeech = try await client.mediaSpeech(mediaId: mediaId)
    }
  }

  private func syncSaver(language: String) -> @MainActor (String) async throws -> DownloadedSubtitle {
    let mediaId = mediaId
    return { [model] subRip in
      guard let profile = model.profile else { throw CancellationError() }
      let client = APIClient(profile: profile)
      return try await model.currentAdministration {
        try await client.saveSyncedSubtitles(mediaId: mediaId, language: language, subRip: subRip)
      }
    }
  }

  private func saver(language: String) -> @MainActor (String) async throws -> DownloadedSubtitle {
    let mediaId = mediaId
    return { [model] subRip in
      guard let profile = model.profile else { throw CancellationError() }
      let client = APIClient(profile: profile)
      return try await model.currentAdministration {
        try await client.saveSpeechSubtitles(mediaId: mediaId, language: language, subRip: subRip)
      }
    }
  }

  private func languages(_ status: SubtitleProviderStatus) -> [String] {
    status.languages + SubtitleLanguages.choices.filter { !status.languages.contains($0) }
  }

  private var client: APIClient? { model.profile.map(APIClient.init(profile:)) }

  private func load() async {
    guard let client else { return }
    status = try? await client.subtitleProviderStatus()
    if let first = status?.languages.first { language = first }
    do {
      downloaded = try await client.downloadedSubtitles(mediaId: mediaId)
    } catch {
      errorText = error.localizedDescription
    }
    if model.libraryCapabilities.contains(ServerFeatureNames.serverSpeech) {
      serverSpeech = try? await client.mediaSpeech(mediaId: mediaId)
    }
  }

  private func search() async {
    guard let client else { return }
    await perform("search") {
      results = try await client.searchSubtitles(mediaId: mediaId, language: language)
    }
  }

  private func download(_ candidate: SubtitleCandidate) async {
    guard let client else { return }
    await perform(candidate.fileId) {
      let subtitle = try await client.downloadSubtitle(
        mediaId: mediaId,
        DownloadSubtitleRequest(
          fileId: candidate.fileId, language: candidate.language, release: candidate.release,
          hearingImpaired: candidate.hearingImpaired, foreignPartsOnly: candidate.foreignPartsOnly))
      if !downloaded.contains(subtitle) { downloaded.append(subtitle) }
      status = try? await client.subtitleProviderStatus()
    }
  }

  private func remove(_ subtitle: DownloadedSubtitle) async {
    guard let client else { return }
    await perform(subtitle.id.uuidString) {
      try await client.removeSubtitle(mediaId: mediaId, id: subtitle.id)
      downloaded.removeAll { $0.id == subtitle.id }
    }
  }

  private func perform(_ id: String, _ action: @MainActor () async throws -> Void) async {
    working = id
    defer { working = nil }
    do {
      try await action()
      errorText = nil
    } catch {
      errorText = error.localizedDescription
    }
  }
}
