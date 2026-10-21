import SwiftUI

struct MediaManagerView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var drafts: [StorageLocationDraft] = []
  @State private var choosesServerFolder = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if model.canManageStorage {
            addLocations
          }
          configuredLibraries
          scanActivity
          importAssignments
          if model.managementUnlocked, let error = model.administrationErrorMessage {
            Text(error).foregroundStyle(.orange).textSelection(.enabled)
          }
        }
        .padding(AureliaDesign.pagePadding)
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
      .padding(.horizontal, AureliaDesign.pagePadding)
      .padding(.vertical, 16)
    }
    .frame(width: 800, height: 720)
    .sheet(isPresented: $choosesServerFolder) {
      ServerFolderPicker { path in
        if !drafts.contains(where: { $0.path == path }) {
          drafts.append(StorageLocationDraft(path: path))
        }
      }
      .environmentObject(model)
    }
    .background(AureliaBackdrop())
    .task { await model.reloadAdministration() }
    .sheet(item: $model.importPreviewLibrary) { library in
      ImportPreviewView(library: library).environmentObject(model)
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "externaldrive.fill.badge.plus")
        .font(.system(size: 30, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
      VStack(alignment: .leading, spacing: 3) {
        Text("Manage Media").font(AureliaDesign.pageTitle)
        Text("Add storage locations, follow scans, and review detected folders.")
          .font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, AureliaDesign.pagePadding)
    .padding(.vertical, 22)
  }

  private var addLocations: some View {
    AureliaSettingsSection(
      "Add Media",
      symbol: "plus.rectangle.on.folder",
      description:
        "Choose one or more folders or drives. Aurelia reads their directory structure and leaves every media file untouched."
    ) {
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
          .padding(14)
          .background(
            AureliaDesign.raisedSurface,
            in: RoundedRectangle(cornerRadius: AureliaDesign.compactRadius, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: AureliaDesign.compactRadius, style: .continuous)
              .stroke(AureliaDesign.hairline, lineWidth: 1)
          }
        }

        HStack {
          Button(model.isLocalHost ? "Choose Folders or Drives…" : "Choose Folders on the Server…")
          {
            if model.isLocalHost {
              chooseStorageLocations(into: &drafts)
            } else {
              choosesServerFolder = true
            }
          }
          .frame(minHeight: AureliaDesign.minimumControlSize)
          .accessibilityIdentifier("media-manager-choose-locations")
          Spacer()
          Button("Analyze and Preview") {
            let selected = drafts
            Task {
              if await model.addStorageLocations(selected) {
                drafts = []
              }
            }
          }
          .buttonStyle(AureliaPrimaryActionButtonStyle())
          .disabled(drafts.isEmpty || model.isWorking)
          .accessibilityIdentifier("media-manager-add-and-scan")
        }
      }
    }
  }

  private var configuredLibraries: some View {
    AureliaSettingsSection(
      "Storage Locations",
      symbol: "externaldrive.fill",
      description:
        "Automatic monitoring keeps reachable locations current. Offline media remains in your library."
    ) {
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
      AureliaSettingsSection("Scan Activity", symbol: "arrow.triangle.2.circlepath") {
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
  private var importAssignments: some View {
    if model.canManageMedia && !model.libraries.isEmpty {
      AureliaSettingsSection(
        "Import Assignments",
        symbol: "rectangle.3.group.bubble",
        description:
          "Review files and folders, assign extras and trailers to a title or season, and change saved manual rules."
      ) {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(model.libraries) { library in
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text(library.name).font(.headline)
                Text(
                  library.importPreviewRequired == true
                    ? "Awaiting import confirmation" : "Automatic detection and saved assignments"
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Review Import…") { model.importPreviewLibrary = library }
                .accessibilityIdentifier("review-import-\(library.id.uuidString.lowercased())")
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var importReview: some View {
    if model.canManageMedia && !model.libraryImportReviews.isEmpty {
      AureliaSettingsSection(
        "Import Review",
        symbol: "film.stack",
        description: "Review trailers that could not be safely matched to a movie."
      ) {
        VStack(spacing: 10) {
          ForEach(model.libraryImportReviews) { review in
            TrailerImportReviewRow(review: review)
          }
        }
      }
    }
  }
}

private struct TrailerImportReviewRow: View {
  @EnvironmentObject private var model: AppModel
  let review: LibraryImportReviewSummary

  @State private var query: String
  @State private var candidates: [CatalogItemSummary] = []
  @State private var errorMessage: String?
  @State private var isSearching = false

  init(review: LibraryImportReviewSummary) {
    self.review = review
    _query = State(initialValue: review.detectedTitle)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(review.detectedTitle).font(.headline)
          Text(review.relativePath)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(review.reason).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Ignore", role: .destructive) {
          Task { await model.resolveImportReview(review, action: .ignore) }
        }
        .disabled(model.isWorking)
      }

      HStack {
        TextField("Search movies in this location", text: $query)
          .textFieldStyle(.roundedBorder)
        Button("Search Movies") { Task { await searchMovies() } }
          .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
      }

      if isSearching { ProgressView().controlSize(.small) }
      ForEach(candidates) { movie in
        HStack {
          Text(movie.year.map { "\(movie.title) (\($0))" } ?? movie.title)
            .lineLimit(1)
          Spacer()
          Button("Assign to Movie") {
            Task {
              await model.resolveImportReview(
                review,
                action: .assignToMovie,
                movieId: movie.id)
            }
          }
          .disabled(model.isWorking)
        }
        .padding(.leading, 10)
      }
      if let errorMessage {
        Text(errorMessage).font(.caption).foregroundStyle(.orange)
      }
    }
    .padding(12)
    .background(
      AureliaDesign.raisedSurface,
      in: RoundedRectangle(cornerRadius: AureliaDesign.compactRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.compactRadius, style: .continuous)
        .stroke(AureliaDesign.hairline, lineWidth: 1)
    }
    .accessibilityIdentifier("trailer-import-review-\(review.id.uuidString.lowercased())")
  }

  private func searchMovies() async {
    isSearching = true
    errorMessage = nil
    defer { isSearching = false }
    do {
      candidates = try await model.searchMoviesForImportReview(
        query,
        libraryId: review.libraryId)
      if candidates.isEmpty {
        errorMessage = "No movies matched that search in this location."
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct AureliaSectionSurfaceModifier: ViewModifier {
  func body(content: Content) -> some View {
    AureliaSurface { content }
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
        if library.importPreviewRequired == true {
          Button("Preview…") { model.importPreviewLibrary = library }
        }
        if library.monitoringEnabled != nil {
          Toggle(
            "Monitor",
            isOn: Binding(
              get: { library.isMonitoringEnabled },
              set: { enabled in
                Task { await model.setMonitoring(libraryID: library.id, enabled: enabled) }
              })
          )
          .toggleStyle(.switch)
          .controlSize(.small)
          .accessibilityIdentifier("library-monitor-\(library.id.uuidString.lowercased())")
          .help("Automatically detect changes in this storage location")
          .disabled(library.importPreviewRequired == true)
        }
        Button("Rescan") { Task { await model.scanLibrary(id: library.id) } }
          .frame(minHeight: AureliaDesign.minimumControlSize)
          .disabled(library.importPreviewRequired == true)
        Button(role: .destructive) {
          Task { await model.removeLibrary(id: library.id) }
        } label: {
          Image(systemName: "trash")
            .frame(
              width: AureliaDesign.minimumControlSize, height: AureliaDesign.minimumControlSize)
        }
        .buttonStyle(.plain)
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
        Text(
          model.scanStatusUnavailable.contains(scan.id)
            ? "Status unavailable" : scan.state.rawValue.capitalized
        )
        .font(.caption.weight(.semibold))
        if scan.state == .queued || scan.state == .running || scan.state == .waitingForStorage {
          Button("Cancel") { Task { await model.cancelScan(id: scan.id) } }
            .controlSize(.small)
        }
      }
      if model.scanStatusUnavailable.contains(scan.id) {
        Text("Keeping the last known progress. Status will update when the server is reachable.")
          .font(.caption).foregroundStyle(.orange)
      }
      if scan.state == .queued || scan.state == .running {
        if let phase = scan.phase {
          Text(phase == "Completed" ? "Catalog complete; metadata runs separately." : phase)
            .font(.caption).foregroundStyle(.secondary)
        }
        ProgressView(
          value: Double(scan.filesProcessed), total: Double(max(scan.filesDiscovered, 1)))
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
      if let recognized = scan.recognizedFiles {
        Text(
          "Recognized \(recognized) · Review \(scan.pendingFiles ?? 0) · Ignored \(scan.ignoredFiles ?? 0) · Failed \(scan.failedFiles ?? 0)"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
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

extension LibraryScanTrigger {
  fileprivate var title: String {
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
