import ImageIO
import SwiftUI
import UIKit

@MainActor
private final class TVDecodedWishPosterCache {
  static let shared = TVDecodedWishPosterCache()

  private let cache = NSCache<NSString, UIImage>()

  init(memoryLimitBytes: Int = 24 * 1_024 * 1_024, itemLimit: Int = 80) {
    cache.totalCostLimit = memoryLimitBytes
    cache.countLimit = itemLimit
  }

  func image(for key: String) -> UIImage? {
    cache.object(forKey: key as NSString)
  }

  func store(_ image: UIImage, for key: String) {
    let pixelWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
    let pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
    let cost = max(1, pixelWidth * pixelHeight * 4)
    cache.setObject(image, forKey: key as NSString, cost: cost)
  }

  func clear() {
    cache.removeAllObjects()
  }

  nonisolated static func downsample(_ data: Data, maxPixelSize: Int = 480) -> UIImage? {
    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
      return nil
    }
    let thumbOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
    else { return nil }
    return UIImage(cgImage: cgImage)
  }
}

private enum TVWishFilter: String, CaseIterable, Identifiable {
  case all
  case open
  case fulfilled
  case declined

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "All"
    case .open: "Waiting"
    case .fulfilled: "In Library"
    case .declined: "Declined"
    }
  }

  var state: TVWishState? {
    switch self {
    case .all: nil
    case .open: .open
    case .fulfilled: .fulfilled
    case .declined: .declined
    }
  }
}

struct TVWishesView: View {
  @EnvironmentObject private var model: TVAppModel
  @State private var filter: TVWishFilter = .all
  @State private var wishes: [TVWishSummary] = []
  @State private var openCount = 0
  @State private var newlyFulfilledCount = 0
  @State private var isLoading = false
  @State private var isLoadingMore = false
  @State private var canLoadMore = false
  @State private var error: String?
  @State private var selectedWish: TVWishSummary?
  @State private var makingWish = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        header
        filterBar
        if let error {
          TVErrorText(message: error)
        }
        if isLoading && wishes.isEmpty {
          HStack(spacing: 16) {
            ProgressView()
            Text("Loading wishes…").font(.system(size: 24)).foregroundStyle(.secondary)
          }
          .padding(.vertical, 40)
        } else if wishes.isEmpty {
          emptyState
        } else {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 680), spacing: 32)],
            spacing: 28
          ) {
            ForEach(wishes) { wish in
              Button {
                selectedWish = wish
              } label: {
                TVWishCard(wish: wish)
              }
              .buttonStyle(TVCardButtonStyle())
              .accessibilityIdentifier("wish-card-\(wish.id.uuidString.lowercased())")
            }
          }
          if canLoadMore {
            HStack {
              Spacer()
              Button {
                Task { await load(reset: false) }
              } label: {
                if isLoadingMore {
                  ProgressView()
                } else {
                  Text("Show More")
                }
              }
              .buttonStyle(TVButtonStyle())
              .disabled(isLoadingMore)
              Spacer()
            }
            .padding(.top, 12)
          }
        }
      }
      .padding(.horizontal, TVDesign.pagePadding)
      .padding(.vertical, 40)
    }
    .background(TVDesign.canvas.ignoresSafeArea())
    .task(id: "\(model.session?.sessionId.uuidString ?? "none")-\(filter.rawValue)") {
      await load(reset: true)
    }
    .onChange(of: model.session?.sessionId) { _, _ in
      wishes = []
      openCount = 0
      newlyFulfilledCount = 0
      canLoadMore = false
      selectedWish = nil
      TVDecodedWishPosterCache.shared.clear()
    }
    .sheet(item: $selectedWish) { wish in
      TVWishDetailSheet(wish: wish) { Task { await load(reset: true) } }
    }
    .fullScreenCover(
      isPresented: $makingWish, onDismiss: { Task { await load(reset: true) } },
      content: { TVMakeWishView() })
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 24) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
          Text("Family Wishes").font(.system(size: 56, weight: .bold))
          if openCount > 0 {
            Text("\(openCount) waiting")
              .font(.system(size: 24, weight: .semibold))
              .foregroundStyle(.secondary)
          }
        }
        Text(
          "Titles your family wished for. Make a wish, or add your Me Too to someone else's."
        )
        .font(.system(size: 22))
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        makingWish = true
      } label: {
        Label("Make a Wish", systemImage: "gift")
      }
      .buttonStyle(TVButtonStyle(kind: .primary))
      .accessibilityIdentifier("wishes-make")
      Button {
        Task { await load(reset: true) }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(TVButtonStyle())
      .disabled(isLoading)
      .accessibilityIdentifier("wishes-refresh")
    }
  }

  private var filterBar: some View {
    HStack(spacing: 16) {
      ForEach(TVWishFilter.allCases) { item in
        Button(item.title) {
          filter = item
        }
        .buttonStyle(TVButtonStyle(kind: filter == item ? .primary : .action))
        .accessibilityIdentifier("wishes-filter-\(item.rawValue)")
      }
      Spacer()
      if newlyFulfilledCount > 0 {
        Text("\(newlyFulfilledCount) newly in library")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.green)
      }
    }
    .focusSection()
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(filter == .all ? "No wishes yet" : "No wishes here")
        .font(.system(size: 32, weight: .bold))
      Text(
        filter == .all
          ? "Choose Make a Wish when you want a movie or series added."
          : "Try another filter to see the rest of the family's wishes."
      )
      .font(.system(size: 24))
      .foregroundStyle(.secondary)
    }
    .padding(36)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      TVDesign.surface, in: RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
  }

  private func load(reset: Bool) async {
    guard let api = model.client, let sessionID = model.session?.sessionId else { return }
    if reset {
      isLoading = true
      error = nil
    } else {
      isLoadingMore = true
    }
    let offset = reset ? 0 : wishes.count
    let activeFilter = filter
    defer {
      if reset {
        isLoading = false
      } else {
        isLoadingMore = false
      }
    }
    do {
      let page = try await api.wishes(
        state: activeFilter.state, offset: offset, limit: TVWishPresentation.pageSize)
      guard !Task.isCancelled, model.session?.sessionId == sessionID, filter == activeFilter else {
        return
      }
      if reset {
        wishes = page.wishes
      } else {
        let existing = Set(wishes.map(\.id))
        wishes.append(contentsOf: page.wishes.filter { !existing.contains($0.id) })
      }
      openCount = page.openCount
      newlyFulfilledCount = page.newlyFulfilledCount
      // Seen here: Home's "Your wish is here" goes away.
      if reset, page.newlyFulfilledCount > 0 { await model.markWishesSeen() }
      canLoadMore = page.wishes.count >= TVWishPresentation.pageSize
    } catch {
      guard !Task.isCancelled, model.session?.sessionId == sessionID else { return }
      self.error = TVWishPresentation.describeError(error)
    }
  }
}

