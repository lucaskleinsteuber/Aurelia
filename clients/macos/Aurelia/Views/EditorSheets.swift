import SwiftUI

struct MetadataMatchSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let mediaId: UUID
  let mediaTitle: String
  let providerMediaId: String?
  let onSaved: () async -> Void
  @State private var query: String
  @State private var candidates: [MetadataCandidateSummary] = []
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
            .onSubmit { Task { await search() } }
          Button("Search") { Task { await search() } }
            .buttonStyle(AureliaPrimaryActionButtonStyle()).disabled(
              query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if candidates.isEmpty {
          ContentUnavailableView(
            "Compare Matches",
            systemImage: "rectangle.and.text.magnifyingglass",
            description: Text("Search by title, then choose the result that belongs to this media.")
          )
          .frame(maxHeight: .infinity)
        } else {
          List(candidates) { candidate in
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
            }
            .padding(.vertical, 6)
          }
          .listStyle(.inset)
        }
        if let errorMessage { Text(errorMessage).foregroundStyle(.orange).font(.callout) }
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
    .task { await search() }
    .accessibilityIdentifier("metadata-match-editor")
  }

  private func search() async {
    isWorking = true
    defer { isWorking = false }
    do {
      candidates = try await model.metadataCandidates(mediaId: mediaId, query: query)
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }

  private func select(_ candidate: MetadataCandidateSummary) async {
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
  @State private var errorMessage: String?
  @State private var showingDeleteConfirmation = false

  init(collection: CollectionSummary?) {
    self.collection = collection
    _name = State(initialValue: collection?.name ?? "")
    _mediaIds = State(initialValue: collection?.items.map(\.id) ?? [])
  }

  var body: some View {
    VStack(spacing: 0) {
      sheetHeader(
        collection == nil ? "New Collection" : "Edit Collection",
        subtitle: "Choose at least two movies or TV shows.",
        symbol: "rectangle.stack.badge.plus")
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        TextField("Collection Name", text: $name).textFieldStyle(.roundedBorder)
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
        if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.orange) }
      }.padding(24)
      Divider()
      HStack {
        if collection != nil {
          Button("Delete Collection", role: .destructive) { showingDeleteConfirmation = true }
        }
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") { Task { await save() } }
          .buttonStyle(AureliaPrimaryActionButtonStyle()).keyboardShortcut(.defaultAction)
          .disabled(!isValid)
      }.padding(16)
    }
    .frame(width: 720, height: 640)
    .background(AureliaBackdrop())
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

  private var isValid: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mediaIds.count >= 2
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
      try await model.saveCollection(id: collection?.id, name: name, mediaIds: mediaIds)
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }
  private func deleteCollection() async {
    guard let collection else { return }
    do {
      try await model.deleteCollection(id: collection.id)
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
