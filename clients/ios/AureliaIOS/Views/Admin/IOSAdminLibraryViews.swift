import SwiftUI

/// Settings › Library: storage locations, scans, import review and library health. Aurelia only
/// reads the media: nothing here moves, renames or deletes a video file.
struct IOSAdminLibraryView: View {
  struct Overview: Sendable {
    let libraries: [IOSLibrarySummary]
    let scans: [IOSLibraryScan]
  }

  var body: some View {
    IOSAdminLoader { client in
      async let libraries = client.libraries()
      async let scans = (try? client.activeScans()) ?? []
      return Overview(libraries: try await libraries, scans: await scans)
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

  var body: some View {
    Form {
      Section {
        if overview.libraries.isEmpty {
          Text("No storage locations yet.").foregroundStyle(.secondary)
        }
        ForEach(overview.libraries) { library in
          NavigationLink {
            IOSAdminStorageLocationView(libraryID: library.id)
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              HStack {
                Text(library.name)
                if overview.scans.contains(where: { $0.libraryId == library.id && $0.isActive }) {
                  ProgressView().controlSize(.mini)
                }
              }
              Text(library.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.middle)
              Text("\(library.kindTitle) · \(library.availabilityTitle)").font(.caption2)
                .foregroundStyle(library.isAvailable ? Color.secondary : Color.orange)
            }
          }
        }
        Button {
          adding = true
        } label: {
          Label("Add Storage Location…", systemImage: "plus")
        }
        .accessibilityIdentifier("admin-add-library")
        Button {
          Task { await admin.perform("Scanning all storage locations…") { _ = try await $0.scanAllLibraries() } }
        } label: {
          Label("Scan All", systemImage: "arrow.clockwise")
        }
        .disabled(overview.libraries.isEmpty)
      } header: {
        Text("Storage Locations")
      } footer: {
        Text("Folders on the server computer with your movies and shows. Aurelia only reads them.")
      }
      if !overview.scans.isEmpty {
        Section("Scanning Now") {
          ForEach(overview.scans) { scan in
            IOSScanRow(
              scan: scan,
              name: overview.libraries.first { $0.id == scan.libraryId }?.name ?? "Storage location")
          }
        }
      }
      Section {
        NavigationLink("Library Health") { IOSAdminLibraryHealthView() }
      } footer: {
        Text("Duplicates, titles whose drive is offline, and titles without movie or TV information.")
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .sheet(isPresented: $adding) {
      NavigationStack { IOSAdminAddLibraryView() }
    }
    .task(id: overview.scans.map(\.filesProcessed)) {
      guard overview.scans.contains(where: \.isActive) else { return }
      try? await Task.sleep(for: .seconds(3))
      await reload()
    }
  }
}

private struct IOSScanRow: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let scan: IOSLibraryScan
  let name: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(name)
        Spacer()
        if scan.isActive {
          Button("Stop", role: .destructive) {
            let id = scan.id
            Task { await admin.perform { try await $0.cancelScan(id: id) } }
          }
          .buttonStyle(.borderless)
        }
      }
      if let progress = scan.progress, scan.isActive { ProgressView(value: progress) }
      Text(
        "\(scan.stateTitle) · \(scan.filesProcessed) of \(scan.filesDiscovered) files · \(scan.addedFiles) added"
      )
      .font(.caption).foregroundStyle(.secondary)
      if let error = scan.error { Text(error).font(.caption).foregroundStyle(.orange) }
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

  var body: some View {
    let library = loaded.library
    Form {
      Section {
        LabeledContent("Name", value: library.name)
        LabeledContent("Folder") { Text(library.path).textSelection(.enabled).multilineTextAlignment(.trailing) }
        LabeledContent("Kind", value: library.kindTitle)
        LabeledContent("Status", value: library.availabilityTitle)
        LabeledContent("Last Scan", value: IOSAdminFormat.relative(library.lastScanCompletedAt))
        if let error = library.lastError { Text(error).foregroundStyle(.orange) }
      }
      Section {
        Button("Scan Now") {
          let id = library.id
          Task { await admin.perform("Scanning \(library.name)…") { _ = try await $0.scanLibrary(id: id) } }
        }
        Toggle(
          "Watch for Changes",
          isOn: Binding(
            get: { library.monitoringEnabled ?? false },
            set: { value in
              let id = library.id
              Task { await admin.perform { _ = try await $0.setLibraryMonitoring(id: id, enabled: value) } }
            }))
        Button(library.importPreviewRequired == true ? "Review Import…" : "Review Assignments…") {
          reviewing = true
        }
      } footer: {
        Text("Watching notices new and changed files by itself. Review shows what each folder and file becomes.")
      }
      if !loaded.discoveries.isEmpty {
        Section {
          ForEach(loaded.discoveries) { discovery in
            IOSDiscoveryRow(discovery: discovery)
          }
        } header: {
          Text("Folders to Sort")
        } footer: {
          Text("Aurelia wasn’t sure whether these folders hold movies or a TV show.")
        }
      }
      if !loaded.reviews.filter({ $0.state == "pending" }).isEmpty {
        Section("Files to Check") {
          ForEach(loaded.reviews.filter { $0.state == "pending" }) { review in
            VStack(alignment: .leading, spacing: 4) {
              Text(review.detectedTitle)
              Text(review.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
              Text(review.reason).font(.caption2).foregroundStyle(.secondary)
              Button("Leave Out") {
                let (id, review) = (library.id, review.id)
                Task { await admin.perform { _ = try await $0.decideImportReview(library: id, review: review, movieId: nil) } }
              }
              .buttonStyle(.borderless)
            }
          }
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
          Text("Files and folders removed from Aurelia. The files themselves were never touched.")
        }
      }
      Section("Recent Scans") {
        if loaded.scans.isEmpty { Text("No scans yet").foregroundStyle(.secondary) }
        ForEach(loaded.scans) { scan in IOSScanRow(scan: scan, name: IOSAdminFormat.date(scan.createdAt)) }
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
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
    .sheet(isPresented: $reviewing) {
      NavigationStack { IOSAdminImportPreviewView(library: library) }
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

/// Add Storage Location: browse the server's folders, then choose how Aurelia reads it.
private struct IOSAdminAddLibraryView: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  @Environment(\.dismiss) private var dismiss
  @State private var chosen: IOSServerFolder?
  @State private var name = ""
  @State private var kind = "automatic"
  @State private var review = false

  var body: some View {
    Group {
      if let chosen {
        IOSAdminForm(title: "Add Storage Location") {
          Section {
            LabeledContent("Folder") { Text(chosen.path).multilineTextAlignment(.trailing) }
            TextField("Name", text: $name)
            Picker("Contains", selection: $kind) {
              Text("Find Out Automatically").tag("automatic")
              Text("Movies").tag("movies")
              Text("TV Shows").tag("tvShows")
            }
            Toggle("Review Before Importing", isOn: $review)
          } footer: {
            Text("With review, Aurelia first shows what each folder and file becomes and imports only after you confirm.")
          }
          Section {
            Button("Choose Another Folder") { self.chosen = nil }
          }
        }
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Add") {
              let request = IOSCreateLibraryRequest(
                name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name,
                path: chosen.path, kind: kind, combineExisting: false, requireImportPreview: review)
              Task {
                if await admin.perform("Adding the storage location…", { _ = try await $0.createLibrary(request) }) {
                  dismiss()
                }
              }
            }
          }
        }
      } else {
        IOSServerFolderBrowser(path: nil) { folder in
          chosen = folder
          name = folder.name
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
    }
  }
}

/// The folders on the server computer, one level at a time.
private struct IOSServerFolderBrowser: View {
  let path: String?
  let choose: (IOSServerFolder) -> Void

  var body: some View {
    IOSAdminLoader { try await $0.serverFolders(path: path) } content: { listing, _ in
      List {
        if let current = listing.path {
          Section {
            Button {
              choose(IOSServerFolder(name: (current as NSString).lastPathComponent, path: current))
            } label: {
              Label("Use This Folder", systemImage: "checkmark.circle.fill")
            }
          } footer: {
            Text(current)
          }
        }
        Section {
          if listing.folders.isEmpty { Text("No folders inside").foregroundStyle(.secondary) }
          ForEach(listing.folders, id: \.path) { folder in
            NavigationLink {
              IOSServerFolderBrowser(path: folder.path, choose: choose)
            } label: {
              Label(folder.name, systemImage: "folder")
            }
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .navigationTitle(listing.path.map { ($0 as NSString).lastPathComponent } ?? "Server Folders")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

/// Import Preview: what each folder and file becomes, corrections, then import.
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

  private var shown: [IOSImportPreviewItem] {
    let query = search.trimmingCharacters(in: .whitespaces)
    return items.filter { item in
      (filter == "all" || item.status == filter)
        && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)
          || item.relativePath.localizedCaseInsensitiveContains(query))
    }
  }

  var body: some View {
    List {
      if let summary {
        Section {
          let counts = summary.counts
          Text(
            "\(counts.movies) movies · \(counts.series) shows · \(counts.episodes) episodes · \(counts.extras + counts.trailers) extras"
          )
          if counts.pending > 0 || counts.errors > 0 {
            Text("\(counts.pending) need review · \(counts.errors) errors").foregroundStyle(.orange)
          }
          Picker("Show", selection: $filter) {
            Text("All").tag("all")
            Text("Needs Review").tag("pending")
            Text("Ignored").tag("ignored")
            Text("Errors").tag("error")
          }
          .pickerStyle(.segmented)
        }
      } else if loading {
        ProgressView("Reading file names and folders…")
      }
      Section {
        ForEach(shown) { item in
          Button {
            editing = [item]
          } label: {
            HStack(spacing: 10) {
              Image(systemName: item.isDirectory ? "folder" : "film").foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? item.relativePath : item.title).foregroundStyle(.primary)
                Text(item.relativePath.isEmpty ? "Storage root" : item.relativePath).font(.caption)
                  .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
    .navigationTitle("Import Preview")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button(library.importPreviewRequired == true ? "Import" : "Apply") { confirm() }
          .disabled(summary == nil || summary?.counts.errors != 0)
      }
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

/// Library Health: duplicates to merge, offline titles to remove and titles without information.
private struct IOSAdminLibraryHealthView: View {
  struct Loaded: Sendable {
    let duplicates: [IOSDuplicateGroup]
    let offline: [IOSHealthOfflineTitle]
    let unmatched: [IOSUnmatchedTitle]
  }

  var body: some View {
    IOSAdminLoader { client in
      async let duplicates = client.healthDuplicates()
      async let offline = client.healthOffline()
      async let unmatched = client.healthUnmatched()
      return Loaded(
        duplicates: try await duplicates, offline: try await offline, unmatched: try await unmatched)
    } content: { loaded, reload in
      IOSAdminLibraryHealthForm(loaded: loaded, reload: reload)
    }
    .navigationTitle("Library Health")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct IOSAdminLibraryHealthForm: View {
  @EnvironmentObject private var admin: IOSAdministrationModel
  let loaded: IOSAdminLibraryHealthView.Loaded
  let reload: () async -> Void
  @State private var confirmation: IOSAdminConfirmation?

  var body: some View {
    Form {
      Section {
        if loaded.duplicates.isEmpty { Text("No duplicates").foregroundStyle(.secondary) }
        ForEach(loaded.duplicates) { group in
          VStack(alignment: .leading, spacing: 6) {
            Text([group.title, group.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
              .font(.headline)
            ForEach(group.items) { item in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.fileName).font(.caption).lineLimit(2)
                  Text(item.availability == "available" ? IOSAdminText.bytes(item.fileSize) : "Offline")
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
                        await admin.perform("Combining…") { client in
                          for source in sources { try await client.mergeDuplicates(source: source, target: target) }
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
      } header: {
        Text("Duplicates")
      }
      Section {
        if loaded.offline.isEmpty { Text("Nothing offline").foregroundStyle(.secondary) }
        ForEach(loaded.offline) { title in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(title.title)
              Text("\(title.libraryName) · offline for \(title.daysOffline) days").font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove", role: .destructive) {
              confirmation = IOSAdminConfirmation(
                title: "Remove “\(title.title)” from Aurelia?",
                message: "Only the entry goes; if the drive comes back, a scan adds the title again.",
                action: "Remove"
              ) {
                let id = title.id
                Task { await admin.perform { try await $0.removeHealthEntry(mediaId: id) } }
              }
            }
            .buttonStyle(.borderless)
          }
        }
      } header: {
        Text("Offline for 30 Days")
      } footer: {
        Text("Titles keep their progress and favorites while their drive is away.")
      }
      Section("Without Information") {
        if loaded.unmatched.isEmpty { Text("Every title has information").foregroundStyle(.secondary) }
        ForEach(loaded.unmatched) { title in
          VStack(alignment: .leading, spacing: 2) {
            Text(title.title)
            Text(title.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .refreshable { await reload() }
    .adminConfirmation($confirmation)
  }
}
