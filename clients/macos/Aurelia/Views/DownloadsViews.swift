import SwiftUI

/// Downloads: titles kept on this Mac to watch without the server, and the ones loading now.
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
          if downloads.totalBytes > 0 {
            Text(
              "\(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)) used on this Mac"
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        if let error = downloads.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        if !downloads.active.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            Text("Downloading").font(.headline)
            ForEach(downloads.active.keys.sorted(), id: \.self) { id in
              HStack {
                Text(downloads.activeNames[id] ?? "Title").lineLimit(1)
                  .frame(maxWidth: 260, alignment: .leading)
                ProgressView(value: downloads.active[id] ?? 0)
                  .frame(maxWidth: 320)
                Text("\(Int((downloads.active[id] ?? 0) * 100)) %").monospacedDigit()
                  .foregroundStyle(.secondary)
                Button("Cancel") { downloads.cancel(id) }
              }
            }
          }
        }
        if model.offlineTitles.isEmpty && downloads.active.isEmpty {
          // Centered in the page, not at the leading edge of the text column above it.
          ContentUnavailableView(
            "No Downloads", systemImage: "arrow.down.circle",
            description: Text("Choose Download in a movie’s or episode’s menu to keep it on this Mac."))
            .frame(maxWidth: .infinity, minHeight: 360)
            .accessibilityIdentifier("downloads-empty")
        } else {
          OfflineTitleList()
        }
      }
      .padding(AureliaDesign.pagePadding)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("downloads-page")
  }
}

/// The downloaded titles with Play and Remove; also shown while the server is out of reach.
struct OfflineTitleList: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var downloads = OfflineDownloads.shared
  @State private var removing: OfflineTitle?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(model.offlineTitles) { title in
        HStack(spacing: 14) {
          Group {
            if let poster = downloads.artwork(title)
              ?? downloads.artwork(title, series: true)
            {
              Image(nsImage: poster).resizable().scaledToFill()
            } else {
              MediaArtworkPlaceholder(symbol: title.isEpisode ? "tv" : "film", symbolSize: 18)
            }
          }
          .frame(width: 40, height: 60)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(title.title).font(.headline)
            Text(details(title)).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            model.playOffline(title)
          } label: {
            Label(title.positionMilliseconds > 0 && !title.isCompleted ? "Resume" : "Play", systemImage: "play.fill")
          }
          .buttonStyle(AureliaPrimaryActionButtonStyle())
          .accessibilityIdentifier("download-play")
          Button(role: .destructive) {
            removing = title
          } label: {
            Image(systemName: "trash")
          }
          .help("Remove Download")
          .accessibilityLabel("Remove Download")
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
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

  private func details(_ title: OfflineTitle) -> String {
    var parts: [String] = []
    if let subtitle = title.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
    parts.append(ByteCountFormatter.string(fromByteCount: title.bytes, countStyle: .file))
    if title.isCompleted {
      parts.append("Watched")
    } else if title.positionMilliseconds > 0, title.durationMilliseconds > 0 {
      parts.append("\(Int(Double(title.positionMilliseconds) / Double(title.durationMilliseconds) * 100)) % watched")
    }
    if title.progressDirty { parts.append("Progress not yet on the server") }
    return parts.joined(separator: " · ")
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
