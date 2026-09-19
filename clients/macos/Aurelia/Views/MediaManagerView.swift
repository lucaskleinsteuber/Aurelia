import SwiftUI

struct MediaManagerView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var drafts: [StorageLocationDraft] = []
  @State private var combineExisting = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if !model.isLocalHost {
            remoteNotice
          } else if model.canManageMedia {
            addLocations
          }
          configuredLibraries
          scanActivity
          classifications
        }
        .padding(24)
      }
      Divider()
      HStack {
        Text("Removing a location never deletes or changes media files.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 760, height: 680)
    .background(AureliaBackdrop())
    .task { await model.reloadAdministration() }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "externaldrive.fill.badge.plus")
        .font(.system(size: 28, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
      VStack(alignment: .leading, spacing: 3) {
        Text("Manage Media").font(.title2.bold())
        Text("Add storage locations, follow scans, and review detected folders.")
          .font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(20)
  }

  private var remoteNotice: some View {
    Label {
      VStack(alignment: .leading, spacing: 4) {
        Text("Add locations on the server Mac").font(.headline)
        Text("A local folder on this Mac cannot be sent to a different Aurelia server.")
          .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: "macstudio")
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
  }

  private var addLocations: some View {
    GroupBox("Add Media") {
      VStack(alignment: .leading, spacing: 14) {
        ForEach($drafts) { $draft in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Image(systemName: "folder.fill")
              Text(draft.path).lineLimit(1).truncationMode(.middle)
              Spacer()
              Button(role: .destructive) {
                drafts.removeAll { $0.id == draft.id }
              } label: {
                Image(systemName: "minus.circle.fill")
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Remove \(draft.suggestedName)")
            }
            HStack {
              TextField("Library name (optional)", text: $draft.libraryName)
                .textFieldStyle(.roundedBorder)
              Picker("Type", selection: $draft.kind) {
                ForEach(LibraryKind.allCases, id: \.self) { kind in
                  Text(kind.title).tag(kind)
                }
              }
              .frame(width: 210)
            }
          }
          .padding(12)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }

        HStack {
          Button("Choose Folders or Drives…") { chooseStorageLocations(into: &drafts) }
            .accessibilityIdentifier("media-manager-choose-locations")
          Toggle("Combine compatible overlapping libraries", isOn: $combineExisting)
            .toggleStyle(.checkbox)
            .font(.caption)
          Spacer()
          Button("Add and Scan") {
            let selected = drafts
            Task {
              if await model.addStorageLocations(selected, combineExisting: combineExisting) {
                drafts = []
              }
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(drafts.isEmpty || model.isWorking)
          .accessibilityIdentifier("media-manager-add-and-scan")
        }
      }
      .padding(8)
    }
  }

  private var configuredLibraries: some View {
    GroupBox("Storage Locations") {
      VStack(spacing: 0) {
        if model.libraries.isEmpty {
          Text("No storage locations yet.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        ForEach(model.libraries) { library in
          LibraryLocationRow(
            library: library,
            canEdit: model.isLocalHost && model.canManageMedia)
          if library.id != model.libraries.last?.id { Divider() }
        }
      }
    }
  }

  @ViewBuilder
  private var scanActivity: some View {
    let scans = model.activeScans + model.recentScans
    if !scans.isEmpty {
      GroupBox("Scan Activity") {
        VStack(spacing: 0) {
          ForEach(scans.prefix(20)) { scan in
            ScanStatusRow(scan: scan, library: model.libraries.first { $0.id == scan.libraryId })
            if scan.id != scans.prefix(20).last?.id { Divider() }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var classifications: some View {
    if !model.libraryDiscoveries.isEmpty {
      GroupBox("Folder Classification") {
        VStack(alignment: .leading, spacing: 10) {
          Text("Choose how ambiguous folders should be imported, or ignore them. TV Show · Force Import accepts unnumbered videos in natural filename order as Season 1 episodes.")
            .font(.caption).foregroundStyle(.secondary)
          ForEach(model.libraryDiscoveries) { discovery in
            DiscoveryDecisionCard(discovery: discovery)
          }
        }
        .padding(8)
      }
    }
  }
}

private struct LibraryLocationRow: View {
  @EnvironmentObject private var model: AppModel
  let library: LibrarySummary
  let canEdit: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: availabilitySymbol)
        .foregroundStyle(library.availability == .available ? Color.primary : Color.orange)
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(library.name).font(.headline)
          Text(library.kind.title).font(.caption).foregroundStyle(.secondary)
        }
        Text(library.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if let error = library.lastError, !error.isEmpty {
          Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
      }
      Spacer()
      Text(library.availability.rawValue.capitalized)
        .font(.caption).foregroundStyle(.secondary)
      if canEdit {
        if library.monitoringEnabled != nil {
          Toggle(
            "Monitor",
            isOn: Binding(
              get: { library.isMonitoringEnabled },
              set: { enabled in
                Task { await model.setMonitoring(libraryID: library.id, enabled: enabled) }
              }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("library-monitor-\(library.id.uuidString.lowercased())")
            .help("Automatically detect changes in this storage location")
        }
        Button("Rescan") { Task { await model.scanLibrary(id: library.id) } }
        Button(role: .destructive) {
          Task { await model.removeLibrary(id: library.id) }
        } label: {
          Image(systemName: "trash")
        }
        .accessibilityLabel("Remove \(library.name)")
      }
    }
    .padding(10)
  }

  private var availabilitySymbol: String {
    library.availability == .available
      ? "externaldrive.fill" : "externaldrive.badge.exclamationmark"
  }
}

private struct ScanStatusRow: View {
  @EnvironmentObject private var model: AppModel
  let scan: LibraryScanSummary
  let library: LibrarySummary?

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Image(systemName: symbol)
          .foregroundStyle(color)
        Text(library?.name ?? "Storage Location").font(.headline)
        Spacer()
        if let trigger = scan.trigger {
          Text(trigger.title)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let attempt = scan.attempt, attempt > 0 {
          Text("Attempt \(attempt)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(scan.state.rawValue.capitalized).font(.caption.weight(.semibold))
        if scan.state == .queued || scan.state == .running || scan.state == .waitingForStorage {
          Button("Cancel") { Task { await model.cancelScan(id: scan.id) } }
            .controlSize(.small)
        }
      }
      if scan.state == .queued || scan.state == .running {
        ProgressView(value: Double(scan.filesProcessed), total: Double(max(scan.filesDiscovered, 1)))
      }
      if scan.state == .waitingForStorage {
        Text("Waiting for Storage")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
      }
      Text(
        "Found \(scan.filesDiscovered) · Added \(scan.addedFiles) · Updated \(scan.updatedFiles) · Missing \(scan.missingFiles) · Skipped \(scan.skippedFiles)"
      )
      .font(.caption).foregroundStyle(.secondary)
      if let error = scan.error, !error.isEmpty {
        Text(error).font(.caption).foregroundStyle(.orange)
      }
      ForEach(Array(scan.issues.prefix(3).enumerated()), id: \.offset) { _, issue in
        Text(issue.message).font(.caption).foregroundStyle(.orange).lineLimit(2)
      }
    }
    .padding(10)
  }

  private var symbol: String {
    switch scan.state {
    case .queued, .running: "arrow.triangle.2.circlepath"
    case .waitingForStorage: "externaldrive.badge.exclamationmark"
    case .completed: "checkmark.circle.fill"
    case .failed, .interrupted: "exclamationmark.triangle.fill"
    case .cancelled: "xmark.circle.fill"
    }
  }

  private var color: Color {
    switch scan.state {
    case .queued, .running: .accentColor
    case .waitingForStorage: .orange
    case .completed: .green
    case .failed, .interrupted: .orange
    case .cancelled: .secondary
    }
  }
}

private extension LibraryScanTrigger {
  var title: String {
    switch self {
    case .manual: "Manual"
    case .fileChange: "Automatic Change"
    case .startup: "Startup Check"
    case .scheduled: "Scheduled Check"
    case .storageReconnected: "Storage Reconnected"
    case .classificationChanged: "Classification Changed"
    }
  }
}
