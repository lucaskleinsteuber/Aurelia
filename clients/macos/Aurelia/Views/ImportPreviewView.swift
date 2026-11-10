import SwiftUI

private enum ImportPreviewFilter: String, CaseIterable {
  case all = "All"
  case pending = "Needs Review"
  case ignored = "Ignored"
  case error = "Errors"
  case saved = "Manual"
}

struct ImportPreviewNode: Identifiable {
  let id: String
  let title: String
  let item: ImportPreviewItem?
  let children: [ImportPreviewNode]?

  var editableItem: ImportPreviewItem {
    item
      ?? ImportPreviewItem(
        relativePath: id, title: title, kind: nil, parentRelativePath: nil,
        seasonNumber: nil, episodeNumber: nil, category: nil, status: .pending,
        reason: "A folder assignment applies to its contents unless a file has its own assignment.",
        isDirectory: true)
  }
}

struct ImportPreviewView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let library: LibrarySummary
  @State private var summary: ImportPreviewSummary?
  @State private var items: [ImportPreviewItem] = []
  @State private var assignments: [ImportAssignmentUpdate] = []
  @State private var selectedPaths = Set<String>()
  @State private var filter = ImportPreviewFilter.all
  @State private var search = ""
  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var editing: [ImportPreviewItem]?
  @State private var hasDraftChanges = false
  @State private var confirmingClose = false
  @State private var confirmingReanalysis = false
  private let isPreviewFixture: Bool

  init(
    library: LibrarySummary, previewSummary: ImportPreviewSummary? = nil,
    previewItems: [ImportPreviewItem] = []
  ) {
    self.library = library
    _summary = State(initialValue: previewSummary)
    _items = State(initialValue: previewItems)
    isPreviewFixture = previewSummary != nil
  }

  #if DEBUG
    static var uiTestFixture: ImportPreviewView {
      let library = LibrarySummary(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000031")!,
        name: "Synthetic Import Archive", path: "/synthetic/Archive", kind: .automatic,
        availability: .available, createdAt: "2026-10-02T00:00:00Z",
        lastScanStartedAt: nil, lastScanCompletedAt: nil, lastError: nil,
        importPreviewRequired: true)
      let summary = ImportPreviewSummary(
        previewId: UUID(uuidString: "30000000-0000-0000-0000-000000000032")!,
        libraryId: library.id, revision: "synthetic-import-revision", state: "Ready",
        counts: ImportPreviewCounts(
          files: 17, movies: 0, series: 1, episodes: 5, extras: 12, trailers: 0,
          pending: 0, ignored: 0, errors: 0), issues: [],
        targets: [
          ImportPreviewTarget(
            relativePath: "Chernobyl", title: "Chernobyl", kind: .series, seasonNumbers: [1])
        ])
      var items = [
        ImportPreviewItem(
          relativePath: "Chernobyl", title: "Chernobyl", kind: .series,
          parentRelativePath: nil, seasonNumber: nil, episodeNumber: nil, category: nil,
          status: .recognized, reason: "One series recognized from its numbered episodes.",
          isDirectory: true)
      ]
      items += (1...5).map { (number: Int) in
        ImportPreviewItem(
          relativePath: "Chernobyl/Season 1/Chernobyl S01E0\(number).mkv",
          title: "Episode \(number)", kind: .episode, parentRelativePath: "Chernobyl",
          seasonNumber: 1, episodeNumber: number, category: nil, status: .recognized,
          reason: "Numbered episode inside Season 1.", isDirectory: false)
      }
      items += (1...12).map { (number: Int) in
        ImportPreviewItem(
          relativePath: "Chernobyl/Featurettes/Featurette \(number).mkv",
          title: number == 1 ? "Interview with the Director" : "Featurette \(number)",
          kind: .extra, parentRelativePath: "Chernobyl", seasonNumber: nil,
          episodeNumber: nil, category: "Featurettes", status: .recognized,
          reason: "Featurettes folder; series-wide because no season is specified.",
          isDirectory: false)
      }
      return ImportPreviewView(library: library, previewSummary: summary, previewItems: items)
    }
  #endif

  var body: some View {
    VStack(spacing: 0) {
      header
      if let summary {
        counts(summary.counts)
        controls
        List(selection: $selectedPaths) {
          OutlineGroup(tree, children: \.children) { node in
            previewRow(node).tag(node.id)
          }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("import-preview-tree")
        if !summary.issues.isEmpty {
          DisclosureGroup("\(summary.issues.count) scan warnings") {
            ScrollView {
              VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(summary.issues.enumerated()), id: \.offset) { _, issue in
                  Text(issue.message).font(.caption).foregroundStyle(.secondary)
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 90)
          }.padding(.horizontal, 22).padding(.vertical, 8)
        }
      } else {
        VStack(spacing: 12) {
          if isWorking { ProgressView("Analyzing filenames and folder structure…") }
          Text("No catalog entries are imported until you confirm this preview.")
            .foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if let errorMessage {
        Text(errorMessage).font(.callout).foregroundStyle(.orange)
          .textSelection(.enabled).padding(16)
      }
      Divider()
      footer
    }
    .frame(minWidth: 820, idealWidth: 980, minHeight: 600, idealHeight: 760)
    .background(AureliaBackdrop())
    .task { if !isPreviewFixture { await analyze() } }
    .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
      if let editing, let summary {
        ImportAssignmentEditor(items: editing, targets: summary.targets) { changes in
          try await apply(changes)
        }
      }
    }
    .confirmationDialog("Discard this unconfirmed preview?", isPresented: $confirmingClose) {
      Button("Discard Preview", role: .destructive) { dismiss() }
      Button("Keep Reviewing", role: .cancel) {}
    } message: {
      Text(
        "Your active library and video files are unchanged. New locations remain paused until an import is confirmed."
      )
    }
    .confirmationDialog(
      "Discard draft assignments and analyze again?", isPresented: $confirmingReanalysis
    ) {
      Button("Discard and Analyze Again", role: .destructive) { Task { await analyze() } }
      Button("Keep Reviewing", role: .cancel) {}
    } message: {
      Text(
        "This reloads saved assignments and current source files. Your active library remains unchanged."
      )
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "folder.badge.questionmark").font(.title)
      VStack(alignment: .leading, spacing: 3) {
        Text("Import Preview").font(AureliaDesign.pageTitle)
        Text(library.name).font(.headline)
        Text(library.path).font(.caption).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer()
      if isWorking { ProgressView().controlSize(.small) }
    }.padding(22)
  }

  private func counts(_ counts: ImportPreviewCounts) -> some View {
    HStack(spacing: 18) {
      Text("\(counts.files) files")
      Text("\(counts.movies) movies · \(counts.series) series · \(counts.episodes) episodes")
      Text("\(counts.extras) extras · \(counts.trailers) trailers")
      Spacer()
      Text("\(counts.pending) need review").foregroundStyle(
        counts.pending > 0 ? Color.orange : .secondary)
    }.font(.caption).padding(.horizontal, 22).padding(.vertical, 12)
  }

  private var controls: some View {
    HStack {
      TextField("Search titles, folders or filenames", text: $search)
        .textFieldStyle(.roundedBorder)
      Picker("Show", selection: $filter) {
        ForEach(ImportPreviewFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.frame(width: 170)
      Button("Edit Assignment…") { editing = selectedItems }
        .disabled(selectedItems.isEmpty || isWorking)
        .accessibilityIdentifier("import-edit-assignment")
      Button("Use Automatic Detection") {
        let changes = selectedItems.map {
          ImportAssignmentUpdate(
            relativePath: $0.relativePath, isDirectory: $0.isDirectory, kind: nil,
            useAutomaticDetection: true)
        }
        Task {
          do { try await apply(changes) } catch { errorMessage = error.localizedDescription }
        }
      }.disabled(selectedItems.isEmpty || isWorking)
    }.padding(.horizontal, 22).padding(.bottom, 12)
  }

  private func previewRow(_ node: ImportPreviewNode) -> some View {
    HStack(spacing: 10) {
      Image(systemName: node.children != nil ? "folder" : symbol(node.item?.kind))
        .foregroundStyle(.secondary).frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(node.item?.title ?? node.title).lineLimit(1)
        if let item = node.item {
          Text(item.relativePath.isEmpty ? "Storage root" : item.relativePath)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
      }
      Spacer()
      if let item = node.item {
        if let season = item.seasonNumber { Text("S\(season)").font(.caption.monospaced()) }
        if let episode = item.episodeNumber { Text("E\(episode)").font(.caption.monospaced()) }
        Text(item.kind?.rawValue.capitalized ?? item.status.rawValue.capitalized)
          .font(.caption).foregroundStyle(
            item.status == .pending || item.status == .error ? Color.orange : .secondary)
        Button {
          editing = [item]
        } label: {
          Image(systemName: "pencil")
        }
        .buttonStyle(.borderless).disabled(isWorking)
        .accessibilityLabel("Edit assignment for \(item.title)")
        .accessibilityIdentifier("import-edit-\(item.relativePath)")
      }
    }
    .help(node.item?.reason ?? "Assign this folder and its contents")
  }

  private var footer: some View {
    HStack {
      Button("Close") {
        if hasDraftChanges { confirmingClose = true } else { dismiss() }
      }.keyboardShortcut(.cancelAction)
      Text("Unresolved files stay in review. Video files are never changed.")
        .font(.caption).foregroundStyle(.secondary)
      Spacer()
      Button("Analyze Again") {
        if hasDraftChanges { confirmingReanalysis = true } else { Task { await analyze() } }
      }.disabled(isWorking)
      Button(library.importPreviewRequired == true ? "Import Recognized Items" : "Apply and Rescan")
      {
        Task { await confirm() }
      }
      .buttonStyle(AureliaPrimaryActionButtonStyle())
      .disabled(summary == nil || isWorking || summary?.counts.errors != 0)
      .accessibilityIdentifier("confirm-import-preview")
    }.padding(18)
  }

  private var tree: [ImportPreviewNode] {
    let filtered = items.filter { item in
      let matches =
        search.isEmpty || item.title.localizedCaseInsensitiveContains(search)
        || item.relativePath.localizedCaseInsensitiveContains(search)
      guard matches else { return false }
      switch filter {
      case .all: return true
      case .pending: return item.status == .pending
      case .ignored: return item.status == .ignored
      case .error: return item.status == .error
      case .saved:
        return assignments.contains {
          $0.relativePath == item.relativePath
            || ($0.isDirectory
              && ($0.relativePath.isEmpty
                || item.relativePath.hasPrefix($0.relativePath + "/")))
        }
      }
    }
    return Self.buildTree(filtered)
  }

  private var selectedItems: [ImportPreviewItem] {
    func flatten(_ nodes: [ImportPreviewNode]) -> [ImportPreviewItem] {
      nodes.flatMap { node in
        (selectedPaths.contains(node.id) ? [node.editableItem] : []) + flatten(node.children ?? [])
      }
    }
    return flatten(tree)
  }

  static func buildTree(_ items: [ImportPreviewItem]) -> [ImportPreviewNode] {
    let byPath = Dictionary(
      items.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
    var descendants: [String: Set<String>] = [:]
    for item in items {
      let parts = item.relativePath.split(separator: "/").map(String.init)
      var parent = ""
      for part in parts {
        let path = parent.isEmpty ? part : parent + "/" + part
        descendants[parent, default: []].insert(path)
        parent = path
      }
    }
    func nodes(_ parent: String) -> [ImportPreviewNode] {
      (descendants[parent] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        .map { path in
          let children = nodes(path)
          return ImportPreviewNode(
            id: path, title: String(path.split(separator: "/").last ?? ""), item: byPath[path],
            children: children.isEmpty ? nil : children)
        }
    }
    let roots = nodes("")
    guard let root = byPath[""] else { return roots }
    return [
      ImportPreviewNode(
        id: "", title: root.title, item: root, children: roots.isEmpty ? nil : roots)
    ]
  }

  private func symbol(_ kind: MediaKind?) -> String {
    switch kind {
    case .movie: "film"
    case .series: "tv"
    case .episode: "play.rectangle"
    case .extra: "sparkles.rectangle.stack"
    case .trailer: "film.stack"
    case nil: "questionmark.document"
    }
  }

  private func analyze() async {
    guard let profile = model.profile else { return }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let client = APIClient(profile: profile)
      let analyzed = try await client.analyzeImport(libraryId: library.id)
      try await loadItems(client: client, summary: analyzed)
      assignments = try await client.importAssignments(libraryId: library.id).assignments
      hasDraftChanges = false
    } catch { errorMessage = error.localizedDescription }
  }

  private func loadItems(client: APIClient, summary newSummary: ImportPreviewSummary) async throws {
    var loaded: [ImportPreviewItem] = []
    var offset = 0
    while true {
      let page = try await client.importPreviewItems(
        libraryId: library.id, previewId: newSummary.previewId, offset: offset)
      guard page.summary.revision == newSummary.revision else {
        throw APIClientError.serverRejected(
          code: "preview_changed", message: "The preview changed. Analyze the location again.")
      }
      loaded.append(contentsOf: page.items)
      offset += page.items.count
      if offset >= page.totalCount { break }
      guard !page.items.isEmpty else {
        throw APIClientError.serverRejected(
          code: "incomplete_preview", message: "The server returned an incomplete preview.")
      }
      try Task.checkCancellation()
    }
    summary = newSummary
    items = loaded
    selectedPaths = []
  }

  private func apply(_ changes: [ImportAssignmentUpdate]) async throws {
    guard let profile = model.profile, let summary else { return }
    isWorking = true
    defer { isWorking = false }
    let client = APIClient(profile: profile)
    let updated = try await client.updateImportPreview(
      libraryId: library.id, previewId: summary.previewId, revision: summary.revision,
      assignments: changes)
    try await loadItems(client: client, summary: updated)
    for change in changes {
      assignments.removeAll {
        $0.relativePath == change.relativePath && $0.isDirectory == change.isDirectory
      }
      if !change.useAutomaticDetection { assignments.append(change) }
    }
    hasDraftChanges = true
    errorMessage = nil
  }

  private func confirm() async {
    guard let profile = model.profile, let summary else { return }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let scan = try await APIClient(profile: profile).confirmImportPreview(
        libraryId: library.id, previewId: summary.previewId, revision: summary.revision)
      await model.didConfirmImport(scan: scan)
      hasDraftChanges = false
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }
}

private enum ImportContentChoice: String, CaseIterable, Identifiable {
  case movie = "Movie"
  case series = "TV Show · Force Import"
  case episode = "Episode"
  case extra = "Extra"
  case trailer = "Trailer"
  case ignore = "Ignore"
  var id: String { rawValue }
  var kind: MediaKind? {
    switch self {
    case .movie: .movie
    case .series: .series
    case .episode: .episode
    case .extra: .extra
    case .trailer: .trailer
    case .ignore: nil
    }
  }
}

struct ImportAssignmentEditor: View {
  @Environment(\.dismiss) private var dismiss
  let items: [ImportPreviewItem]
  let targets: [ImportPreviewTarget]
  let onSave: ([ImportAssignmentUpdate]) async throws -> Void
  @State private var choice: ImportContentChoice
  @State private var parentPath: String?
  @State private var entireSeries: Bool
  @State private var season: String
  @State private var episode: String
  @State private var category: String
  @State private var title: String
  @State private var query = ""
  @State private var isWorking = false
  @State private var errorMessage: String?

  init(
    items: [ImportPreviewItem], targets: [ImportPreviewTarget],
    onSave: @escaping ([ImportAssignmentUpdate]) async throws -> Void
  ) {
    self.items = items
    self.targets = targets
    self.onSave = onSave
    let first = items.first
    _choice = State(
      initialValue: first?.kind.flatMap { kind in
        ImportContentChoice.allCases.first { $0.kind == kind }
      } ?? .extra)
    _parentPath = State(initialValue: first?.parentRelativePath)
    _entireSeries = State(initialValue: first?.seasonNumber == nil)
    _season = State(initialValue: first?.seasonNumber.map(String.init) ?? "1")
    _episode = State(initialValue: first?.episodeNumber.map(String.init) ?? "1")
    _category = State(initialValue: first?.category ?? "")
    _title = State(
      initialValue: items.count == 1 && first?.isDirectory == false ? first?.title ?? "" : "")
  }

  private var needsParent: Bool { [.episode, .extra, .trailer].contains(choice) }
  private var parent: ImportPreviewTarget? { targets.first { $0.relativePath == parentPath } }
  private var canSave: Bool {
    if needsParent && parent == nil { return false }
    if choice == .episode {
      guard parent?.kind == .series, let season = Int(season), season >= 0, season <= 99,
        let episode = Int(episode), episode > 0, episode <= 999
      else { return false }
      if items.count > 1 || items.contains(where: \.isDirectory) { return false }
    } else if parent?.kind == .series && !entireSeries {
      guard let season = Int(season), season >= 0, season <= 99 else { return false }
    }
    return !isWorking
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Edit Import Assignment").font(.title2.bold())
      Text(items.count == 1 ? items[0].relativePath : "\(items.count) selected files or folders")
        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
      Form {
        Picker("Import as", selection: $choice) {
          ForEach(
            ImportContentChoice.allCases.filter {
              ($0 != .series || items.allSatisfy(\.isDirectory))
                && ($0 != .episode || (items.count == 1 && !items[0].isDirectory))
            }
          ) { Text($0.rawValue).tag($0) }
        }.accessibilityIdentifier("import-assignment-kind")
        if needsParent {
          TextField("Search target titles", text: $query)
          Picker("Belongs to", selection: $parentPath) {
            Text("Choose a movie or series").tag(Optional<String>.none)
            ForEach(
              targets.filter {
                (choice != .episode || $0.kind == .series)
                  && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    || $0.relativePath == parentPath)
              }
            ) { target in
              Text("\(target.title) · \(target.kind.rawValue.capitalized)").tag(
                Optional(target.relativePath))
            }
          }.accessibilityIdentifier("import-assignment-parent")
          if parent?.kind == .series {
            if choice != .episode {
              Toggle("Entire Series", isOn: $entireSeries)
                .accessibilityIdentifier("import-entire-series")
            }
            if choice == .episode || !entireSeries {
              TextField("Season number", text: $season)
                .accessibilityIdentifier("import-assignment-season")
              if let parent, !parent.seasonNumbers.isEmpty {
                Menu("Choose Existing Season") {
                  ForEach(parent.seasonNumbers, id: \.self) { number in
                    Button("Season \(number)") { season = String(number) }
                  }
                }
              }
            }
          }
          if choice == .episode {
            TextField("Episode number", text: $episode)
              .accessibilityIdentifier("import-assignment-episode")
          }
          if choice == .extra || choice == .trailer {
            TextField("Category (optional)", text: $category)
              .accessibilityIdentifier("import-assignment-category")
          }
        }
        if items.count == 1 && !items[0].isDirectory {
          TextField("Display title", text: $title)
            .accessibilityIdentifier("import-assignment-title")
        }
      }.formStyle(.grouped)
      Text(
        "Folder rules are inherited. Individual file assignments take precedence. Unnumbered episodes are only numbered when you explicitly choose TV Show · Force Import."
      )
      .font(.caption).foregroundStyle(.secondary)
      if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
        Spacer()
        if isWorking { ProgressView().controlSize(.small) }
        Button("Save Assignment") { Task { await save() } }
          .buttonStyle(AureliaPrimaryActionButtonStyle()).disabled(!canSave)
          .keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 610, height: 590).background(AureliaBackdrop())
  }

  private func save() async {
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    let changes = items.map { item in
      ImportAssignmentUpdate(
        relativePath: item.relativePath, isDirectory: item.isDirectory, kind: choice.kind,
        parentRelativePath: needsParent ? parentPath : nil,
        seasonNumber: choice == .episode
          || (needsParent && parent?.kind == .series && !entireSeries) ? Int(season) : nil,
        episodeNumber: choice == .episode ? Int(episode) : nil,
        category: needsParent && !category.isEmpty ? category : nil,
        title: items.count == 1 && !item.isDirectory && !title.isEmpty ? title : nil)
    }
    do {
      try await onSave(changes)
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }
}
