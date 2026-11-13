import SwiftUI

/// Settings › Metadata: movie and TV information from TMDB, matches to review, subtitle
/// downloads from OpenSubtitles, artwork and search.
struct IOSAdminMetadataView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel

  struct Overview: Sendable {
    let provider: IOSMetadataProvider?
    let jobs: [IOSMetadataJob]
    let reviews: [IOSMetadataReview]
    let subtitles: IOSSubtitleProvider?
  }

  var body: some View {
    IOSAdminLoader { client in
      async let provider = try? client.metadataProvider()
      async let jobs = client.metadataJobs(limit: 10)
      async let reviews = (try? client.metadataReviews()) ?? []
      async let subtitles = try? client.subtitleProvider()
      return Overview(
        provider: await provider, jobs: try await jobs, reviews: await reviews,
        subtitles: await subtitles)
    } content: { overview, reload in
      IOSAdminMetadataContent(overview: overview, owner: admin.permissions.owner, reload: reload)
    }
    .navigationTitle("Metadata")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminMetadataContent: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let overview: IOSAdminMetadataView.Overview
  let owner: Bool
  let reload: () async -> Void
  @State private var token = ""
  @State private var confirmation: IOSAdminConfirmation?

  private var activeJob: IOSMetadataJob? { overview.jobs.first(where: \.isActive) }

  var body: some View {
    Form {
      IOSAdminPageHeader(
        page: .metadata,
        text:
          "Posters, descriptions, cast and ratings come from TMDB, subtitles from OpenSubtitles. Aurelia finds them by the file and folder names.")
      if let provider = overview.provider {
        Section {
          if provider.hasToken {
            Toggle(
              isOn: Binding(
                get: { provider.enabled },
                set: { enabled in
                  let language = provider.language
                  Task {
                    await admin.perform {
                      _ = try await $0.saveMetadataProvider(enabled: enabled, token: nil, language: language)
                    }
                  }
                })
            ) {
              IOSAdminToggleLabel(
                "Look Up Movie and TV Information", "New titles get posters and descriptions by themselves.")
            }
            LabeledContent(
              "Artwork",
              value: "\(IOSAdminText.bytes(provider.artworkBytes)) of \(IOSAdminText.bytes(provider.artworkLimitBytes))")
            if owner {
              Button("Remove TMDB Key…", role: .destructive) {
                confirmation = IOSAdminConfirmation(
                  title: "Remove the TMDB key?",
                  message: "Information already found stays. New titles get no information until you add a key.",
                  action: "Remove"
                ) {
                  Task { await admin.perform { _ = try await $0.removeMetadataToken() } }
                }
              }
            }
          } else if owner {
            Text(
              "Aurelia needs a free TMDB key to find posters and descriptions. Create one at themoviedb.org under Settings › API and paste the “API Read Access Token” here."
            )
            .font(.subheadline).foregroundStyle(.secondary)
            SecureField("TMDB API Read Access Token", text: $token)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Turn On") {
              let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
              let language = provider.language
              Task {
                if await admin.perform("Checking the key…", {
                  _ = try await $0.saveMetadataProvider(enabled: true, token: value, language: language)
                }) {
                  token = ""
                }
              }
            }
            .disabled(token.trimmingCharacters(in: .whitespaces).count < 20)
          } else {
            Text("The owner hasn’t added a TMDB key yet.").foregroundStyle(.secondary)
          }
        } header: {
          Text("Movie and TV Information")
        } footer: {
          Text(provider.attribution)
        }
      }
      Section {
        if let job = activeJob {
          VStack(alignment: .leading, spacing: 6) {
            if let progress = job.progress { ProgressView(value: progress) }
            Text(job.summary).font(.caption).foregroundStyle(.secondary)
          }
          Button("Stop", role: .destructive) {
            let id = job.id
            Task { await admin.perform { try await $0.cancelMetadataJob(id: id) } }
          }
        } else {
          if let last = overview.jobs.first {
            Text(last.summary).font(.caption).foregroundStyle(.secondary)
          }
          IOSAdminActionButton(
            "Find Missing Information", systemImage: "magnifyingglass",
            detail: "Looks up only titles that have no information yet.", doneText: "Started"
          ) { _ = try await $0.startMetadataJob() }
          if owner {
            IOSAdminActionButton(
              "Refresh All Information", systemImage: "arrow.triangle.2.circlepath",
              detail: "Looks up every title again, for example after changing the language. Takes a while.",
              doneText: "Started"
            ) { _ = try await $0.startMetadataJob(fullRefresh: true) }
          }
        }
        NavigationLink {
          IOSAdminMetadataReviewsView()
        } label: {
          LabeledContent {
            Text("\(overview.reviews.count)")
          } label: {
            IOSAdminToggleLabel("Review Matches", "Titles where Aurelia wasn’t sure it found the right one.")
          }
        }
      } header: {
        Text("Library Information")
      } footer: {
        Text("Titles without any match are under Library › Library Health › Without Information.")
      }
      if let subtitles = overview.subtitles, owner {
        Section {
          NavigationLink {
            IOSAdminSubtitlesView(provider: subtitles)
          } label: {
            LabeledContent {
              Text(subtitles.hasApiKey ? (subtitles.enabled ? "On" : "Off") : "Not Set Up")
            } label: {
              IOSAdminToggleLabel("OpenSubtitles", "Downloads subtitles in your languages when a title has none.")
            }
          }
        } header: {
          Text("Subtitle Downloads")
        }
      }
      Section {
        IOSAdminActionButton(
          "Remove Unused Artwork", systemImage: "photo.stack",
          detail: "Frees space taken by posters of titles that are gone."
        ) { try await $0.pruneArtwork() }
        IOSAdminActionButton(
          "Rebuild Search", systemImage: "text.magnifyingglass",
          detail: "Use this if search misses titles you know are there."
        ) { try await $0.rebuildSearch() }
      } header: {
        Text("Artwork and Search")
      } footer: {
        Text("Only Aurelia’s own copies of posters and backdrops are removed, never your files.")
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
    .task(id: activeJob?.itemsProcessed) {
      guard activeJob != nil else { return }
      try? await Task.sleep(for: .seconds(3))
      await reload()
    }
  }
}

/// Titles whose match TMDB wasn't sure about: choose the right one or none.
private struct IOSAdminMetadataReviewsView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel

  var body: some View {
    IOSAdminLoader { try await $0.metadataReviews() } content: { reviews, reload in
      List {
        if reviews.isEmpty {
          Text("Nothing to review").foregroundStyle(.secondary)
        }
        ForEach(reviews) { review in
          Section {
            ForEach(review.candidates) { candidate in
              Button {
                let (media, choice) = (review.mediaId, candidate)
                Task { await admin.perform("Saving…") { try await $0.selectMetadataMatch(mediaId: media, candidate: choice) } }
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text([candidate.title, candidate.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.primary)
                  if let overview = candidate.overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                  }
                  Text("\(Int(candidate.confidence * 100)) % match").font(.caption2).foregroundStyle(.secondary)
                }
              }
            }
            Button("None of These") {
              let media = review.mediaId
              Task { await admin.perform { try await $0.clearMetadataMatch(mediaId: media) } }
            }
          } header: {
            Text(review.title)
          } footer: {
            Text(review.reason)
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .refreshable { await reload() }
    }
    .navigationTitle("Review Matches")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// OpenSubtitles: key, account, languages and automatic downloads.
private struct IOSAdminSubtitlesView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dismiss) private var dismiss
  let provider: IOSSubtitleProvider
  @State private var enabled: Bool
  @State private var automatic: Bool
  @State private var languages: String
  @State private var apiKey = ""
  @State private var account = ""
  @State private var password = ""
  @State private var confirmation: IOSAdminConfirmation?

  init(provider: IOSSubtitleProvider) {
    self.provider = provider
    _enabled = State(initialValue: provider.enabled)
    _automatic = State(initialValue: provider.automatic)
    _languages = State(initialValue: provider.languages.joined(separator: ", "))
  }

  private var languageCodes: [String] {
    languages.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      .filter { !$0.isEmpty }
  }

  var body: some View {
    IOSAdminForm(title: "OpenSubtitles") {
      Section {
        Toggle("Subtitle Downloads", isOn: $enabled)
        Toggle("Download Automatically", isOn: $automatic).disabled(!enabled)
        TextField("Languages, such as en, de", text: $languages)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
      } footer: {
        Text(
          "Automatic downloads look for missing subtitles in these languages now and then. Downloads today: \(provider.remainingDownloads.map(String.init) ?? "—") left."
        )
      }
      Section {
        if provider.hasApiKey {
          LabeledContent("API Key", value: "Saved")
          Button("Remove API Key", role: .destructive) {
            confirmation = IOSAdminConfirmation(
              title: "Remove the OpenSubtitles key?", message: "Downloaded subtitles stay.",
              action: "Remove"
            ) {
              Task { await admin.perform { _ = try await $0.removeSubtitleKey() } }
            }
          }
        } else {
          SecureField("API Key", text: $apiKey).textInputAutocapitalization(.never)
        }
        if provider.hasAccount {
          LabeledContent("Account", value: provider.accountName ?? "Saved")
          Button("Remove Account", role: .destructive) {
            Task { await admin.perform { _ = try await $0.removeSubtitleAccount() } }
          }
        } else {
          TextField("Account Name (optional)", text: $account)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          SecureField("Account Password", text: $password)
        }
      } header: {
        Text("Key and Account")
      } footer: {
        Text("An account allows more downloads a day. The password is kept only on the server.")
      }
      Section { Text(provider.attribution).font(.caption).foregroundStyle(.secondary) }
    }
    .adminConfirmation($confirmation)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          var request = IOSUpdateSubtitleProvider(
            enabled: enabled, languages: languageCodes, automatic: automatic && enabled)
          if !apiKey.isEmpty { request.apiKey = apiKey }
          if !account.isEmpty, !password.isEmpty {
            request.accountName = account
            request.accountPassword = password
          }
          let payload = request
          Task {
            if await admin.perform("Saving…", { _ = try await $0.saveSubtitleProvider(payload) }) {
              apiKey = ""
              password = ""
              dismiss()
            }
          }
        }
        .disabled(languageCodes.isEmpty)
      }
    }
    .onDisappear {
      apiKey = ""
      password = ""
    }
  }
}
