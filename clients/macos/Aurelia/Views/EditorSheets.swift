import SwiftUI

struct MetadataMatchSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let mediaId: UUID
  let mediaTitle: String
  let providerMediaId: String?
  let onSaved: () async -> Void
  @State private var query: String
  @StateObject private var searchController = MetadataSearchController()
  @State private var searchRequest = UUID()
  @State private var isWorking = false
  @State private var errorMessage: String?

  init(metadata: MediaMetadataSummary, onSaved: @escaping () async -> Void) {
    self.mediaId = metadata.mediaId
    self.mediaTitle = metadata.title
    self.providerMediaId = metadata.providerMediaId
    self.onSaved = onSaved
    _query = State(initialValue: metadata.title)
  }

  init(
    mediaId: UUID,
    title: String,
    providerMediaId: String? = nil,
    onSaved: @escaping () async -> Void
  ) {
    self.mediaId = mediaId
    self.mediaTitle = title
    self.providerMediaId = providerMediaId
    self.onSaved = onSaved
    _query = State(initialValue: title)
  }

  var body: some View {
    VStack(spacing: 0) {
      sheetHeader("Find Metadata Match", subtitle: mediaTitle, symbol: "magnifyingglass")
      Divider()
      VStack(spacing: 16) {
        HStack {
          TextField("Search title", text: $query).textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("metadata-match-query")
            .onSubmit { searchRequest = UUID() }
            .disabled(isWorking)
          if searchController.isSearching {
            ProgressView().controlSize(.small).accessibilityLabel("Searching metadata")
          }
        }
        if searchController.candidates.isEmpty {
          ContentUnavailableView(
            searchController.isSearching ? "Searching…" : "Compare Matches",
            systemImage: "rectangle.and.text.magnifyingglass",
            description: Text("Type a title to find matches, then choose the correct result.")
          )
          .frame(maxHeight: .infinity)
        } else {
          List(searchController.candidates) { candidate in
            HStack(alignment: .top, spacing: 14) {
              MediaArtworkPlaceholder(symbol: "film")
                .frame(width: 72, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.compactRadius))
              VStack(alignment: .leading, spacing: 5) {
                Text(candidate.title).font(.headline)
                Text(
                  [candidate.originalTitle, candidate.year.map(String.init)]
                    .compactMap { $0 }.joined(separator: " · ")
                )
                .font(.caption).foregroundStyle(.secondary)
                if let overview = candidate.overview { Text(overview).font(.caption).lineLimit(3) }
                Text("\(Int(candidate.confidence * 100))% match")
                  .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Use Match") { Task { await select(candidate) } }
                .buttonStyle(AureliaPrimaryActionButtonStyle())
                .disabled(isWorking)
            }
            .padding(.vertical, 6)
          }
          .listStyle(.inset)
        }
        if let errorMessage { Text(errorMessage).foregroundStyle(.orange).font(.callout) }
        if let message = searchController.errorMessage {
          Text(message).foregroundStyle(.orange).font(.callout)
          Button("Try Again") { searchRequest = UUID() }
        }
      }
      .padding(24)
      Divider()
      HStack {
        if providerMediaId != nil {
          Button("Remove Match", role: .destructive) { Task { await removeMatch() } }
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(16)
    }
    .frame(width: 720, height: 640)
    .background(AureliaBackdrop())
    .onChange(of: query) { searchController.invalidate() }
    .task(id: query + searchRequest.uuidString) {
      await searchController.search(query: query) { value in
        try await model.metadataCandidates(mediaId: mediaId, query: value)
      }
    }
    .onDisappear { searchController.invalidate() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("metadata-match-editor")
  }

  private func select(_ candidate: MetadataCandidateSummary) async {
    isWorking = true
    defer { isWorking = false }
    do {
      _ = try await model.selectMetadataMatch(
        mediaId: mediaId,
        providerMediaId: candidate.providerMediaId,
        mediaType: candidate.mediaType)
      await onSaved()
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }

  private func removeMatch() async {
    isWorking = true
    defer { isWorking = false }
    do {
      _ = try await model.clearMetadataMatch(mediaId: mediaId)
      await onSaved()
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }
}

struct CollectionEditorSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let collection: CollectionSummary?
  @State private var name: String
  @State private var mediaIds: [UUID]
  @State private var isSmart: Bool
  @State private var isShared: Bool
  @State private var smartKind: String = "all"
  @State private var smartGenre: String = ""
  @State private var smartYearMin: String = ""
  @State private var smartYearMax: String = ""
  @State private var smartRatingMin: String = ""
  @State private var smartWatched: String = "any"
  @State private var smartDays: String = "any"
  @State private var smartFavoritesOnly: Bool = false
  @State private var smartSearch: String = ""
  @State private var smartMatch: String = "all"
  @State private var errorMessage: String?
  @State private var showingDeleteConfirmation = false

  init(collection: CollectionSummary?) {
    self.collection = collection
    _name = State(initialValue: collection?.name ?? "")
    _mediaIds = State(initialValue: collection?.items.map(\.id) ?? [])
    _isSmart = State(initialValue: collection?.isSmart ?? false)
    _isShared = State(initialValue: collection?.isShared ?? false)
    if let rulesJson = collection?.rulesJson,
      let data = rulesJson.data(using: .utf8),
      let rules = try? JSONDecoder().decode(SmartCollectionRules.self, from: data)
    {
      _smartKind = State(initialValue: rules.kind ?? "all")
      _smartGenre = State(initialValue: rules.genres?.joined(separator: ", ") ?? "")
      _smartYearMin = State(initialValue: rules.yearMin.map(String.init) ?? "")
      _smartYearMax = State(initialValue: rules.yearMax.map(String.init) ?? "")
      _smartRatingMin = State(
        initialValue: rules.ratingMin.map { String(format: "%.1f", $0) } ?? "")
      _smartWatched = State(initialValue: rules.watched ?? "any")
      _smartDays = State(initialValue: rules.addedWithinDays.map(String.init) ?? "any")
      _smartFavoritesOnly = State(initialValue: rules.favoritesOnly ?? false)
      _smartSearch = State(initialValue: rules.search ?? "")
      _smartMatch = State(initialValue: rules.match ?? "all")
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      sheetHeader(
        collection == nil ? "New Collection" : "Edit Collection",
        subtitle: isSmart
          ? "Define automatic rules for this smart list."
          : "Choose at least two movies or TV shows.",
        symbol: isSmart ? "sparkles.rectangle.stack" : "rectangle.stack.badge.plus")
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        TextField("Collection Name", text: $name).textFieldStyle(.roundedBorder)

        Picker("Collection Type", selection: $isSmart) {
          Text("Standard Collection").tag(false)
          Text("Smart List").tag(true)
        }
        .pickerStyle(.segmented)

        if isSmart {
          smartListRuleBuilder
        } else {
          standardItemPicker
        }

        if model.canManageMedia {
          Toggle("Shared Collection (visible to all profiles)", isOn: $isShared)
            .font(.caption)
        }

        if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.orange) }
      }
      .padding(24)
      Divider()
      HStack {
        if collection != nil {
          Button("Delete Collection", role: .destructive) { showingDeleteConfirmation = true }
        }
        Spacer()
        Button("Cancel") {
          model.preselectedCollectionItem = nil
          dismiss()
        }.keyboardShortcut(.cancelAction)
        Button("Save") { Task { await save() } }
          .buttonStyle(AureliaPrimaryActionButtonStyle()).keyboardShortcut(.defaultAction)
          .disabled(!isValid)
      }
      .padding(16)
    }
    .frame(width: 720, height: 680)
    .background(AureliaBackdrop())
    .onAppear {
      if collection == nil, let preselected = model.preselectedCollectionItem,
        !mediaIds.contains(preselected.id)
      {
        mediaIds.append(preselected.id)
      }
    }
    .onDisappear {
      model.preselectedCollectionItem = nil
    }
    .confirmationDialog(
      "Delete \(collection?.name ?? "Collection")?",
      isPresented: $showingDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete Collection", role: .destructive) { Task { await deleteCollection() } }
    } message: {
      Text("Only the collection is removed. Media and files remain untouched.")
    }
    .accessibilityIdentifier("collection-editor")
  }

  private var standardItemPicker: some View {
    List(model.catalogItems) { item in
      HStack {
        Image(systemName: mediaIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(mediaIds.contains(item.id) ? Color.accentColor : .secondary)
        Text(item.title)
        Spacer()
        Text(item.kind == .movie ? "Movie" : "TV Show")
          .font(.caption).foregroundStyle(.secondary)
        if let index = mediaIds.firstIndex(of: item.id) {
          Button {
            move(index, by: -1)
          } label: {
            Image(systemName: "arrow.up")
          }
          .buttonStyle(.borderless).disabled(index == 0)
          Button {
            move(index, by: 1)
          } label: {
            Image(systemName: "arrow.down")
          }
          .buttonStyle(.borderless).disabled(index == mediaIds.count - 1)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { toggle(item.id) }
    }
    .listStyle(.inset)
  }

  private var smartListRuleBuilder: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Rules").font(.headline)
        Spacer()
        Picker("Match", selection: $smartMatch) {
          Text("All rules (AND)").tag("all")
          Text("Any rule (OR)").tag("any")
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
      }

      Form {
        Picker("Media Type", selection: $smartKind) {
          Text("All Titles").tag("all")
          Text("Movies Only").tag("movies")
          Text("TV Shows Only").tag("series")
        }

        TextField("Genre (comma separated)", text: $smartGenre)

        HStack {
          TextField("Min Year", text: $smartYearMin)
          TextField("Max Year", text: $smartYearMax)
        }

        HStack {
          TextField("Min Rating (0.0 - 10.0)", text: $smartRatingMin)
          Picker("Watched", selection: $smartWatched) {
            Text("Any").tag("any")
            Text("Unwatched").tag("unwatched")
            Text("Watched").tag("watched")
          }
        }

        HStack {
          Picker("Added Within", selection: $smartDays) {
            Text("Anytime").tag("any")
            Text("Past 30 Days").tag("30")
            Text("Past 90 Days").tag("90")
            Text("Past 365 Days").tag("365")
          }
          Toggle("Favorites Only", isOn: $smartFavoritesOnly)
        }

        TextField("Search Title Query", text: $smartSearch)
      }
      .formStyle(.grouped)

      HStack {
        Image(systemName: "sparkles")
          .foregroundStyle(.tint)
        Text("Matching \(previewMatchCount) titles in your library")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 4)
    }
  }

  private var previewMatchCount: Int {
    model.catalogItems.filter { item in
      var matches: [Bool] = []
      if smartKind == "movies" {
        matches.append(item.kind == .movie)
      } else if smartKind == "series" {
        matches.append(item.kind == .series)
      }
      if let yMin = Int(smartYearMin), let itemYear = item.year { matches.append(itemYear >= yMin) }
      if let yMax = Int(smartYearMax), let itemYear = item.year { matches.append(itemYear <= yMax) }
      if !smartGenre.isEmpty {
        let targets = smartGenre.components(separatedBy: ",").map {
          $0.trimmingCharacters(in: .whitespaces).lowercased()
        }.filter { !$0.isEmpty }
        if !targets.isEmpty {
          matches.append(
            item.genres.contains { g in targets.contains(where: { g.lowercased().contains($0) }) })
        }
      }
      if smartWatched == "watched" {
        matches.append(item.watchState == .completed)
      } else if smartWatched == "unwatched" {
        matches.append(item.watchState != .completed)
      }
      if smartFavoritesOnly { matches.append(item.isFavorite) }
      if !smartSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        matches.append(
          item.title.localizedCaseInsensitiveContains(
            smartSearch.trimmingCharacters(in: .whitespacesAndNewlines)))
      }
      if matches.isEmpty { return true }
      return smartMatch == "any" ? matches.contains(true) : !matches.contains(false)
    }.count
  }

  private var builtRulesJson: String? {
    let genresList = smartGenre.components(separatedBy: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    let rules = SmartCollectionRules(
      kind: smartKind == "all" ? nil : smartKind,
      genres: genresList.isEmpty ? nil : genresList,
      yearMin: Int(smartYearMin),
      yearMax: Int(smartYearMax),
      ratingMin: Double(smartRatingMin),
      ratingMax: nil,
      watched: smartWatched == "any" ? nil : smartWatched,
      addedWithinDays: Int(smartDays),
      favoritesOnly: smartFavoritesOnly ? true : nil,
      search: smartSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil : smartSearch.trimmingCharacters(in: .whitespacesAndNewlines),
      match: smartMatch
    )
    guard let data = try? JSONEncoder().encode(rules) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private var isValid: Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return false }
    return isSmart || mediaIds.count >= 2
  }

  private func toggle(_ id: UUID) {
    if let index = mediaIds.firstIndex(of: id) {
      mediaIds.remove(at: index)
    } else {
      mediaIds.append(id)
    }
  }

  private func move(_ index: Int, by offset: Int) {
    let target = index + offset
    guard mediaIds.indices.contains(target) else { return }
    mediaIds.swapAt(index, target)
  }

  private func save() async {
    do {
      try await model.saveCollection(
        id: collection?.id,
        name: name,
        mediaIds: isSmart ? [] : mediaIds,
        isSmart: isSmart,
        isShared: isShared,
        rulesJson: isSmart ? builtRulesJson : nil
      )
      model.preselectedCollectionItem = nil
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }

  private func deleteCollection() async {
    guard let collection else { return }
    do {
      try await model.deleteCollection(id: collection.id)
      model.preselectedCollectionItem = nil
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }
}

struct MetadataReviewQueueSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var reviews: [MetadataReviewSummary] = []
  @State private var errorMessage: String?
  @State private var manualReview: MetadataReviewSummary?

  var body: some View {
    VStack(spacing: 0) {
      sheetHeader(
        "Review Queue", subtitle: "Resolve uncertain metadata matches.", symbol: "checklist")
      Divider()
      if reviews.isEmpty {
        ContentUnavailableView(
          "Nothing to Review", systemImage: "checkmark.circle",
          description: Text("Items that need a decision will appear here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(reviews) { review in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              VStack(alignment: .leading) {
                Text(review.title).font(.headline)
                Text(review.reason).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text(review.state == .needsReview ? "Needs Review" : "Resolved")
                .font(.caption.weight(.semibold))
            }
            ForEach(review.candidates.prefix(3)) { candidate in
              HStack {
                Text(candidate.title)
                Spacer()
                Text(candidate.year.map(String.init) ?? "").foregroundStyle(.secondary)
                Text("\(Int((candidate.confidence * 100).rounded()))% match")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Button("Use Match") { Task { await choose(review, candidate) } }
                  .disabled(review.state != .needsReview)
              }
            }
            Button("Search Manually…") { manualReview = review }
              .disabled(review.state != .needsReview)
          }.padding(.vertical, 8)
        }
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.orange).padding() }
      Divider()
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }.padding(16)
    }
    .frame(width: 720, height: 640)
    .background(AureliaBackdrop())
    .task { await load() }
    .sheet(item: $manualReview) { review in
      MetadataMatchSheet(mediaId: review.mediaId, title: review.title) {
        await load()
      }
      .environmentObject(model)
    }
  }

  private func load() async {
    do { reviews = try await model.metadataReviews() } catch {
      errorMessage = error.localizedDescription
    }
  }
  private func choose(_ review: MetadataReviewSummary, _ candidate: MetadataCandidateSummary) async
  {
    do {
      _ = try await model.selectMetadataMatch(
        mediaId: review.mediaId,
        providerMediaId: candidate.providerMediaId,
        mediaType: candidate.mediaType)
      await load()
    } catch { errorMessage = error.localizedDescription }
  }
}

private func sheetHeader(_ title: String, subtitle: String, symbol: String) -> some View {
  HStack(spacing: 14) {
    Image(systemName: symbol).font(.title2).frame(width: 42, height: 42)
      .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.title2.bold())
      Text(subtitle).font(.callout).foregroundStyle(.secondary)
    }
    Spacer()
  }.padding(20)
}

private func nilIfEmpty(_ value: String) -> String? {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

private func values(_ value: String) -> [String] {
  value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
}
