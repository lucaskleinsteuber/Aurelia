import SwiftUI
import UniformTypeIdentifiers

/// Settings › Server: the owner's overview and the server's own features, as on the Mac.
struct IOSAdminServerView: View {
  struct Overview: Sendable {
    let status: IOSServerStatus
    let health: IOSServerHealth
    let capabilities: IOSServerCapabilities?
    let configuration: IOSServerConfiguration?
  }

  var body: some View {
    IOSAdminLoader { client in
      async let status = client.serverStatus()
      async let health = client.serverHealth()
      async let capabilities = try? client.serverCapabilities()
      async let configuration = try? client.serverSettings()
      return Overview(
        status: try await status, health: try await health,
        capabilities: await capabilities, configuration: await configuration)
    } content: { overview, reload in
      IOSAdminServerContent(overview: overview, reload: reload)
    }
    .navigationTitle("Server")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminServerContent: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let overview: IOSAdminServerView.Overview
  let reload: () async -> Void
  @State private var confirmation: IOSAdminConfirmation?

  private var canRestart: Bool {
    overview.capabilities?.nativeHostOperations == true
      || overview.capabilities?.linuxPackage == true
  }

  var body: some View {
    let status = overview.status
    Form {
      Section("Your Server") {
        LabeledContent("Status", value: status.readiness?.state.capitalized ?? status.state.capitalized)
        LabeledContent("Version", value: status.version)
        if let location = overview.capabilities?.location {
          LabeledContent("Where", value: location)
        }
        LabeledContent("Profiles", value: "\(status.users)")
        LabeledContent("Storage Locations", value: "\(status.libraries)")
        LabeledContent("Playing Now", value: "\(status.activeStreams)")
        if canRestart {
          Button("Restart Server…") {
            confirmation = IOSAdminConfirmation(
              title: "Restart the server?",
              message: "Everything playing stops for a moment. Devices reconnect by themselves.",
              action: "Restart"
            ) {
              Task { await admin.perform("Restarting the server…") { _ = try await $0.restartServer() } }
            }
          }
          .accessibilityIdentifier("admin-restart")
        }
      }
      if let components = status.readiness?.components.filter({ $0.state != "ready" && $0.state != "ok" }),
        !components.isEmpty
      {
        Section("Needs Attention") {
          ForEach(components) { component in
            LabeledContent(component.title, value: component.detail)
          }
        }
      }
      IOSServerHealthSection(health: overview.health)
      if let configuration = overview.configuration {
        Section {
          IOSPolicyToggle(configuration: configuration, key: "pairingEnabled", label: "Allow New Devices")
          IOSPolicyToggle(
            configuration: configuration, key: "automaticBackupsEnabled", label: "Automatic Backups")
          Button("Back Up Now") {
            Task { await admin.perform("Backing up the database…") { try await $0.createBackup() } }
          }
          .accessibilityIdentifier("admin-backup-now")
        } header: {
          Text("Devices and Backups")
        } footer: {
          Text("New devices still need a code from you. Backups keep the database, never videos.")
        }
      }
      Section("Features") {
        NavigationLink("Scrub Previews") { IOSAdminScrubPreviewsView() }
        NavigationLink("Intros and Credits") { IOSAdminSegmentsView() }
        NavigationLink("Speech Recognition") { IOSAdminSpeechView() }
        NavigationLink("Video Conversion") { IOSAdminTranscodingView() }
      }
      Section {
        NavigationLink("Server Details and Network") {
          IOSAdminDetailsView(status: status, configuration: overview.configuration)
        }
        if let configuration = overview.configuration {
          NavigationLink("Sign-In and Streaming Limits") {
            IOSAdminPolicyView(title: "Limits", groups: [.limits], configuration: configuration)
          }
          NavigationLink("Library Maintenance") {
            IOSAdminPolicyView(
              title: "Library Maintenance", groups: [.maintenance], configuration: configuration,
              toggles: ["monitoringEnabled"])
          }
        }
        NavigationLink("Background Jobs") { IOSAdminJobsView() }
        NavigationLink("Backups") {
          IOSAdminBackupsView(
            configuration: overview.configuration,
            canRestore: canRestart, encrypted: overview.capabilities?.encryptedBackups != false)
        }
        NavigationLink("Diagnostics") { IOSAdminDiagnosticsView(configuration: overview.configuration) }
      } header: {
        Text("Advanced")
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
  }
}

/// One switch of the owner's server policy, saved on change.
private struct IOSPolicyToggle: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let configuration: IOSServerConfiguration
  let key: String
  let label: String
  @State private var value: Bool?

  var body: some View {
    Toggle(
      label,
      isOn: Binding(
        get: { value ?? configuration.stored[key]?.bool ?? false },
        set: { newValue in
          value = newValue
          let draft = IOSServerPolicy.draft(stored: configuration.stored, switches: [key: newValue])
          Task {
            let saved = await admin.perform {
              _ = try await $0.saveServerSettings(draft.draft)
            }
            if !saved { value = nil }
          }
        }))
  }
}

/// The health card: uptime, space, what runs and the last problems.
struct IOSServerHealthSection: View {
  let health: IOSServerHealth

  var body: some View {
    Section("Server Health") {
      LabeledContent("Running For", value: IOSAdminText.uptime(health.uptimeSeconds))
      LabeledContent("Free Space", value: IOSAdminText.bytes(health.freeDiskBytes))
      LabeledContent("Database", value: IOSAdminText.bytes(health.databaseBytes))
      LabeledContent("Streams", value: "\(health.activeStreams)")
      LabeledContent("Live Conversions", value: "\(health.activeLiveConversions)")
      LabeledContent("Offline Titles", value: "\(health.offlineMediaCount)")
      LabeledContent(
        "Scrub Previews",
        value:
          "\(health.scrubPreviewTitleCount) titles · \(IOSAdminText.bytes(health.scrubPreviewBytes))")
      if let scan = health.lastScan {
        LabeledContent(
          "Last Scan",
          value:
            "\(IOSAdminText.jobState(scan.state)) · \(IOSAdminFormat.relative(scan.completedAt ?? scan.startedAt))"
        )
      }
      let jobs = health.backgroundJobs
      LabeledContent(
        "Background Jobs",
        value: "\(jobs.activeScans + jobs.activeMetadataJobs + jobs.activeScrubPreviewJobs)")
      if let backup = health.backup {
        LabeledContent("Backups", value: Self.backupSummary(backup))
      }
      if health.recentIssues.isEmpty {
        Label("No recent problems", systemImage: "checkmark.circle").foregroundStyle(.secondary)
      } else {
        DisclosureGroup("Recent Problems (\(health.recentIssues.count))") {
          ForEach(health.recentIssues.prefix(20)) { issue in
            VStack(alignment: .leading, spacing: 2) {
              Text(IOSAdminText.event(issue.code))
              Text(IOSAdminFormat.date(issue.at)).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  static func backupSummary(_ backup: IOSServerHealthBackup) -> String {
    if backup.lastAttemptFailed { return "Last Failed" }
    if backup.totalBackups == 0 { return backup.enabled ? "Scheduled" : "Off" }
    return "\(backup.totalBackups) · \(IOSAdminText.bytes(backup.totalBackupBytes))"
  }
}

/// Server details and its network, which is changed on the computer the server runs on.
private struct IOSAdminDetailsView: View {
  let status: IOSServerStatus
  let configuration: IOSServerConfiguration?

  var body: some View {
    IOSAdminForm(title: "Details and Network") {
      Section("Server") {
        LabeledContent("Version", value: status.version)
        LabeledContent("Database", value: IOSAdminText.bytes(status.databaseBytes))
        LabeledContent("Certificate Valid Until", value: IOSAdminFormat.date(status.certificateExpiresAt))
      }
      Section {
        if let active = configuration?.active {
          LabeledContent("Name", value: active.serverName)
          LabeledContent("Home Network Access", value: active.lanAccessEnabled ? "On" : "Off")
          LabeledContent("HTTPS Port", value: "\(active.lanHttpsPort)")
        }
        if let bonjour = configuration?.stored["bonjourEnabled"]?.bool {
          LabeledContent("Found Automatically (Bonjour)", value: bonjour ? "On" : "Off")
        }
        ForEach(status.networkAddresses, id: \.self) { address in
          Text(address).font(.callout.monospaced()).textSelection(.enabled)
        }
        if configuration?.restartRequired == true {
          Label("A restart applies the saved network settings.", systemImage: "arrow.clockwise")
            .foregroundStyle(.orange)
        }
      } header: {
        Text("Network")
      } footer: {
        Text(
          "Change the network in Aurelia on the Mac or Linux computer the server runs on: a change can cut this \(IOSDesign.deviceName) off, and there it is undone by itself after 60 seconds if no device reconnects."
        )
      }
    }
  }
}

/// Whole-number settings of one or more policy groups, saved together.
struct IOSAdminPolicyView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dismiss) private var dismiss
  let title: String
  let groups: [IOSPolicyField.Group]
  let configuration: IOSServerConfiguration
  var toggles: [String] = []
  @State private var numbers: [String: Int] = [:]
  @State private var switches: [String: Bool] = [:]

  private var draft: (draft: [String: IOSJSONValue], problem: String?) {
    IOSServerPolicy.draft(stored: configuration.stored, numbers: numbers, switches: switches)
  }

  var body: some View {
    IOSAdminForm(title: title) {
      if !toggles.isEmpty {
        Section {
          ForEach(toggles, id: \.self) { key in
            Toggle(
              IOSServerPolicy.toggles.first { $0.key == key }?.label ?? key,
              isOn: Binding(
                get: { switches[key] ?? configuration.stored[key]?.bool ?? false },
                set: { switches[key] = $0 }))
          }
        }
      }
      ForEach(groups, id: \.self) { group in
        Section {
          ForEach(IOSServerPolicy.fields.filter { $0.group == group }) { field in
            if let stored = IOSServerPolicy.value(configuration.stored, field.key) {
              let value = numbers[field.key] ?? stored
              Stepper(
                value: Binding(get: { value }, set: { numbers[field.key] = $0 }),
                in: field.range, step: field.step
              ) {
                LabeledContent(field.label) {
                  Text(field.unit == ":00" ? String(format: "%02d:00", value) : "\(value) \(field.unit)")
                    .monospacedDigit()
                }
              }
            }
          }
        } header: {
          Text(Self.groupTitle(group))
        }
      }
      if let problem = draft.problem {
        Section { Text(problem).foregroundStyle(.orange) }
      }
    }
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          let value = draft.draft
          Task {
            if await admin.perform("Saving…", { _ = try await $0.saveServerSettings(value) }) {
              dismiss()
            }
          }
        }
        .disabled(draft.problem != nil || (numbers.isEmpty && switches.isEmpty))
      }
    }
  }

  static func groupTitle(_ group: IOSPolicyField.Group) -> String {
    switch group {
    case .limits: "Sign-In and Streaming"
    case .maintenance: "Maintenance"
    case .backups: "Automatic Backups"
    case .events: "Events"
    }
  }
}

/// Scrub previews: small still pictures for scrubbing, optional and with a size cap.
private struct IOSAdminScrubPreviewsView: View {
  var body: some View {
    IOSAdminLoader { try await $0.serverScrubPreviews() } content: { settings, reload in
      IOSAdminScrubPreviewsForm(settings: settings, reload: reload)
    }
    .navigationTitle("Scrub Previews")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminScrubPreviewsForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let settings: IOSScrubPreviewSettings
  let reload: () async -> Void
  @State private var draft: IOSUpdateScrubPreviews?
  @State private var confirmation: IOSAdminConfirmation?

  private var current: IOSUpdateScrubPreviews {
    draft
      ?? .init(
        mode: settings.mode, intervalSeconds: settings.intervalSeconds,
        storageCapMegabytes: settings.storageCapMegabytes)
  }

  var body: some View {
    Form {
      if !settings.available {
        Section { Text("This server can’t make scrub previews.").foregroundStyle(.secondary) }
      } else {
        Section {
          Picker("Make Previews", selection: binding(\.mode)) {
            Text("Off").tag("off")
            Text("While Playing").tag("onDemand")
            Text("Ahead of Time").tag("background")
            if !["off", "onDemand", "background"].contains(current.mode) {
              Text(current.mode.capitalized).tag(current.mode)
            }
          }
          Picker("One Picture Every", selection: binding(\.intervalSeconds)) {
            ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
            if ![5, 10, 15, 30].contains(current.intervalSeconds) {
              Text("\(current.intervalSeconds) seconds").tag(current.intervalSeconds)
            }
          }
          Stepper(value: binding(\.storageCapMegabytes), in: 100...100_000, step: 100) {
            LabeledContent("Space at Most", value: "\(current.storageCapMegabytes) MB")
          }
        } footer: {
          Text(
            "Small still pictures show where you are when scrubbing. They are kept in the server’s data folder and never larger than the space set here. Video is never stored."
          )
        }
        Section("Stored") {
          LabeledContent("Titles", value: "\(settings.storedTitleCount)")
          LabeledContent("Space", value: IOSAdminText.bytes(settings.storedBytes))
          LabeledContent(
            "Progress",
            value: "\(settings.completedCount) of \(settings.totalScheduledCount) · \(settings.pendingCount) waiting")
          if settings.pausedForPlayback {
            Label("Paused while someone watches", systemImage: "pause.circle")
              .foregroundStyle(.secondary)
          }
          Button("Remove All Previews…", role: .destructive) {
            confirmation = IOSAdminConfirmation(
              title: "Remove all scrub previews?",
              message: "They are made again if previews stay on.", action: "Remove"
            ) {
              Task { await admin.perform("Removing previews…") { _ = try await $0.deleteServerScrubPreviews() } }
            }
          }
          .disabled(settings.storedTitleCount == 0)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          let value = current
          Task {
            if await admin.perform("Saving…", { _ = try await $0.saveServerScrubPreviews(value) }) {
              draft = nil
            }
          }
        }
        .disabled(draft == nil)
      }
    }
  }

  private func binding<Value>(_ path: WritableKeyPath<IOSUpdateScrubPreviews, Value>) -> Binding<Value> {
    Binding(
      get: { current[keyPath: path] },
      set: { value in
        var next = current
        next[keyPath: path] = value
        draft = next
      })
  }
}

/// Intros and credits: the server finds them by comparing episodes; only times are stored.
private struct IOSAdminSegmentsView: View {
  struct Overview: Sendable {
    let settings: IOSSegmentSettings
    let series: [IOSSegmentSeries]
  }

  var body: some View {
    IOSAdminLoader { client in
      async let settings = client.serverSegments()
      async let series = (try? client.segmentSeries()) ?? []
      return Overview(settings: try await settings, series: await series)
    } content: { overview, reload in
      IOSAdminSegmentsForm(overview: overview, reload: reload)
    }
    .navigationTitle("Intros and Credits")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminSegmentsForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let overview: IOSAdminSegmentsView.Overview
  let reload: () async -> Void

  var body: some View {
    let settings = overview.settings
    Form {
      if !settings.available {
        Section { Text("This server can’t examine intros and credits.").foregroundStyle(.secondary) }
      } else {
        Section {
          Toggle(
            "Find Intros and Credits",
            isOn: Binding(
              get: { settings.enabled },
              set: { enabled in
                Task {
                  await admin.perform {
                    _ = try await $0.saveServerSegments(enabled: enabled, usePictures: settings.usePictures)
                  }
                }
              }))
          if let pictures = settings.usePictures {
            Toggle(
              "Also Compare Pictures for Credits",
              isOn: Binding(
                get: { pictures },
                set: { value in
                  Task {
                    await admin.perform {
                      _ = try await $0.saveServerSegments(enabled: settings.enabled, usePictures: value)
                    }
                  }
                }))
          }
        } footer: {
          Text(
            "The server compares the sound of a season’s episodes, and small grey pictures of the last minutes for credits, in the background while nobody watches. Only the times are stored."
          )
        }
        Section("Progress") {
          ProgressView(value: settings.progress)
          LabeledContent("Episodes Examined", value: "\(settings.analyzedCount + settings.noResultCount)")
          LabeledContent("Waiting", value: "\(settings.pendingCount)")
          if let movies = settings.movieCount {
            LabeledContent("Movies with Credits", value: "\(settings.moviesWithCredits ?? 0) of \(movies)")
          }
          if let title = settings.currentTitle {
            LabeledContent("Now", value: [title, settings.currentStep].compactMap { $0 }.joined(separator: " · "))
          }
          if settings.pausedForPlayback {
            Label("Paused while someone watches", systemImage: "pause.circle").foregroundStyle(.secondary)
          }
          Button("Examine Everything Again") {
            Task { await admin.perform("Starting…") { _ = try await $0.reanalyzeSegments() } }
          }
          if settings.movieCount != nil {
            Button("Examine All Movies Again") {
              Task { await admin.perform("Starting…") { _ = try await $0.reanalyzeSegments(movies: true) } }
            }
          }
        }
        if !overview.series.isEmpty {
          Section("Series") {
            ForEach(overview.series) { series in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(series.title)
                  Text(
                    "\(series.withIntro) intros · \(series.withCredits) credits of \(series.episodeCount)\(series.pendingCount > 0 ? " · \(series.pendingCount) waiting" : "")"
                  )
                  .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Again") {
                  let id = series.seriesId
                  Task { await admin.perform("Starting…") { _ = try await $0.reanalyzeSegments(seriesId: id) } }
                }
                .buttonStyle(.borderless)
              }
            }
          }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
  }
}

/// Speech recognition: the model the server uses to write and sync subtitles.
private struct IOSAdminSpeechView: View {
  var body: some View {
    IOSAdminLoader { try await $0.serverSpeech() } content: { speech, reload in
      IOSAdminSpeechForm(speech: speech, reload: reload)
    }
    .navigationTitle("Speech Recognition")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminSpeechForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let speech: IOSServerSpeech
  let reload: () async -> Void
  @State private var confirmation: IOSAdminConfirmation?

  var body: some View {
    Form {
      if !speech.available {
        Section {
          Text("This server has no speech recognition. On Linux, install whisper.cpp from your distribution.")
            .foregroundStyle(.secondary)
        }
      } else {
        Section {
          if let model = speech.model {
            LabeledContent(
              "Model", value: "\(speech.models.first { $0.name == model }?.label ?? model) · \(IOSAdminText.bytes(speech.modelBytes))")
            Button("Remove Model…", role: .destructive) {
              confirmation = IOSAdminConfirmation(
                title: "Remove the speech model?",
                message: "Subtitles already written stay. Download a model again to write new ones.",
                action: "Remove"
              ) {
                Task { await admin.perform("Removing…") { _ = try await $0.removeSpeechModel() } }
              }
            }
          } else if let download = speech.downloading {
            ProgressView(
              value: Double(download.receivedBytes), total: Double(max(download.totalBytes, 1))
            ) {
              Text("Downloading \(download.name)…")
            }
          } else {
            ForEach(speech.models) { choice in
              Button {
                let name = choice.name
                Task { await admin.perform("Starting the download…") { _ = try await $0.downloadSpeechModel(name) } }
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text("Download \(choice.label) · \(IOSAdminText.bytes(choice.bytes))")
                  Text(choice.description).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
          if let error = speech.downloadError { Text(error).foregroundStyle(.orange) }
        } footer: {
          Text(
            "The server writes subtitles from speech and syncs subtitles to speech with this model, pausing while anyone watches. Sound and words stay in memory; only finished subtitles are stored."
          )
        }
        if !speech.jobs.isEmpty {
          Section("Now") {
            ForEach(speech.jobs, id: \.mediaId) { job in
              VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                ProgressView(value: job.progress)
                Text(job.pausedForPlayback ? "Paused while someone watches" : job.state.capitalized)
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
    .task(id: speech.downloading?.receivedBytes) {
      guard speech.downloading != nil else { return }
      try? await Task.sleep(for: .seconds(2))
      await reload()
    }
  }
}

/// Video conversion: the encoder and what converts now.
private struct IOSAdminTranscodingView: View {
  var body: some View {
    IOSAdminLoader { try await $0.serverTranscoding() } content: { status, reload in
      Form {
        Section {
          LabeledContent("Encoder", value: status.encoderSummary)
          LabeledContent("Converting Now", value: "\(status.runningConversions) of \(status.videoLimit)")
          if let hint = status.hint { Text(hint).foregroundStyle(.orange) }
        } footer: {
          Text("Converted video stays in memory while it plays and is never stored.")
        }
        if !status.sessions.isEmpty {
          Section("Playing") {
            ForEach(Array(status.sessions.enumerated()), id: \.offset) { _, session in
              VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                Text(
                  "\(session.quality) · \(session.converting ? session.speed.map { String(format: "%.1f× real time", $0) } ?? "starting" : "ready")"
                )
                .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .refreshable { await reload() }
    }
    .navigationTitle("Video Conversion")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Recent scans and metadata jobs, with Retry for a failed one.
private struct IOSAdminJobsView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel

  var body: some View {
    IOSAdminLoader { try await $0.serverJobs() } content: { jobs, reload in
      Form {
        Section("Scans") {
          if jobs.scans.isEmpty { Text("No scans yet").foregroundStyle(.secondary) }
          ForEach(jobs.scans) { scan in
            VStack(alignment: .leading, spacing: 2) {
              Text("\(scan.stateTitle) · \(IOSAdminFormat.relative(scan.completedAt ?? scan.startedAt ?? scan.createdAt))")
              Text("\(scan.addedFiles) added · \(scan.updatedFiles) updated · \(scan.missingFiles) missing")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        Section("Movie and TV Information") {
          if jobs.metadata.isEmpty { Text("No jobs yet").foregroundStyle(.secondary) }
          ForEach(jobs.metadata) { job in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(job.summary)
                Text(IOSAdminFormat.relative(job.completedAt ?? job.createdAt)).font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if job.state == "failed" || job.state == "interrupted" {
                Button("Retry") {
                  let id = job.id
                  Task { await admin.perform { try await $0.retryMetadataJob(id: id) } }
                }
                .buttonStyle(.borderless)
              }
            }
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .refreshable { await reload() }
    }
    .navigationTitle("Background Jobs")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Backups: the list, checking one, the schedule, and an encrypted backup to save or restore.
private struct IOSAdminBackupsView: View {
  let configuration: IOSServerConfiguration?
  let canRestore: Bool
  let encrypted: Bool

  var body: some View {
    IOSAdminLoader { try await $0.serverBackups() } content: { backups, reload in
      IOSAdminBackupsForm(
        backups: backups, configuration: configuration, canRestore: canRestore,
        encrypted: encrypted, reload: reload)
    }
    .navigationTitle("Backups")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminBackupsForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @EnvironmentObject private var model: IOSAppModel
  let backups: [IOSServerBackup]
  let configuration: IOSServerConfiguration?
  let canRestore: Bool
  let encrypted: Bool
  let reload: () async -> Void
  @State private var passphrase = ""
  @State private var repeated = ""
  @State private var exported: URL?
  @State private var choosingRestore = false
  @State private var restoreConfirmed = false
  @State private var acceptOtherServer = false
  @State private var prepared: IOSPreparedRestore?
  @State private var message: String?
  @State private var confirmation: IOSAdminConfirmation?

  var body: some View {
    Form {
      Section("On the Server") {
        if backups.isEmpty { Text("No backups yet").foregroundStyle(.secondary) }
        ForEach(backups) { backup in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(backup.kind.capitalized)
              Text("\(IOSAdminFormat.date(backup.createdAt)) · \(IOSAdminText.bytes(backup.bytes))")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check") {
              let name = backup.name
              Task {
                if let valid = await admin.value("Checking the backup…", { try await $0.verifyBackup(name: name) }) {
                  message = valid ? "The backup is complete and readable." : "The backup is damaged."
                }
              }
            }
            .buttonStyle(.borderless)
          }
        }
        Button("Back Up Now") {
          Task { await admin.perform("Backing up the database…") { try await $0.createBackup() } }
        }
      }
      if let configuration {
        Section {
          NavigationLink("Schedule and Keeping") {
            IOSAdminPolicyView(
              title: "Automatic Backups", groups: [.backups], configuration: configuration,
              toggles: ["automaticBackupsEnabled"])
          }
        }
      }
      if encrypted {
        Section {
          SecureField("Passphrase (at least 12 characters)", text: $passphrase)
            .textContentType(.newPassword)
          SecureField("Repeat Passphrase", text: $repeated).textContentType(.newPassword)
          Button("Save Encrypted Backup") {
            let phrase = passphrase
            let destination = FileManager.default.temporaryDirectory
              .appendingPathComponent("Aurelia-Server.aureliabackup")
            Task {
              if await admin.perform("Encrypting the backup…", {
                try await $0.exportEncryptedBackup(passphrase: phrase, to: destination)
              }) {
                exported = destination
                passphrase = ""
                repeated = ""
              }
            }
          }
          .disabled(passphrase.count < 12 || passphrase != repeated)
          if let exported {
            ShareLink(item: exported) {
              Label("Save or Share the Backup…", systemImage: "square.and.arrow.up")
            }
          }
        } header: {
          Text("Encrypted Full Backup")
        } footer: {
          Text(
            "Includes the database, configuration, server identity and your imported pictures. Videos are never included. Keep the passphrase safe; it can’t be recovered."
          )
        }
        if canRestore {
          Section {
            Toggle("Restoring signs out every device", isOn: $restoreConfirmed)
            Toggle("Allow a backup from another server", isOn: $acceptOtherServer)
            Button("Choose Backup and Check…") { choosingRestore = true }
              .disabled(passphrase.count < 12 || !restoreConfirmed)
            if let prepared {
              Button("Restore and Restart…", role: .destructive) {
                confirmation = IOSAdminConfirmation(
                  title: "Restore this backup?",
                  message:
                    "The server replaces its data with the backup and restarts. Every device signs in again.",
                  action: "Restore"
                ) {
                  let id = prepared.id
                  Task {
                    if await admin.perform("Restoring…", { try await $0.applyRestore(id: id) }) {
                      self.prepared = nil
                      message = "Restore requested. Sign in again after the server restarts."
                    }
                  }
                }
              }
            }
          } header: {
            Text("Restore")
          } footer: {
            Text("Enter the backup’s passphrase above. The backup is checked first; nothing changes until you restore.")
          }
        }
      }
      if let message { Section { Text(message) } }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
    .fileImporter(isPresented: $choosingRestore, allowedContentTypes: [.data]) { result in
      guard case .success(let file) = result else { return }
      let phrase = passphrase
      let other = acceptOtherServer
      Task {
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        if let result = await admin.value("Sending and checking the backup…", {
          try await $0.prepareRestore(from: file, passphrase: phrase, acceptDifferentIdentity: other)
        }) {
          prepared = result
          passphrase = ""
          repeated = ""
          message = "The backup was checked. Nothing has changed yet."
        }
      }
    }
    .onDisappear {
      passphrase = ""
      repeated = ""
      if let exported { try? FileManager.default.removeItem(at: exported) }
    }
  }
}

/// Diagnostics: recent events and a cleaned report to share.
private struct IOSAdminDiagnosticsView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let configuration: IOSServerConfiguration?
  @State private var report: URL?

  var body: some View {
    IOSAdminLoader { try await $0.serverDiagnostics() } content: { events, reload in
      Form {
        Section {
          Button("Prepare Diagnostics Report") {
            let destination = FileManager.default.temporaryDirectory
              .appendingPathComponent("Aurelia-Diagnostics.json")
            Task {
              if let data = await admin.value("Preparing the report…", { try await $0.serverDiagnosticsReport() }) {
                try? data.write(to: destination, options: .atomic)
                report = destination
              }
            }
          }
          if let report {
            ShareLink(item: report) { Label("Share Report…", systemImage: "square.and.arrow.up") }
          }
        } footer: {
          Text("The report holds event codes, versions and counts: no passwords, tokens, file paths or titles.")
        }
        if let configuration {
          Section {
            NavigationLink("Keeping Events") {
              IOSAdminPolicyView(title: "Events", groups: [.events], configuration: configuration)
            }
          }
        }
        Section("Recent Events") {
          if events.isEmpty { Text("No events").foregroundStyle(.secondary) }
          ForEach(events.prefix(200)) { event in
            VStack(alignment: .leading, spacing: 2) {
              Text(IOSAdminText.event(event.code))
              Text("\(IOSAdminFormat.date(event.at)) · \(event.severity.capitalized)")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .refreshable { await reload() }
    }
    .navigationTitle("Diagnostics")
    .navigationBarTitleDisplayMode(.inline)
    .onDisappear { if let report { try? FileManager.default.removeItem(at: report) } }
  }
}
