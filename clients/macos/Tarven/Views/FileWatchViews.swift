import SwiftUI

/// Server settings: the file watch, whether it runs, how thoroughly and how far it is.
struct ServerFileWatchEditor: View {
  @EnvironmentObject private var model: AppModel
  let client: APIClient
  @State private var stored: FileCheckSettings?
  @State private var working = false
  @State private var refreshRound = 0
  @State private var message: String?
  @State private var loadError: String?

  private static let description =
    "The server reads every file in the background, only while nobody watches, and tells you in Library Health when one is damaged, can't be read or changed by itself. Files are only read, never changed."

  var body: some View {
    Group {
      if let stored {
        TarvenSettingsSection(
          "File Watch", symbol: "checkmark.shield", description: Self.description
        ) {
          VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Toggle(
                "Watch Files",
                isOn: Binding(get: { stored.enabled }, set: { save(.init(enabled: $0)) })
              )
              .accessibilityIdentifier("server-file-watch-enabled")
              Text("Off until you turn it on. The first round reads the whole library once.")
                .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
              Picker(
                "How Thoroughly",
                selection: Binding(
                  get: { FileCheckDepth(rawValue: stored.depth) ?? .container },
                  set: { save(.init(enabled: stored.enabled, depth: $0.rawValue)) })
              ) {
                ForEach(FileCheckDepth.allCases) { depth in
                  Text(depth.title).tag(depth)
                    .selectionDisabled(!stored.canInspect && depth != .read)
                }
              }
              .pickerStyle(.menu)
              .fixedSize()
              .accessibilityIdentifier("server-file-watch-depth")
              Text(
                (FileCheckDepth(rawValue: stored.depth)?.detail ?? "")
                  + (stored.canInspect
                    ? "" : " This server has no FFmpeg, so it can only read every byte.")
              )
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
              Picker(
                "Read Again",
                selection: Binding(
                  get: { stored.recheckDays },
                  set: { save(.init(enabled: stored.enabled, recheckDays: $0)) })
              ) {
                ForEach(FileWatchText.recheckChoices, id: \.days) { choice in
                  Text(choice.title).tag(choice.days)
                }
              }
              .pickerStyle(.menu)
              .fixedSize()
              .accessibilityIdentifier("server-file-watch-recheck")
              Text(
                "Reads every file again in this rhythm and compares it with the first time, to find bit rot."
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
              if stored.enabled && stored.totalCount > 0 {
                ProgressView(value: stored.progress)
                  .accessibilityIdentifier("server-file-watch-progress")
              }
              Text(FileWatchText.status(stored))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("server-file-watch-status")
              if let current = FileWatchText.current(stored) {
                Label(current, systemImage: "doc.text.magnifyingglass")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            if working { ProgressView().controlSize(.small) }
            if let message = message ?? loadError { ErrorBanner(message: message, inline: true) }
          }
          .frame(maxWidth: .infinity, alignment: .leading).disabled(working)
        }
        .accessibilityIdentifier("server-file-watch")
      } else if let loadError {
        TarvenSettingsSection("File Watch", symbol: "checkmark.shield") {
          ErrorBanner(
            message: loadError, retry: { refreshRound += 1 }, retryDisabled: working, inline: true)
        }
      }
    }
    .task(id: "\(model.administrationGeneration)-\(refreshRound)") { await refreshWhileWorking() }
  }

  /// Loads now, then follows the progress every few seconds while files are still waiting.
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
        try await scope.request { try await client.serverFileChecks() }
      }
      loadError = nil
    } catch let failure as APIClientError where failure.httpStatus == 404 {
      // A server before 2.19.0 has no file watch.
      stored = nil
      loadError = nil
    } catch {
      loadError = scope.message(for: error)
    }
  }

  private func save(_ request: UpdateFileCheckSettingsRequest) {
    let scope = ServerAdministrationScope(model: model, generation: model.administrationGeneration)
    working = true
    message = nil
    Task {
      defer { working = false }
      do {
        stored = try await model.currentAdministration {
          try await scope.request { try await client.saveServerFileChecks(request) }
        }
        refreshRound += 1
      } catch {
        message = scope.message(for: error)
      }
    }
  }
}

