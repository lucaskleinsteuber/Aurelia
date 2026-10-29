import SwiftUI

enum LibraryHealthTab: String, CaseIterable, Identifiable, Sendable {
  case duplicates = "Duplicates"
  case offline = "Offline Titles"
  case unmatched = "Unmatched Metadata"
  case exclusions = "Excluded Items"

  var id: String { rawValue }
}

struct LibraryHealthView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var selectedTab: LibraryHealthTab = .duplicates

  // Duplicates State
  @State private var duplicateGroups: [DuplicateGroup] = []
  @State private var isLoadingDuplicates = false
  @State private var duplicateError: String?

  // Offline State
  @State private var offlineTitles: [OfflineTitleSummary] = []
  @State private var offlineDays: Int = 30
  @State private var isLoadingOffline = false
  @State private var offlineError: String?

  // Unmatched State
  @State private var unmatchedTitles: [UnmatchedTitleSummary] = []
  @State private var isLoadingUnmatched = false
  @State private var unmatchedError: String?
  @State private var matchingTarget: UnmatchedTitleSummary?

  // Exclusions State
  @State private var library: UUID?
  @State private var exclusions: [ExcludedMediaSummary] = []
  @State private var selectedExclusion: ExcludedMediaSummary?
  @State private var exclusionError: String?
  @State private var reimportTask: Task<Void, Never>?

  // Merge Confirmation State
  @State private var mergeSource: DuplicateItemSummary?
  @State private var mergeTarget: DuplicateItemSummary?
  @State private var showingMergeConfirmation = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Library Health & Maintenance", systemImage: "stethoscope")
          .font(.title2.bold())
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(20)

      Picker("Tab", selection: $selectedTab) {
        ForEach(LibraryHealthTab.allCases) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 20)
      .padding(.bottom, 16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          switch selectedTab {
          case .duplicates:
            duplicatesContent
          case .offline:
            offlineContent
          case .unmatched:
            unmatchedContent
          case .exclusions:
            exclusionsContent
          }
        }
        .padding(20)
      }
    }
    .frame(minWidth: 780, minHeight: 580)
    .background(AureliaBackdrop())
    .task(id: selectedTab) {
      await loadCurrentTab()
    }
    .confirmationDialog(
      "Merge duplicates?",
      isPresented: $showingMergeConfirmation,
      titleVisibility: .visible
    ) {
      Button("Merge into Preferred Version", role: .destructive) {
        if let s = mergeSource, let t = mergeTarget {
          Task { await executeMerge(source: s, target: t) }
        }
      }
    } message: {
      Text(
        "Viewing history, favorites, progress and collection memberships will be combined into the preferred version. The duplicate entry will be removed from Aurelia. Media files on disk are NEVER touched or deleted."
      )
    }
    .sheet(item: $matchingTarget) { target in
      MetadataMatchSheet(mediaId: target.id, title: target.title) {
        Task { await loadUnmatched() }
      }
      .environmentObject(model)
    }
    .accessibilityIdentifier("library-health-view")
  }

  // MARK: - Duplicates Content

  @ViewBuilder
  private var duplicatesContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Duplicate Titles")
        .font(.headline)
      Text(
        "Titles with the same movie or episode match. You can designate a preferred version or merge watch records."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if isLoadingDuplicates && duplicateGroups.isEmpty {
        ProgressView("Analyzing duplicates…")
          .frame(maxWidth: .infinity, minHeight: 200)
      } else if duplicateGroups.isEmpty {
        ContentUnavailableView(
          "No Duplicates Found",
          systemImage: "checkmark.seal",
          description: Text("Your library has no duplicate media entries.")
        )
        .frame(maxWidth: .infinity, minHeight: 200)
      } else {
        ForEach(duplicateGroups) { group in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(group.title)
                .font(.headline)
              if let year = group.year {
                Text("(\(year))")
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text("\(group.items.count) versions")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
              ForEach(group.items) { item in
                HStack(spacing: 12) {
                  Image(systemName: item.isPreferred ? "star.fill" : "film")
                    .foregroundStyle(item.isPreferred ? .yellow : .secondary)

                  VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                      Text(item.sourcePath.components(separatedBy: "/").last ?? item.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                      if item.isPreferred {
                        Text("Preferred")
                          .font(.caption2.weight(.bold))
                          .padding(.horizontal, 6)
                          .padding(.vertical, 2)
                          .background(Color.yellow.opacity(0.2), in: Capsule())
                          .foregroundStyle(.yellow)
                      }
                    }

                    HStack(spacing: 10) {
                      if let res = item.videoResolution { Text(res) }
                      if let codec = item.videoCodec { Text(codec) }
                      if let audio = item.audioCodec { Text(audio) }
                      Text(
                        ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                      Text(item.availability)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  }

                  Spacer()

                  if !item.isPreferred {
                    Button("Set Preferred") {
                      Task { await setPreferred(item) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let preferred = group.items.first(where: { $0.isPreferred }) {
                      Button("Merge into Preferred") {
                        mergeSource = item
                        mergeTarget = preferred
                        showingMergeConfirmation = true
                      }
                      .buttonStyle(.borderedProminent)
                      .controlSize(.small)
                    }
                  }
                }
                .padding(10)
                .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: 8))
              }
            }
          }
          .padding(14)
          .background(AureliaDesign.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
      }

      if let duplicateError {
        Text(duplicateError).foregroundStyle(.orange).font(.caption)
      }
    }
  }

  // MARK: - Offline Content

  @ViewBuilder
  private var offlineContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Missing & Offline Titles")
            .font(.headline)
          Text(
            "Items whose source file is unreachable on disk. You can remove missing entries from the library catalog."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
        Picker("Offline for", selection: $offlineDays) {
          Text("7+ Days").tag(7)
          Text("30+ Days").tag(30)
          Text("90+ Days").tag(90)
        }
        .frame(width: 140)
        .onChange(of: offlineDays) {
          Task { await loadOffline() }
        }
      }

      if isLoadingOffline && offlineTitles.isEmpty {
        ProgressView("Checking offline titles…")
          .frame(maxWidth: .infinity, minHeight: 200)
      } else if offlineTitles.isEmpty {
        ContentUnavailableView(
          "No Offline Titles",
          systemImage: "externaldrive.badge.checkmark",
          description: Text("All media items in your library are reachable.")
        )
        .frame(maxWidth: .infinity, minHeight: 200)
      } else {
        ForEach(offlineTitles) { title in
          HStack(spacing: 12) {
            AuthenticatedArtwork(artwork: title.poster, symbol: "exclamationmark.triangle")
              .frame(width: 44, height: 60)
              .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
              Text(title.title).font(.body.weight(.medium))
              Text(title.sourcePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
              HStack(spacing: 8) {
                Text("Library: \(title.libraryName)")
                Text("·")
                Text("Offline for \(title.daysOffline) days")
              }
              .font(.caption2)
              .foregroundStyle(.orange)
            }

            Spacer()

            Button("Remove Entry", role: .destructive) {
              Task { await removeOfflineEntry(title) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
          .padding(10)
          .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: 8))
        }
      }

      if let offlineError {
        Text(offlineError).foregroundStyle(.orange).font(.caption)
      }
    }
  }

  // MARK: - Unmatched Content

  @ViewBuilder
  private var unmatchedContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Unmatched Metadata")
        .font(.headline)
      Text("Files in your storage locations that have not been identified by TMDB.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if isLoadingUnmatched && unmatchedTitles.isEmpty {
        ProgressView("Finding unmatched titles…")
          .frame(maxWidth: .infinity, minHeight: 200)
      } else if unmatchedTitles.isEmpty {
        ContentUnavailableView(
          "All Titles Matched",
          systemImage: "sparkles",
          description: Text("Every title in your library is matched to TMDB metadata.")
        )
        .frame(maxWidth: .infinity, minHeight: 200)
      } else {
        ForEach(unmatchedTitles) { title in
          HStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
              .font(.title2)
              .foregroundStyle(.secondary)
              .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
              Text(title.title).font(.body.weight(.medium))
              Text(title.sourcePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
              if let detected = title.detectedTitle {
                Text("Detected: \(detected) \(title.detectedYear.map { "(\($0))" } ?? "")")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }

            Spacer()

            Button("Match…") {
              matchingTarget = title
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
          .padding(10)
          .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: 8))
        }
      }

      if let unmatchedError {
        Text(unmatchedError).foregroundStyle(.orange).font(.caption)
      }
    }
  }

  // MARK: - Exclusions Content

  @ViewBuilder
  private var exclusionsContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Excluded Items")
        .font(.headline)
      Text("Removed sources stay excluded from scans until you explicitly reimport them.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("Storage Location", selection: $library) {
        Text("Select location").tag(UUID?.none)
        ForEach(model.libraries) { Text($0.name).tag(Optional($0.id)) }
      }
      .frame(width: 240)
      .onChange(of: library) {
        Task { await loadExclusions() }
      }

      ForEach(exclusions) { excluded in
        HStack {
          Label(excluded.relativePath, systemImage: excluded.isDirectory ? "folder" : "film")
            .lineLimit(2)
          Spacer()
          Button("Reimport…") { selectedExclusion = excluded }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: 8))
      }

      if library != nil && exclusions.isEmpty {
        Text("No excluded items.").foregroundStyle(.secondary).padding(.top, 8)
      }
      if let exclusionError {
        Text(exclusionError).foregroundStyle(.orange).font(.caption)
      }
    }
    .confirmationDialog(
      "Reimport this source?",
      isPresented: Binding(
        get: { selectedExclusion != nil }, set: { if !$0 { selectedExclusion = nil } }),
      titleVisibility: .visible
    ) {
      Button("Reimport with Scan") {
        guard let excluded = selectedExclusion, let profile = model.profile else { return }
        let generation = model.administrationGeneration
        reimportTask = Task {
          defer { reimportTask = nil }
          do {
            try await model.currentAdministration {
              try await APIClient(profile: profile).reinclude(
                library: excluded.libraryId, excluded: excluded.id)
            }
            guard model.isCurrentAdministration(generation) else { return }
            await loadExclusions()
            await model.reloadAdministration()
          } catch is CancellationError {
          } catch {
            guard model.isCurrentAdministration(generation) else { return }
            model.handleAdministrationFailure(error, generation: generation)
            self.exclusionError = error.localizedDescription
          }
        }
      }
    } message: {
      Text(
        "This clears the source exclusion and starts a scan. Previously removed personal metadata and playback history are not restored."
      )
    }
  }

  // MARK: - API Calls

  private func loadCurrentTab() async {
    switch selectedTab {
    case .duplicates: await loadDuplicates()
    case .offline: await loadOffline()
    case .unmatched: await loadUnmatched()
    case .exclusions: await loadExclusions()
    }
  }

  private func loadDuplicates() async {
    guard let profile = model.profile else { return }
    isLoadingDuplicates = true
    do {
      duplicateGroups = try await APIClient(profile: profile).healthDuplicates()
      duplicateError = nil
      isLoadingDuplicates = false
    } catch {
      isLoadingDuplicates = false
      duplicateError = error.localizedDescription
    }
  }

  private func loadOffline() async {
    guard let profile = model.profile else { return }
    isLoadingOffline = true
    do {
      offlineTitles = try await APIClient(profile: profile).healthOffline(days: offlineDays)
      offlineError = nil
      isLoadingOffline = false
    } catch {
      isLoadingOffline = false
      offlineError = error.localizedDescription
    }
  }

  private func loadUnmatched() async {
    guard let profile = model.profile else { return }
    isLoadingUnmatched = true
    do {
      unmatchedTitles = try await APIClient(profile: profile).healthUnmatched()
      unmatchedError = nil
      isLoadingUnmatched = false
    } catch {
      isLoadingUnmatched = false
      unmatchedError = error.localizedDescription
    }
  }

  private func loadExclusions() async {
    exclusions = []
    guard let library, let profile = model.profile else { return }
    let generation = model.administrationGeneration
    do {
      let loaded = try await model.currentAdministration {
        try await APIClient(profile: profile).excludedItems(library: library)
      }
      guard model.isCurrentAdministration(generation), self.library == library else { return }
      exclusions = loaded
      exclusionError = nil
    } catch is CancellationError {
    } catch {
      guard model.isCurrentAdministration(generation), self.library == library else { return }
      model.handleAdministrationFailure(error, generation: generation)
      self.exclusionError = error.localizedDescription
    }
  }

  private func setPreferred(_ item: DuplicateItemSummary) async {
    guard let profile = model.profile else { return }
    do {
      try await APIClient(profile: profile).healthSetPreferred(preferredId: item.id)
      await loadDuplicates()
    } catch {
      duplicateError = error.localizedDescription
    }
  }

  private func executeMerge(source: DuplicateItemSummary, target: DuplicateItemSummary) async {
    guard let profile = model.profile else { return }
    do {
      try await APIClient(profile: profile).healthMerge(sourceId: source.id, targetId: target.id)
      await loadDuplicates()
    } catch {
      duplicateError = error.localizedDescription
    }
  }

  private func removeOfflineEntry(_ title: OfflineTitleSummary) async {
    guard let profile = model.profile else { return }
    do {
      try await APIClient(profile: profile).healthRemoveEntry(mediaId: title.id)
      await loadOffline()
    } catch {
      offlineError = error.localizedDescription
    }
  }
}

