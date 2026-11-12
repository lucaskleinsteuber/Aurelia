import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

private struct CollectionMemberDraft: Identifiable, Equatable {
  let mediaId: UUID
  let seasonNumber: Int?
  let title: String
  let kind: MediaKind

  var id: String {
    "\(mediaId.uuidString.lowercased()):\(seasonNumber.map(String.init) ?? "")"
  }

  var asInput: CollectionMemberInput {
    CollectionMemberInput(mediaId: mediaId, seasonNumber: seasonNumber)
  }

  var typeLabel: String {
    if let seasonNumber {
      return seasonNumber == 0 ? "Specials (Season 0)" : "Season \(seasonNumber)"
    }
    switch kind {
    case .movie: return "Movie"
    case .series: return "TV Show"
    case .episode: return "Episode"
    default: return kind.rawValue.capitalized
    }
  }
}

private struct CollectionCropTarget: Identifiable {
  let id = UUID()
  let kind: String
  let image: NSImage
  let uploadId: UUID?
  let data: Data
  let initialCrop: ArtworkCrop?
}

struct CollectionEditorSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let collection: CollectionSummary?
  @State private var name: String
  @State private var overview: String
  @State private var sortMode: String
  @State private var members: [CollectionMemberDraft]
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
  @State private var searchQuery: String = ""
  @State private var expandedSeries: [UUID: [SeasonPresentation]] = [:]
  @State private var openSeriesIds: Set<UUID> = []
  @State private var loadingSeriesIds: Set<UUID> = []
  @State private var posterPreview: NSImage?
  @State private var posterUpload: (uploadId: UUID?, data: Data?, crop: ArtworkCrop)?
  @State private var removePoster = false
  @State private var backdropPreview: NSImage?
  @State private var backdropUpload: (uploadId: UUID?, data: Data?, crop: ArtworkCrop)?
  @State private var removeBackdrop = false
  @State private var cropTarget: CollectionCropTarget?
  @State private var unusedUploadIds: [UUID] = []
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var showingDeleteConfirmation = false

  init(collection: CollectionSummary?) {
    self.collection = collection
    _name = State(initialValue: collection?.name ?? "")
    _overview = State(initialValue: collection?.overview ?? "")
    _sortMode = State(initialValue: collection?.sortMode ?? ((collection?.isSmart ?? false) ? "release" : "custom"))
    _members = State(
      initialValue: (collection?.items ?? []).map {
        CollectionMemberDraft(mediaId: $0.id, seasonNumber: nil, title: $0.title, kind: $0.kind)
      })
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
          : "Customize metadata, artwork, sort order, and members.",
        symbol: isSmart ? "sparkles.rectangle.stack" : "rectangle.stack.badge.plus")

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          TextField("Collection Name", text: $name)
            .textFieldStyle(.roundedBorder)

          VStack(alignment: .leading, spacing: 4) {
            Text("Description")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            TextField(
              "Optional description of this collection…", text: $overview, axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
          }

          HStack(spacing: 16) {
            Picker("Collection Type", selection: $isSmart) {
              Text("Box Set").tag(false)
              Text("Smart List").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: isSmart) { _, nowSmart in
              if nowSmart && sortMode == "custom" { sortMode = "release" }
            }

            Picker("Sort Order", selection: $sortMode) {
              if !isSmart {
                Text("Custom Order").tag("custom")
              }
              Text("Release Date").tag("release")
              Text("Title").tag("title")
            }
            .frame(maxWidth: 220)
          }

          artworkEditorRow

          if isSmart {
            smartListRuleBuilder
          } else {
            standardItemPicker
          }

          if model.canManageMedia {
            Toggle("Shared Collection (visible to all profiles)", isOn: $isShared)
              .font(.caption)
          }

          if let errorMessage {
            Text(errorMessage).font(.callout).foregroundStyle(.orange)
          }
        }
        .padding(24)
      }

      Divider()
      HStack {
        if collection != nil {
          Button("Delete Collection", role: .destructive) { showingDeleteConfirmation = true }
            .disabled(isSaving)
        }
        Spacer()
        Button("Cancel") {
          clearPreselection()
          Task { await discardUnusedUploads() }
          dismiss()
        }.keyboardShortcut(.cancelAction)
        Button(isSaving ? "Saving…" : "Save") {
          Task { await save() }
        }
        .buttonStyle(AureliaPrimaryActionButtonStyle()).keyboardShortcut(.defaultAction)
        .disabled(!isValid || isSaving)
      }
      .padding(16)
    }
    .frame(width: 780, height: 760)
    .background(AureliaBackdrop())
    .onAppear {
      applyPreselection()
    }
    .task {
      await loadCollectionDetails()
    }
    .onDisappear {
      clearPreselection()
    }
    .sheet(item: $cropTarget) { target in
      ArtworkCropSheet(
        image: target.image,
        ratio: target.kind == "poster" ? (2.0 / 3.0) : (16.0 / 9.0),
        roundPreview: false,
        initial: target.initialCrop,
        title: target.kind == "poster" ? "Adjust Collection Cover" : "Adjust Collection Backdrop",
        previewAccessibilityLabel: target.kind == "poster" ? "Cover Preview" : "Backdrop Preview",
        note: "Only the cropped region is sent to the server."
      ) { crop in
        if target.kind == "poster" {
          posterPreview = target.image
          posterUpload = (target.uploadId, target.data, crop)
          removePoster = false
        } else {
          backdropPreview = target.image
          backdropUpload = (target.uploadId, target.data, crop)
          removeBackdrop = false
        }
        cropTarget = nil
      }
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

  private var artworkEditorRow: some View {
    HStack(spacing: 18) {
      artworkSlot(
        title: "Cover (2:3)",
        kind: "poster",
        localImage: posterPreview,
        existingArtwork: removePoster ? nil : collection?.poster,
        width: 84,
        height: 126,
        canReset: posterUpload != nil || (collection?.poster != nil && !removePoster),
        onReset: {
          posterPreview = nil
          posterUpload = nil
          removePoster = collection?.poster != nil
        })

      artworkSlot(
        title: "Backdrop (16:9)",
        kind: "backdrop",
        localImage: backdropPreview,
        existingArtwork: removeBackdrop ? nil : collection?.backdrop,
        width: 224,
        height: 126,
        canReset: backdropUpload != nil || (collection?.backdrop != nil && !removeBackdrop),
        onReset: {
          backdropPreview = nil
          backdropUpload = nil
          removeBackdrop = collection?.backdrop != nil
        })

      Spacer()
    }
    .padding(12)
    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: AureliaDesign.cardRadius))
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.cardRadius).stroke(AureliaDesign.hairline, lineWidth: 1)
    }
  }

  private func artworkSlot(
    title: String,
    kind: String,
    localImage: NSImage?,
    existingArtwork: ArtworkSummary?,
    width: CGFloat,
    height: CGFloat,
    canReset: Bool,
    onReset: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      HStack(spacing: 10) {
        Group {
          if let localImage {
            Image(nsImage: localImage).resizable().scaledToFill()
          } else {
            AuthenticatedArtwork(
              artwork: existingArtwork,
              symbol: kind == "poster" ? "rectangle.stack.fill" : "photo.fill",
              contentMode: .fill)
          }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8).stroke(AureliaDesign.hairline, lineWidth: 1)
        }

        VStack(alignment: .leading, spacing: 6) {
          Button("Choose Image…") { chooseArtwork(kind: kind) }
            .buttonStyle(.bordered)
            .controlSize(.small)
          if canReset {
            Button("Use Automatic", action: onReset)
              .buttonStyle(.bordered)
              .controlSize(.small)
          }
        }
      }
    }
  }

  private var standardItemPicker: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !members.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Selected Members (\(members.count))")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Spacer()
            if sortMode != "custom" {
              Text("Sorted on server by \(sortMode == "title" ? "Title" : "Release Date")")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          List {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
              HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                  .foregroundStyle(.tertiary)
                  .font(.caption)
                Text(member.title)
                  .lineLimit(1)
                Spacer()
                Text(member.typeLabel)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Button {
                  moveMember(index, by: -1)
                } label: {
                  Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                Button {
                  moveMember(index, by: 1)
                } label: {
                  Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(index == members.count - 1)
                Button {
                  members.remove(at: index)
                } label: {
                  Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
              }
            }
            .onMove { from, to in
              members.move(fromOffsets: from, toOffset: to)
              sortMode = "custom"
            }
          }
          .listStyle(.inset)
          .frame(height: min(CGFloat(members.count) * 34 + 16, 175))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }

      HStack {
        Text("Library Titles & Seasons")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        TextField("Search library…", text: $searchQuery)
          .textFieldStyle(.roundedBorder)
          .frame(width: 240)
      }

      List {
        ForEach(filteredCatalogItems) { item in
          HStack(spacing: 8) {
            let selected = isSelected(mediaId: item.id, seasonNumber: nil)
            Button {
              toggleMember(
                CollectionMemberDraft(
                  mediaId: item.id, seasonNumber: nil, title: item.title, kind: item.kind))
            } label: {
              HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(item.title)
                Spacer()
                Text(item.kind == .movie ? "Movie" : "TV Show")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if item.kind == .series {
              Button {
                toggleSeriesExpansion(item)
              } label: {
                if loadingSeriesIds.contains(item.id) {
                  ProgressView().controlSize(.small)
                } else {
                  Image(
                    systemName: openSeriesIds.contains(item.id)
                      ? "chevron.down" : "chevron.right"
                  )
                  .foregroundStyle(.secondary)
                }
              }
              .buttonStyle(.borderless)
              .help("Choose seasons or individual episodes")
            }
          }

          if item.kind == .series, openSeriesIds.contains(item.id),
            let seasons = expandedSeries[item.id]
          {
            ForEach(seasons) { season in
              let seasonDraft = CollectionMemberDraft(
                mediaId: item.id,
                seasonNumber: season.number,
                title: "\(item.title) · \(season.number == 0 ? "Specials" : "Season \(season.number)")",
                kind: .series)
              let seasonSelected = isSelected(mediaId: item.id, seasonNumber: season.number)
              Button {
                toggleMember(seasonDraft)
              } label: {
                HStack {
                  Image(systemName: seasonSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(seasonSelected ? Color.accentColor : .secondary)
                  Text(season.number == 0 ? "Specials (Season 0)" : "Season \(season.number)")
                    .font(.callout.weight(.medium))
                  Spacer()
                  Text("\(season.episodes.count) episodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 22)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)

              ForEach(season.episodes) { episode in
                let epCode = "S\(String(format: "%02d", episode.seasonNumber))E\(String(format: "%02d", episode.episodeNumber))"
                let epDraft = CollectionMemberDraft(
                  mediaId: episode.id,
                  seasonNumber: nil,
                  title: "\(item.title) · \(epCode) · \(episode.item.title)",
                  kind: .episode)
                let epSelected = isSelected(mediaId: episode.id, seasonNumber: nil)
                Button {
                  toggleMember(epDraft)
                } label: {
                  HStack {
                    Image(systemName: epSelected ? "checkmark.circle.fill" : "circle")
                      .foregroundStyle(epSelected ? Color.accentColor : .secondary)
                    Text("\(epCode) · \(episode.item.title)")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    Spacer()
                    Text("Episode")
                      .font(.caption2)
                      .foregroundStyle(.tertiary)
                  }
                  .padding(.leading, 42)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
              }
            }
          }
        }
      }
      .listStyle(.inset)
      .frame(minHeight: 200)
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
  }

  private var filteredCatalogItems: [CatalogItemSummary] {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidates = model.catalogItems.filter { $0.kind == .movie || $0.kind == .series }
    if query.isEmpty { return candidates }
    return candidates.filter { $0.title.localizedCaseInsensitiveContains(query) }
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
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func isSelected(mediaId: UUID, seasonNumber: Int?) -> Bool {
    members.contains { $0.mediaId == mediaId && $0.seasonNumber == seasonNumber }
  }

  private func toggleMember(_ draft: CollectionMemberDraft) {
    if let index = members.firstIndex(where: { $0.id == draft.id }) {
      members.remove(at: index)
    } else {
      members.append(draft)
    }
  }

  private func moveMember(_ index: Int, by offset: Int) {
    let target = index + offset
    guard members.indices.contains(target) else { return }
    members.swapAt(index, target)
    sortMode = "custom"
  }

  private func toggleSeriesExpansion(_ item: CatalogItemSummary) {
    if openSeriesIds.contains(item.id) {
      openSeriesIds.remove(item.id)
      return
    }
    openSeriesIds.insert(item.id)
    guard expandedSeries[item.id] == nil, !loadingSeriesIds.contains(item.id) else { return }
    loadingSeriesIds.insert(item.id)
    Task {
      defer { loadingSeriesIds.remove(item.id) }
      if let detail = try? await model.catalogDetail(id: item.id) {
        expandedSeries[item.id] = detail.seasons
      }
    }
  }

  private func chooseArtwork(kind: String) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.jpeg, .png, .heic, .webP, .image]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        let png = try EditorImageImport.png(url: url)
        guard let nsImage = NSImage(data: png) else { return }
        var uploadedId: UUID?
        if let collection, let profile = model.profile {
          let uploaded = try await APIClient(profile: profile).uploadCollectionEditorImage(
            id: collection.id, png: png)
          uploadedId = uploaded.id
          unusedUploadIds.append(uploaded.id)
        }
        cropTarget = CollectionCropTarget(
          kind: kind,
          image: nsImage,
          uploadId: uploadedId,
          data: png,
          initialCrop: kind == "poster" ? posterUpload?.crop : backdropUpload?.crop)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func applyPreselection() {
    guard collection == nil, let preselected = model.preselectedCollectionItem else { return }
    let season = model.preselectedCollectionSeasonNumber
    let title: String
    if let season {
      title = "\(preselected.title) · \(season == 0 ? "Specials" : "Season \(season)")"
    } else {
      title = preselected.title
    }
    let draft = CollectionMemberDraft(
      mediaId: preselected.id, seasonNumber: season, title: title, kind: preselected.kind)
    if !members.contains(where: { $0.id == draft.id }) {
      members.append(draft)
    }
  }

  private func clearPreselection() {
    model.preselectedCollectionItem = nil
    model.preselectedCollectionSeasonNumber = nil
  }

  private func loadCollectionDetails() async {
    guard let collection else { return }
    guard let detail = try? await model.collectionDetail(id: collection.id) else { return }
    if overview.isEmpty, let fetchedOverview = detail.overview {
      overview = fetchedOverview
    }
    sortMode = detail.sortMode
    members = detail.members.map {
      CollectionMemberDraft(
        mediaId: $0.mediaId,
        seasonNumber: $0.seasonNumber,
        title: $0.title,
        kind: $0.kind)
    }
  }

  private func discardUnusedUploads() async {
    guard let collection, let profile = model.profile, !unusedUploadIds.isEmpty else { return }
    let client = APIClient(profile: profile)
    for uploadId in unusedUploadIds {
      try? await client.discardCollectionEditorImage(id: collection.id, uploadId: uploadId)
    }
    unusedUploadIds.removeAll()
  }

  private func save() async {
    isSaving = true
    defer { isSaving = false }
    do {
      let cleanedOverview = overview.trimmingCharacters(in: .whitespacesAndNewlines)
      let effectiveSort = isSmart && sortMode == "custom" ? "release" : sortMode
      _ = try await model.saveCollection(
        id: collection?.id,
        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        mediaIds: [],
        isSmart: isSmart,
        isShared: isShared,
        rulesJson: isSmart ? builtRulesJson : nil,
        overview: cleanedOverview.isEmpty ? "" : cleanedOverview,
        sortMode: effectiveSort,
        members: isSmart ? nil : members.map(\.asInput),
        posterUpload: posterUpload,
        backdropUpload: backdropUpload,
        removePoster: removePoster,
        removeBackdrop: removeBackdrop
      )
      unusedUploadIds.removeAll()
      clearPreselection()
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }

  private func deleteCollection() async {
    guard let collection else { return }
    do {
      try await model.deleteCollection(id: collection.id)
      clearPreselection()
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