private struct TVWishCard: View {
  let wish: TVWishSummary

  var body: some View {
    HStack(alignment: .top, spacing: 26) {
      TVWishPosterThumbnail(posterPath: wish.posterPath, kind: wish.kind)
        .frame(width: 140, height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(wish.title)
            .font(.system(size: 28, weight: .bold))
            .lineLimit(2)
            .foregroundStyle(.white)
          Spacer(minLength: 8)
          TVWishStatePill(state: wish.state)
        }

        Text(TVWishPresentation.metaLine(wish))
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.secondary)

        Text(supportersSummary)
          .font(.system(size: 20))
          .foregroundStyle(.white.opacity(0.82))
          .lineLimit(2)

        if let note = wish.note, !note.isEmpty {
          Text("“\(note)”")
            .font(.system(size: 20))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        if let resolution = wish.resolutionNote, !resolution.isEmpty {
          Text(resolution)
            .font(.system(size: 20))
            .foregroundStyle(.white.opacity(0.82))
            .lineLimit(2)
        } else if let overview = wish.overview, !overview.isEmpty {
          Text(overview)
            .font(.system(size: 19))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      TVDesign.surface, in: RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
  }

  private var supportersSummary: String {
    var parts = ["Wished by \(wish.userName)"]
    let others = wish.supporters.filter { $0.userId != wish.userId }.map(\.name)
    if !others.isEmpty {
      parts.append("Me Too (\(others.count)): \(others.joined(separator: ", "))")
    }
    return parts.joined(separator: " · ")
  }
}

private struct TVWishStatePill: View {
  let state: TVWishState

  var body: some View {
    Text(TVWishPresentation.stateLabel(state))
      .font(.system(size: 18, weight: .semibold))
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .foregroundStyle(foreground)
      .background(background, in: Capsule())
  }

  private var foreground: Color {
    switch state {
    case .open: .white
    case .fulfilled: .black
    case .declined: .white.opacity(0.85)
    }
  }

  private var background: Color {
    switch state {
    case .open: .white.opacity(0.16)
    case .fulfilled: .green.opacity(0.88)
    case .declined: .orange.opacity(0.32)
    }
  }
}

struct TVWishPosterThumbnail: View {
  @EnvironmentObject private var model: TVAppModel
  let posterPath: String?
  let kind: TVMediaKind
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      Color.white.opacity(0.06)
      if let image {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        Image(systemName: kind == .series ? "tv" : "film")
          .font(.system(size: 42))
          .foregroundStyle(.tertiary)
      }
    }
    .clipped()
    .task(id: cacheKey) {
      image = nil
      guard let cacheKey, let posterPath, let api = model.client else { return }
      if let cached = TVDecodedWishPosterCache.shared.image(for: cacheKey) {
        image = cached
        return
      }
      guard
        let data = await model.wishPosterBytes.data(
          posterPath: posterPath, width: 342, client: api),
        !Task.isCancelled
      else { return }
      let decoded = await Task.detached(priority: .utility) {
        TVDecodedWishPosterCache.downsample(data)
      }.value
      guard let decoded, !Task.isCancelled else { return }
      TVDecodedWishPosterCache.shared.store(decoded, for: cacheKey)
      image = decoded
    }
  }

