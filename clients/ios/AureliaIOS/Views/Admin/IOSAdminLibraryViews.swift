import SwiftUI

/// Settings › Library: storage locations, scans, import review and library health. Aurelia only
/// reads the media: nothing here moves, renames or deletes a video file.
struct IOSAdminLibraryView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel

  struct Overview: Sendable {
    let libraries: [IOSLibrarySummary]
    let scans: [IOSLibraryScan]
    let configuration: IOSServerConfiguration?
  }

  var body: some View {
    let owner = admin.permissions.owner
    IOSAdminLoader { client in
      async let libraries = client.libraries()
      async let scans = (try? client.activeScans()) ?? []
      async let configuration = owner ? try? client.serverSettings() : nil
      return Overview(
        libraries: try await libraries, scans: await scans, configuration: await configuration)
    } content: { overview, reload in
      IOSAdminLibraryContent(overview: overview, reload: reload)
    }
    .navigationTitle("Library")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminLibraryContent: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let overview: IOSAdminLibraryView.Overview
  let reload: () async -> Void
  @State private var adding = false
  @State private var reviewing: IOSLibrarySummary?
  @State private var confirmation: IOSAdminConfirmation?

  private func isScanning(_ library: IOSLibrarySummary) -> Bool {
    overview.scans.contains { $0.libraryId == library.id && $0.isActive }
  }

  var body: some View {
    Form {
      IOSAdminPageHeader(
        page: .library,
        text:
          "The folders on the server computer that hold your movies and shows. Aurelia only reads them: nothing here moves, renames or deletes a video.")
      Section {
        if overview.libraries.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("No storage locations yet").font(.headline)
            Text("Add the folder on the server computer where your movies or shows are, and Aurelia finds them.")
              .font(.subheadline).foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }
        ForEach(overview.libraries) { library in
          NavigationLink {
            IOSAdminStorageLocationView(libraryID: library.id)
          } label: {
            IOSLibraryRow(
              library: library, scan: overview.scans.first { $0.libraryId == library.id && $0.isActive })
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { confirmRemove(library) } label: {
              Label("Remove", systemImage: "trash")
            }
            if !IOSLibraryAdminText.isWaitingForReview(library) {
              Button { scan(library) } label: { Label("Scan", systemImage: "arrow.clockwise") }
                .tint(.indigo)
            }
          }
          .contextMenu { menu(for: library) }
          .accessibilityIdentifier("admin-library-\(library.id.uuidString.lowercased())")
        }
        Button {
          adding = true
        } label: {
          Label("Add Storage Location…", systemImage: "plus.circle.fill")
        }
        .accessibilityIdentifier("admin-add-library")
        if !overview.libraries.isEmpty {
          IOSAdminActionButton(
            "Scan All", systemImage: "arrow.clockwise",
            detail: "Looks for new, changed and missing files in every location.", doneText: "Started"
          ) { _ = try await $0.scanAllLibraries() }
        }
      } header: {
        Text("Storage Locations")
      } footer: {
        Text(
          overview.libraries.isEmpty
            ? "A storage location is a folder or drive connected to the server computer, not to this \(IOSDesign.deviceName)."
            : "Tap a location for its details and import review. Swipe it or touch and hold for Scan, Watch for Changes and Remove."
        )
      }
      let active = overview.scans.filter(\.isActive)
      if !active.isEmpty {
        Section {
          ForEach(active) { scan in
            IOSScanRow(
              scan: scan,
              name: overview.libraries.first { $0.id == scan.libraryId }?.name ?? "Storage location")
          }
        } header: {
          Text("Scanning Now")
        } footer: {
          Text("A scan reads only file names and folders. New titles appear while it runs.")
        }
      }
      if let configuration = overview.configuration {
        Section {
          IOSPolicyToggle(
            configuration: configuration, key: "monitoringEnabled", label: "Watch Storage for Changes",
            detail: "Notices new and changed files by itself, so you rarely need to scan by hand.")
          NavigationLink {
            IOSAdminPolicyView(
              title: "Automatic Scans", groups: [.maintenance], configuration: configuration,
              explanation:
                "How often the server scans by itself and when maintenance runs. Each storage location can also watch for changes on its own.")
          } label: {
            IOSAdminToggleLabel("Scan Schedule", "When the server checks every location by itself.")
          }
        } header: {
          Text("Automatic Scans")
        } footer: {
          Text(
            "This switch is for the whole server. A location's own “Watch for Changes” only matters while it is on."
          )
        }
      }
      Section {
        NavigationLink {
          IOSAdminLibraryHealthView()
        } label: {
          IOSAdminToggleLabel(
            "Library Health", "Duplicates, titles whose drive is away, and titles without information.")
        }
        .accessibilityIdentifier("admin-library-health")
      }
      Section {
        NavigationLink {
          IOSAdminDangerZoneView()
        } label: {
          Label("Reset Library…", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
        .accessibilityIdentifier("admin-danger")
      } footer: {
        Text("Starts the catalog over for chosen locations. Video files are never touched.")
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
    .sheet(isPresented: $adding) {
      NavigationStack {
        IOSAdminAddLibraryView { added in
          Task { await afterAdding(added) }
        }
      }
    }
    .sheet(item: $reviewing) { library in
      NavigationStack { IOSAdminImportPreviewView(library: library) }
    }
    .task(id: overview.scans.map(\.filesProcessed)) {
      guard overview.scans.contains(where: \.isActive) else { return }
      try? await Task.sleep(for: .seconds(3))
      await reload()
    }
  }

  @ViewBuilder
  private func menu(for library: IOSLibrarySummary) -> some View {
    let waiting = IOSLibraryAdminText.isWaitingForReview(library)
    if waiting {
      Button { reviewing = library } label: { Label("Review Import…", systemImage: "checklist") }
    } else {
      Button { scan(library) } label: { Label("Scan Now", systemImage: "arrow.clockwise") }
      Button {
        let (id, enabled) = (library.id, !(library.monitoringEnabled ?? false))
        Task { await admin.perform { _ = try await $0.setLibraryMonitoring(id: id, enabled: enabled) } }
      } label: {
        Label(
          library.monitoringEnabled == true ? "Stop Watching for Changes" : "Watch for Changes",
          systemImage: library.monitoringEnabled == true ? "eye.slash" : "eye")
      }
      Button { reviewing = library } label: { Label("Review Assignments…", systemImage: "checklist") }
    }
    Divider()
    Button(role: .destructive) { confirmRemove(library) } label: {
      Label("Remove…", systemImage: "trash")
    }
  }

  private func scan(_ library: IOSLibrarySummary) {
    let id = library.id
    Task { await admin.perform("Scanning \(library.name)…") { _ = try await $0.scanLibrary(id: id) } }
  }

  private func confirmRemove(_ library: IOSLibrarySummary) {
    confirmation = IOSAdminConfirmation(
      title: "Remove “\(library.name)”?",
      message:
        "Its titles, watch history and favorites leave Aurelia. The folder and its videos stay untouched.",
      action: "Remove"
    ) {
      let id = library.id
      Task { await admin.perform("Removing…") { try await $0.removeLibrary(id: id) } }
    }
  }

  /// After adding: review the first import, or start scanning so something visibly happens.
  private func afterAdding(_ added: [IOSLibrarySummary]) async {
    if let first = added.first(where: { $0.importPreviewRequired == true }) {
      reviewing = first
      return
    }
    let ids = added.map(\.id)
    await admin.perform("Scanning the new storage location…") { client in
      for id in ids { _ = try await client.scanLibrary(id: id) }
    }
  }
}

/// A storage location in the list: name, folder and what it is doing now.
private struct IOSLibraryRow: View {
  let library: IOSLibrarySummary
  let scan: IOSLibraryScan?

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: library.isAvailable ? "externaldrive.fill" : "externaldrive.badge.exclamationmark")
        .font(.title3)
        .foregroundStyle(library.isAvailable ? Color.secondary : Color.orange)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(library.name).font(.body.weight(.medium))
          if library.monitoringEnabled == true {
            Image(systemName: "eye").font(.caption2).foregroundStyle(.secondary)
              .accessibilityLabel("Watching for changes")
          }
        }
        Text(library.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          .truncationMode(.middle)
        let waiting = IOSLibraryAdminText.isWaitingForReview(library)
        Text(IOSLibraryAdminText.status(library, scanning: scan != nil))
          .font(.caption2)
          .foregroundStyle(waiting || !library.isAvailable ? Color.orange : Color.secondary)
        if let scan {
          if let progress = scan.progress { ProgressView(value: progress).tint(.indigo) }
          Text(IOSLibraryAdminText.summary(scan)).font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 2)
  }
}

private struct IOSScanRow: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let scan: IOSLibraryScan
  let name: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(name)
          Text(
            [scan.stateTitle, IOSLibraryAdminText.trigger(scan.trigger)].compactMap { $0 }
              .joined(separator: " · ")
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if scan.isActive {
          Button("Stop", role: .destructive) {
            let id = scan.id
            Task { await admin.perform { try await $0.cancelScan(id: id) } }
          }
          .buttonStyle(.borderless)
        }
      }
      if let progress = scan.progress, scan.isActive { ProgressView(value: progress).tint(.indigo) }
      Text(IOSLibraryAdminText.summary(scan)).font(.caption).foregroundStyle(.secondary)
      if let error = scan.error { Text(error).font(.caption).foregroundStyle(.orange) }
      if !scan.issues.isEmpty {
        DisclosureGroup("\(scan.issues.count) \(scan.issues.count == 1 ? "Problem" : "Problems")") {
          ForEach(Array(scan.issues.prefix(10).enumerated()), id: \.offset) { _, issue in
            VStack(alignment: .leading, spacing: 2) {
              Text(issue.message).font(.caption)
              if let path = issue.path {
                Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
              }
            }
          }
        }
        .font(.caption)
      }
    }
  }
}

