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
      if let errorText {
        Label(errorText, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange).font(.callout)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: mediaId) { await load() }
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
