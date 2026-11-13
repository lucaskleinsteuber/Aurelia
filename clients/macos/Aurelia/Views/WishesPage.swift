import AppKit
import SwiftUI

struct WishesPage: View {
  enum Filter: String, CaseIterable, Identifiable {
    case all = "All"
    case open = "Open"
    case fulfilled = "In Library"
    case declined = "Declined"

    var id: String { rawValue }

    var wishState: WishState? {
      switch self {
      case .all: nil
      case .open: .open
      case .fulfilled: .fulfilled
      case .declined: .declined
      }
    }
  }

  @EnvironmentObject private var model: AppModel
  let onOpenMedia: (UUID) -> Void

  @State private var wishes: [WishSummary] = []
  @State private var filter: Filter = .open
  @State private var isLoading = false
  @State private var isLoadingMore = false
  @State private var hasMore = false
  @State private var providerEnabled = true
  @State private var bannerMessage: String?
  @State private var errorMessage: String?
  @State private var alreadyInLibraryConflict: WishAlreadyInLibraryProblem?

  // Search & request composer
  @State private var searchQuery = ""
  @State private var searchKindFilter: MediaKind? = nil
  @State private var wishNote = ""
  @State private var isSearching = false
  @State private var searchResults: [WishSearchHit]?
  @State private var showManualForm = false
  @State private var manualKind: MediaKind = .movie
  @State private var manualTitle = ""
  @State private var manualYear = ""
  @State private var manualNote = ""
  @State private var submittingKey: String?
  @State private var busyWishIDs: Set<UUID> = []

  // Admin decline modal state
  @State private var decliningWish: WishSummary?
  @State private var declineNote = ""