/// One storage location: scanning, watching, import review, left-out items and removing it.
private struct IOSAdminStorageLocationView: View {
  let libraryID: UUID

  struct Loaded: Sendable {
    let library: IOSLibrarySummary
    let scans: [IOSLibraryScan]
    let exclusions: [IOSExcludedMedia]
    let discoveries: [IOSLibraryDiscovery]
    let reviews: [IOSLibraryImportReview]
  }

  var body: some View {
    IOSAdminLoader { client in
      async let libraries = client.libraries()
      async let scans = (try? client.libraryScans(id: libraryID)) ?? []
      async let exclusions = (try? client.exclusions(library: libraryID)) ?? []
      async let discoveries = (try? client.discoveries(library: libraryID)) ?? []
      async let reviews = (try? client.importReviews(library: libraryID)) ?? []
      guard let library = try await libraries.first(where: { $0.id == libraryID }) else {
        throw IOSCoreError.server(
          status: 404, code: "library_not_found", message: "This storage location was removed.",
          retryAfter: nil)
      }
      return Loaded(
        library: library, scans: await scans, exclusions: await exclusions,
        discoveries: await discoveries, reviews: await reviews)
    } content: { loaded, reload in
      IOSAdminStorageLocationForm(loaded: loaded, reload: reload)
    }
    .navigationTitle("Storage Location")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminStorageLocationForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dismiss) private var dismiss
  let loaded: IOSAdminStorageLocationView.Loaded
  let reload: () async -> Void
  @State private var confirmation: IOSAdminConfirmation?
  @State private var reviewing = false
  @State private var assigning: IOSLibraryImportReview?