  private var cacheKey: String? {
    guard let serverID = model.connection?.serverID,
      let trimmed = posterPath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return "\(serverID.uuidString):wish:\(trimmed):w342"
  }
}

private struct TVWishDetailSheet: View {
  @EnvironmentObject private var model: TVAppModel
  @Environment(\.dismiss) private var dismiss
  let wish: TVWishSummary
  let changed: () -> Void
  @State private var choosing: Mode?
  @State private var working = false
  @State private var error: String?

  private enum Mode { case fulfil, decline }
  private static let declineNotes = [
    "We can't get this one right now.",
    "It isn't available to buy or rent here.",
    "Not for this profile's age.",
  ]

  private var isMine: Bool { wish.userId == model.session?.user.id }

  var body: some View {
    ScrollView {
      HStack(alignment: .top, spacing: 44) {
        TVWishPosterThumbnail(posterPath: wish.posterPath, kind: wish.kind)
          .frame(width: 260, height: 390)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        VStack(alignment: .leading, spacing: 18) {
          TVWishStatePill(state: wish.state)
          Text(wish.title).font(.system(size: 48, weight: .bold))
          Text(TVWishPresentation.metaLine(wish))
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.secondary)

          Text("Wished by \(wish.userName)")
            .font(.system(size: 24))
          let voters = wish.supporters.filter { $0.userId != wish.userId }.map(\.name)
          if !voters.isEmpty {
            Text("Me Too: \(voters.joined(separator: ", "))")
              .font(.system(size: 22))
              .foregroundStyle(.secondary)
          }
          if let note = wish.note, !note.isEmpty {
            Text("Note: \(note)")
              .font(.system(size: 24))
          }
          if let resolution = wish.resolutionNote, !resolution.isEmpty {
            Text("Answer: \(resolution)")
              .font(.system(size: 24))
          }
          if let by = wish.resolvedByUserName, !by.isEmpty {
            Text("Updated by \(by)")
              .font(.system(size: 20))
              .foregroundStyle(.secondary)
          }
          if let overview = wish.overview, !overview.isEmpty {
            Text(overview)
              .font(.system(size: 22))
              .foregroundStyle(.secondary)
              .lineLimit(5)
          }
          if let error { TVErrorText(message: error) }
          switch choosing {
          case .fulfil: fulfilChoices
          case .decline: declineChoices
          case nil: actions
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(80)
    }
    .background(TVDesign.canvas.ignoresSafeArea())
  }

  private var actions: some View {
    HStack(spacing: 24) {
      if wish.state == .open, wish.canSupport, !isMine {
        Button(wish.supportedByCaller ? "Remove My Me Too" : "Me Too") {
          perform {
            _ = try await $0.setWishSupport(id: wish.id, supported: !wish.supportedByCaller)
          }
        }
        .accessibilityIdentifier("wish-me-too")
      }
      if wish.state == .open, isMine {
        Button("Remove My Wish", role: .destructive) {
          perform { try await $0.deleteWish(id: wish.id) }
        }
      }
      if wish.state == .open, model.isWishAdmin {
        Button("In Library…") { choosing = .fulfil }.accessibilityIdentifier("wish-fulfil")
        Button("Decline…") { choosing = .decline }.accessibilityIdentifier("wish-decline")
      }
      Button("Close") { dismiss() }
    }
    .buttonStyle(TVButtonStyle())
    .disabled(working)
    .padding(.top, 12)
    .focusSection()
  }

  /// The title that fulfils the wish: one of the server's suggestions from the library.
  private var fulfilChoices: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        wish.suggestions.isEmpty
          ? "Nothing matching is in the library yet. Add the title, then come back."
          : "Which title in the library is it?"
      )
      .font(.system(size: 24))
      ForEach(wish.suggestions, id: \.mediaId) { suggestion in
        Button(
          [suggestion.title, suggestion.year.map(String.init)].compactMap { $0 }
            .joined(separator: " · ")
        ) {
          perform {
            _ = try await $0.updateWishState(
              id: wish.id,
              requestBody: TVUpdateWishStateRequest(
                state: .fulfilled, resolutionNote: nil, fulfilledMediaItemId: suggestion.mediaId))
          }
        }
      }
      Button("Back") { choosing = nil }
    }
    .buttonStyle(TVButtonStyle())
    .disabled(working)
    .focusSection()
  }

  private var declineChoices: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Tell \(wish.userName) why, or decline without a note.").font(.system(size: 24))
      ForEach([String?.none] + Self.declineNotes.map(Optional.some), id: \.self) { note in
        Button(note ?? "Decline Without a Note") {
          perform {
            _ = try await $0.updateWishState(
              id: wish.id,
              requestBody: TVUpdateWishStateRequest(
                state: .declined, resolutionNote: note, fulfilledMediaItemId: nil))
          }
        }
      }
      Button("Back") { choosing = nil }
    }
    .buttonStyle(TVButtonStyle())
    .disabled(working)
    .focusSection()
  }

  private func perform(_ work: @escaping @Sendable (TVAPIClient) async throws -> Void) {
    guard let client = model.client else { return }
    working = true
    error = nil
    Task {
      defer { working = false }
      do {
        try await work(client)
        await model.refreshWishSummary()
        changed()
        dismiss()
      } catch {
        self.error = TVWishPresentation.describeError(error)
      }
    }
  }
}

