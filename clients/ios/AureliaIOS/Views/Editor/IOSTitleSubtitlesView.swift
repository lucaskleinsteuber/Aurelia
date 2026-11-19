import SwiftUI

/// A title's subtitles in the editor: what was downloaded, a search on OpenSubtitles by language,
/// and subtitles the server writes from speech or syncs to it (server-speech-v1).
struct IOSTitleSubtitlesView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let mediaID: UUID
  @ObservedObject var admin: IOSAdministrationModel

  @State private var provider: IOSSubtitleProvider?
  @State private var providerLoaded = false
  @State private var downloaded: [IOSDownloadedSubtitle] = []
  @State private var language = "en"
  @State private var results: [IOSSubtitleCandidate]?
  @State private var working = false
  @State private var error: String?
  @State private var speech: IOSMediaSpeechInfo?
  @State private var audioTracks: [IOSSpeechAudioTrack]?
  @State private var subtitleTracks: [IOSLiveSubtitleTrack] = []
  @State private var audioTrack = 0
  @State private var spokenLanguage = "en"
  @State private var syncTrack = -1

  var body: some View {
    Form {
      Section {
        if downloaded.isEmpty {
          Text("No subtitles downloaded for this title.").foregroundStyle(.secondary)
        }
        ForEach(downloaded) { subtitle in
          VStack(alignment: .leading, spacing: 2) {
            Text(subtitle.title)
            Text(
              [subtitle.release, subtitle.automatic ? "Automatic" : nil].compactMap { $0 }
                .joined(separator: " · ")
            )
            .font(.footnote).foregroundStyle(.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
          }
          .swipeActions {
            Button("Remove", role: .destructive) { Task { await remove(subtitle) } }
              .tint(.red)
          }
        }
      } header: {
        Text("Downloaded")
      } footer: {
        if !downloaded.isEmpty { Text("Swipe a subtitle to remove it.") }
      }

      // Only the owner may read the provider's settings; others search and learn from the answer.
      if provider?.enabled ?? true {
        Section {
          Picker("Language", selection: $language) {
            ForEach(IOSSubtitleLanguages.choices, id: \.self) {
              Text(IOSSubtitleLanguages.name($0)).tag($0)
            }
          }
          Button {
            Task { await search() }
          } label: {
            HStack {
              Text("Search OpenSubtitles")
              if working, results == nil {
                Spacer()
                ProgressView()
              }
            }
          }
          .disabled(working)
          .accessibilityIdentifier("subtitles-search")
          if let results {
            if results.isEmpty {
              Text("No subtitles found in \(IOSSubtitleLanguages.name(language)).")
                .foregroundStyle(.secondary)
            }
            ForEach(results.prefix(15)) { candidate in
              Button {
                Task { await download(candidate) }
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text(candidate.release ?? IOSSubtitleLanguages.name(candidate.language))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                  Text(candidate.details).font(.footnote).foregroundStyle(.secondary)
                }
              }
              .disabled(working)
            }
          }
        } header: {
          Text("OpenSubtitles")
        } footer: {
          Text(
            [
              provider?.remainingDownloads.map { "\($0) downloads left today." },
              provider?.attribution ?? "Subtitles from OpenSubtitles.com.",
            ].compactMap { $0 }.joined(separator: " "))
        }
      } else if providerLoaded {
        Section("OpenSubtitles") {
          Text("Set up subtitle downloads in Settings › Metadata to search for subtitles.")
            .foregroundStyle(.secondary)
        }
      }

      if model.capabilities?.supportsServerSpeech == true {
        speechSection
      }
      if let error {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Subtitles")
    .navigationBarTitleDisplayMode(.inline)
    .tint(.blue)
    .task { await load() }
    .task(id: speech?.job?.isRunning == true) { await followSpeech() }
  }

  @ViewBuilder private var speechSection: some View {
    Section {
      if let speech, !speech.canListen {
        Text(
          speech.available
            ? "The server needs a speech model first: Settings › Server › Speech Recognition."
            : "The server has no speech recognition (whisper.cpp) installed."
        )
        .foregroundStyle(.secondary)
      } else if let job = speech?.job, job.isRunning {
        VStack(alignment: .leading, spacing: 6) {
          Text(job.kind == "sync" ? "Syncing to Speech" : "Writing Subtitles from Speech")
          if job.state == "listening", !job.pausedForPlayback {
            ProgressView(value: job.progress)
          }
          Text(job.statusText).font(.footnote).foregroundStyle(.secondary)
        }
        Button("Stop", role: .destructive) { Task { await cancelSpeech() } }
      } else if let tracks = audioTracks {
        if let job = speech?.job {
          Label(
            job.statusText,
            systemImage: job.state == "failed" ? "exclamationmark.triangle" : "checkmark.circle")
        }
        if tracks.isEmpty {
          Text("This title has no sound track.").foregroundStyle(.secondary)
        } else {
          Picker("Sound Track", selection: $audioTrack) {
            ForEach(tracks) { Text($0.label).tag($0.index) }
          }
          .onChange(of: audioTrack) { _, index in
            if let code = IOSSubtitleLanguages.code(
              forTrack: tracks.first { $0.index == index }?.language)
            {
              spokenLanguage = code
            }
          }
          Picker("Spoken Language", selection: $spokenLanguage) {
            ForEach(IOSSubtitleLanguages.choices, id: \.self) {
              Text(IOSSubtitleLanguages.name($0)).tag($0)
            }
          }
          Button("Create Subtitles from Speech") {
            Task {
              await startSpeech(
                IOSStartSpeechRequest(
                  kind: "create", language: spokenLanguage, audioIndex: audioTrack))
            }
          }
          .accessibilityIdentifier("subtitles-speech-create")
          if !subtitleTracks.isEmpty {
            Picker("Subtitles to Sync", selection: $syncTrack) {
              ForEach(subtitleTracks, id: \.index) { track in
                Text(
                  track.title ?? track.language.map(IOSSubtitleLanguages.name)
                    ?? "Track \(track.index + 1)"
                )
                .tag(track.index)
              }
            }
            Button("Sync to Speech") {
              let track = subtitleTracks.first { $0.index == syncTrack }
              let language = IOSSubtitleLanguages.code(forTrack: track?.language) ?? spokenLanguage
              Task {
                await startSpeech(
                  IOSStartSpeechRequest(
                    kind: "sync", language: language, audioIndex: audioTrack,
                    subtitleIndex: syncTrack))
              }
            }
            .disabled(!subtitleTracks.contains { $0.index == syncTrack })
          }
        }
      } else {
        Button("Create or Sync Subtitles from Speech…") { Task { await loadTracks() } }
          .disabled(working)
          .accessibilityIdentifier("subtitles-speech")
      }
    } header: {
      Text("From Speech")
    } footer: {
      Text(
        "The server listens to a sound track in the background and writes subtitles from what is said, or moves existing subtitles so they fit the speech. It pauses while anyone watches; the sound is never stored."
      )
    }
  }

  // MARK: Actions

  private func load() async {
    let id = mediaID
    downloaded = (try? await admin.run { try await $0.downloadedSubtitles(id: id) }) ?? downloaded
    if !providerLoaded {
      provider = try? await admin.run { try await $0.subtitleProvider() }
      providerLoaded = true
      language = IOSSubtitleLanguages.first(provider)
    }
    if model.capabilities?.supportsServerSpeech == true {
      speech = try? await admin.run { try await $0.mediaSpeech(id: id) }
    }
  }

  private func search() async {
    working = true
    defer { working = false }
    error = nil
    results = nil
    let id = mediaID
    let code = language
    do {
      results = try await admin.run { try await $0.searchSubtitles(id: id, language: code) }
    } catch is CancellationError {
    } catch {
      self.error = message(error)
    }
  }

  private func download(_ candidate: IOSSubtitleCandidate) async {
    working = true
    defer { working = false }
    error = nil
    let id = mediaID
    let request = candidate.download
    do {
      let saved = try await admin.run { try await $0.downloadSubtitle(id: id, request) }
      downloaded.removeAll { $0.id == saved.id }
      downloaded.append(saved)
      results = nil
    } catch is CancellationError {
    } catch {
      self.error = message(error)
    }
  }

  private func remove(_ subtitle: IOSDownloadedSubtitle) async {
    let id = mediaID
    do {
      try await admin.run { try await $0.removeSubtitle(id: id, subtitle: subtitle.id) }
      downloaded.removeAll { $0.id == subtitle.id }
    } catch is CancellationError {
    } catch {
      self.error = message(error)
    }
  }

  private func loadTracks() async {
    working = true
    defer { working = false }
    let id = mediaID
    do {
      let tracks = try await admin.run { try await $0.speechTracks(id: id) }
      let chosen = tracks.audio.first(where: \.isDefault) ?? tracks.audio.first
      audioTrack = chosen?.index ?? 0
      spokenLanguage = IOSSubtitleLanguages.code(forTrack: chosen?.language) ?? "en"
      subtitleTracks = tracks.subtitles
      syncTrack = tracks.subtitles.first?.index ?? -1
      audioTracks = tracks.audio
    } catch is CancellationError {
    } catch {
      self.error = message(error)
    }
  }

  private func startSpeech(_ request: IOSStartSpeechRequest) async {
    let id = mediaID
    do {
      speech = try await admin.run { try await $0.startMediaSpeech(id: id, request) }
      audioTracks = nil
    } catch is CancellationError {
    } catch {
      self.error = message(error)
    }
  }

  private func cancelSpeech() async {
    let id = mediaID
    try? await admin.run { try await $0.cancelMediaSpeech(id: id) }
    speech = try? await admin.run { try await $0.mediaSpeech(id: id) }
  }

  /// Follows the server's job while it runs; its subtitles appear in the list when it is done.
  private func followSpeech() async {
    let id = mediaID
    while speech?.job?.isRunning == true, !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      guard let client = model.client else { return }
      speech = try? await client.mediaSpeech(id: id)
      if speech?.job?.isRunning != true {
        downloaded = (try? await client.downloadedSubtitles(id: id)) ?? downloaded
      }
    }
  }

  private func message(_ error: Error) -> String {
    if let failure = error as? IOSCoreError, failure.problemCode == "subtitle_quota_reached" {
      return
        "Today's OpenSubtitles downloads are used up. Try again tomorrow, or add an OpenSubtitles account in Settings › Metadata for more."
    }
    return IOSAdministrationModel.message(error)
  }
}
