import SwiftUI

struct IOSCollectionCard: View {
  let collection: IOSCollection
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      VStack(spacing: 2) {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(Color.white.opacity(0.14))
          .frame(height: 3)
          .padding(.horizontal, 14)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color.white.opacity(0.22))
          .frame(height: 4)
          .padding(.horizontal, 7)
        IOSArtworkView(
          artwork: collection.poster ?? collection.backdrop
            ?? collection.items.lazy.compactMap(\.poster).first,
          width: 320,
          symbol: "rectangle.stack")
          .aspectRatio(2 / 3, contentMode: .fit)
          .overlay(alignment: .topLeading) {
            if let provider = IOSCollectionRules.providerLabel(collection.provider) {
              badge(provider == "TMDB Collection" ? "TMDB" : provider)
            } else if collection.isSmart {
              badge("Smart")
            }
          }
          .overlay(alignment: .bottom) {
            let total =
              collection.itemCount > 0 ? collection.itemCount : collection.totalCount
            if total > 0, collection.watchedCount > 0 {
              IOSProgressBar(fraction: Double(collection.watchedCount) / Double(total))
                .padding(8)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: IOSDesign.cardRadius, style: .continuous))
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(collection.name).font(.footnote.weight(.semibold)).lineLimit(1)
        Text(IOSCollectionRules.cardSubtitle(collection))
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }

  private func badge(_ text: String) -> some View {
    Text(text).font(.caption2.weight(.bold))
      .padding(.horizontal, 6).padding(.vertical, 3)
      .background(.ultraThinMaterial, in: Capsule())
      .padding(6)
  }
}

struct IOSCollectionsView: View {
  @EnvironmentObject private var model: IOSAppModel
  @State private var collections: [IOSCollection] = []
  @State private var loading = false
  @State private var complete = false
  @State private var error: String?
  @State private var generation = UUID()
  @State private var creating = false

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        LazyVGrid(columns: IOSDesign.gridColumns, spacing: 20) {
          ForEach(collections) { collection in
            NavigationLink {
              IOSCollectionView(collection: collection)
            } label: {
              IOSCollectionCard(collection: collection)
            }.buttonStyle(IOSContentButtonStyle()).onAppear {
              if collection.id == collections.last?.id { Task { await next() } }
            }
          }
        }
        if loading { ProgressView() }
        if let error {
          IOSErrorText(message: error)
          Button("Try Again") { Task { await next(replacing: true) } }.buttonStyle(IOSButtonStyle())
        }
        if complete && collections.isEmpty {
          ContentUnavailableView("No Collections", systemImage: "rectangle.stack")
        }
      }.padding(.horizontal, IOSDesign.margin).padding(.vertical, 12)
    }
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Collections")
    .toolbar {
      if model.supportsCollections {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            creating = true
          } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("New Collection")
        }
      }
    }
    .sheet(isPresented: $creating) {
      IOSCollectionEditorView(existing: nil) { _ in
        Task { await next(replacing: true) }
      }
      .environmentObject(model)
    }
    .task(id: model.libraryRefresh) {
      generation = UUID()
      complete = false
      loading = false
      await next(replacing: true)
    }
  }

  private func next(replacing: Bool = false) async {
    guard (!loading || replacing), (!complete || replacing), let api = model.client else { return }
    let run = generation
    let session = model.session?.sessionId
    loading = true
    defer { if generation == run { loading = false } }
    do {
      let values = try await api.collections(offset: replacing ? 0 : collections.count)
      guard !Task.isCancelled, generation == run, model.session?.sessionId == session else {
        return
      }
      if replacing {
        collections = values
      } else {
        let old = Set(collections.map(\.id))
        collections += values.filter { !old.contains($0.id) }
      }
      complete = values.count < 60
      error = nil
    } catch {
      guard generation == run, model.session?.sessionId == session else { return }
      self.error = error.localizedDescription
      model.handleSessionFailure(error)
    }
  }
}

