import ImageIO
import SwiftUI
import UIKit

@MainActor
private final class IOSDecodedWishPosterCache {
  static let shared = IOSDecodedWishPosterCache()

  private let images = NSCache<NSString, UIImage>()

  init(totalCostLimit: Int = 48 * 1_024 * 1_024, countLimit: Int = 120) {
    images.totalCostLimit = totalCostLimit
    images.countLimit = countLimit
  }

  func image(for key: String) -> UIImage? {
    images.object(forKey: key as NSString)
  }

  func store(_ image: UIImage, key: String, cost: Int) {
    images.setObject(image, forKey: key as NSString, cost: cost)
  }

  func clear() {
    images.removeAllObjects()
  }
}

struct IOSWishesView: View {
  enum Filter: String, CaseIterable, Identifiable {
    case all = "All"
    case open = "Open"
    case fulfilled = "In Library"
    case declined = "Declined"

    var id: String { rawValue }

    var wishState: IOSWishState? {
      switch self {
      case .all: nil
      case .open: .open
      case .fulfilled: .fulfilled
      case .declined: .declined
      }
    }
  }

  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var sizeClass
  @FocusState private var manualYearFocused: Bool

  @State private var wishes: [IOSWishSummary] = []
  @State private var filter: Filter = .open
  @State private var isLoading = false
  @State private var isLoadingMore = false
  @State private var hasMore = false
  @State private var listRequest = UUID()
  @State private var searchRequest = UUID()
  @State private var providerEnabled = true
  @State private var bannerMessage: String?
  @State private var errorMessage: String?
  @State private var alreadyInLibraryConflict: IOSWishAlreadyInLibraryProblem?

  // Request composer
  @State private var composerExpanded = false
  @State private var searchQuery = ""
  @State private var searchKindFilter: IOSMediaKind? = nil
  @State private var wishNote = ""
  @State private var isSearching = false
  @State private var searchResults: [IOSWishSearchHit]?
  @State private var showManualForm = false
  @State private var manualKind: IOSMediaKind = .movie
  @State private var manualTitle = ""
  @State private var manualYear = ""
  @State private var manualNote = ""
  @State private var submittingKey: String?
  @State private var busyWishIDs: Set<UUID> = []