  var body: some View {
    let library = loaded.library
    let waiting = IOSLibraryAdminText.isWaitingForReview(library)
    let scanning = loaded.scans.contains(where: \.isActive)
    Form {
      Section {
        HStack(spacing: 12) {
          Image(systemName: library.isAvailable ? "externaldrive.fill" : "externaldrive.badge.exclamationmark")
            .font(.title2).foregroundStyle(library.isAvailable ? Color.indigo : Color.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text(library.name).font(.headline)
            Text(library.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        LabeledContent("Contains", value: library.kindTitle)
        LabeledContent("Status", value: library.availabilityTitle)
        LabeledContent("Last Scan", value: IOSAdminFormat.relative(library.lastScanCompletedAt))
        if let error = library.lastError { Text(error).font(.callout).foregroundStyle(.orange) }
      } footer: {
        if !library.isAvailable {
          Text(
            "The drive isn’t reachable from the server. Titles keep their progress and favorites until it is back."
          )
        }
      }
      if waiting {
        Section {
          Button {
            reviewing = true
          } label: {
            Label("Review Import…", systemImage: "checklist").font(.body.weight(.semibold))
          }
          .accessibilityIdentifier("admin-review-import")
        } header: {
          Text("Waiting for You")
        } footer: {
          Text(
            "Nothing from this location is in the library yet. Review shows what each folder and file becomes; you can correct it, then import."
          )
        }
      }
      Section {
        IOSAdminActionButton(
          "Scan Now", systemImage: "arrow.clockwise",
          detail: waiting ? "Available after the import." : "Looks for new, changed and missing files.",
          doneText: "Started"
        ) { [id = library.id] client in _ = try await client.scanLibrary(id: id) }
        .disabled(waiting || scanning)
        Toggle(
          isOn: Binding(
            get: { library.monitoringEnabled ?? false },
            set: { value in
              let id = library.id
              Task { await admin.perform { _ = try await $0.setLibraryMonitoring(id: id, enabled: value) } }
            })
        ) {
          IOSAdminToggleLabel(
            "Watch for Changes", "Adds new files and notices changes by itself, without a scan.")
        }
        .disabled(waiting)
        if !waiting {
          Button {
            reviewing = true
          } label: {
            IOSAdminToggleLabel(
              "Review Assignments…", "See and correct what each folder and file became.")
          }
        }
      } header: {
        Text("Scanning")
      }
      if !loaded.discoveries.isEmpty {
        Section {
          ForEach(loaded.discoveries) { discovery in
            IOSDiscoveryRow(discovery: discovery)
          }
        } header: {
          Text("Folders to Sort")
        } footer: {
          Text("Aurelia wasn’t sure whether these folders hold movies or a TV show. Your choice applies at once.")
        }
      }
      let pending = loaded.reviews.filter { $0.state == "pending" }
      if !pending.isEmpty {
        Section {
          ForEach(pending) { review in
            VStack(alignment: .leading, spacing: 6) {
              Text(review.detectedTitle)
              Text(review.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
              Text(review.reason).font(.caption2).foregroundStyle(.secondary)
              HStack(spacing: 16) {
                Button("Assign to Movie…") { assigning = review }
                Button("Leave Out") {
                  let (id, review) = (library.id, review.id)
                  Task {
                    await admin.perform { _ = try await $0.decideImportReview(library: id, review: review, movieId: nil) }
                  }
                }
              }
              .buttonStyle(.borderless)
              .font(.callout)
            }
          }
        } header: {
          Text("Files to Check")
        } footer: {
          Text(
            "Files Aurelia couldn’t place, such as an extra or a second version of a movie. Assign them to a movie or leave them out."
          )
        }
      }
      if !loaded.exclusions.isEmpty {
        Section {
          ForEach(loaded.exclusions) { excluded in
            HStack {
              Label(excluded.relativePath, systemImage: excluded.isDirectory ? "folder" : "film")
                .lineLimit(2)
              Spacer()
              Button("Include") {
                let (library, id) = (library.id, excluded.id)
                Task { await admin.perform { try await $0.restoreExclusion(library: library, id: id) } }
              }
              .buttonStyle(.borderless)
            }
          }
        } header: {
          Text("Left Out")
        } footer: {
          Text("Files and folders you removed from Aurelia. Include brings them back with the next scan; the files were never touched.")
        }
      }
      Section {
        if loaded.scans.isEmpty { Text("No scans yet").foregroundStyle(.secondary) }
        ForEach(loaded.scans) { scan in
          IOSScanRow(scan: scan, name: IOSAdminFormat.date(scan.createdAt))
        }
      } header: {
        Text("Recent Scans")
      }
      Section {
        Button("Remove Storage Location…", role: .destructive) {
          confirmation = IOSAdminConfirmation(
            title: "Remove “\(library.name)”?",
            message:
              "Its titles, watch history and favorites leave Aurelia. The folder and its videos stay untouched.",
            action: "Remove"
          ) {
            let id = library.id
            Task {
              if await admin.perform("Removing…", { try await $0.removeLibrary(id: id) }) { dismiss() }
            }
          }
        }
      } footer: {
        Text("Only Aurelia forgets the location. The folder and every file in it stay as they are.")
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
    .sheet(isPresented: $reviewing) {
      NavigationStack { IOSAdminImportPreviewView(library: library) }
    }
    .sheet(item: $assigning) { review in
      NavigationStack { IOSAssignToMovieView(library: library, review: review) }
    }
    .task(id: loaded.scans.map(\.filesProcessed)) {
      guard scanning else { return }
      try? await Task.sleep(for: .seconds(3))
      await reload()
    }
  }
}

/// Assigns a file under review to a movie of the same storage location.
private struct IOSAssignToMovieView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dismiss) private var dismiss
  let library: IOSLibrarySummary
  let review: IOSLibraryImportReview
  @State private var query = ""
  @State private var results: [IOSCatalogItem] = []
  @State private var searching = false

  var body: some View {
    List {
      Section {
        Text(review.relativePath).font(.caption).foregroundStyle(.secondary)
      } footer: {
        Text("Search for the movie this file belongs to, for example as a second version or an extra.")
      }
      if searching { ProgressView() }
      if !searching && results.isEmpty && !query.isEmpty {
        Text("No movie found in “\(library.name)”.").foregroundStyle(.secondary)
      }
      ForEach(results) { movie in
        Button {
          let (libraryID, reviewID, movieID) = (library.id, review.id, movie.id)
          Task {
            if await admin.perform("Assigning…", {
              _ = try await $0.decideImportReview(library: libraryID, review: reviewID, movieId: movieID)
            }) {
              dismiss()
            }
          }
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(movie.title).foregroundStyle(.primary)
            if let year = movie.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
          }
        }
      }
    }
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movie title")
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Assign to Movie")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    .task(id: query) {
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      let (typed, id) = (query, library.id)
      searching = !typed.isEmpty
      results = (try? await admin.run { try await $0.searchMovies(typed, library: id) }) ?? []
      searching = false
    }
  }
}

private struct IOSDiscoveryRow: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let discovery: IOSLibraryDiscovery

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(discovery.detectedTitle)
      Text(discovery.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      Picker(
        "Contains",
        selection: Binding(
          get: { discovery.decision ?? "" },
          set: { decision in
            let (library, id) = (discovery.libraryId, discovery.id)
            Task {
              await admin.perform("Saving…") {
                if decision.isEmpty {
                  _ = try await $0.resetClassification(library: library, discovery: id)
                } else {
                  _ = try await $0.setClassification(library: library, discovery: id, decision: decision)
                }
              }
            }
          })
      ) {
        Text("Decide Automatically").tag("")
        Text("A Movie").tag("movie")
        Text("A TV Show").tag("tvShows")
        Text("Leave Out").tag("ignore")
      }
    }
  }
}