/// Library Health › File Problems: the files the watch found a problem in.
struct FileProblemsPanel: View {
  @EnvironmentObject private var model: AppModel
  @State private var showsSetAside = false
  @State private var problems: [FileProblemSummary] = []
  @State private var loaded = false
  @State private var loading = false
  @State private var error: String?
  @State private var notice: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("File Problems").font(.headline)
      Text(
        "Files the file watch found a problem in. Play a title to check it, and replace a damaged file from a backup or a new copy; then choose Examine Again. Tarven never changes files."
      )
      .font(.caption).foregroundStyle(.secondary)
      Picker("Show", selection: $showsSetAside) {
        Text("Open Problems").tag(false)
        Text("Set Aside").tag(true)
      }
      .pickerStyle(.segmented)
      .fixedSize()
      .labelsHidden()
      if let error {
        ErrorBanner(
          message: error, retry: { Task { await load() } }, retryDisabled: loading, inline: true)
      }
      if let notice {
        Text(notice).font(.caption).foregroundStyle(.secondary)
      }
      if problems.isEmpty && error != nil {
        EmptyView()
      } else if (loading || !loaded) && problems.isEmpty {
        TarvenDelayedProgress()
          .frame(maxWidth: .infinity, minHeight: 200)
          .accessibilityLabel("Loading file problems")
      } else if problems.isEmpty {
        ContentUnavailableView(
          showsSetAside ? "Nothing Set Aside" : "No File Problems",
          systemImage: "checkmark.shield",
          description: Text(
            showsSetAside
              ? "No problem is set aside."
              : "No examined file has a problem. Turn on the file watch in the server settings to examine your files."
          )
        )
        .frame(maxWidth: .infinity, minHeight: 200)
      } else {
        ForEach(problems) { problem in row(problem) }
      }
    }
    .task(id: showsSetAside) { await load() }
    .accessibilityIdentifier("library-health-file-problems")
  }

  private func row(_ problem: FileProblemSummary) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: FileWatchText.problemSymbol(problem.state))
        .foregroundStyle(problem.state == "notice" ? Color.secondary : Color.orange)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 3) {
        Text("\(problem.title) · \(FileWatchText.problemTitle(problem.state))").font(
          .callout.weight(.semibold))
        Text(problem.fileName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if let detail = problem.detail {
          Text(detail).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        let facts = FileWatchText.facts(problem)
        if !facts.isEmpty {
          Text(facts).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 6) {
        Button("Examine Again") {
          act(done: "The file is examined again in the background.") {
            try await $0.recheckFile(mediaId: problem.mediaId)
          }
        }
        .help("Reads the file again from the start and keeps it as the new reference")
        Button(showsSetAside ? "Bring Back" : "Set Aside") {
          let ignored = !showsSetAside
          act(done: nil) {
            try await $0.setFileProblemIgnored(mediaId: problem.mediaId, ignored: ignored)
          }
        }
        .help(
          showsSetAside
            ? "Shows the problem with the open ones again"
            : "Keeps the problem out of the count, for a file you know about")
      }
      .controlSize(.small)
      .disabled(loading)
    }
    .padding(12)
    .background(
      .quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func load() async {
    guard let profile = model.profile else { return }
    loading = true
    defer { loading = false }
    do {
      problems = try await APIClient(profile: profile).fileProblems(ignored: showsSetAside)
      error = nil
      loaded = true
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func act(done: String?, _ work: @escaping @Sendable (APIClient) async throws -> Void) {
    guard let profile = model.profile else { return }
    Task {
      do {
        try await work(APIClient(profile: profile))
        notice = done
        await load()
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}

/// Library Health › Drives: what the drives with storage locations report about themselves.
struct DrivesPanel: View {
  @EnvironmentObject private var model: AppModel
  @State private var answer: DriveHealthResponse?
  @State private var loading = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Drives").font(.headline)
      Text(
        "How the drives with your storage locations are doing, as they report it themselves (SMART). Many USB cases and network shares don't report it."
      )
      .font(.caption).foregroundStyle(.secondary)
      if let error {
        ErrorBanner(
          message: error, retry: { Task { await load(refresh: false) } }, retryDisabled: loading,
          inline: true)
      }
      if let answer {
        if answer.drives.isEmpty {
          ContentUnavailableView(
            "No Storage Locations", systemImage: "externaldrive",
            description: Text("Add a storage location to see its drive here.")
          )
          .frame(maxWidth: .infinity, minHeight: 160)
        }
        ForEach(answer.drives) { drive in row(drive) }
        HStack {
          if let at = answer.checkedAt.flatMap(ServerDate.parse) {
            Text("Asked \(at.formatted(date: .abbreviated, time: .shortened))")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Ask Again") { Task { await load(refresh: true) } }.disabled(loading)
        }
      } else if error == nil {
        TarvenDelayedProgress()
          .frame(maxWidth: .infinity, minHeight: 160)
          .accessibilityLabel("Asking the drives")
      }
    }
    .task { await load(refresh: false) }
    .accessibilityIdentifier("library-health-drives")
  }

  private func row(_ drive: DriveHealthSummary) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(
        systemName: drive.state == "failing" || drive.state == "warning"
          ? "externaldrive.badge.exclamationmark" : "externaldrive"
      )
      .foregroundStyle(
        drive.state == "failing"
          ? Color.red : drive.state == "warning" ? Color.orange : Color.secondary
      )
      .frame(width: 22)
      VStack(alignment: .leading, spacing: 3) {
        Text("\(drive.name) · \(FileWatchText.driveTitle(drive.state))").font(
          .callout.weight(.semibold))
        Text(drive.libraries.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
        if let detail = drive.detail {
          Text(detail).font(.caption).foregroundStyle(
            drive.state == "failing" ? Color.red : Color.primary
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        let facts = FileWatchText.driveFacts(drive)
        if !facts.isEmpty {
          Text(facts).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(
      .quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func load(refresh: Bool) async {
    guard let profile = model.profile else { return }
    loading = true
    defer { loading = false }
    do {
      answer = try await APIClient(profile: profile).drives(refresh: refresh)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}
