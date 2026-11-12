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
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Details") {
          TextField("Name", text: $name)
          TextField("Overview", text: $overview, axis: .vertical)
            .lineLimit(2...5)
          Picker("Sort Order", selection: $sortMode) {
            Text("Custom").tag("custom")
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
                Image(systemName: member.seasonNumber != nil ? "tv" : member.kind == .movie ? "film" : "tv.fill")
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

        if let error {
          Section {
            Text(error).font(.footnote).foregroundStyle(.red)
          }
        }
      }
      .navigationTitle(existing == nil ? "New Collection" : "Edit Collection")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(saving ? "Saving…" : "Save") {
            Task { await save() }
          }
          .disabled(!canSave)
        }
      }
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
        IOSCollectionCropSheet(draft: draft) { crop in
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

  private func populateInitialState() {
    guard !initialized else { return }
    initialized = true
    if let existing {
      name = existing.name
      overview = existing.overview ?? ""
      sortMode = existing.sortMode
      isShared = existing.isShared
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
      if let existing {
        uploadId = try await api.uploadCollectionEditorImage(collectionID: existing.id, jpeg).id
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
    guard let id, let existing, let api = model.client else { return }
    Task { try? await api.discardCollectionEditorImage(collectionID: existing.id, uploadID: id) }
  }

  private func cleanupStagedUploads() {
    discardUpload(stagedCover?.uploadId)
    discardUpload(stagedBackdrop?.uploadId)
  }

  private func save() async {
    guard let api = model.client, let cleanedName = IOSCollectionRules.cleanedName(name) else {
      return
    }
    saving = true
    error = nil
    defer { saving = false }
    let payload = IOSSaveCollection(
      name: cleanedName,
      mediaIds: members.filter { $0.seasonNumber == nil }.map(\.mediaId),
      isSmart: existing?.isSmart ?? false,
      isShared: isShared,
      rulesJson: existing?.rulesJson,
      overview: IOSCollectionRules.cleanedOverview(overview),
      sortMode: sortMode,
      members: members.map {
        IOSCollectionMemberInput(mediaId: $0.mediaId, seasonNumber: $0.seasonNumber)
      })
    do {
      let saved: IOSCollection
      if let existing {
        saved = try await api.updateCollection(id: existing.id, payload)
      } else {
        saved = try await api.createCollection(payload)
      }
      if model.supportsCollectionsV3 {
        if let cover = stagedCover {
          let uploadId =
            if let existingUploadId = cover.uploadId {
              existingUploadId
            } else {
              try await api.uploadCollectionEditorImage(collectionID: saved.id, cover.data).id
            }
          _ = try await api.saveCollectionArtwork(
            collectionID: saved.id, kind: "poster",
            IOSSaveCollectionArtwork(uploadId: uploadId, crop: cover.crop))
          stagedCover = nil
        } else if removeCover {
          try await api.deleteCollectionArtwork(collectionID: saved.id, kind: "poster")
        }
        if let backdrop = stagedBackdrop {
          let uploadId =
            if let existingUploadId = backdrop.uploadId {
              existingUploadId
            } else {
              try await api.uploadCollectionEditorImage(collectionID: saved.id, backdrop.data).id
            }
          _ = try await api.saveCollectionArtwork(
            collectionID: saved.id, kind: "backdrop",
            IOSSaveCollectionArtwork(uploadId: uploadId, crop: backdrop.crop))
          stagedBackdrop = nil
        } else if removeBackdrop {
          try await api.deleteCollectionArtwork(collectionID: saved.id, kind: "backdrop")
        }
      }
      savedSuccessfully = true
      model.scheduleLibraryRefresh()
      onSaved?(saved)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }

  private struct IOSCollectionCropSheet: View {
    let draft: CropDraft
    let done: (IOSArtworkCrop?) -> Void
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var dragging: CGSize = .zero
    @GestureState private var pinching: CGFloat = 1

    private var imageSize: CGSize { CGSize(width: draft.image.width, height: draft.image.height) }

    var body: some View {
      NavigationStack {
        GeometryReader { geometry in
          let maxW = max(120, geometry.size.width - 40)
          let maxH = max(120, geometry.size.height - 40)
          let frameW = min(maxW, maxH * draft.aspectRatio)
          let frameSize = CGSize(width: frameW, height: frameW / draft.aspectRatio)
          let liveZoom = min(max(zoom * pinching, 1), IOSRectCrop.maximumZoom)
          let live = IOSRectCrop.clamped(
            offset: CGSize(
              width: offset.width + dragging.width, height: offset.height + dragging.height),
            imageSize: imageSize, frameSize: frameSize, zoom: liveZoom)
          let scale = max(frameSize.width / imageSize.width, frameSize.height / imageSize.height)
            * liveZoom
          ZStack {
            Color.black.ignoresSafeArea()
            Image(decorative: draft.image, scale: 1)
              .resizable()
              .frame(width: imageSize.width * scale, height: imageSize.height * scale)
              .offset(live)
            Rectangle().fill(.black.opacity(0.55))
              .mask {
                Rectangle().overlay {
                  RoundedRectangle(cornerRadius: 10)
                    .frame(width: frameSize.width, height: frameSize.height)
                    .blendMode(.destinationOut)
                }
                .compositingGroup()
              }
              .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 10).strokeBorder(.white, lineWidth: 2)
              .frame(width: frameSize.width, height: frameSize.height)
              .allowsHitTesting(false)
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
          .clipped()
          .contentShape(Rectangle())
          .gesture(
            DragGesture()
              .updating($dragging) { value, state, _ in state = value.translation }
              .onEnded { value in
                offset = IOSRectCrop.clamped(
                  offset: CGSize(
                    width: offset.width + value.translation.width,
                    height: offset.height + value.translation.height),
                  imageSize: imageSize, frameSize: frameSize, zoom: zoom)
              }
              .simultaneously(
                with: MagnifyGesture()
                  .updating($pinching) { value, state, _ in state = value.magnification }
                  .onEnded { value in
                    zoom = min(max(zoom * value.magnification, 1), IOSRectCrop.maximumZoom)
                    offset = IOSRectCrop.clamped(
                      offset: offset, imageSize: imageSize, frameSize: frameSize, zoom: zoom)
                  })
          )
          .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
            ToolbarItem(placement: .confirmationAction) {
              Button("Use Artwork") {
                done(
                  IOSRectCrop.normalizedCrop(
                    imageSize: imageSize, frameSize: frameSize, zoom: zoom, offset: offset))
              }
            }
          }
        }
        .navigationTitle(draft.kind == "backdrop" ? "Crop Backdrop" : "Crop Cover")
        .navigationBarTitleDisplayMode(.inline)
      }
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
