import SwiftUI

/// Downloads: titles kept on this Mac to watch without the server, and the ones loading now.
/// Laid out like the library: how much space they take, what is loading, the movies as posters
/// and each series with its downloaded episodes.
struct DownloadsPage: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var downloads = OfflineDownloads.shared

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AureliaDesign.sectionSpacing) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Downloads").font(AureliaDesign.pageTitle)
          Text(
            "Titles on this Mac play even when the server is asleep or out of reach. Progress goes back to the server when it answers again."
          )
          .foregroundStyle(.secondary)
        }
        .aureliaRiseIn(0)
        if !model.offlineTitles.isEmpty || !downloads.active.isEmpty {
          DownloadStorageSummary(titles: model.offlineTitles, totalBytes: downloads.totalBytes)
            .aureliaRiseIn(1)
        }
        if let error = downloads.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        if !downloads.active.isEmpty {
          VStack(alignment: .leading, spacing: 14) {
            AureliaSectionHeading(title: "Downloading", count: downloads.active.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16)], spacing: 16) {
              ForEach(downloads.active.keys.sorted(), id: \.self) { id in
                ActiveDownloadCard(
                  name: downloads.activeNames[id] ?? "Title", share: downloads.active[id] ?? 0
                ) { downloads.cancel(id) }
              }
            }
          }
          .aureliaRiseIn(2)
        }
        if model.offlineTitles.isEmpty && downloads.active.isEmpty {
          // Centered in the page, not at the leading edge of the text column above it.
          ContentUnavailableView(
            "No Downloads", systemImage: "arrow.down.circle",
            description: Text("Choose Download in a movie’s or episode’s menu to keep it on this Mac."))
            .frame(maxWidth: .infinity, minHeight: 360)
            .accessibilityIdentifier("downloads-empty")
            .aureliaRiseIn(1)
        } else {
          OfflineTitleList()
            .aureliaRiseIn(3)
        }
      }
      .padding(AureliaDesign.pagePadding)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollClipDisabled()
    .aureliaOverlayScrollbars()
    .accessibilityIdentifier("downloads-page")
  }
}

/// How much the downloads take and how much room is left on this Mac, as one bar.
private struct DownloadStorageSummary: View {
  let titles: [OfflineTitle]
  let totalBytes: Int64

  private var freeBytes: Int64? {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  var body: some View {
    let movies = titles.filter { !$0.isEpisode }.count
    let episodes = titles.count - movies
    let free = freeBytes
    let share = free.map { totalBytes > 0 ? Double(totalBytes) / Double(totalBytes + $0) : 0 } ?? 0
    HStack(spacing: 18) {
      Image(systemName: "internaldrive")
        .font(.system(size: 26, weight: .light))
        .foregroundStyle(.tint)
        .frame(width: 44)
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
            .font(.title3.weight(.semibold)).monospacedDigit()
          Text("used by downloads").foregroundStyle(.secondary)
          Spacer()
          if let free {
            Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free on this Mac")
              .font(.callout).foregroundStyle(.secondary).monospacedDigit()
          }
        }
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.1))
            Capsule().fill(.tint)
              .frame(width: max(totalBytes > 0 ? 6 : 0, geometry.size.width * min(share, 1)))
          }
        }
        .frame(height: 6)
        Text(summary(movies: movies, episodes: episodes))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(18)
    .frame(maxWidth: 760, alignment: .leading)
    .background(AureliaDesign.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AureliaDesign.hairline) }
    .accessibilityElement(children: .combine)
  }

  private func summary(movies: Int, episodes: Int) -> String {
    var parts: [String] = []
    if movies > 0 { parts.append(movies == 1 ? "1 movie" : "\(movies) movies") }
    if episodes > 0 { parts.append(episodes == 1 ? "1 episode" : "\(episodes) episodes") }
    return parts.isEmpty ? "Nothing downloaded yet" : parts.joined(separator: " · ")
  }
}

/// A title loading now: its name, a progress bar and Cancel.
private struct ActiveDownloadCard: View {
  let name: String
  let share: Double
  let cancel: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        Circle().stroke(.white.opacity(0.12), lineWidth: 4)
        Circle().trim(from: 0, to: share).stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(.easeOut(duration: 0.3), value: share)
        Image(systemName: "arrow.down").font(.system(size: 13, weight: .bold))
      }
      .frame(width: 38, height: 38)
      VStack(alignment: .leading, spacing: 3) {
        Text(name).font(.headline).lineLimit(1)
        Text("\(Int(share * 100)) % downloaded").font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      Spacer(minLength: 8)
      Button("Cancel", action: cancel)
    }
    .padding(14)
    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

