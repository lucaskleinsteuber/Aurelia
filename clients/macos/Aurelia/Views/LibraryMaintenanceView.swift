import SwiftUI

enum LibraryHealthTab: String, CaseIterable, Identifiable, Sendable {
  case duplicates = "Duplicates"
  case offline = "Offline Titles"
  case unmatched = "Unmatched Metadata"
  case exclusions = "Excluded Items"
  case files = "File Problems"
  case drives = "Drives"

  var id: String { rawValue }

  /// The tabs this server offers: File Problems and Drives need the file watch (server 2.19.0).
  static func available(fileChecks: Bool) -> [LibraryHealthTab] {
    allCases.filter { fileChecks || ($0 != .files && $0 != .drives) }
  }
}

struct LibraryHealthView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var selectedTab: LibraryHealthTab = .duplicates

  // Duplicates State
  @State private var duplicateGroups: [DuplicateGroup] = []
  @State private var isLoadingDuplicates = false
  @State private var duplicateError: String?
  @State private var loadedDuplicates = false

  // Offline State
  @State private var offlineTitles: [OfflineTitleSummary] = []
  @State private var offlineDays: Int = 30
  @State private var isLoadingOffline = false
  @State private var offlineError: String?
  @State private var loadedOffline = false
  @State private var offlineRemoval: OfflineTitleSummary?

  // Unmatched State
  @State private var unmatchedTitles: [UnmatchedTitleSummary] = []
  @State private var isLoadingUnmatched = false
  @State private var unmatchedError: String?
  @State private var loadedUnmatched = false
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
    AureliaSheet(
      title: "Library Health & Maintenance",
      subtitle:
        "Find duplicate, missing, unmatched and damaged titles, and bring back excluded ones.",
      symbol: "stethoscope",
      onCancel: { dismiss() }
    ) {
      VStack(spacing: 0) {
        Picker("Tab", selection: $selectedTab) {
          ForEach(
            LibraryHealthTab.available(
              fileChecks: model.libraryCapabilities.contains(ServerFeatureNames.fileChecks))
          ) { tab in
            Text(tab.rawValue).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 20)
        .padding(.vertical, 16)

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
            case .files:
              FileProblemsPanel()
            case .drives:
              DrivesPanel()
            }
          }
          .padding(20)
        }
      }
    }
    .frame(minWidth: 780, minHeight: 580)
    .task(id: selectedTab) {
      await loadCurrentTab()
    }
    .confirmationDialog(
      "Move watch data to the available copy?",
      isPresented: $showingMergeConfirmation,
      titleVisibility: .visible
    ) {
      Button("Move and Remove Missing Copy", role: .destructive) {
        if let source = mergeSource, let target = mergeTarget {
          Task { await executeMerge(source: source, target: target) }
        }
      }
    } message: {
      Text(
        "Favorites, progress, viewing history and collection memberships of every profile move to “\(mergeTarget?.fileName ?? "the available copy")”. The missing copy is then removed from the library. Files on disk are never touched."
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
        "Movies and episodes that exist as several files. Aurelia never deletes files: remove an unwanted file yourself, or move the watch data of a missing copy to the one you still have."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if let duplicateError {
        ErrorBanner(
          message: duplicateError, retry: { Task { await loadDuplicates() } },
          retryDisabled: isLoadingDuplicates, inline: true)
      }
      if duplicateGroups.isEmpty && duplicateError != nil {
        // A failed check is not "no duplicates": the banner above offers Try Again.
        EmptyView()
      } else if (isLoadingDuplicates || !loadedDuplicates) && duplicateGroups.isEmpty {
        AureliaDelayedProgress()
          .frame(maxWidth: .infinity, minHeight: 200)
          .accessibilityLabel("Analyzing duplicates")
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
                  Image(systemName: item.isAvailable ? "film" : "exclamationmark.triangle")
                    .foregroundStyle(item.isAvailable ? Color.secondary : Color.orange)

                  VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName)
                      .font(.body.weight(.medium))
                      .lineLimit(1)
                    HStack(spacing: 10) {
                      if let size = item.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                      }
                      Text(item.isAvailable ? "Available" : "File missing")
                    }
                    .font(.caption2)
                    .foregroundStyle(item.isAvailable ? Color.secondary : Color.orange)
                  }

                  Spacer()

                  if !item.isAvailable, let available = group.items.first(where: \.isAvailable) {
                    Button("Move Watch Data…") {
                      mergeSource = item
                      mergeTarget = available
                      showingMergeConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                  }
                }
                .padding(10)
                .background(
                  AureliaDesign.surface,
                  in: RoundedRectangle(cornerRadius: AureliaDesign.smallRadius))
              }
            }
          }
          .padding(14)
          .background(
            AureliaDesign.surface.opacity(0.5),
            in: RoundedRectangle(cornerRadius: AureliaDesign.smallRadius))
        }
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
            "Titles whose file has not been found for a while. Removing one deletes its favorites, progress and history for every profile; the file is never touched."
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

      if let offlineError {
        ErrorBanner(
          message: offlineError, retry: { Task { await loadOffline() } },
          retryDisabled: isLoadingOffline, inline: true)
      }
      if offlineTitles.isEmpty && offlineError != nil {
        // A failed check is not "all reachable": the banner above offers Try Again.
        EmptyView()
      } else if (isLoadingOffline || !loadedOffline) && offlineTitles.isEmpty {
        AureliaDelayedProgress()
          .frame(maxWidth: .infinity, minHeight: 200)
          .accessibilityLabel("Checking offline titles")
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
            Image(systemName: "exclamationmark.triangle")
              .font(.title2)
              .foregroundStyle(.orange)
              .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
              Text(title.title).font(.body.weight(.medium))
              Text(title.fileName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
              HStack(spacing: 8) {
                Text("Library: \(title.libraryName)")
                Text("·")
                Text("Offline for \(title.daysOffline) days")
              }
              .font(.caption2)
              .foregroundStyle(.orange)
            }

            Spacer()

            Button("Remove…", role: .destructive) {
              offlineRemoval = title
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
          .padding(10)
          .background(
            AureliaDesign.surface,
            in: RoundedRectangle(cornerRadius: AureliaDesign.smallRadius))
        }
      }

    }
    .confirmationDialog(
      "Remove “\(offlineRemoval?.title ?? "")” from the library?",
      isPresented: Binding(
        get: { offlineRemoval != nil }, set: { if !$0 { offlineRemoval = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove from Library", role: .destructive) {
        if let title = offlineRemoval { Task { await removeOfflineEntry(title) } }
      }
    } message: {
      Text(
        "Its details, favorites, progress, history and collection memberships are deleted for every profile. If the file comes back, it stays excluded until you reimport it under Excluded Items."
      )
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

      if let unmatchedError {
        ErrorBanner(
          message: unmatchedError, retry: { Task { await loadUnmatched() } },
          retryDisabled: isLoadingUnmatched, inline: true)
      }
      if unmatchedTitles.isEmpty && unmatchedError != nil {
        // A failed check is not "all matched": the banner above offers Try Again.
        EmptyView()
      } else if (isLoadingUnmatched || !loadedUnmatched) && unmatchedTitles.isEmpty {
        AureliaDelayedProgress()
          .frame(maxWidth: .infinity, minHeight: 200)
          .accessibilityLabel("Finding unmatched titles")
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
              Text(title.fileName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
              Text(title.issueReason)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Match…") {
              matchingTarget = title
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
          .padding(10)
          .background(
            AureliaDesign.surface,
            in: RoundedRectangle(cornerRadius: AureliaDesign.smallRadius))
        }
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
        .background(
          AureliaDesign.surface,
          in: RoundedRectangle(cornerRadius: AureliaDesign.smallRadius))
      }

      if library != nil && exclusions.isEmpty {
        Text("No excluded items.").foregroundStyle(.secondary).padding(.top, 8)
      }
      if let exclusionError {
        ErrorBanner(
          message: exclusionError, retry: { Task { await loadExclusions() } }, inline: true)
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
    case .files, .drives: break
    }
  }

  private func loadDuplicates() async {
    guard let profile = model.profile else { return }
    isLoadingDuplicates = true
    do {
      duplicateGroups = try await APIClient(profile: profile).healthDuplicates()
      duplicateError = nil
      isLoadingDuplicates = false
      loadedDuplicates = true
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
      loadedOffline = true
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
      loadedUnmatched = true
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
    VStack(spacing: 0) {
      AureliaSheetHeader(
        title: "Reset Library",
        subtitle: "Remove storage locations and everything Aurelia knows about their titles.",
        symbol: "exclamationmark.triangle")
      Divider()
      resetContent
      Divider()
      footer
    }
    .frame(minWidth: 650, minHeight: 600).background(AureliaBackdrop())
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

  private var resetContent: some View {
    VStack(alignment: .leading, spacing: 18) {
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
            : working
              ? "Catalog removed. Waiting for the server to clean up its artwork…"
              : "Catalog removed. The server finishes cleaning up its artwork later; your video files were not changed."
        ).foregroundStyle(.secondary)
        if let serverError = result.error { ErrorBanner(message: serverError, inline: true) }
      }
      if let error { ErrorBanner(message: error, inline: true) }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var footer: some View {
    HStack {
      if working { ProgressView().controlSize(.small) }
      Spacer()
      if result == nil {
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(working)
        Button(
          preview == nil ? "Review Reset" : "Reset Selected Libraries…",
          role: preview == nil ? nil : .destructive
        ) {
          if preview != nil {
            confirmation = true
          } else {
            operationTask = Task { await review() }
          }
        }
        .buttonStyle(AureliaPrimaryActionButtonStyle(compact: true))
        .keyboardShortcut(.defaultAction)
        .disabled(selected.isEmpty || working || !model.canManageStorage)
      } else {
        AureliaSheetDoneButton { dismiss() }
          .disabled(working)
      }
    }
    .padding(16)
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
        guard await model.unlockManagementInteractively() else { return }
        accepted = try await model.currentAdministration {
          try await client.resetLibrary(preview: preview)
        }
      }
      guard model.isCurrentAdministration(generation) else { return }
      result = accepted
      // The catalog is gone once the reset is accepted; artwork cleanup can take a while or stop
      // with a server error. Wait up to two minutes and never longer than the server is working.
      var checks = 0
      while let current = result, current.state != "completed", current.error == nil, checks < 24 {
        checks += 1
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