/// Add Storage Location: choose one or more folders on the server, then how Aurelia reads them.
private struct IOSAdminAddLibraryView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dismiss) private var dismiss
  let added: ([IOSLibrarySummary]) -> Void
  @State private var chosen: [IOSServerFolder] = []
  @State private var browsing = true
  @State private var name = ""
  @State private var kind = "automatic"
  @State private var review = true
  @State private var problem: String?
  @State private var saving = false

  var body: some View {
    Group {
      if browsing {
        IOSServerFolderBrowser(path: nil, chosen: chosen) { folder in
          if !chosen.contains(folder) { chosen.append(folder) }
          if chosen.count == 1 { name = IOSLibraryAdminText.suggestedName(for: folder.path) }
          browsing = false
        }
      } else {
        IOSAdminForm(title: "Add Storage Location") {
          Section {
            ForEach(chosen, id: \.path) { folder in
              Label {
                VStack(alignment: .leading, spacing: 2) {
                  Text(IOSLibraryAdminText.suggestedName(for: folder.path))
                  Text(folder.path).font(.caption).foregroundStyle(.secondary)
                }
              } icon: {
                Image(systemName: "folder.fill").foregroundStyle(.indigo)
              }
            }
            .onDelete { chosen.remove(atOffsets: $0) }
            Button {
              browsing = true
            } label: {
              Label("Add Another Folder", systemImage: "plus")
            }
          } header: {
            Text(chosen.count == 1 ? "Folder" : "\(chosen.count) Folders")
          } footer: {
            Text("Folders on the server computer. Swipe one to take it off this list.")
          }
          Section {
            if chosen.count == 1 {
              TextField("Name", text: $name)
            }
            Picker("Contains", selection: $kind) {
              Text("Find Out Automatically").tag("automatic")
              Text("Movies").tag("movies")
              Text("TV Shows").tag("tvShows")
            }
          } footer: {
            Text(
              "“Find Out Automatically” sorts movies and shows by their folder and file names. Choose Movies or TV Shows when a folder holds only one kind."
            )
          }
          Section {
            Toggle(isOn: $review) {
              IOSAdminToggleLabel(
                "Review Before Importing",
                "First shows what each folder and file becomes. Nothing is imported until you confirm.")
            }
          } footer: {
            Text(
              review
                ? "After adding, the review opens right away."
                : "After adding, the first scan starts right away and titles appear as it finds them.")
          }
          if let problem { Section { Text(problem).foregroundStyle(.orange) } }
        }
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            if saving {
              ProgressView()
            } else {
              Button("Add") { Task { await add() } }.disabled(chosen.isEmpty)
            }
          }
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
    }
  }

  private func add() async {
    saving = true
    defer { saving = false }
    let requests = chosen.map { folder in
      IOSCreateLibraryRequest(
        name: chosen.count == 1 && !name.trimmingCharacters(in: .whitespaces).isEmpty
          ? name.trimmingCharacters(in: .whitespaces) : nil,
        path: folder.path, kind: kind, combineExisting: false, requireImportPreview: review)
    }
    var created: [IOSLibrarySummary] = []
    for request in requests {
      guard let library = await admin.value(nil, { try await $0.createLibrary(request) }) else {
        problem = created.isEmpty ? nil : "\(created.count) of \(requests.count) folders were added."
        if !created.isEmpty { added(created) }
        return
      }
      created.append(library)
    }
    dismiss()
    added(created)
  }
}