  // Admin decline sheet & library detail navigation
  @State private var decliningWish: IOSWishSummary?
  @State private var declineNote = ""
  @State private var openedLibraryItem: IOSWishLibraryDestination?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        headerRow
        if let alreadyInLibraryConflict { conflictBanner(alreadyInLibraryConflict) }
        if let errorMessage { noticeBanner(errorMessage, isError: true) }
        if let bannerMessage { noticeBanner(bannerMessage, isError: false) }
        if composerExpanded { composerSection }
        filterBar
        wishesSection
      }
      .frame(maxWidth: IOSLayoutMetrics.readableContentMaxWidth, alignment: .leading)
      .padding(.horizontal, IOSDesign.margin(for: sizeClass))
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
    .iosNumberPadDone { manualYearFocused = false }
    .background(IOSDesign.canvas.ignoresSafeArea())
    .navigationTitle("Family Wishes")
    .navigationDestination(item: $openedLibraryItem) { target in
      IOSDetailView(id: target.item.detailID, initial: target.item)
    }
    .sheet(item: $decliningWish) { wish in
      declineSheet(for: wish)
    }
    .task {
      await IOSWishNotificationCenter.shared.requestPermissionOnFirstVisitIfNeeded()
      await loadWishes(reset: true, markSeen: true)
    }
    .onChange(of: filter) { _, _ in
      Task { await loadWishes(reset: true, markSeen: false) }
    }
    .accessibilityIdentifier("wishes-page")
  }

  @ViewBuilder
  private var headerRow: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 12) {
        headerDescription
          .frame(maxWidth: .infinity, alignment: .leading)
        composerToggle(expanded: true)
      }
    } else {
      HStack(spacing: 12) {
        headerDescription
        Spacer(minLength: 8)
        composerToggle(expanded: false)
          .fixedSize(horizontal: true, vertical: false)
          .layoutPriority(1)
      }
    }
  }

  private var headerDescription: some View {
    Text(
      model.isWishAdmin
        ? "Titles requested by the household."
        : "Request a movie or TV series for the library."
    )
    .font(.subheadline)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private func composerToggle(expanded: Bool) -> some View {
    Button {
      composerExpanded.toggle()
      if composerExpanded && !providerEnabled { showManualForm = true }
    } label: {
      Label {
        Text(composerExpanded ? "Close" : "Make a Wish")
          .lineLimit(expanded ? nil : 1)
          .fixedSize(horizontal: !expanded, vertical: true)
      } icon: {
        Image(systemName: composerExpanded ? "xmark" : "plus")
      }
      .labelStyle(.titleAndIcon)
      .frame(minWidth: 44, maxWidth: expanded ? .infinity : nil, minHeight: 44)
    }
    .buttonStyle(
      IOSButtonStyle(kind: composerExpanded ? .secondary : .primary, fullWidth: expanded)
    )
    .accessibilityIdentifier("wishes-toggle-composer")
  }

  private var filterBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(Filter.allCases) { item in
          Button(item.rawValue) {
            filter = item
          }
          .font(.subheadline.weight(.semibold))
          .padding(.horizontal, 14)
          .frame(minHeight: 44)
          .foregroundStyle(filter == item ? Color.black : Color.white)
          .background(
            filter == item ? Color.white : IOSDesign.surface,
            in: Capsule()
          )
          .accessibilityAddTraits(filter == item ? .isSelected : [])
        }
      }
    }
  }

  private var composerSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        TextField("Search for a movie or TV series…", text: $searchQuery)
          .textFieldStyle(.plain)
          .padding(12)
          .background(IOSDesign.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .submitLabel(.search)
          .onSubmit {
            Task { await performSearch() }
          }
          .accessibilityIdentifier("wishes-search-field")

        if !searchQuery.isEmpty {
          Button {
            searchQuery = ""
            searchResults = nil
            alreadyInLibraryConflict = nil
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear search")
        }
      }

      let kindControlsLayout =
        dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        : AnyLayout(HStackLayout(spacing: 8))
      kindControlsLayout {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            kindChip(title: "All", selection: nil)
            kindChip(title: "Movie", selection: .movie)
            kindChip(title: "TV Series", selection: .series)
          }
        }
        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
        if providerEnabled {
          Button("Search") {
            Task { await performSearch() }
          }
          .buttonStyle(IOSButtonStyle(kind: .primary))
          .disabled(
            isSearching || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
          .accessibilityIdentifier("wishes-search-submit")
        }
      }

      if providerEnabled {
        TextField("Optional note (e.g. director’s cut or season)", text: $wishNote)
          .textFieldStyle(.plain)
          .padding(10)
          .background(IOSDesign.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .accessibilityIdentifier("wishes-note-field")
      }

      if isSearching {
        HStack(spacing: 8) {
          ProgressView()
          Text("Searching TMDB…").font(.footnote).foregroundStyle(.secondary)
        }
      } else if let searchResults {
        if searchResults.isEmpty {
          Text("No matches found on TMDB.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
          VStack(spacing: 10) {
            ForEach(searchResults) { hit in
              searchHitRow(hit)
            }
          }
        }
      }

      if !providerEnabled || showManualForm {
        manualComposerCard
      } else {
        Button("Can't find it? Enter title manually") {
          manualTitle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
          showManualForm = true
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white.opacity(0.85))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
    }
    .padding(16)
    .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func kindChip(title: String, selection: IOSMediaKind?) -> some View {
    let selected = searchKindFilter == selection
    return Button(title) {
      searchKindFilter = selection
    }
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 12)
    .frame(minHeight: 44)
    .foregroundStyle(selected ? Color.black : Color.white)
    .background(selected ? Color.white : IOSDesign.raised, in: Capsule())
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func searchHitRow(_ hit: IOSWishSearchHit) -> some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    return layout {
      HStack(alignment: .top, spacing: 12) {
        if !dynamicTypeSize.isAccessibilitySize {
          IOSWishPosterView(posterPath: hit.posterPath, kind: hit.kind, width: 48, height: 72)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(hit.year.map { "\(hit.title) (\($0))" } ?? hit.title)
            .font(.subheadline.weight(.semibold))
          Text(IOSWishPresentation.kindLabel(hit.kind))
            .font(.caption)
            .foregroundStyle(.secondary)
          if let overview = hit.overview, !overview.isEmpty {
            Text(overview).font(.caption).foregroundStyle(.secondary)
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
          }
        }
      }

      if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 6) }

      if hit.alreadyInLibrary, let mediaId = hit.existingMediaId {
        Button("In Library") {
          Task { await openLibraryTitle(mediaId) }
        }
        .buttonStyle(IOSButtonStyle(kind: .secondary))
      } else if hit.alreadyWished, let wishId = hit.existingWishId {
        if hit.supportedByCaller {
          Text("Wished")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        } else {
          Button("+ Me Too") {
            Task { await toggleSupport(wishID: wishId, supported: true) }
          }
          .buttonStyle(IOSButtonStyle(kind: .secondary))
        }
      } else {
        Button("Wish") {
          Task { await submitSearchHit(hit) }
        }
        .buttonStyle(IOSButtonStyle(kind: .primary))
        .disabled(submittingKey == hit.id)
      }
    }
    .padding(10)
    .background(
      IOSDesign.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var manualComposerCard: some View {
    let actionLayout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(spacing: 10))
    return VStack(alignment: .leading, spacing: 10) {
      Text(
        providerEnabled ? "Write a Wish Manually" : "TMDB search is off — enter details manually"
      )
      .font(.subheadline.weight(.semibold))

      Picker("Type", selection: $manualKind) {
        Text("Movie").tag(IOSMediaKind.movie)
        Text("TV Series").tag(IOSMediaKind.series)
      }
      .pickerStyle(.segmented)

      TextField("Title", text: $manualTitle)
        .textFieldStyle(.plain)
        .padding(10)
        .background(IOSDesign.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("wishes-manual-title")

      TextField("Year (optional)", text: $manualYear)
        .keyboardType(.numberPad)
        .focused($manualYearFocused)
        .textFieldStyle(.plain)
        .padding(10)
        .background(IOSDesign.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("wishes-manual-year")

      TextField("Note (optional)", text: $manualNote)
        .textFieldStyle(.plain)
        .padding(10)
        .background(IOSDesign.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

      actionLayout {
        Button("Send Wish") {
          manualYearFocused = false
          Task { await submitManualWish() }
        }
        .buttonStyle(IOSButtonStyle(kind: .primary))
        .disabled(
          submittingKey == "manual"
            || manualTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .accessibilityIdentifier("wishes-manual-submit")

        if providerEnabled {
          Button("Cancel") {
            manualYearFocused = false
            showManualForm = false
          }
          .buttonStyle(IOSButtonStyle(kind: .secondary))
        }
      }
    }
    .padding(12)
    .background(IOSDesign.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  @ViewBuilder
  private func conflictBanner(_ problem: IOSWishAlreadyInLibraryProblem) -> some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(spacing: 12))
    layout {
      HStack(spacing: 12) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("Already in the library").font(.subheadline.weight(.semibold))
          Text(problem.message).font(.caption).foregroundStyle(.secondary)
        }
      }
      if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 6) }
      Button("Open") {
        Task { await openLibraryTitle(problem.mediaId) }
      }
      .buttonStyle(IOSButtonStyle(kind: .secondary))
    }
    .padding(12)
    .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func noticeBanner(_ text: String, isError: Bool) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(isError ? .orange : .white)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  @ViewBuilder
  private var wishesSection: some View {
    if isLoading && wishes.isEmpty {
      HStack(spacing: 10) {
        ProgressView()
        Text("Loading wishes…").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.top, 32)
    } else if wishes.isEmpty {
      ContentUnavailableView(
        "No Wishes",
        systemImage: "sparkles",
        description: Text("Tap Make a Wish above when there's a movie or TV series you'd like.")
      )
      .padding(.top, 24)
    } else {
      LazyVStack(spacing: 12) {
        ForEach(wishes) { wish in
          wishCard(wish)
        }
        if hasMore {
          Button {
            Task { await loadMore() }
          } label: {
            if isLoadingMore {
              ProgressView()
            } else {
              Text("Show More")
            }
          }
          .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: true))
          .disabled(isLoadingMore)
        }
      }
    }
  }

  private func wishCard(_ wish: IOSWishSummary) -> some View {
    let isBusy = busyWishIDs.contains(wish.id)
    let isOwnWish = model.session?.user.id == wish.userId

    return VStack(alignment: .leading, spacing: 10) {
      wishHeaderLayout {
        if !dynamicTypeSize.isAccessibilitySize
          || wish.posterPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
          IOSWishPosterView(posterPath: wish.posterPath, kind: wish.kind, width: 62, height: 92)
            .accessibilityHidden(true)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(wish.year.map { "\(wish.title) (\($0))" } ?? wish.title)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)

          wishBadges(wish, isOwnWish: isOwnWish)

          Text("Wished by \(wish.userName)")
            .font(.caption)
            .foregroundStyle(.secondary)

          if !wish.supporters.isEmpty {
            Text("Also wished by \(wish.supporters.map(\.name).joined(separator: ", "))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          if let note = wish.note, !note.isEmpty {
            Text("“\(note)”")
              .font(.caption)
              .foregroundStyle(.white.opacity(0.85))
          }

          if wish.state != .open {
            if let by = wish.resolvedByUserName {
              Text(
                wish.state == .fulfilled
                  ? "Marked in library by \(by)" : "Declined by \(by)"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            if let resolution = wish.resolutionNote, !resolution.isEmpty {
              Text("Note: \(resolution)").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }

      if wish.state == .open && model.isWishAdmin && !wish.suggestions.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Possible matches in your library")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ForEach(wish.suggestions) { suggestion in
            Button {
              Task {
                await resolveWish(
                  wish, state: .fulfilled, note: nil, mediaID: suggestion.mediaId)
              }
            } label: {
              HStack {
                Text(
                  suggestion.year.map { "\(suggestion.title) (\($0))" } ?? suggestion.title
                )
                .font(.caption)
                Spacer()
                Text("Link & Complete").font(.caption.weight(.semibold))
              }
              .padding(8)
              .background(
                IOSDesign.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
          }
        }
      }

      wishActions(wish, isBusy: isBusy, isOwnWish: isOwnWish)
    }
    .padding(14)
    .background(IOSDesign.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var wishHeaderLayout: AnyLayout {
    if dynamicTypeSize.isAccessibilitySize {
      AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
    } else {
      AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }
  }

  @ViewBuilder
  private func wishBadges(_ wish: IOSWishSummary, isOwnWish: Bool) -> some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 6) {
        wishBadgeLabels(wish, isOwnWish: isOwnWish, wrapping: true)
      }
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 6) {
          wishBadgeLabels(wish, isOwnWish: isOwnWish, wrapping: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        VStack(alignment: .leading, spacing: 6) {
          wishBadgeLabels(wish, isOwnWish: isOwnWish, wrapping: true)
        }
      }
    }
  }

  @ViewBuilder
  private func wishBadgeLabels(
    _ wish: IOSWishSummary, isOwnWish: Bool, wrapping: Bool
  ) -> some View {
    badgePill(IOSWishPresentation.kindLabel(wish.kind), wrapping: wrapping)
    badgePill(IOSWishPresentation.stateLabel(wish.state), wrapping: wrapping)
    if let rating = wish.ageRating, !rating.isEmpty {
      badgePill(rating, wrapping: wrapping)
    }
    if wish.state == .fulfilled && isOwnWish && wish.seenByWisherAt == nil {
      badgePill("New", wrapping: wrapping)
    }
  }

  @ViewBuilder
  private func wishActions(_ wish: IOSWishSummary, isBusy: Bool, isOwnWish: Bool) -> some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(spacing: 8) {
        wishActionButtons(wish, isBusy: isBusy, isOwnWish: isOwnWish, expanded: true)
      }
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          wishActionButtons(wish, isBusy: isBusy, isOwnWish: isOwnWish, expanded: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        LazyVGrid(
          columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
          alignment: .leading, spacing: 8
        ) {
          wishActionButtons(wish, isBusy: isBusy, isOwnWish: isOwnWish, expanded: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func wishActionButtons(
    _ wish: IOSWishSummary, isBusy: Bool, isOwnWish: Bool, expanded: Bool
  ) -> some View {
    if wish.state == .open && wish.canSupport {
      Button(wish.supportedByCaller ? "Remove Vote" : "+ Me Too") {
        Task { await toggleSupport(wishID: wish.id, supported: !wish.supportedByCaller) }
      }
      .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: expanded))
      .disabled(isBusy)
    }

    if wish.state == .fulfilled, let mediaId = wish.fulfilledMediaItemId {
      Button("Open in Library") {
        Task { await openLibraryTitle(mediaId) }
      }
      .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: expanded))
    }

    if model.isWishAdmin && wish.state == .open {
      Button("In Library") {
        Task {
          await resolveWish(
            wish, state: .fulfilled, note: nil,
            mediaID: wish.suggestions.first?.mediaId)
        }
      }
      .buttonStyle(IOSButtonStyle(kind: .primary, fullWidth: expanded))
      .disabled(isBusy)

      Button("Decline") {
        declineNote = ""
        decliningWish = wish
      }
      .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: expanded))
      .disabled(isBusy)
    }

    if (isOwnWish && wish.state == .open) || model.isWishAdmin {
      Button(isOwnWish && !model.isWishAdmin ? "Withdraw" : "Remove", role: .destructive) {
        Task { await deleteWish(wish) }
      }
      .buttonStyle(IOSButtonStyle(kind: .secondary, fullWidth: expanded))
      .disabled(isBusy)
    }
  }

  private func badgePill(_ text: String, wrapping: Bool) -> some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .lineLimit(wrapping ? nil : 1)
      .fixedSize(horizontal: !wrapping, vertical: true)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(IOSDesign.raised, in: Capsule())
  }

  private func declineSheet(for wish: IOSWishSummary) -> some View {
    NavigationStack {
      Form {
        Section {
          Text("Decline “\(wish.title)”?")
            .font(.headline)
          TextField("Optional note for the family", text: $declineNote, axis: .vertical)
            .lineLimit(3...5)
        }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .navigationTitle("Decline Wish")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { decliningWish = nil }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Decline", role: .destructive) {
            let trimmed = declineNote.trimmingCharacters(in: .whitespacesAndNewlines)
            decliningWish = nil
            Task {
              await resolveWish(
                wish, state: .declined, note: trimmed.isEmpty ? nil : trimmed, mediaID: nil)
            }
          }
        }
      }
    }
  }

  // MARK: - Actions

  private func loadWishes(reset: Bool, markSeen: Bool) async {
    guard let api = model.client else { return }
    let request = UUID()
    listRequest = request
    let requestedFilter = filter
    let sessionID = model.session?.sessionId
    isLoadingMore = false
    if reset { isLoading = true }
    errorMessage = nil
    defer { if reset, listRequest == request { isLoading = false } }
    do {
      if markSeen {
        let updated = try? await api.markWishesSeen()
        guard !Task.isCancelled, listRequest == request, model.session?.sessionId == sessionID
        else {
          return
        }
        if let updated { model.updateWishSummaryFromPage(updated) }
      }
      let response = try await api.wishes(
        state: requestedFilter.wishState, offset: 0, limit: IOSWishPresentation.pageSize)
      guard !Task.isCancelled, listRequest == request, filter == requestedFilter,
        model.session?.sessionId == sessionID
      else { return }
      wishes = response.wishes
      providerEnabled = response.providerEnabled
      if !response.providerEnabled { showManualForm = true }
      hasMore = response.wishes.count == IOSWishPresentation.pageSize
      model.updateWishSummaryFromPage(
        IOSWishSummaryResponse(
          openCount: response.openCount, newlyFulfilledCount: response.newlyFulfilledCount))
    } catch {
      guard !Task.isCancelled, listRequest == request, filter == requestedFilter,
        model.session?.sessionId == sessionID
      else { return }
      errorMessage = IOSWishPresentation.describeError(error)
      model.handleSessionFailure(error)
    }
  }

  private func loadMore() async {
    guard let api = model.client, !isLoading, !isLoadingMore, hasMore else { return }
    let request = listRequest
    let requestedFilter = filter
    let sessionID = model.session?.sessionId
    isLoadingMore = true
    defer { if listRequest == request { isLoadingMore = false } }
    do {
      let response = try await api.wishes(
        state: requestedFilter.wishState, offset: wishes.count, limit: IOSWishPresentation.pageSize)
      guard !Task.isCancelled, listRequest == request, filter == requestedFilter,
        model.session?.sessionId == sessionID
      else { return }
      let existing = Set(wishes.map(\.id))
      wishes.append(contentsOf: response.wishes.filter { !existing.contains($0.id) })
      hasMore = response.wishes.count == IOSWishPresentation.pageSize
    } catch {
      guard !Task.isCancelled, listRequest == request, filter == requestedFilter,
        model.session?.sessionId == sessionID
      else { return }
      errorMessage = IOSWishPresentation.describeError(error)
    }
  }

  private func performSearch() async {
    guard let api = model.client else { return }
    let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let request = UUID()
    searchRequest = request
    let kind = searchKindFilter
    let sessionID = model.session?.sessionId
    isSearching = true
    errorMessage = nil
    alreadyInLibraryConflict = nil
    defer { if searchRequest == request { isSearching = false } }
    do {
      let response = try await api.wishSearch(query: trimmed, kind: kind)
      guard !Task.isCancelled, searchRequest == request, model.session?.sessionId == sessionID
      else {
        return
      }
      providerEnabled = response.providerEnabled
      if !response.providerEnabled { showManualForm = true }
      searchResults = response.results
    } catch {
      guard !Task.isCancelled, searchRequest == request, model.session?.sessionId == sessionID
      else {
        return
      }
      errorMessage = IOSWishPresentation.describeError(error)
      model.handleSessionFailure(error)
    }
  }

  private func submitSearchHit(_ hit: IOSWishSearchHit) async {
    guard let api = model.client else { return }
    submittingKey = hit.id
    errorMessage = nil
    bannerMessage = nil
    alreadyInLibraryConflict = nil
    defer { submittingKey = nil }
    let trimmedNote = wishNote.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = IOSCreateWishRequest(
      kind: hit.kind,
      title: hit.title,
      year: hit.year,
      provider: hit.provider,
      providerMediaId: hit.providerMediaId,
      overview: hit.overview,
      posterPath: hit.posterPath,
      note: trimmedNote.isEmpty ? nil : trimmedNote)
    await handleCreate(body, api: api)
  }

  private func submitManualWish() async {
    guard let api = model.client else { return }
    let trimmedTitle = manualTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      errorMessage = "Enter a title first."
      return
    }
    let parsedYear = IOSWishPresentation.parseYear(manualYear)
    if let yearError = parsedYear.error {
      errorMessage = yearError
      return
    }
    submittingKey = "manual"
    errorMessage = nil
    bannerMessage = nil
    alreadyInLibraryConflict = nil
    defer { submittingKey = nil }
    let trimmedNote = manualNote.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = IOSCreateWishRequest(
      kind: manualKind,
      title: trimmedTitle,
      year: parsedYear.year,
      provider: nil,
      providerMediaId: nil,
      overview: nil,
      posterPath: nil,
      note: trimmedNote.isEmpty ? nil : trimmedNote)
    if await handleCreate(body, api: api) {
      manualTitle = ""
      manualYear = ""
      manualNote = ""
      if providerEnabled { showManualForm = false }
    }
  }

  @discardableResult
  private func handleCreate(_ body: IOSCreateWishRequest, api: IOSAPIClient) async -> Bool {
    do {
      switch try await api.createWish(body) {
      case .created(let response):
        bannerMessage =
          response.mergedIntoExistingSupport
          ? "Someone already wished for \(response.wish.title) — added your support."
          : "Added \(response.wish.title) to Family Wishes."
        wishNote = ""
        searchResults = nil
        composerExpanded = false
        await loadWishes(reset: true, markSeen: false)
        return true
      case .alreadyInLibrary(let problem):
        alreadyInLibraryConflict = problem
        return false
      }
    } catch {
      errorMessage = IOSWishPresentation.describeError(error)
      model.handleSessionFailure(error)
      return false
    }
  }

  private func toggleSupport(wishID: UUID, supported: Bool) async {
    guard let api = model.client else { return }
    busyWishIDs.insert(wishID)
    errorMessage = nil
    defer { busyWishIDs.remove(wishID) }
    do {
      _ = try await api.setWishSupport(id: wishID, supported: supported)
      await loadWishes(reset: true, markSeen: false)
    } catch {
      errorMessage = IOSWishPresentation.describeError(error)
      model.handleSessionFailure(error)
    }
  }

  private func resolveWish(
    _ wish: IOSWishSummary, state: IOSWishState, note: String?, mediaID: UUID?
  ) async {
    guard let api = model.client else { return }
    busyWishIDs.insert(wish.id)
    errorMessage = nil
    defer { busyWishIDs.remove(wish.id) }
    do {
      _ = try await api.updateWishState(
        id: wish.id,
        requestBody: IOSUpdateWishStateRequest(
          state: state, resolutionNote: note, fulfilledMediaItemId: mediaID))
      bannerMessage =
        state == .fulfilled
        ? "Marked \(wish.title) as in library."
        : "Declined \(wish.title)."
      await loadWishes(reset: true, markSeen: false)
    } catch {
      errorMessage = IOSWishPresentation.describeError(error)
      model.handleSessionFailure(error)
    }
  }

  private func deleteWish(_ wish: IOSWishSummary) async {
    guard let api = model.client else { return }
    busyWishIDs.insert(wish.id)
    errorMessage = nil
    defer { busyWishIDs.remove(wish.id) }
    do {
      try await api.deleteWish(id: wish.id)
      await loadWishes(reset: true, markSeen: false)
    } catch {
      errorMessage = IOSWishPresentation.describeError(error)
      model.handleSessionFailure(error)
    }
  }

  private func openLibraryTitle(_ mediaId: UUID) async {
    guard let api = model.client else { return }
    do {
      let item = try await api.summary(id: mediaId)
      openedLibraryItem = IOSWishLibraryDestination(item: item)
    } catch {
      errorMessage = IOSWishPresentation.describeError(error)
      model.handleSessionFailure(error)
    }
  }
}