/// The downloaded titles: movies as posters, and each series with its episodes.
struct OfflineTitleList: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var downloads = OfflineDownloads.shared
  @State private var removing: OfflineTitle?

  private var movies: [OfflineTitle] {
    model.offlineTitles.filter { !$0.isEpisode }.sorted { $0.downloadedAt > $1.downloadedAt }
  }

  /// Episodes grouped by series, the most recently downloaded series first.
  private var series: [(name: String, episodes: [OfflineTitle])] {
    let groups = Dictionary(grouping: model.offlineTitles.filter(\.isEpisode)) {
      $0.parentTitle ?? $0.title
    }
    return groups.map { name, episodes in
      (name, episodes.sorted {
        ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
      })
    }
    .sorted {
      ($0.episodes.map(\.downloadedAt).max() ?? .distantPast)
        > ($1.episodes.map(\.downloadedAt).max() ?? .distantPast)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AureliaDesign.sectionSpacing) {
      if !movies.isEmpty {
        VStack(alignment: .leading, spacing: 14) {
          AureliaSectionHeading(title: "Movies", count: movies.count)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 154, maximum: 190), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
            ForEach(movies) { title in
              Button { model.playOffline(title) } label: {
                OfflinePosterCard(title: title, poster: downloads.artwork(title))
              }
              .buttonStyle(AureliaCardButtonStyle())
              .accessibilityIdentifier("download-play")
              .contextMenu { menu(title) }
            }
          }
        }
      }
      ForEach(series, id: \.name) { group in
        VStack(alignment: .leading, spacing: 14) {
          HStack(spacing: 12) {
            Group {
              if let first = group.episodes.first, let poster = downloads.artwork(first, series: true) {
                Image(nsImage: poster).resizable().scaledToFill()
              } else {
                MediaArtworkPlaceholder(symbol: "tv", symbolSize: 14)
              }
            }
            .frame(width: 34, height: 51)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(group.name).font(AureliaDesign.sectionTitle)
              Text(
                "\(group.episodes.count == 1 ? "1 episode" : "\(group.episodes.count) episodes") · \(ByteCountFormatter.string(fromByteCount: group.episodes.reduce(0) { $0 + $1.bytes }, countStyle: .file))"
              )
              .font(.caption).foregroundStyle(.secondary)
            }
          }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 18, alignment: .top)], alignment: .leading, spacing: 20) {
            ForEach(group.episodes) { title in
              Button { model.playOffline(title) } label: {
                OfflineEpisodeCard(
                  title: title,
                  picture: downloads.artwork(title, backdrop: true) ?? downloads.artwork(title))
              }
              .buttonStyle(AureliaCardButtonStyle())
              .accessibilityIdentifier("download-play")
              .contextMenu { menu(title) }
            }
          }
        }
      }
    }
    .confirmationDialog(
      "Remove \(removing?.title ?? "this download")?", isPresented: Binding(
        get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing
    ) { title in
      Button("Remove Download", role: .destructive) { downloads.remove(title.id) }
    } message: { _ in
      Text("The copy on this Mac is deleted. The title stays on the server.")
    }
  }

  @ViewBuilder
  private func menu(_ title: OfflineTitle) -> some View {
    Button(OfflineTitlePresentation.playLabel(title), systemImage: "play.fill") { model.playOffline(title) }
    Divider()
    Button("Remove Download…", systemImage: "trash", role: .destructive) { removing = title }
  }
}

enum OfflineTitlePresentation {
  static func playLabel(_ title: OfflineTitle) -> String {
    title.positionMilliseconds > 0 && !title.isCompleted ? "Resume" : "Play"
  }

  /// How far the title is watched, 0…1, or nil when it was not started.
  static func progress(_ title: OfflineTitle) -> Double? {
    if title.isCompleted { return nil }
    guard title.positionMilliseconds > 0, title.durationMilliseconds > 0 else { return nil }
    return min(1, Double(title.positionMilliseconds) / Double(title.durationMilliseconds))
  }

  /// "2.1 GB · Watched", "1.4 GB · 35 % watched", plus a note while progress waits for the server.
  static func details(_ title: OfflineTitle) -> String {
    var parts = [ByteCountFormatter.string(fromByteCount: title.bytes, countStyle: .file)]
    if title.isCompleted {
      parts.append("Watched")
    } else if let progress = progress(title) {
      parts.append("\(Int(progress * 100)) % watched")
    }
    if title.progressDirty { parts.append("Progress not yet on the server") }
    return parts.joined(separator: " · ")
  }
}

