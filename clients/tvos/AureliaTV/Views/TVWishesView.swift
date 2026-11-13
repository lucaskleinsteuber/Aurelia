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
      TVWishDetailSheet(wish: wish)
    }
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
          "View titles your family wished for. Add or manage wishes on Mac, Linux, iPhone, iPad, or in a browser."
        )
        .font(.system(size: 22))
        .foregroundStyle(.secondary)
      }
      Spacer()
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
          ? "Ask on Mac, Linux, iPhone, iPad, or in a web browser when you want a movie or series added."
          : "Try another filter to see the rest of the family's wishes."
      )
      .font(.system(size: 24))
      .foregroundStyle(.secondary)
    }
    .padding(36)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(TVDesign.surface, in: RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
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

        HStack(spacing: 10) {
          Text(TVWishPresentation.kindLabel(wish.kind))
          if let year = wish.year {
            Text("· \(String(year))")
          }
          if let age = wish.ageRating, !age.isEmpty {
            Text("· \(age)")
          }
        }
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
    .background(TVDesign.surface, in: RoundedRectangle(cornerRadius: TVDesign.cardRadius, style: .continuous))
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

private struct TVWishPosterThumbnail: View {
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
      guard let data = await model.wishPosterBytes.data(posterPath: posterPath, width: 342, client: api),
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
  @Environment(\.dismiss) private var dismiss
  let wish: TVWishSummary

  var body: some View {
    ScrollView {
      HStack(alignment: .top, spacing: 44) {
        TVWishPosterThumbnail(posterPath: wish.posterPath, kind: wish.kind)
          .frame(width: 260, height: 390)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        VStack(alignment: .leading, spacing: 18) {
          TVWishStatePill(state: wish.state)
          Text(wish.title).font(.system(size: 48, weight: .bold))
          HStack(spacing: 14) {
            Text(TVWishPresentation.kindLabel(wish.kind))
            if let year = wish.year { Text("· \(String(year))") }
            if let age = wish.ageRating, !age.isEmpty { Text("· \(age)") }
          }
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
          }
          Button("Close") { dismiss() }
            .buttonStyle(TVButtonStyle(kind: .primary))
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(80)
    }
    .background(TVDesign.canvas.ignoresSafeArea())
  }
}