struct IOSCollectionView: View {
  @EnvironmentObject private var model: IOSAppModel
  let collection: IOSCollection
  @StateObject private var actions = IOSLibraryActions()
  @State private var activeID: UUID?
  @State private var detail: IOSCollectionDetail?
  @State private var loading = false
  @State private var unavailable = false
  @State private var error: String?
  @State private var requestID = UUID()
  @State private var editing = false
  @State private var confirmDelete = false
  @State private var savingCopy = false
  @State private var playback: CollectionPlaybackRequest?
  @State private var expandedMembers = Set<UUID>()
  @State private var fullOverview = false
  @Environment(\.dismiss) private var dismiss

  private struct CollectionPlaybackRequest: Identifiable {
    let item: IOSCatalogItem
    let queue: [IOSCatalogItem]
    let startOver: Bool
    var id: UUID { item.id }
  }

  private var targetID: UUID { activeID ?? collection.id }

  private var currentSummary: IOSCollection {
    detail?.summary ?? collection
  }

  private var canEdit: Bool {
    model.supportsCollections
      && IOSCollectionRules.canEdit(
        currentSummary, userID: model.session?.user.id,
        role: model.session?.user.role, supportsV3: model.supportsCollectionsV3)
  }

  private var heroArtwork: IOSArtwork? {
    detail?.backdrop
      ?? detail?.members.lazy.compactMap { $0.item?.backdrop ?? $0.episodes?.first?.backdrop }.first
      ?? detail?.poster
      ?? collection.backdrop
      ?? collection.poster
  }