private struct IOSWishLibraryDestination: Hashable {
  let item: IOSCatalogItem

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.item.id == rhs.item.id }
  func hash(into hasher: inout Hasher) { hasher.combine(item.id) }
}

struct IOSWishPosterView: View {
  @EnvironmentObject private var model: IOSAppModel
  let posterPath: String?
  let kind: IOSMediaKind
  let width: CGFloat
  let height: CGFloat

  @State private var image: UIImage?

  private var trimmedPath: String? {
    let trimmed = posterPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private var cacheKey: String? {
    guard let trimmedPath, let serverID = model.connection?.serverID else { return nil }
    return "\(serverID.uuidString):wish:\(trimmedPath)"
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(IOSDesign.raised)
      if let image {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Image(systemName: kind == .series ? "tv.fill" : "film")
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: width, height: height)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .task(id: cacheKey) {
      image = nil
      guard let trimmedPath, let cacheKey, let api = model.client else { return }
      if let cached = IOSDecodedWishPosterCache.shared.image(for: cacheKey) {
        image = cached
        return
      }
      guard
        let data = await model.wishPosterBytes.data(
          posterPath: trimmedPath, width: 342, client: api),
        !Task.isCancelled
      else { return }
      let decoded = await Task.detached(priority: .utility) {
        Self.decode(data, maxPixelSize: Int(max(width, height) * 3))
      }.value
      guard !Task.isCancelled, let decoded else { return }
      IOSDecodedWishPosterCache.shared.store(decoded.image, key: cacheKey, cost: decoded.bytes)
      image = decoded.image
    }
  }

  private struct DecodedImage: @unchecked Sendable {
    let image: UIImage
    let bytes: Int
  }

  nonisolated private static func decode(_ data: Data, maxPixelSize: Int) -> DecodedImage? {
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let cgImage = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelSize),
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { return nil }
    let uiImage = UIImage(cgImage: cgImage)
    return DecodedImage(image: uiImage, bytes: cgImage.bytesPerRow * cgImage.height)
  }
}