/// The folders on the server computer, one level at a time, with a way up and a typed path.
private struct IOSServerFolderBrowser: View {
  let path: String?
  let chosen: [IOSServerFolder]
  let choose: (IOSServerFolder) -> Void
  @State private var typing = false
  @State private var typed = ""
  @State private var typedPath: String?

  var body: some View {
    IOSAdminLoader { try await $0.serverFolders(path: path) } content: { listing, _ in
      List {
        if let current = listing.path {
          Section {
            Button {
              choose(IOSServerFolder(name: IOSLibraryAdminText.suggestedName(for: current), path: current))
            } label: {
              Label("Use This Folder", systemImage: "checkmark.circle.fill").font(.body.weight(.semibold))
            }
            .accessibilityIdentifier("admin-use-folder")
            .disabled(chosen.contains { $0.path == current })
          } header: {
            Text(current).textCase(nil).font(.caption.monospaced())
          } footer: {
            Text("Or open a folder below to go deeper.")
          }
        } else {
          Section {
            Text(
              "These are the drives and folders of the server computer, not of this \(IOSDesign.deviceName). Open one to find your movies or shows."
            )
            .font(.subheadline).foregroundStyle(.secondary)
          }
        }
        Section {
          if listing.folders.isEmpty { Text("No folders inside").foregroundStyle(.secondary) }
          ForEach(listing.folders, id: \.path) { folder in
            NavigationLink {
              IOSServerFolderBrowser(path: folder.path, chosen: chosen, choose: choose)
            } label: {
              Label {
                VStack(alignment: .leading, spacing: 2) {
                  Text(folder.name)
                  if listing.path == nil {
                    Text(folder.path).font(.caption).foregroundStyle(.secondary)
                  }
                }
              } icon: {
                Image(systemName: listing.path == nil ? "externaldrive" : "folder")
                  .foregroundStyle(.indigo)
              }
            }
            .swipeActions {
              Button("Use") { choose(folder) }.tint(.indigo)
            }
          }
        } header: {
          if listing.path == nil { Text("Places") }
        }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .navigationTitle(listing.path.map { IOSLibraryAdminText.suggestedName(for: $0) } ?? "Server Folders")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            typed = listing.path ?? ""
            typing = true
          } label: {
            Label("Type a Path", systemImage: "character.cursor.ibeam")
          }
        }
      }
      .alert("Go to Folder", isPresented: $typing) {
        TextField("/path/on/the/server", text: $typed)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("Go") { typedPath = IOSLibraryAdminText.typedPath(typed) }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Type a folder path on the server computer, such as /mnt/media.")
      }
      .navigationDestination(item: $typedPath) { path in
        IOSServerFolderBrowser(path: path, chosen: chosen, choose: choose)
      }
    }
  }
}