  private var boxCoverArtwork: IOSArtwork? {
    detail?.poster
      ?? collection.poster
      ?? detail?.members.lazy.compactMap { $0.item?.poster }.first
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if let detail {
          heroSection(detail)
          membersSection(detail)
        }
        if loading && detail == nil {
          ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("collection-loading")
        }
        if unavailable {
          ContentUnavailableView("Collection Unavailable", systemImage: "rectangle.stack")
            .accessibilityIdentifier("collection-unavailable")
        }
        if let error {
          VStack(alignment: .leading, spacing: 10) {
            IOSErrorText(message: error)
            Button("Try Again") { Task { await reload() } }.buttonStyle(IOSButtonStyle())
          }.padding(.horizontal, IOSDesign.margin)
        }
      }
      .padding(.bottom, 32)
    }
    .ignoresSafeArea(edges: .top)
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      if canEdit {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button("Edit Collection…", systemImage: "pencil") { editing = true }
            Button("Delete Collection", systemImage: "trash", role: .destructive) {
              confirmDelete = true
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .accessibilityLabel("Edit Collection")
        }
      }
    }
    .sheet(isPresented: $editing) {
      IOSCollectionEditorView(existing: detail) { _ in
        Task { await reload() }
      }
      .environmentObject(model)
    }
    .confirmationDialog(
      "Delete \(detail?.name ?? collection.name)?", isPresented: $confirmDelete,
      titleVisibility: .visible
    ) {
      Button("Delete Collection", role: .destructive) { Task { await delete() } }
    } message: {
      Text("Only the collection goes away; its titles stay in the library.")
    }
    .fullScreenCover(
      item: $playback,
      onDismiss: {
        model.playerPresented = false
        Task { await reload() }
      },
      content: { req in
        if let connection = model.connection, let session = model.session {
          let target = req.item
          IOSPlayerView(makeController: {
            IOSPlaybackController(
              connection: connection, session: session, mediaID: target.id,
              title: target.episodeLabel.map {
                "\(target.parentTitle ?? target.title) · \($0)"
              } ?? target.title,
              outbox: model.environment.outbox,
              api: model.makeClient(connection: connection, session: session),
              runtime: model.environment.makePlaybackRuntime(),
              queue: req.queue,
              seriesID: target.kind == .episode ? target.parentId : nil,
              preferencesStore: model.environment.preferences,
              adaptiveStreaming: model.supportsAdaptiveStreaming,
              supportsSuggestions: model.supportsSuggestions,
              onClose: { playback = nil },
              onSessionFailure: { failure in
                guard model.session?.sessionId == session.sessionId else { return }
                model.handleSessionFailure(failure)
                playback = nil
              },
              startOver: req.startOver)
          })
        }
      }
    )
    .task(id: "\(model.libraryRefresh.uuidString)-\(targetID.uuidString)") {
      await reload()
    }
    .modifier(IOSLibraryActionPresentation(actions: actions))
  }

  private func heroSection(_ detail: IOSCollectionDetail) -> some View {
    VStack(spacing: 0) {
      IOSArtworkView(artwork: heroArtwork, width: 1280, symbol: nil)
        .frame(maxWidth: .infinity).frame(height: IOSDesign.isPad ? 420 : 300)
        .clipped()
        .overlay {
          LinearGradient(
            stops: [
              .init(color: .black.opacity(0.45), location: 0),
              .init(color: .clear, location: 0.28),
              .init(color: IOSDesign.canvas.opacity(0.88), location: 0.85),
              .init(color: IOSDesign.canvas, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }

      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .bottom, spacing: 14) {
          IOSArtworkView(artwork: boxCoverArtwork, width: 320, symbol: "rectangle.stack")
            .frame(width: 84, height: 126)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1))

          VStack(alignment: .leading, spacing: 4) {
            if let badge = IOSCollectionRules.providerLabel(detail.provider)
              ?? (detail.isSmart ? "Smart List" : nil)
            {
              IOSEyebrow(text: badge)
            } else {
              IOSEyebrow(text: "Collection")
            }
            Text(detail.name).font(.title2.weight(.bold)).lineLimit(2)
            Text(IOSCollectionRules.statsLine(detail))
              .font(.caption).foregroundStyle(.secondary)
            if !detail.genres.isEmpty {
              Text(detail.genres.prefix(3).joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 0)
        }

        if detail.itemCount > 0 {
          let fraction = Double(detail.watchedCount) / Double(detail.itemCount)
          IOSProgressBar(fraction: fraction)
        }

        if let overview = detail.overview, !overview.isEmpty {
          Button {
            fullOverview.toggle()
          } label: {
            Text(overview).font(.subheadline).foregroundStyle(.white.opacity(0.85))
              .lineLimit(fullOverview ? nil : 3)
              .multilineTextAlignment(.leading)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
        }

        let playable = IOSCollectionRules.playableItems(from: detail)
        if !playable.isEmpty {
          HStack(spacing: 10) {
            Button {
              Task { await playCollection(detail) }
            } label: {
              HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text(IOSCollectionRules.playLabel(detail.nextItem))
              }
            }
            .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: true))

            if model.supportsCollectionsV3 && !canEdit && detail.provider != nil {
              Button {
                Task { await saveAsCollection(detail) }
              } label: {
                if savingCopy {
                  ProgressView().tint(.white)
                } else {
                  Label("Save", systemImage: "square.and.arrow.down")
                }
              }
              .buttonStyle(IOSButtonStyle(kind: .secondary))
              .disabled(savingCopy)
            }
          }
        } else if model.supportsCollectionsV3 && !canEdit && detail.provider != nil {
          Button {
            Task { await saveAsCollection(detail) }
          } label: {
            Label("Save as Collection", systemImage: "square.and.arrow.down")
          }
          .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
          .disabled(savingCopy)
        }
      }
      .padding(.horizontal, IOSDesign.margin)
      .padding(.top, -56)
    }
  }

  @ViewBuilder
  private func membersSection(_ detail: IOSCollectionDetail) -> some View {
    if detail.members.isEmpty {
      ContentUnavailableView("No Titles Available", systemImage: "rectangle.stack")
        .padding(.horizontal, IOSDesign.margin)
    } else {
      VStack(alignment: .leading, spacing: 12) {
        Text("In This Collection")
          .font(.title3.weight(.bold))
          .padding(.horizontal, IOSDesign.margin)

        LazyVStack(spacing: 10) {
          ForEach(Array(detail.members.enumerated()), id: \.element.id) { index, member in
            memberCard(detail: detail, index: index, member: member)
          }
        }
        .padding(.horizontal, IOSDesign.margin)
      }
    }
  }

  private func memberCard(detail: IOSCollectionDetail, index: Int, member: IOSCollectionMember)
    -> some View
  {
    let episodes = member.episodes ?? []
    let expanded = expandedMembers.contains(member.id)
    let firstEpisode = episodes.first { $0.isPlayable } ?? episodes.first
    let linkedItem = member.item.map { model.overlay($0) }
    let subtitleParts: [String] = {
      var list: [String] = []
      if let season = member.seasonNumber {
        list.append(season == 0 ? "Specials" : "Season \(season)")
      }
      if !episodes.isEmpty {
        list.append(episodes.count == 1 ? "1 episode" : "\(episodes.count) episodes")
      } else if let total = member.itemCount, total > 1 {
        list.append("\(total) episodes")
      } else if let year = linkedItem?.year {
        list.append(String(year))
      }
      if let wc = member.watchedCount, let ic = member.itemCount, ic > 1 {
        list.append("\(wc) of \(ic) watched")
      } else if (member.watchedCount ?? 0) > 0 {
        list.append("Watched")
      }
      return list
    }()

    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        NavigationLink {
          if let item = linkedItem {
            IOSDetailView(
              id: item.detailID, initial: item, selectedEpisodeID: member.kind == .episode ? item.id : nil)
          } else {
            IOSDetailView(
              id: member.mediaId,
              initial: firstEpisode ?? IOSCatalogItem(
                id: member.mediaId, kind: member.kind, title: member.displayTitle, originalTitle: nil,
                year: nil, overview: nil, genres: [], poster: nil, backdrop: nil,
                availability: .available, isFavorite: false, progress: nil, addedAt: "",
                parentTitle: nil, seasonNumber: member.seasonNumber, episodeNumber: nil,
                parentId: nil, watchState: nil, libraryAvailability: nil))
          }
        } label: {
          HStack(spacing: 12) {
            IOSArtworkView(
              artwork: linkedItem?.poster ?? firstEpisode?.poster ?? firstEpisode?.backdrop,
              width: 320, symbol: member.kind == .movie ? "film" : "tv")
              .frame(width: 54, height: 81)
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
              Text("\(index + 1). \(member.displayTitle)")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
              if !subtitleParts.isEmpty {
                Text(subtitleParts.joined(separator: " · "))
                  .font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              if let fraction = linkedItem?.progressFraction {
                IOSProgressBar(fraction: fraction).frame(maxWidth: 140)
              }
            }
          }
        }
        .buttonStyle(.plain)

        Spacer(minLength: 4)

        if !episodes.isEmpty {
          Button {
            if expanded {
              expandedMembers.remove(member.id)
            } else {
              expandedMembers.insert(member.id)
            }
          } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
              .font(.caption.weight(.bold))
              .padding(8)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(expanded ? "Hide Episodes" : "Show Episodes")
        }

        if let playTarget = (member.kind == .movie || member.kind == .episode ? linkedItem : firstEpisode),
          playTarget.isPlayable
        {
          Button {
            startPlayback(detail: detail, target: playTarget, startOver: false)
          } label: {
            Image(systemName: "play.circle.fill").font(.title3)
          }
          .buttonStyle(.plain)
        }
      }
      .contextMenu {
        if let linkedItem {
          IOSMediaContextActions(item: linkedItem, actions: actions)
        }
        if canEdit {
          if index > 0 {
            Button("Move Up", systemImage: "arrow.up") {
              Task { await moveMember(at: index, by: -1) }
            }
          }
          if index + 1 < detail.members.count {
            Button("Move Down", systemImage: "arrow.down") {
              Task { await moveMember(at: index, by: 1) }
            }
          }
          Button("Remove from Collection", role: .destructive) {
            Task { await remove(member) }
          }
        }
      }

      if expanded && !episodes.isEmpty {
        Divider().opacity(0.3)
        ForEach(episodes) { originalEp in
          let ep = model.overlay(originalEp)
          Button {
            startPlayback(detail: detail, target: ep, startOver: false)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "play.fill").font(.caption2).foregroundStyle(.secondary)
              Text(ep.episodeLabel.map { "\($0) · \(ep.title)" } ?? ep.title)
                .font(.caption).lineLimit(1)
              Spacer()
              if ep.watchState == "completed" {
                Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 4)
            .padding(.leading, 8)
          }
          .buttonStyle(.plain)
          .disabled(!ep.isPlayable)
        }
      }
    }
    .padding(10)
    .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityIdentifier("collection-item-\(member.mediaId)")
  }

  private func playCollection(_ detail: IOSCollectionDetail) async {
    let next: IOSCollectionNextResponse?
    if model.supportsCollectionsV3, let api = model.client {
      next = (try? await api.collectionNext(id: detail.id)) ?? detail.nextItem
    } else {
      next = detail.nextItem
    }
    if let next {
      startPlayback(detail: detail, target: model.overlay(next.item), startOver: !next.resume)
    } else if let first = IOSCollectionRules.playableItems(from: detail).first {
      startPlayback(detail: detail, target: first, startOver: false)
    }
  }

  private func startPlayback(
    detail: IOSCollectionDetail, target: IOSCatalogItem, startOver: Bool
  ) {
    guard target.isPlayable else { return }
    model.playerPresented = true
    let queue = IOSCollectionRules.queue(in: detail, startingAt: target)
    playback = CollectionPlaybackRequest(item: target, queue: queue, startOver: startOver)
  }

  private func saveAsCollection(_ detail: IOSCollectionDetail) async {
    guard let api = model.client, !savingCopy else { return }
    savingCopy = true
    defer { savingCopy = false }
    do {
      let copied = try await api.saveFromFranchise(id: detail.id)
      model.scheduleLibraryRefresh()
      activeID = copied.id
      await reload()
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func moveMember(at index: Int, by delta: Int) async {
    guard let api = model.client, var currentDetail = detail else { return }
    let destination = index + delta
    guard currentDetail.members.indices.contains(index),
      currentDetail.members.indices.contains(destination)
    else { return }
    let entry = currentDetail.members.remove(at: index)
    currentDetail.members.insert(entry, at: destination)
    let order = currentDetail.members.map {
      IOSCollectionMemberInput(mediaId: $0.mediaId, seasonNumber: $0.seasonNumber)
    }
    do {
      detail = try await api.updateCollectionOrder(
        id: currentDetail.id, IOSCollectionOrderRequest(members: order, sortMode: "custom"))
      model.scheduleLibraryRefresh()
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func remove(_ member: IOSCollectionMember) async {
    guard let api = model.client else { return }
    do {
      try await api.setCollectionItem(
        collectionID: targetID, mediaID: member.mediaId,
        seasonNumber: member.seasonNumber, included: false)
      model.scheduleLibraryRefresh()
      await reload()
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func delete() async {
    guard let api = model.client else { return }
    do {
      try await api.deleteCollection(id: targetID)
      model.scheduleLibraryRefresh()
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func reload() async {
    guard let api = model.client, let sessionID = model.session?.sessionId else { return }
    let request = UUID()
    requestID = request
    loading = detail == nil
    unavailable = false
    error = nil
    defer {
      if requestID == request, model.session?.sessionId == sessionID { loading = false }
    }
    do {
      if model.supportsCollectionsV3 {
        let loaded = try await api.collectionDetail(id: targetID)
        guard !Task.isCancelled, requestID == request, model.session?.sessionId == sessionID else {
          return
        }
        for member in loaded.members {
          if let item = member.item { model.updateSummary(item) }
          for ep in member.episodes ?? [] { model.updateSummary(ep) }
        }
        detail = loaded
        return
      }
      var offset = 0
      while true {
        let page = try await api.collections(offset: offset)
        guard !Task.isCancelled, requestID == request, model.session?.sessionId == sessionID else {
          return
        }
        if let value = page.first(where: { $0.id == targetID }) {
          for item in value.items { model.updateSummary(item) }
          let members = value.items.map {
            IOSCollectionMember(mediaId: $0.id, kind: $0.kind, title: $0.title, item: $0)
          }
          detail = IOSCollectionDetail(
            id: value.id, name: value.name, overview: value.overview, poster: value.poster,
            backdrop: value.backdrop, provider: value.provider, canEdit: value.canEdit,
            isSmart: value.isSmart, isShared: value.isShared, userId: value.userId,
            rulesJson: value.rulesJson, sortMode: value.sortMode ?? "custom",
            itemCount: value.itemCount, watchedCount: value.watchedCount,
            yearRange: value.yearRange, members: members)
          return
        }
        if page.count < 60 {
          unavailable = true
          return
        }
        offset += page.count
      }
    } catch let failure as IOSCoreError where failure.isNotFound {
      guard !Task.isCancelled, requestID == request, model.session?.sessionId == sessionID else {
        return
      }
      unavailable = true
    } catch {
      guard !Task.isCancelled, requestID == request, model.session?.sessionId == sessionID else {
        return
      }
      self.error = error.localizedDescription
      model.handleSessionFailure(error)
    }
  }
}

private extension IOSCoreError {
  var isNotFound: Bool {
    if case .server(let status, _, _, _) = self { return status == 404 }
    return false
  }
}

struct IOSAddToCollectionSheet: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss
  let target: IOSLibraryActions.AddCollectionTarget

  @State private var collections: [IOSCollection] = []
  @State private var loading = true
  @State private var error: String?
  @State private var creating = false
  @State private var busyID: UUID?

  private var editableCollections: [IOSCollection] {
    collections.filter {
      !$0.isSmart
        && IOSCollectionRules.canEdit(
          $0, userID: model.session?.user.id,
          role: model.session?.user.role, supportsV3: model.supportsCollectionsV3)
    }
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Button {
            creating = true
          } label: {
            Label("New Collection…", systemImage: "plus.circle")
          }
        } header: {
          Text(target.title)
        }

        if loading {
          ProgressView().frame(maxWidth: .infinity)
        } else if editableCollections.isEmpty {
          Text("No editable collections yet. Create one above.")
            .font(.footnote).foregroundStyle(.secondary)
        } else {
          Section("Collections") {
            ForEach(editableCollections) { col in
              Button {
                Task { await add(to: col) }
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(col.name).foregroundStyle(.primary)
                    Text(IOSCollectionRules.cardSubtitle(col))
                      .font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer()
                  if busyID == col.id {
                    ProgressView()
                  } else {
                    Image(systemName: "plus.circle")
                      .foregroundStyle(Color.accentColor)
                  }
                }
              }
              .disabled(busyID != nil)
            }
          }
        }

        if let error {
          Section {
            Text(error).font(.footnote).foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Add to Collection")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .sheet(isPresented: $creating) {
        IOSCollectionEditorView(existing: nil, preselectedMember: target) { _ in
          dismiss()
        }
        .environmentObject(model)
      }
      .task { await load() }
    }
  }

  private func load() async {
    guard let api = model.client else { return }
    loading = true
    defer { loading = false }
    do {
      collections = try await api.collections(offset: 0, limit: 200)
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func add(to collection: IOSCollection) async {
    guard let api = model.client else { return }
    busyID = collection.id
    defer { busyID = nil }
    do {
      try await api.setCollectionItem(
        collectionID: collection.id, mediaID: target.mediaId,
        seasonNumber: target.seasonNumber, included: true)
      model.scheduleLibraryRefresh()
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
