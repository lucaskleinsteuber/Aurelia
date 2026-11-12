import SwiftUI

/// Server settings › Speech Recognition for the owner: whether whisper.cpp is there, the model to
/// download or remove (kept in the server's data folder, with its size), and the jobs running.
struct ServerSpeechEditor: View {
  @EnvironmentObject private var model: AppModel
  let client: APIClient
  @State private var settings: ServerSpeechSettings?
  @State private var choice = "small"
  @State private var message: String?
  @State private var confirmRemove = false

  var body: some View {
    Group {
      if let settings {
        AureliaSettingsSection(
          "Speech Recognition", symbol: "waveform",
          description:
            "The server writes subtitles from what is said, and moves existing subtitles so they fit the speech, with whisper.cpp on the server. Sound stays in memory; only the finished subtitles are kept."
        ) {
          VStack(alignment: .leading, spacing: 12) {
            if !settings.available {
              Text(
                "whisper.cpp isn't installed on this server. On Debian or Ubuntu: sudo apt install whisper.cpp. This Mac then still writes subtitles itself."
              )
              .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let download = settings.downloading {
              ProgressView(
                value: Double(download.receivedBytes), total: Double(max(download.totalBytes, 1))
              ) {
                Text("Downloading the \(download.name) model…")
              } currentValueLabel: {
                Text(
                  "\(ByteCountFormatter.string(fromByteCount: download.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file))"
                )
              }
              Button("Stop Download") { Task { await remove() } }
                .help("Stops the download and removes what was downloaded.")
            } else if let current = settings.model {
              LabeledContent(
                "Model",
                value:
                  "\(settings.models.first { $0.name == current }?.label ?? current) · \(ByteCountFormatter.string(fromByteCount: settings.modelBytes, countStyle: .file))"
              )
              Button("Remove Model…", role: .destructive) { confirmRemove = true }
                .help("Deletes the model from the server's data folder. Subtitles already written stay.")
            } else {
              Picker("Model", selection: $choice) {
                ForEach(settings.models) { option in
                  Text("\(option.label) · \(option.description)").tag(option.name)
                }
              }
              .pickerStyle(.radioGroup)
              Button("Download Model") { Task { await download() } }
                .help("Downloads the chosen model once from whisper.cpp's model page into the server's data folder.")
                .accessibilityIdentifier("server-speech-download")
            }
            if let error = settings.downloadError {
              Text(error).font(.caption).foregroundStyle(.orange)
            }
            ForEach(settings.jobs.filter(\.isRunning), id: \.mediaId) { job in
              ServerSpeechJobRow(job: job) { Task { await cancel(job) } }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Remove the speech model?", isPresented: $confirmRemove) {
          Button("Remove Model", role: .destructive) { Task { await remove() } }
        } message: {
          Text("Subtitles from speech then stay off until a model is downloaded again.")
        }
      }
    }
    .task(id: model.administrationGeneration) {
      while !Task.isCancelled {
        await load()
        try? await Task.sleep(for: .seconds(settings?.downloading != nil || settings?.jobs.contains(where: \.isRunning) == true ? 2 : 10))
      }
    }
  }

  private func load() async {
    do {
      settings = try await model.currentAdministration { try await client.serverSpeech() }
      message = nil
    } catch is CancellationError {
    } catch {
      message = error.localizedDescription
    }
  }

  private func download() async {
    await act { try await client.downloadSpeechModel(choice) }
  }

  private func remove() async {
    await act { try await client.removeSpeechModel() }
  }

  private func cancel(_ job: ServerSpeechJob) async {
    do {
      try await model.currentAdministration { try await client.cancelServerSpeech(mediaId: job.mediaId) }
      await load()
    } catch {
      message = error.localizedDescription
    }
  }

  private func act(_ action: @escaping @MainActor () async throws -> ServerSpeechSettings) async {
    do {
      settings = try await model.currentAdministration { try await action() }
      message = nil
    } catch {
      message = error.localizedDescription
    }
  }
}

/// One server job: what it does, how far it is, and Cancel.
struct ServerSpeechJobRow: View {
  let job: ServerSpeechJob
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(job.kind == .sync ? "Syncing \(job.title)" : "Listening to \(job.title)").lineLimit(1)
        Spacer()
        Button("Cancel", action: cancel)
          .help("Stops listening; nothing is saved.")
      }
      ProgressView(value: job.progress)
      Text(
        job.pausedForPlayback
          ? "Paused while someone watches." : job.state == .waiting ? "Waiting for the server…"
          : "\(Int((job.progress * 100).rounded())) % heard"
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }
}