/// A downloaded movie as a poster, with its size, progress and a play button on hover.
private struct OfflinePosterCard: View {
  let title: OfflineTitle
  let poster: NSImage?
  @State private var hovering = false
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ZStack(alignment: .bottom) {
        Group {
          if let poster {
            Image(nsImage: poster).resizable().scaledToFill()
          } else {
            MediaArtworkPlaceholder(symbol: "film")
          }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipped()
        LinearGradient(colors: [.clear, .black.opacity(hovering ? 0.55 : 0.0)], startPoint: .center, endPoint: .bottom)
        Image(systemName: "play.fill")
          .font(.title3)
          .frame(width: 46, height: 46)
          .background(.ultraThinMaterial, in: Circle())
          .opacity(hovering ? 1 : 0)
          .frame(maxHeight: .infinity)
        if let progress = OfflineTitlePresentation.progress(title) {
          GeometryReader { geometry in
            Capsule().fill(.black.opacity(0.42)).frame(height: 4)
              .overlay(alignment: .leading) {
                Capsule().fill(.white).frame(width: geometry.size.width * progress, height: 4)
              }
              .frame(maxHeight: .infinity, alignment: .bottom)
          }
          .padding(8)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous))
      .overlay(alignment: .topTrailing) {
        if title.isCompleted {
          Image(systemName: "checkmark").font(.caption.weight(.bold))
            .frame(width: 24, height: 24).background(.black.opacity(0.56), in: Circle()).padding(8)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
          .stroke(hovering ? .white.opacity(0.35) : AureliaDesign.hairline)
      }
      .shadow(color: .black.opacity(hovering ? 0.42 : 0), radius: 18, y: 10)
      .offset(y: hovering && !reduceMotion ? -4 : 0)
      VStack(alignment: .leading, spacing: 2) {
        Text(title.title).font(.callout.weight(.semibold)).lineLimit(1)
        Text(OfflineTitlePresentation.details(title)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .contentShape(Rectangle())
    .animation(reduceMotion ? nil : AureliaDesign.responsiveSpring, value: hovering)
    .onHover { hovering = $0 }
    .accessibilityLabel("\(OfflineTitlePresentation.playLabel(title)) \(title.title)")
  }
}

/// A downloaded episode as a wide card with its picture, number, size and progress.
private struct OfflineEpisodeCard: View {
  let title: OfflineTitle
  let picture: NSImage?
  @State private var hovering = false
  @Environment(\.aureliaReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      Group {
        if let picture {
          Image(nsImage: picture).resizable().scaledToFill()
        } else {
          MediaArtworkPlaceholder(symbol: "play.rectangle")
        }
      }
      .frame(maxWidth: .infinity)
      .aspectRatio(16 / 9, contentMode: .fit)
      .clipped()
      LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
      VStack(alignment: .leading, spacing: 3) {
        if let label = title.episodeLabel {
          Text(label.uppercased()).font(.caption2.weight(.bold)).tracking(1.1)
            .foregroundStyle(.white.opacity(0.8))
        }
        Text(title.title).font(.headline).lineLimit(1)
        Text(OfflineTitlePresentation.details(title)).font(.caption).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
      }
      .padding(14)
      .padding(.trailing, 44)
      Image(systemName: "play.fill")
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(.black)
        .frame(width: 32, height: 32)
        .background(.white.opacity(0.92), in: Circle())
        .opacity(hovering ? 1 : 0)
        .scaleEffect(hovering || reduceMotion ? 1 : 0.85)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
      if let progress = OfflineTitlePresentation.progress(title) {
        GeometryReader { geometry in
          Capsule().fill(.white).frame(width: geometry.size.width * progress, height: 4)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: AureliaDesign.cardRadius, style: .continuous)
        .stroke(hovering ? .white.opacity(0.25) : AureliaDesign.hairline)
    }
    .shadow(color: .black.opacity(hovering ? 0.34 : 0), radius: 14, y: 8)
    .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
    .contentShape(Rectangle())
    .animation(reduceMotion ? nil : AureliaDesign.responsiveSpring, value: hovering)
    .onHover { hovering = $0 }
    .accessibilityLabel("\(OfflineTitlePresentation.playLabel(title)) \(title.parentTitle ?? "") \(title.title)")
  }
}

/// Download, its progress, or Remove Download for one movie or episode.
struct DownloadMenuItems: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var downloads = OfflineDownloads.shared
  let item: CatalogItemSummary

  var body: some View {
    if item.kind == .movie || item.kind == .episode {
      if let share = downloads.active[item.id] {
        Button("Cancel Download (\(Int(share * 100)) %)", systemImage: "xmark.circle") {
          downloads.cancel(item.id)
        }
      } else if downloads.isDownloaded(item.id) {
        Button("Remove Download", systemImage: "trash") { downloads.remove(item.id) }
      } else {
        Button("Download", systemImage: "arrow.down.circle") { model.download(item) }
          .disabled(!item.isPlayable)
      }
    }
  }
}