/// Import Preview: what each folder and file becomes, corrections for one or many, then import.
private struct IOSAdminImportPreviewView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dismiss) private var dismiss
  let library: IOSLibrarySummary
  @State private var summary: IOSImportPreviewSummary?
  @State private var items: [IOSImportPreviewItem] = []
  @State private var filter = "all"
  @State private var search = ""
  @State private var editing: [IOSImportPreviewItem]?
  @State private var loading = true
  @State private var selecting = false
  @State private var selection: Set<String> = []
  @State private var confirmingDiscard = false
  @State private var confirmingAgain = false

  private var shown: [IOSImportPreviewItem] {
    let query = search.trimmingCharacters(in: .whitespaces)
    return items.filter { item in
      (filter == "all" || item.status == filter)
        && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)
          || item.relativePath.localizedCaseInsensitiveContains(query))
    }
  }
  private var isFirstImport: Bool { library.importPreviewRequired == true }

  var body: some View {
    List {
      Section {
        Text(
          isFirstImport
            ? "Aurelia read the folder and file names of “\(library.name)”. Nothing is imported until you tap Import. Tap an item to correct it, or Select to correct several at once."
            : "What each folder and file of “\(library.name)” became. Tap an item to correct it; Apply saves your corrections."
        )
        .font(.subheadline).foregroundStyle(.secondary)
        if let summary {
          let counts = summary.counts
          Text(
            "\(counts.movies) movies · \(counts.series) shows · \(counts.episodes) episodes · \(counts.extras + counts.trailers) extras"
          )
          if counts.pending > 0 || counts.errors > 0 {
            Text("\(counts.pending) need review · \(counts.errors) errors").foregroundStyle(.orange)
          }
          if counts.errors > 0 {
            Text("Fix the errors first: they would import wrongly.").font(.caption).foregroundStyle(.orange)
          }
          Picker("Show", selection: $filter) {
            Text("All").tag("all")
            Text("Needs Review").tag("pending")
            Text("Ignored").tag("ignored")
            Text("Errors").tag("error")
          }
          .pickerStyle(.segmented)
        } else if loading {
          ProgressView("Reading file names and folders…")
        }
      }
      Section {
        ForEach(shown) { item in
          Button {
            if selecting {
              if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            } else {
              editing = [item]
            }
          } label: {
            HStack(spacing: 10) {
              if selecting {
                Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(selection.contains(item.id) ? Color.accentColor : .secondary)
              }
              Image(systemName: item.isDirectory ? "folder" : "film").foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? item.relativePath : item.title).foregroundStyle(.primary)
                Text(item.relativePath.isEmpty ? "Storage root" : item.relativePath).font(.caption)
                  .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if item.status == "pending" || item.status == "error", !item.reason.isEmpty {
                  Text(item.reason).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
              }
              Spacer()
              Text(Self.kindLabel(item))
                .font(.caption)
                .foregroundStyle(item.status == "pending" || item.status == "error" ? Color.orange : .secondary)
            }
          }
        }
      }
    }
    .searchable(text: $search)
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle(selecting ? "\(selection.count) Selected" : "Import Preview")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Close") {
          if isFirstImport && summary != nil { confirmingDiscard = true } else { dismiss() }
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(isFirstImport ? "Import" : "Apply") { confirm() }
          .disabled(summary == nil || summary?.counts.errors != 0 || selecting)
      }
      ToolbarItemGroup(placement: .bottomBar) {
        if selecting {
          Button("Done") {
            selecting = false
            selection = []
          }
          Spacer()
          Button("Correct \(selection.count)…") {
            editing = items.filter { selection.contains($0.id) }
          }
          .disabled(selection.isEmpty)
        } else {
          Button("Select") { selecting = true }.disabled(items.isEmpty)
          Spacer()
          Button("Analyze Again") { confirmingAgain = true }.disabled(summary == nil)
        }
      }
    }
    .confirmationDialog(
      "Close without importing?", isPresented: $confirmingDiscard, titleVisibility: .visible
    ) {
      Button("Close", role: .destructive) { dismiss() }
      Button("Keep Reviewing", role: .cancel) {}
    } message: {
      Text("Nothing from “\(library.name)” is imported yet. Your corrections are kept for next time.")
    }
    .confirmationDialog(
      "Read the folder again?", isPresented: $confirmingAgain, titleVisibility: .visible
    ) {
      Button("Analyze Again") { Task { await analyze() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Use this after adding or renaming files. Corrections you saved stay.")
    }
    .task { await analyze() }
    .sheet(
      isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
    ) {
      if let editing, let summary {
        NavigationStack {
          IOSImportAssignmentEditor(items: editing, targets: summary.targets) { changes in
            await save(changes)
          }
        }
      }
    }
  }

  static func kindLabel(_ item: IOSImportPreviewItem) -> String {
    switch item.kind {
    case "movie": return "Movie"
    case "series": return "Series"
    case "episode":
      return "S\(item.seasonNumber ?? 0) E\(item.episodeNumber ?? 0)"
    case "extra": return "Extra"
    case "trailer": return "Trailer"
    default:
      return item.status == "ignored" ? "Ignored" : item.status == "error" ? "Error" : "Needs Review"
    }
  }

  private func analyze() async {
    loading = true
    defer { loading = false }
    let id = library.id
    guard let summary = await admin.value(nil, { try await $0.analyzeImport(library: id) }) else {
      return
    }
    self.summary = summary
    await loadItems(summary)
  }

  private func loadItems(_ summary: IOSImportPreviewSummary) async {
    let (library, preview) = (library.id, summary.previewId)
    var all: [IOSImportPreviewItem] = []
    var offset = 0
    while true {
      let start = offset
      guard let page = await admin.value(nil, {
        try await $0.importPreviewItems(library: library, preview: preview, offset: start)
      }) else { return }
      all += page.items
      offset += page.items.count
      if page.items.isEmpty || offset >= page.totalCount { break }
    }
    items = all
  }

  private func save(_ changes: [IOSImportAssignment]) async {
    guard let summary else { return }
    let (library, preview, revision) = (library.id, summary.previewId, summary.revision)
    if let updated = await admin.value("Saving…", {
      try await $0.updateImportPreview(
        library: library, preview: preview, revision: revision, assignments: changes)
    }) {
      self.summary = updated
      editing = nil
      selecting = false
      selection = []
      await loadItems(updated)
    }
  }

  private func confirm() {
    guard let summary else { return }
    let (library, preview, revision) = (library.id, summary.previewId, summary.revision)
    Task {
      if await admin.perform("Importing…", {
        _ = try await $0.confirmImportPreview(library: library, preview: preview, revision: revision)
      }) {
        dismiss()
      }
    }
  }
}

