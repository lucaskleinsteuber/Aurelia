import SwiftUI

struct LibraryMaintenanceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showingReset = false
  @State private var library: UUID?
  @State private var exclusions: [ExcludedMediaSummary] = []
  @State private var selectedExclusion: ExcludedMediaSummary?
  @State private var error: String?
  @State private var reimportTask: Task<Void, Never>?
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      AureliaSettingsSection(
        "Excluded Items", symbol: "eye.slash",
        description: "Removed sources stay excluded from scans until you explicitly reimport them."
      ) {
        VStack(alignment: .leading, spacing: 12) {
          Picker("Storage Location", selection: $library) {
            Text("Select location").tag(UUID?.none)
            ForEach(model.libraries) { Text($0.name).tag(Optional($0.id)) }
          }
          ForEach(exclusions) { excluded in
            HStack {
              Label(excluded.relativePath, systemImage: excluded.isDirectory ? "folder" : "film")
                .lineLimit(2)
              Spacer()
              Button("Reimport…") { selectedExclusion = excluded }
            }
          }
          if library != nil && exclusions.isEmpty {
            Text("No excluded items.").foregroundStyle(.secondary)
          }
          if let error { Text(error).foregroundStyle(.orange) }
        }
      }
      AureliaSettingsSection(
        "Reset Library", symbol: "exclamationmark.triangle",
        description:
          "Remove selected libraries from Aurelia. Accounts, devices, server settings and video files remain untouched."
      ) {
        Button("Reset Library…", role: .destructive) { showingReset = true }.disabled(
          model.libraries.isEmpty)
      }
    }
    .task(id: library) { await load() }
    .onDisappear { reimportTask?.cancel() }
    .sheet(isPresented: $showingReset) { LibraryResetSheet().environmentObject(model) }
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
            await load()
            guard model.isCurrentAdministration(generation) else { return }
            await model.reloadAdministration()
          } catch is CancellationError {
          } catch {
            guard model.isCurrentAdministration(generation) else { return }
            model.handleAdministrationFailure(error, generation: generation)
            self.error = error.localizedDescription
          }
        }
      }
    } message: {
      Text(
        "This clears the source exclusion and starts a scan. Previously removed personal metadata and playback history are not restored."
      )
    }
  }
  private func load() async {
    exclusions = []
    guard let library, let profile = model.profile else { return }
    let generation = model.administrationGeneration
    do {
      let loaded = try await model.currentAdministration {
        try await APIClient(profile: profile).excludedItems(library: library)
      }
      guard model.isCurrentAdministration(generation), self.library == library else { return }
      exclusions = loaded
      error = nil
    } catch is CancellationError {
    } catch {
      guard model.isCurrentAdministration(generation), self.library == library else { return }
      model.handleAdministrationFailure(error, generation: generation)
      self.error = error.localizedDescription
    }
  }
}

private struct LibraryResetSheet: View {
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