// Preserve existing LibraryMaintenanceView as a wrapper for backward compatibility
struct LibraryMaintenanceView: View {
  var body: some View {
    LibraryHealthView()
  }
}

struct LibraryResetSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var selected: Set<UUID> = []
  @State private var preview: ResetLibraryPreview?
  @State private var confirmation = false
  @State private var working = false
  @State private var result: LibraryMutationResult?
  @State private var error: String?
  @State private var operationTask: Task<Void, Never>?
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("Reset Library", systemImage: "exclamationmark.triangle").font(.title2.bold())
      Text(
        "Choose the storage locations to remove. This deletes catalog entries, metadata, images, favorites and playback history for all users. Storage locations must be explicitly added again afterward."
      )
      List(model.libraries) { library in
        Toggle(
          library.name,
          isOn: Binding(
            get: { selected.contains(library.id) },
            set: {
              if $0 { selected.insert(library.id) } else { selected.remove(library.id) }
              preview = nil
            }))
      }.frame(minHeight: 150)
      Text(
        "Videos, accounts, device sessions, server settings and TLS identity are never deleted. Existing backups are retained and may contain earlier library data."
      )
      .font(.callout).foregroundStyle(.secondary)
      if let preview {
        Text(
          "\(preview.titles) catalog entries · \(preview.artwork) artwork assets · \(preview.storageLocations) storage locations"
        ).font(.headline)
      }
      if let result {
        Text(
          result.state == "completed"
            ? "Reset complete. Your video files were not changed."
            : "Catalog removed. Waiting for managed artwork cleanup…"
        ).foregroundStyle(result.state == "completed" ? .green : .orange)
      }
      if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
      HStack {
        if working { ProgressView().controlSize(.small) }
        Spacer()
        Button(result?.state == "completed" ? "Done" : "Cancel") { dismiss() }.disabled(working)
        if result == nil {
          Button(
            preview == nil ? "Review Reset" : "Reset Selected Libraries…",
            role: preview == nil ? nil : .destructive
          ) {
            if preview != nil {
              confirmation = true
            } else {
              operationTask = Task { await review() }
            }
          }.disabled(selected.isEmpty || working || !model.canManageStorage)
        }
      }
    }.padding(24).frame(minWidth: 650, minHeight: 530).background(AureliaBackdrop())
      .interactiveDismissDisabled(working)
      .onDisappear { operationTask?.cancel() }
      .onChange(of: model.profile?.sessionId) { _, _ in
        operationTask?.cancel()
        dismiss()
      }
      .confirmationDialog(
        "Permanently reset the selected libraries?", isPresented: $confirmation,
        titleVisibility: .visible
      ) {
        Button("Reset Selected Libraries", role: .destructive) {
          operationTask = Task { await reset() }
        }
      } message: {
        Text(
          "The selected libraries will be removed using your current management unlock. Your video files will not be changed. This cannot be undone without restoring a backup."
        )
      }
  }
  private func review() async {
    guard let profile = model.profile, model.canManageStorage else { return }
    let generation = model.administrationGeneration
    let libraries = selected.sorted { $0.uuidString < $1.uuidString }
    working = true
    defer { working = false }
    do {
      let loaded = try await model.currentAdministration {
        try await APIClient(profile: profile).previewReset(libraries: libraries)
      }
      guard model.isCurrentAdministration(generation) else { return }
      preview = loaded
      error = nil
    } catch is CancellationError {
    } catch {
      guard model.isCurrentAdministration(generation) else { return }
      model.handleAdministrationFailure(error, generation: generation)
      self.error = error.localizedDescription
    }
  }
  private func reset() async {
    guard let profile = model.profile, let preview, model.canManageStorage else { return }
    let generation = model.administrationGeneration
    working = true
    defer { working = false }
    do {
      let client = APIClient(profile: profile)
      let accepted: LibraryMutationResult
      do {
        accepted = try await model.currentAdministration {
          try await client.resetLibrary(preview: preview)
        }
      } catch let failure as APIClientError where failure.isManagementLocked {
        let password = try AdministrationPasswordPrompt.confirm(
          serverName: model.profile?.name ?? "Aurelia")
        _ = await model.unlockManagement(password: password)
        accepted = try await model.currentAdministration {
          try await client.resetLibrary(preview: preview)
        }
      }
      guard model.isCurrentAdministration(generation) else { return }
      result = accepted
      while let current = result, current.state != "completed" {
        try await Task.sleep(for: .seconds(5))
        guard model.isCurrentAdministration(generation) else { return }
        let updated = try await model.currentAdministration {
          try await client.libraryMutation(id: current.id)
        }
        guard model.isCurrentAdministration(generation) else { return }
        result = updated
      }
      guard model.isCurrentAdministration(generation) else { return }
      try await model.refresh()
      guard model.isCurrentAdministration(generation) else { return }
      await model.reloadAdministration()
      guard model.isCurrentAdministration(generation) else { return }
      error = nil
    } catch is CancellationError {} catch {
      guard model.isCurrentAdministration(generation) else { return }
      model.handleAdministrationFailure(error, generation: generation)
      self.error = error.localizedDescription
      self.preview = nil
    }
  }
}