/// What the chosen files or folders become.
private struct IOSImportAssignmentEditor: View {
  @Environment(\.dismiss) private var dismiss
  let items: [IOSImportPreviewItem]
  let targets: [IOSImportPreviewTarget]
  let save: ([IOSImportAssignment]) async -> Void
  @State private var form: IOSImportRules.Form
  @State private var problem: String?

  init(
    items: [IOSImportPreviewItem], targets: [IOSImportPreviewTarget],
    save: @escaping ([IOSImportAssignment]) async -> Void
  ) {
    self.items = items
    self.targets = targets
    self.save = save
    _form = State(initialValue: IOSImportRules.Form(start: items))
  }

  private var needsParent: Bool { ["episode", "extra", "trailer"].contains(form.choice) }
  private var parent: IOSImportPreviewTarget? { targets.first { $0.relativePath == form.parentPath } }

  var body: some View {
    IOSAdminForm(title: items.count == 1 ? (items[0].title.isEmpty ? "Item" : items[0].title) : "\(items.count) Items") {
      Section {
        Picker("This Is", selection: $form.choice) {
          ForEach(IOSImportRules.choices(for: items)) { Text($0.label).tag($0.id) }
        }
      } footer: {
        Text(
          items.count == 1
            ? (items[0].relativePath.isEmpty ? "The storage root" : items[0].relativePath)
            : "The choice applies to all \(items.count) items.")
      }
      if needsParent {
        Section {
          Picker("Belongs To", selection: $form.parentPath) {
            Text("Choose…").tag("")
            ForEach(targets) { Text($0.title).tag($0.relativePath) }
          }
          if parent?.kind == "series" {
            if form.choice != "episode" { Toggle("For the Whole Series", isOn: $form.entireSeries) }
            if form.choice == "episode" || !form.entireSeries {
              Stepper("Season \(form.season)", value: $form.season, in: 0...99)
            }
            if form.choice == "episode" {
              Stepper("Episode \(form.episode)", value: $form.episode, in: 1...999)
            }
          }
          if form.choice != "episode" { TextField("Category (optional)", text: $form.category) }
        } footer: {
          Text("Episodes, extras and trailers belong to a movie or show of this location.")
        }
      }
      if items.count == 1 && !items[0].isDirectory {
        Section { TextField("Title (optional)", text: $form.title) }
      }
      if let problem { Section { Text(problem).foregroundStyle(.orange) } }
      Section {
        Button("Use Automatic Detection") {
          let changes = items.map {
            IOSImportAssignment(
              relativePath: $0.relativePath, isDirectory: $0.isDirectory, kind: nil,
              useAutomaticDetection: true)
          }
          Task { await save(changes) }
        }
      } footer: {
        Text("Forgets your correction and lets Aurelia decide from the names again.")
      }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          do {
            let changes = try IOSImportRules.changes(items: items, form: form, targets: targets)
            problem = nil
            Task { await save(changes) }
          } catch {
            problem = error.localizedDescription
          }
        }
      }
    }
  }
}