/// Make a Wish: a TMDB search with the TV keyboard or dictation, then Wish or Me Too.
struct TVMakeWishView: View {
  @EnvironmentObject private var model: TVAppModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var results: [TVWishSearchHit] = []
  @State private var providerEnabled = true
  @State private var searching = false
  @State private var message: String?
  @State private var wishing: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 30) {
        HStack {
          Text("Make a Wish").font(.system(size: 56, weight: .bold))
          Spacer()
          Button("Done") { dismiss() }.buttonStyle(TVButtonStyle())
        }
        TextField("Movie or Series", text: $query)
          .frame(width: 900)
          .accessibilityIdentifier("wish-search")
        if let message { TVErrorText(message: message) }
        if !providerEnabled {
          Text("The server has TMDB turned off, so titles can't be found here.")
            .font(.system(size: 24)).foregroundStyle(.secondary)
        }
        if searching { ProgressView() }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 40)], spacing: 40) {
          ForEach(results) { hit in
            Button {
              Task { await wish(hit) }
            } label: {
              VStack(alignment: .leading, spacing: 10) {
                TVWishPosterThumbnail(posterPath: hit.posterPath, kind: hit.kind)
                  .frame(width: 240, height: 360)
                  .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(hit.title).font(.system(size: 22, weight: .semibold)).lineLimit(2)
                Text(
                  hit.alreadyInLibrary
                    ? "In the Library" : wishing == hit.id ? "Wishing…" : TVWishActions.label(hit)
                )
                .font(.system(size: 20)).foregroundStyle(.secondary)
              }
              .frame(width: 240)
            }
            .buttonStyle(.borderless)
            .disabled(
              wishing != nil || hit.alreadyInLibrary || (hit.alreadyWished && hit.supportedByCaller)
            )
          }
        }
      }
      .padding(80)
    }
    .background(TVDesign.canvas.ignoresSafeArea())
    .task(id: query) {
      let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
      guard text.count >= 2 else {
        results = []
        return
      }
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, let client = model.client else { return }
      searching = true
      defer { searching = false }
      do {
        let found = try await client.wishSearch(query: text)
        results = found.results
        providerEnabled = found.providerEnabled
        message = nil
      } catch {
        if !(error is CancellationError) { message = TVWishPresentation.describeError(error) }
      }
    }
  }

  private func wish(_ hit: TVWishSearchHit) async {
    guard let client = model.client else { return }
    wishing = hit.id
    defer { wishing = nil }
    do {
      switch try await TVWishActions.wish(hit, client: client) {
      case .wished(let id):
        results = results.map { $0.id == hit.id ? TVPeoplePresentation.wished($0, wishId: id) : $0 }
        message = "Wished for \(hit.title)."
        await model.refreshWishSummary()
      case .inLibrary(let text):
        message = text
      }
    } catch {
      message = TVWishPresentation.describeError(error)
    }
  }
}
