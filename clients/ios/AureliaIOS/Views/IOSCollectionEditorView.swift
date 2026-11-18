import PhotosUI
import SwiftUI

struct IOSCollectionEditorView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss

  let existing: IOSCollectionDetail?
  var preselectedMember: IOSLibraryActions.AddCollectionTarget? = nil
  var onSaved: ((IOSCollection) -> Void)? = nil

  @State private var name = ""
  @State private var overview = ""
  @State private var sortMode = "custom"
  @State private var isShared = false
  @State private var members: [EditableMember] = []
  /// A Smart List chooses its titles by rules; the server keeps it up to date.
  @State private var isSmart = false
  @State private var rules = IOSSmartRules()
  @State private var genreEntry = ""
  @State private var stagedCover: StagedArtwork?
  @State private var stagedBackdrop: StagedArtwork?
  @State private var removeCover = false
  @State private var removeBackdrop = false
  @State private var coverPickerItem: PhotosPickerItem?
  @State private var backdropPickerItem: PhotosPickerItem?
  @State private var cropDraft: CropDraft?
  @State private var showingMemberPicker = false
  @State private var saving = false
  @State private var uploadingArtwork = false
  @State private var error: String?
  @State private var initialized = false
  @State private var savedSuccessfully = false
  /// Creating the collection and attaching artwork are separate server operations. Keep the
  /// created identity so a failed artwork upload can be retried without creating a duplicate.
  @StateObject private var saveRecovery = IOSCollectionSaveRecovery()
  private var savedCollection: IOSCollection? { saveRecovery.savedCollection }

  struct EditableMember: Identifiable, Equatable {
    let mediaId: UUID
    var seasonNumber: Int?
    var title: String
    var kind: IOSMediaKind
    var subtitle: String?
    var id: String { "\(mediaId.uuidString):\(seasonNumber.map(String.init) ?? "all")" }
  }

  private struct StagedArtwork {
    let uploadId: UUID?
    let data: Data
    let crop: IOSArtworkCrop
    let preview: CGImage
  }

  private struct CropDraft: Identifiable {
    let id = UUID()
    let kind: String
    let image: CGImage
    var aspectRatio: CGFloat { kind == "backdrop" ? (16.0 / 9.0) : (2.0 / 3.0) }
  }

  private var canShare: Bool {
    let role = model.session?.user.role
    return role == "owner" || role == "admin"
  }

  private var canSave: Bool {
    IOSCollectionRules.cleanedName(name) != nil && !saving && !uploadingArtwork
      && (!isSmart || rules.problem == nil)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Details") {
          TextField("Name", text: $name)
          TextField("Overview", text: $overview, axis: .vertical)
            .lineLimit(2...5)
          Toggle("Smart List", isOn: $isSmart)
            .onChange(of: isSmart) { _, smart in
              if smart, sortMode == "custom" { sortMode = "release" }
            }
            .accessibilityIdentifier("collection-smart")
          Picker("Sort Order", selection: $sortMode) {
            if !isSmart { Text("Custom").tag("custom") }
            Text("Release Date").tag("release")
            Text("Title").tag("title")
          }
          if canShare {
            Toggle("Share with Household", isOn: $isShared)
          }
        }

        if model.supportsCollectionsV3 {
          Section("Artwork") {
            coverRow
            backdropRow
          }
        }

        if isSmart {
          smartRulesSections
        } else {
          membersSection
        }

        if let error {
          Section {
            Text(error).font(.footnote).foregroundStyle(.red)
          }
        }
      }
      .disabled(saving || uploadingArtwork)
      .navigationTitle(
        existing == nil && savedCollection == nil ? "New Collection" : "Edit Collection"
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(saving || uploadingArtwork)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(saving ? "Saving…" : "Save") {
            Task { await save() }
          }
          .disabled(!canSave)
        }
      }
      .interactiveDismissDisabled(saving || uploadingArtwork)
      .onAppear { populateInitialState() }
      .onDisappear {
        if !savedSuccessfully { cleanupStagedUploads() }
      }
      .onChange(of: coverPickerItem) { _, item in
        guard let item else { return }
        coverPickerItem = nil
        Task { await handlePickedItem(item, kind: "poster") }
      }
      .onChange(of: backdropPickerItem) { _, item in
        guard let item else { return }
        backdropPickerItem = nil
        Task { await handlePickedItem(item, kind: "backdrop") }
      }
      .sheet(item: $cropDraft) { draft in
        IOSArtworkCropSheet(
          image: draft.image, aspectRatio: draft.aspectRatio,
          title: draft.kind == "backdrop" ? "Crop Backdrop" : "Crop Cover"
        ) { crop in
          cropDraft = nil
          guard let crop else { return }
          Task { await uploadCropped(kind: draft.kind, image: draft.image, crop: crop) }
        }
      }
      .sheet(isPresented: $showingMemberPicker) {
        IOSCollectionMemberPickerSheet(members: $members)
          .environmentObject(model)
      }
    }
  }

  private var coverRow: some View {
    HStack(spacing: 12) {
      Group {
        if let stagedCover {
          Image(decorative: stagedCover.preview, scale: 1)
            .resizable().scaledToFill()
        } else if !removeCover, let poster = existing?.poster {
          IOSArtworkView(artwork: poster, width: 320, symbol: "photo")
        } else {
          Image(systemName: "photo").foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IOSDesign.surface)
        }
      }
      .frame(width: 48, height: 72)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

      let hasCover = stagedCover != nil || (existing?.poster != nil && !removeCover)
      VStack(alignment: .leading, spacing: 4) {
        Text("Cover (2:3)").font(.subheadline.weight(.semibold))
        HStack(spacing: 12) {
          PhotosPicker(selection: $coverPickerItem, matching: .images) {
            Text(hasCover ? "Replace" : "Choose")
              .font(.footnote.weight(.semibold))
          }
          .disabled(uploadingArtwork)
          if hasCover {
            Button("Remove", role: .destructive) {
              discardUpload(stagedCover?.uploadId)
              stagedCover = nil
              removeCover = true
            }
            .font(.footnote)
          }
        }
      }
      Spacer()
    }
  }

  private var backdropRow: some View {
    HStack(spacing: 12) {
      Group {
        if let stagedBackdrop {
          Image(decorative: stagedBackdrop.preview, scale: 1)
            .resizable().scaledToFill()
        } else if !removeBackdrop, let backdrop = existing?.backdrop {
          IOSArtworkView(artwork: backdrop, width: 640, symbol: "photo")
        } else {
          Image(systemName: "photo").foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IOSDesign.surface)
        }
      }
      .frame(width: 96, height: 54)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

      let hasBackdrop = stagedBackdrop != nil || (existing?.backdrop != nil && !removeBackdrop)
      VStack(alignment: .leading, spacing: 4) {
        Text("Backdrop (16:9)").font(.subheadline.weight(.semibold))
        HStack(spacing: 12) {
          PhotosPicker(selection: $backdropPickerItem, matching: .images) {
            Text(hasBackdrop ? "Replace" : "Choose")
              .font(.footnote.weight(.semibold))
          }
          .disabled(uploadingArtwork)
          if hasBackdrop {
            Button("Remove", role: .destructive) {
              discardUpload(stagedBackdrop?.uploadId)
              stagedBackdrop = nil
              removeBackdrop = true
            }
            .font(.footnote)
          }
        }
      }
      Spacer()
    }
  }

  private var membersSection: some View {
    Section {
      Button {
        showingMemberPicker = true
      } label: {
        Label("Add Movies, Shows or Seasons…", systemImage: "plus.circle")
      }

      if members.isEmpty {
        Text("Optional: add titles now or later from any movie, show or season.")
          .font(.footnote).foregroundStyle(.secondary)
      } else {
        ForEach(members) { member in
          HStack(spacing: 10) {
            Image(
              systemName: member.seasonNumber != nil
                ? "tv" : member.kind == .movie ? "film" : "tv.fill"
            )
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(member.title).font(.body).lineLimit(1)
              if let subtitle = member.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
        .onMove { offsets, destination in
          members.move(fromOffsets: offsets, toOffset: destination)
          sortMode = "custom"
        }
        .onDelete { offsets in
          members.remove(atOffsets: offsets)
        }
      }
    } header: {
      HStack {
        Text("Titles (\(members.count))")
        Spacer()
        if members.count > 1 { EditButton() }
      }
    }
  }

  @ViewBuilder private var smartRulesSections: some View {
    Section {
      Picker("Titles", selection: $rules.kind) {
        Text("Movies and Shows").tag(String?.none)
        Text("Movies").tag(Optional("movie"))
        Text("Shows").tag(Optional("series"))
      }
      Picker("Match", selection: $rules.combination) {
        Text("All Rules").tag("and")
        Text("Any Rule").tag("or")
      }
      .pickerStyle(.segmented)
    } header: {
      Text("Rules")
    } footer: {
      Text(rules.summary)
    }
    Section("Genres") {
      ForEach(rules.genres, id: \.self) { Text($0) }
        .onDelete { rules.genres.remove(atOffsets: $0) }
      HStack {
        TextField("Add Genre, such as Comedy", text: $genreEntry)
          .onSubmit(addGenre)
        Button("Add", action: addGenre)
          .disabled(genreEntry.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    Section("Time and Rating") {
      Picker("Decade", selection: $rules.decade) {
        Text("Any").tag(Int?.none)
        ForEach(IOSSmartRules.decades, id: \.self) { Text("\($0)s").tag(Optional($0)) }
      }
      HStack {
        TextField("From Year", text: yearBinding(\.yearMin)).keyboardType(.numberPad)
        TextField("Until Year", text: yearBinding(\.yearMax)).keyboardType(.numberPad)
      }
      Picker("Rated at Least", selection: $rules.ratingMin) {
        Text("Any").tag(Double?.none)
        ForEach([5.0, 6.0, 7.0, 7.5, 8.0, 9.0], id: \.self) {
          Text($0.formatted()).tag(Optional($0))
        }
      }
      Picker("Added", selection: $rules.addedWithinDays) {
        Text("Any Time").tag(Int?.none)
        ForEach(IOSSmartRules.addedChoices, id: \.self) {
          Text("In the Last \($0) Days").tag(Optional($0))
        }
      }
    }
    Section {
      Picker("Watched", selection: $rules.watchedState) {
        Text("Any").tag(String?.none)
        Text("Unwatched").tag(Optional("unwatched"))
        Text("In Progress").tag(Optional("inProgress"))
        Text("Watched").tag(Optional("watched"))
      }
      Toggle("Favorites Only", isOn: $rules.favoritesOnly)
      Toggle("Watchlist Only", isOn: $rules.watchlistOnly)
      TextField(
        "Title Contains",
        text: Binding(get: { rules.textContains ?? "" }, set: { rules.textContains = $0 }))
    } header: {
      Text("For This Profile")
    } footer: {
      if let problem = rules.problem {
        Text(problem).foregroundStyle(.orange)
      } else {
        Text(
          "The server picks the titles and keeps the list up to date. Watched, favorites and the watchlist count for whoever looks at it."
        )
      }
    }
  }

  private func yearBinding(_ key: WritableKeyPath<IOSSmartRules, Int?>) -> Binding<String> {
    Binding(
      get: { rules[keyPath: key].map(String.init) ?? "" },
      set: { rules[keyPath: key] = Int(String($0.filter(\.isNumber).prefix(4))) })
  }

  private func addGenre() {
    let clean = genreEntry.trimmingCharacters(in: .whitespacesAndNewlines)
    if !clean.isEmpty,
      !rules.genres.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame })
    {
      rules.genres.append(clean)
    }
    genreEntry = ""
  }

  private func populateInitialState() {
    guard !initialized else { return }
    initialized = true
    if let existing {
      name = existing.name
      overview = existing.overview ?? ""
      sortMode = existing.sortMode
      isShared = existing.isShared
      isSmart = existing.isSmart
      rules = IOSSmartRules.decode(existing.rulesJson)
      members = existing.members.map { member in
        let subtitle: String? =
          if let season = member.seasonNumber {
            season == 0 ? "Specials" : "Season \(season)"
          } else {
            member.kind == .episode ? member.item?.episodeLabel ?? "Episode" : nil
          }
        return EditableMember(
          mediaId: member.mediaId,
          seasonNumber: member.seasonNumber,
          title: member.displayTitle,
          kind: member.kind,
          subtitle: subtitle)
      }
    } else if let preselectedMember {
      let subtitle = preselectedMember.seasonNumber.map {
        $0 == 0 ? "Specials" : "Season \($0)"
      }
      members = [
        EditableMember(
          mediaId: preselectedMember.mediaId,
          seasonNumber: preselectedMember.seasonNumber,
          title: preselectedMember.title,
          kind: preselectedMember.kind,
          subtitle: subtitle)
      ]
    }
  }

  private func handlePickedItem(_ item: PhotosPickerItem, kind: String) async {
    error = nil
    guard let data = try? await item.loadTransferable(type: Data.self),
      let image = IOSPhotoCrop.uprightImage(data)
    else {
      error = "This image could not be opened."
      return
    }
    cropDraft = CropDraft(kind: kind, image: image)
  }

  private func uploadCropped(kind: String, image: CGImage, crop: IOSArtworkCrop) async {
    guard let api = model.client, let jpeg = IOSRectCrop.jpegUploadData(image) else {
      error = "The selected image could not be prepared for upload."
      return
    }
    uploadingArtwork = true
    defer { uploadingArtwork = false }
    do {
      let uploadId: UUID?
      if let collectionID = savedCollection?.id ?? existing?.id {
        uploadId = try await api.uploadCollectionEditorImage(collectionID: collectionID, jpeg).id
      } else {
        uploadId = nil
      }
      let staged = StagedArtwork(uploadId: uploadId, data: jpeg, crop: crop, preview: image)
      if kind == "poster" {
        discardUpload(stagedCover?.uploadId)
        stagedCover = staged
        removeCover = false
      } else {
        discardUpload(stagedBackdrop?.uploadId)
        stagedBackdrop = staged
        removeBackdrop = false
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func discardUpload(_ id: UUID?) {
    guard let id, let collectionID = savedCollection?.id ?? existing?.id, let api = model.client
    else { return }
    Task { try? await api.discardCollectionEditorImage(collectionID: collectionID, uploadID: id) }
  }

  private func cleanupStagedUploads() {
    discardUpload(stagedCover?.uploadId)
    discardUpload(stagedBackdrop?.uploadId)
  }

  private func save() async {
    guard canSave, let api = model.client, let cleanedName = IOSCollectionRules.cleanedName(name)
    else {
      return
    }
    saving = true
    error = nil
    defer { saving = false }
    let payload = IOSSaveCollection(
      name: cleanedName,
      mediaIds: isSmart ? nil : members.filter { $0.seasonNumber == nil }.map(\.mediaId),
      isSmart: isSmart,
      isShared: isShared,
      rulesJson: isSmart ? rules.json : nil,
      overview: IOSCollectionRules.cleanedOverview(overview),
      sortMode: isSmart && sortMode == "custom" ? "release" : sortMode,
      members: isSmart
        ? nil
        : members.map {
          IOSCollectionMemberInput(mediaId: $0.mediaId, seasonNumber: $0.seasonNumber)
        })
    var detailsSaved = false
    do {
      let saved = try await saveRecovery.saveDetails(
        existingID: existing?.id, payload: payload, api: api)
      detailsSaved = true
      if model.supportsCollectionsV3 {
        if let cover = stagedCover {
          let uploadId =
            if let existingUploadId = cover.uploadId {
              existingUploadId
            } else {
              try await api.uploadCollectionEditorImage(collectionID: saved.id, cover.data).id
            }
          stagedCover = StagedArtwork(
            uploadId: uploadId, data: cover.data, crop: cover.crop, preview: cover.preview)
          _ = try await api.saveCollectionArtwork(
            collectionID: saved.id, kind: "poster",
            IOSSaveCollectionArtwork(uploadId: uploadId, crop: cover.crop))
          stagedCover = nil
        } else if removeCover {
          try await api.deleteCollectionArtwork(collectionID: saved.id, kind: "poster")
          removeCover = false
        }
        if let backdrop = stagedBackdrop {
          let uploadId =
            if let existingUploadId = backdrop.uploadId {
              existingUploadId
            } else {
              try await api.uploadCollectionEditorImage(collectionID: saved.id, backdrop.data).id
            }
          stagedBackdrop = StagedArtwork(
            uploadId: uploadId, data: backdrop.data, crop: backdrop.crop, preview: backdrop.preview)
          _ = try await api.saveCollectionArtwork(
            collectionID: saved.id, kind: "backdrop",
            IOSSaveCollectionArtwork(uploadId: uploadId, crop: backdrop.crop))
          stagedBackdrop = nil
        } else if removeBackdrop {
          try await api.deleteCollectionArtwork(collectionID: saved.id, kind: "backdrop")
          removeBackdrop = false
        }
      }
      savedSuccessfully = true
      model.scheduleLibraryRefresh()
      onSaved?(saved)
      dismiss()
    } catch {
      self.error =
        !detailsSaved
        ? error.localizedDescription
        : "The collection was saved, but its artwork could not be saved. Try Save again. \(error.localizedDescription)"
      if detailsSaved { model.scheduleLibraryRefresh() }
    }
  }
}

private struct IOSCollectionMemberPickerSheet: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss
  @Binding var members: [IOSCollectionEditorView.EditableMember]

  @State private var search = ""
  @State private var items: [IOSCatalogItem] = []
  @State private var expandedSeries: [UUID: IOSCatalogDetail] = [:]
  @State private var loadingSeries = Set<UUID>()
  @State private var loading = false

  private var filtered: [IOSCatalogItem] {
    let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return items }
    return items.filter { $0.title.localizedCaseInsensitiveContains(q) }
  }

  var body: some View {
    NavigationStack {
      List {
        if loading && items.isEmpty {
          ProgressView().frame(maxWidth: .infinity)
        }
        ForEach(filtered) { item in
          if item.kind == .series {
            seriesRows(item)
          } else {
            memberRow(
              mediaId: item.id, seasonNumber: nil,
              title: item.title, kind: item.kind,
              subtitle: item.year.map(String.init))
          }
        }
      }
      .searchable(text: $search, prompt: "Search movies & shows")
      .navigationTitle("Add Titles")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task { await loadCatalog() }
    }
  }

  @ViewBuilder
  private func seriesRows(_ show: IOSCatalogItem) -> some View {
    let detail = expandedSeries[show.id]
    DisclosureGroup(
      isExpanded: Binding(
        get: { detail != nil },
        set: { open in
          if open {
            Task { await expandSeries(show.id) }
          } else {
            expandedSeries[show.id] = nil
          }
        })
    ) {
      memberRow(
        mediaId: show.id, seasonNumber: nil,
        title: "All of \(show.title)", kind: .series, subtitle: "Entire Series")
      if loadingSeries.contains(show.id) {
        ProgressView()
      } else if let detail {
        ForEach(detail.seasons, id: \.number) { season in
          let label = season.number == 0 ? "Specials" : "Season \(season.number)"
          memberRow(
            mediaId: show.id, seasonNumber: season.number,
            title: "\(show.title) · \(label)", kind: .series,
            subtitle: "\(season.episodes.count) episodes")
          ForEach(season.episodes, id: \.item.id) { ep in
            memberRow(
              mediaId: ep.item.id, seasonNumber: nil,
              title: "\(ep.item.episodeLabel ?? "E\(ep.episodeNumber)") · \(ep.item.title)",
              kind: .episode, subtitle: show.title)
          }
        }
      }
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(show.title).font(.body)
          if let year = show.year {
            Text(String(year)).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        if loadingSeries.contains(show.id) { ProgressView() }
      }
    }
  }

  private func memberRow(
    mediaId: UUID, seasonNumber: Int?, title: String, kind: IOSMediaKind, subtitle: String?
  ) -> some View {
    let entry = IOSCollectionEditorView.EditableMember(
      mediaId: mediaId, seasonNumber: seasonNumber, title: title, kind: kind, subtitle: subtitle)
    let selected = members.contains { $0.id == entry.id }
    return Button {
      if let idx = members.firstIndex(where: { $0.id == entry.id }) {
        members.remove(at: idx)
      } else {
        members.append(entry)
      }
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).foregroundStyle(.primary)
          if let subtitle {
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : .secondary)
      }
    }
  }

  private func loadCatalog() async {
    guard items.isEmpty, let api = model.client else { return }
    loading = true
    defer { loading = false }
    async let movies = try? api.catalogPage(kind: .movie, offset: 0, limit: 200)
    async let shows = try? api.catalogPage(kind: .series, offset: 0, limit: 200)
    let (m, s) = await (movies, shows)
    items = ((m?.items ?? []) + (s?.items ?? [])).sorted {
      $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  private func expandSeries(_ id: UUID) async {
    guard expandedSeries[id] == nil, let api = model.client else { return }
    loadingSeries.insert(id)
    defer { loadingSeries.remove(id) }
    if let detail = try? await api.detail(id: id) {
      expandedSeries[id] = detail
    }
  }
}