/// Library Health: duplicates to combine, titles whose drive is away, and titles without
/// information to match. Each part loads on its own, so one problem doesn't hide the others.
private struct IOSAdminLibraryHealthView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @State private var duplicates: Result<[IOSDuplicateGroup], Error>?
  @State private var offline: Result<[IOSHealthOfflineTitle], Error>?
  @State private var unmatched: Result<[IOSUnmatchedTitle], Error>?
  @State private var offlineDays = 30
  @State private var confirmation: IOSAdminConfirmation?
  @State private var matching: IOSUnmatchedTitle?

  var body: some View {
    Form {
      IOSAdminPageHeader(
        systemImage: "stethoscope", title: "Library Health",
        text: "Things worth tidying up. Nothing here deletes a file: only Aurelia’s entries change.")
      duplicatesSection
      offlineSection
      unmatchedSection
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Library Health")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await loadAll() }
    .adminConfirmation($confirmation)
    .task { await loadAll() }
    .onChange(of: offlineDays) { _, _ in Task { await loadOffline() } }
    .sheet(item: $matching) { title in
      NavigationStack {
        IOSMetadataMatchView(title: title) { Task { await loadUnmatched() } }
      }
    }
  }

  private var duplicatesSection: some View {
    Section {
      switch duplicates {
      case nil: ProgressView()
      case .failure(let error):
        IOSAdminSectionProblem(message: IOSAdministrationModel.message(error)) { await loadDuplicates() }
      case .success(let groups):
        if groups.isEmpty { Label("No duplicates", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
        ForEach(groups) { group in duplicateGroup(group) }
      }
    } header: {
      Text("Duplicates")
    } footer: {
      Text("The same title found more than once. Keep one: the others are combined into it with their watch history and favorites.")
    }
  }

  private var offlineSection: some View {
    Section {
      Picker("Away For", selection: $offlineDays) {
        ForEach(IOSLibraryAdminText.offlineChoices, id: \.self) { Text("\($0) days").tag($0) }
      }
      switch offline {
      case nil: ProgressView()
      case .failure(let error):
        IOSAdminSectionProblem(message: IOSAdministrationModel.message(error)) { await loadOffline() }
      case .success(let titles):
        if titles.isEmpty { Label("Nothing away that long", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
        ForEach(titles) { title in offlineRow(title) }
      }
    } header: {
      Text("Drive Away")
    } footer: {
      Text("Titles keep their progress and favorites while their drive is away. Remove only those that won’t come back.")
    }
  }

  private func offlineRow(_ title: IOSHealthOfflineTitle) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title.title)
        Text("\(title.libraryName) · away for \(title.daysOffline) days").font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Remove", role: .destructive) { confirmRemove(title) }.buttonStyle(.borderless)
    }
  }

  private func confirmRemove(_ title: IOSHealthOfflineTitle) {
    let id = title.id
    confirmation = IOSAdminConfirmation(
      title: "Remove “\(title.title)” from Aurelia?",
      message: "Only the entry goes; if the drive comes back, a scan adds the title again.",
      action: "Remove"
    ) {
      Task {
        let removed = await admin.perform { try await $0.removeHealthEntry(mediaId: id) }
        if removed { await loadOffline() }
      }
    }
  }

  private var unmatchedSection: some View {
    Section {
      switch unmatched {
      case nil: ProgressView()
      case .failure(let error):
        IOSAdminSectionProblem(message: IOSAdministrationModel.message(error)) { await loadUnmatched() }
      case .success(let titles):
        if titles.isEmpty { Label("Every title has information", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
        ForEach(titles) { title in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(title.title)
              Text(title.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Match…") { matching = title }.buttonStyle(.borderless)
          }
        }
      }
    } header: {
      Text("Without Information")
    } footer: {
      Text("Aurelia couldn’t find these on TMDB by their file names. Match one to give it a poster and description.")
    }
  }

  @ViewBuilder
  private func duplicateGroup(_ group: IOSDuplicateGroup) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text([group.title, group.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
        .font(.headline)
      ForEach(group.items) { item in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(item.fileName).font(.caption).lineLimit(2)
            Text(item.availability == "available" ? IOSAdminText.bytes(item.fileSize) : "Drive away")
              .font(.caption2).foregroundStyle(.secondary)
          }
          Spacer()
          if group.items.count > 1 {
            Button("Keep") {
              let target = item.id
              let sources = group.items.map(\.id).filter { $0 != target }
              confirmation = IOSAdminConfirmation(
                title: "Keep this one?",
                message:
                  "The others are combined into it, with their watch history and favorites. No file is deleted.",
                action: "Combine"
              ) {
                Task {
                  if await admin.perform("Combining…", { client in
                    for source in sources { try await client.mergeDuplicates(source: source, target: target) }
                  }) {
                    await loadDuplicates()
                  }
                }
              }
            }
            .buttonStyle(.borderless)
          }
        }
      }
    }
  }

  private func loadAll() async {
    async let first: Void = loadDuplicates()
    async let second: Void = loadOffline()
    async let third: Void = loadUnmatched()
    _ = await (first, second, third)
  }

  private func loadDuplicates() async {
    duplicates = await load { try await $0.healthDuplicates() }
  }
  private func loadOffline() async {
    let days = offlineDays
    offline = await load { try await $0.healthOffline(days: days) }
  }
  private func loadUnmatched() async {
    unmatched = await load { try await $0.healthUnmatched() }
  }

  private func load<Value: Sendable>(_ work: @Sendable (IOSAPIClient) async throws -> Value) async
    -> Result<Value, Error>?
  {
    do {
      return .success(try await admin.run(work))
    } catch is CancellationError {
      return nil
    } catch {
      return .failure(error)
    }
  }
}

/// Finds a title on TMDB by name and gives it that information.
private struct IOSMetadataMatchView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dismiss) private var dismiss
  let title: IOSUnmatchedTitle
  let matched: () -> Void
  @State private var query: String
  @State private var candidates: [IOSMetadataCandidate] = []
  @State private var searching = false

  init(title: IOSUnmatchedTitle, matched: @escaping () -> Void) {
    self.title = title
    self.matched = matched
    _query = State(initialValue: title.title)
  }

  var body: some View {
    List {
      Section {
        Text(title.fileName).font(.caption).foregroundStyle(.secondary)
      } footer: {
        Text("Search by the movie’s or show’s real name, then choose the right one.")
      }
      if searching { ProgressView() }
      if !searching && candidates.isEmpty {
        Text("No results. Try another spelling or the original title.").foregroundStyle(.secondary)
      }
      ForEach(candidates) { candidate in
        Button {
          let id = title.id
          Task {
            if await admin.perform("Matching…", { try await $0.selectMetadataMatch(mediaId: id, candidate: candidate) }) {
              matched()
              dismiss()
            }
          }
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text(
              [candidate.title, candidate.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
            )
            .foregroundStyle(.primary)
            Text(candidate.mediaType == "tv" ? "TV Show" : "Movie").font(.caption).foregroundStyle(.secondary)
            if let overview = candidate.overview, !overview.isEmpty {
              Text(overview).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
          }
        }
      }
    }
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Match “\(title.title)”")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    .task(id: query) {
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      let (typed, id) = (query.trimmingCharacters(in: .whitespaces), title.id)
      guard !typed.isEmpty else { candidates = []; return }
      searching = true
      candidates = (try? await admin.run { try await $0.searchMetadata(mediaId: id, query: typed) }) ?? []
      searching = false
    }
  }
}