  private static let pageSize = 30

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        headerSection
        composerSection
        feedbackSection
        listSection
      }
      .padding(AureliaDesign.pagePadding)
      .padding(.top, 22)
    }
    .scrollClipDisabled()
    .aureliaOverlayScrollbars()
    .task {
      await WishNotificationCenter.shared.requestPermissionOnFirstVisitIfNeeded()
      await loadWishes(reset: true, markSeen: true)
    }
    .onChange(of: filter) { _, _ in
      Task { await loadWishes(reset: true, markSeen: false) }
    }
    .sheet(item: $decliningWish) { wish in
      declineSheet(for: wish)
    }
    .accessibilityIdentifier("wishes-page")
  }

  private var headerSection: some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      AureliaSectionHeading(title: "Family Wishes", count: wishes.count)
      Spacer()
      Button {
        Task { await loadWishes(reset: true, markSeen: true) }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
      .disabled(isLoading)
    }
  }

  private var composerSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        AureliaSearchField(
          prompt: "Search for a movie or TV series to wish…",
          text: $searchQuery
        )
        .onSubmit { Task { await runSearch() } }
        .accessibilityIdentifier("wishes-search-field")

        Picker("Type", selection: $searchKindFilter) {
          Text("Any Type").tag(Optional<MediaKind>.none)
          Text("Movies").tag(Optional<MediaKind>.some(.movie))
          Text("TV Series").tag(Optional<MediaKind>.some(.series))
        }
        .labelsHidden()
        .frame(width: 120)

        Button {
          Task { await runSearch() }
        } label: {
          if isSearching {
            ProgressView().controlSize(.small)
          } else {
            Text("Search")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSearching || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("wishes-search-button")

        if providerEnabled {
          Button(showManualForm ? "Hide Manual Form" : "Add Manually") {
            showManualForm.toggle()
          }
          .buttonStyle(.bordered)
        }
      }

      if !providerEnabled || showManualForm {
        manualComposer
      } else {
        TextField("Optional note for the family (e.g. director’s cut or season)", text: $wishNote)
          .textFieldStyle(.roundedBorder)
          .font(.callout)
      }

      if let searchResults {
        searchResultsView(searchResults)
      }
    }
    .padding(18)
    .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private var manualComposer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        providerEnabled
          ? "Add a wish by title when search does not find it."
          : "TMDB search is off on this server. Add your wish by title and optional year."
      )
      .font(.callout)
      .foregroundStyle(.secondary)

      HStack(spacing: 10) {
        Picker("Kind", selection: $manualKind) {
          Text("Movie").tag(MediaKind.movie)
          Text("TV Series").tag(MediaKind.series)
        }
        .labelsHidden()
        .frame(width: 120)

        TextField("Title", text: $manualTitle)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("wishes-manual-title")

        TextField("Year", text: $manualYear)
          .textFieldStyle(.roundedBorder)
          .frame(width: 84)
          .accessibilityIdentifier("wishes-manual-year")
      }

      HStack(spacing: 10) {
        TextField("Optional note", text: $manualNote)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("wishes-manual-note")

        Button("Add Wish") {
          Task { await submitManualWish() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          submittingKey == "manual"
            || manualTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .accessibilityIdentifier("wishes-manual-submit")
      }
    }
    .padding(.top, 4)
  }

  @ViewBuilder
  private func searchResultsView(_ results: [WishSearchHit]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Search Results")
          .font(.headline)
        Spacer()
        Button("Clear Results") { self.searchResults = nil }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .font(.callout)
      }
      if results.isEmpty {
        Text("No matching titles found.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(results) { hit in
          searchResultRow(hit)
        }
      }
    }
    .padding(.top, 6)
  }

  private func searchResultRow(_ hit: WishSearchHit) -> some View {
    HStack(alignment: .top, spacing: 14) {
      if let profile = model.profile {
        WishPosterThumbnail(
          posterPath: hit.posterPath,
          width: 92,
          profile: profile,
          cache: model.wishPosterCache
        )
        .frame(width: 48, height: 72)
      }

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(hit.title)
            .font(.headline)
          if let year = hit.year {
            Text(String(year))
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          badgePill(WishPresentation.kindLabel(hit.kind), tint: .secondary)
        }
        if let overview = hit.overview, !overview.isEmpty {
          Text(overview)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      Spacer(minLength: 12)

      if hit.alreadyInLibrary {
        if let mediaId = hit.existingMediaId {
          Button("In Library · Open") { onOpenMedia(mediaId) }
            .buttonStyle(.bordered)
        } else {
          badgePill("In Library", tint: .green)
        }
      } else if hit.alreadyWished, let existingId = hit.existingWishId {
        if hit.supportedByCaller {
          badgePill("Me Too · On", tint: .accentColor)
        } else {
          Button("Me Too") {
            Task { await toggleSupport(wishID: existingId, supported: true) }
          }
          .buttonStyle(.bordered)
        }
      } else {
        Button("Wish") {
          Task { await submitSearchWish(hit) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(submittingKey == hit.id)
      }
    }
    .padding(12)
    .background(AureliaDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  @ViewBuilder
  private var feedbackSection: some View {
    if let conflict = alreadyInLibraryConflict {
      HStack(spacing: 12) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Text(conflict.message)
          .font(.callout)
        Spacer()
        Button("Open \(conflict.title)") {
          onOpenMedia(conflict.mediaId)
          alreadyInLibraryConflict = nil
        }
        .buttonStyle(.borderedProminent)
      }
      .padding(14)
      .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    if let bannerMessage {
      Text(bannerMessage)
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    if let errorMessage {
      Text(errorMessage)
        .font(.callout)
        .foregroundStyle(.red)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
  }

  private var listSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker("Filter", selection: $filter) {
        ForEach(Filter.allCases) { item in
          Text(item.rawValue).tag(item)
        }
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 420)

      if isLoading && wishes.isEmpty {
        ProgressView("Loading family wishes…")
          .frame(maxWidth: .infinity, minHeight: 160)
      } else if wishes.isEmpty {
        ContentUnavailableView(
          "No Wishes Here",
          systemImage: "sparkles",
          description: Text("Search above to wish for a movie or TV series.")
        )
        .frame(maxWidth: .infinity, minHeight: 220)
      } else {
        VStack(spacing: 12) {
          ForEach(wishes) { wish in
            wishCard(wish)
          }
        }
        if hasMore {
          HStack {
            Spacer()
            Button {
              Task { await loadWishes(reset: false, markSeen: false) }
            } label: {
              if isLoadingMore {
                ProgressView().controlSize(.small)
              } else {
                Text("Load More")
              }
            }
            .buttonStyle(.bordered)
            .disabled(isLoadingMore)
          }
          .padding(.top, 4)
        }
      }
    }
  }

  private func wishCard(_ wish: WishSummary) -> some View {
    let callerId = model.profile?.user?.id
    let isOwner = callerId == wish.userId
    let isBusy = busyWishIDs.contains(wish.id)
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 14) {
        if let profile = model.profile {
          WishPosterThumbnail(
            posterPath: wish.posterPath,
            width: 185,
            profile: profile,
            cache: model.wishPosterCache
          )
          .frame(width: 68, height: 102)
        }

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text(wish.title)
              .font(.title3.weight(.semibold))
            if let year = wish.year {
              Text(String(year))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            badgePill(WishPresentation.kindLabel(wish.kind), tint: .secondary)
            badgePill(WishPresentation.stateLabel(wish.state), tint: stateTint(wish.state))
            if let ageRating = wish.ageRating, !ageRating.isEmpty {
              badgePill(ageRating, tint: .secondary)
            }
          }

          HStack(spacing: 6) {
            Text("Requested by \(wish.userName)")
              .font(.callout)
              .foregroundStyle(.secondary)
            if !wish.supporters.isEmpty {
              Text("· +\(wish.supporters.count) Me Too")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }

          if let note = wish.note, !note.isEmpty {
            Text("“\(note)”")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          if let overview = wish.overview, !overview.isEmpty {
            Text(overview)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(3)
          }

          if wish.state == .fulfilled {
            Text("Your wish is here!")
              .font(.callout.weight(.semibold))
              .foregroundStyle(.green)
          }

          if let resolutionNote = wish.resolutionNote, !resolutionNote.isEmpty {
            Text("Note: \(resolutionNote)")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }

        Spacer(minLength: 8)
      }

      if model.isWishAdmin, wish.state == .open, !wish.suggestions.isEmpty {
        suggestionsStrip(wish)
      }

      HStack(spacing: 10) {
        if wish.canSupport {
          Button(wish.supportedByCaller ? "Me Too · On" : "Me Too") {
            Task { await toggleSupport(wishID: wish.id, supported: !wish.supportedByCaller) }
          }
          .buttonStyle(.bordered)
          .disabled(isBusy)
        }

        if wish.state == .fulfilled, let mediaId = wish.fulfilledMediaItemId {
          Button("Open in Library") {
            onOpenMedia(mediaId)
          }
          .buttonStyle(.borderedProminent)
        }

        if wish.state == .open, isOwner {
          Button("Withdraw") {
            Task { await deleteWish(wish.id) }
          }
          .buttonStyle(.bordered)
          .disabled(isBusy)
        }

        Spacer()

        if model.isWishAdmin {
          adminActions(for: wish, isBusy: isBusy)
        }
      }
    }
    .padding(16)
    .background(AureliaDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  @ViewBuilder
  private func suggestionsStrip(_ wish: WishSummary) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Is this that wish?")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        ForEach(wish.suggestions) { suggestion in
          Button {
            Task {
              await setWishState(
                wish.id, state: .fulfilled, resolutionNote: nil, mediaId: suggestion.mediaId)
            }
          } label: {
            Label(
              suggestion.year.map { "\(suggestion.title) (\($0))" } ?? suggestion.title,
              systemImage: "checkmark.circle"
            )
          }
          .buttonStyle(.bordered)
        }
      }
    }
    .padding(10)
    .background(AureliaDesign.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  @ViewBuilder
  private func adminActions(for wish: WishSummary, isBusy: Bool) -> some View {
    switch wish.state {
    case .open:
      Button("Mark Added") {
        Task { await setWishState(wish.id, state: .fulfilled, resolutionNote: nil, mediaId: nil) }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isBusy)

      Button("Decline…") {
        declineNote = ""
        decliningWish = wish
      }
      .buttonStyle(.bordered)
      .disabled(isBusy)
    case .fulfilled, .declined:
      Button("Reopen") {
        Task { await setWishState(wish.id, state: .open, resolutionNote: nil, mediaId: nil) }
      }
      .buttonStyle(.bordered)
      .disabled(isBusy)
    }

    Button("Delete", role: .destructive) {
      Task { await deleteWish(wish.id) }
    }
    .buttonStyle(.bordered)
    .disabled(isBusy)
  }

  private func declineSheet(for wish: WishSummary) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Decline “\(wish.title)”?")
        .font(.headline)
      TextField("Optional note explaining why", text: $declineNote)
        .textFieldStyle(.roundedBorder)
        .frame(width: 340)
      HStack {
        Spacer()
        Button("Cancel") { decliningWish = nil }
        Button("Decline") {
          let note = declineNote.trimmingCharacters(in: .whitespacesAndNewlines)
          decliningWish = nil
          Task {
            await setWishState(
              wish.id,
              state: .declined,
              resolutionNote: note.isEmpty ? nil : note,
              mediaId: nil)
          }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(22)
  }

  private func stateTint(_ state: WishState) -> Color {
    switch state {
    case .open: .orange
    case .fulfilled: .green
    case .declined: .secondary
    }
  }

  private func badgePill(_ text: String, tint: Color) -> some View {
    Text(text)
      .font(.caption.weight(.medium))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Capsule().fill(tint.opacity(0.16)))
      .foregroundStyle(tint == .secondary ? .secondary : tint)
  }

  // MARK: - Actions

  private func loadWishes(reset: Bool, markSeen: Bool) async {
    guard let profile = model.profile, model.supportsWishes else { return }
    if reset {
      isLoading = true
    } else {
      isLoadingMore = true
    }
    defer {
      isLoading = false
      isLoadingMore = false
    }
    let offset = reset ? 0 : wishes.count
    do {
      let response = try await APIClient(profile: profile).wishes(
        state: filter.wishState, offset: offset, limit: Self.pageSize)
      providerEnabled = response.providerEnabled
      if reset {
        wishes = response.wishes
      } else {
        let existingIds = Set(wishes.map(\.id))
        wishes.append(contentsOf: response.wishes.filter { !existingIds.contains($0.id) })
      }
      hasMore = response.wishes.count >= Self.pageSize
      model.updateWishSummary(
        WishSummaryResponse(
          openCount: response.openCount,
          newlyFulfilledCount: response.newlyFulfilledCount))
      errorMessage = nil
      if markSeen, response.newlyFulfilledCount > 0 {
        if let updated = try? await APIClient(profile: profile).markWishesSeen() {
          model.updateWishSummary(updated)
        }
      }
    } catch {
      errorMessage = WishPresentation.describeError(error)
    }
  }

  private func runSearch() async {
    guard let profile = model.profile else { return }
    let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    isSearching = true
    alreadyInLibraryConflict = nil
    errorMessage = nil
    defer { isSearching = false }
    do {
      let response = try await APIClient(profile: profile).wishSearch(
        query: trimmed, kind: searchKindFilter)
      providerEnabled = response.providerEnabled
      searchResults = response.results
      if !response.providerEnabled {
        showManualForm = true
        if manualTitle.isEmpty { manualTitle = trimmed }
      }
    } catch let api as APIClientError where api.problemCode == "provider_disabled" {
      providerEnabled = false
      showManualForm = true
      if manualTitle.isEmpty { manualTitle = trimmed }
      errorMessage = WishPresentation.describeError(api)
    } catch {
      errorMessage = WishPresentation.describeError(error)
    }
  }

  private func submitSearchWish(_ hit: WishSearchHit) async {
    let trimmedNote = wishNote.trimmingCharacters(in: .whitespacesAndNewlines)
    await createWish(
      key: hit.id,
      payload: CreateWishRequest(
        kind: hit.kind,
        title: hit.title,
        year: hit.year,
        provider: hit.provider,
        providerMediaId: hit.providerMediaId,
        overview: hit.overview,
        posterPath: hit.posterPath,
        note: trimmedNote.isEmpty ? nil : trimmedNote))
  }

  private func submitManualWish() async {
    let trimmedTitle = manualTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else { return }
    let parsedYear = WishPresentation.parseYear(manualYear)
    if let yearError = parsedYear.error {
      errorMessage = yearError
      return
    }
    let trimmedNote = manualNote.trimmingCharacters(in: .whitespacesAndNewlines)
    let created = await createWish(
      key: "manual",
      payload: CreateWishRequest(
        kind: manualKind,
        title: trimmedTitle,
        year: parsedYear.year,
        provider: nil,
        providerMediaId: nil,
        overview: nil,
        posterPath: nil,
        note: trimmedNote.isEmpty ? nil : trimmedNote))
    if created {
      manualTitle = ""
      manualYear = ""
      manualNote = ""
    }
  }

  @discardableResult
  private func createWish(key: String, payload: CreateWishRequest) async -> Bool {
    guard let profile = model.profile else { return false }
    submittingKey = key
    errorMessage = nil
    alreadyInLibraryConflict = nil
    bannerMessage = nil
    defer { submittingKey = nil }
    do {
      let outcome = try await APIClient(profile: profile).createWish(payload)
      switch outcome {
      case .alreadyInLibrary(let conflict):
        alreadyInLibraryConflict = conflict
        return false
      case .created(let created):
        bannerMessage =
          created.mergedIntoExistingSupport
          ? "Added your Me Too support to “\(created.wish.title)”."
          : "Added “\(created.wish.title)” to Family Wishes."
        wishNote = ""
        searchResults = nil
        await loadWishes(reset: true, markSeen: false)
        return true
      }
    } catch {
      errorMessage = WishPresentation.describeError(error)
      return false
    }
  }

  private func toggleSupport(wishID: UUID, supported: Bool) async {
    guard let profile = model.profile else { return }
    busyWishIDs.insert(wishID)
    defer { busyWishIDs.remove(wishID) }
    do {
      let updated = try await APIClient(profile: profile).setWishSupport(
        id: wishID, supported: supported)
      replaceWish(updated)
      errorMessage = nil
      if let results = searchResults {
        searchResults = results.map { item in
          guard item.existingWishId == wishID else { return item }
          return WishSearchHit(
            provider: item.provider,
            providerMediaId: item.providerMediaId,
            kind: item.kind,
            title: item.title,
            year: item.year,
            overview: item.overview,
            posterPath: item.posterPath,
            posterUrl: item.posterUrl,
            alreadyInLibrary: item.alreadyInLibrary,
            existingMediaId: item.existingMediaId,
            alreadyWished: item.alreadyWished,
            existingWishId: item.existingWishId,
            supportedByCaller: updated.supportedByCaller)
        }
      }
    } catch {
      errorMessage = WishPresentation.describeError(error)
    }
  }

  private func setWishState(
    _ wishID: UUID, state: WishState, resolutionNote: String?, mediaId: UUID?
  ) async {
    guard let profile = model.profile else { return }
    busyWishIDs.insert(wishID)
    defer { busyWishIDs.remove(wishID) }
    do {
      let updated = try await APIClient(profile: profile).updateWishState(
        id: wishID, state: state, resolutionNote: resolutionNote, fulfilledMediaItemId: mediaId)
      replaceWish(updated)
      await model.refreshWishSummary(notify: false)
      errorMessage = nil
    } catch {
      errorMessage = WishPresentation.describeError(error)
    }
  }

  private func deleteWish(_ wishID: UUID) async {
    guard let profile = model.profile else { return }
    busyWishIDs.insert(wishID)
    defer { busyWishIDs.remove(wishID) }
    do {
      try await APIClient(profile: profile).deleteWish(id: wishID)
      wishes.removeAll { $0.id == wishID }
      await model.refreshWishSummary(notify: false)
      errorMessage = nil
    } catch {
      errorMessage = WishPresentation.describeError(error)
    }
  }

  private func replaceWish(_ updated: WishSummary) {
    if let target = filter.wishState, updated.state != target {
      wishes.removeAll { $0.id == updated.id }
      return
    }
    if let idx = wishes.firstIndex(where: { $0.id == updated.id }) {
      wishes[idx] = updated
    } else {
      wishes.insert(updated, at: 0)
    }
  }
}

private struct WishPosterThumbnail: View {
  let posterPath: String?
  let width: Int
  let profile: StoredServerProfile
  let cache: WishPosterCache

  @State private var image: NSImage?

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(AureliaDesign.raisedSurface)
      if let displayed = image ?? cache.cachedImage(posterPath: posterPath, width: width, profile: profile) {
        Image(nsImage: displayed)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Image(systemName: "film")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .task(id: posterPath) {
      image = await cache.image(posterPath: posterPath, width: width, profile: profile)
    }
  }
}
