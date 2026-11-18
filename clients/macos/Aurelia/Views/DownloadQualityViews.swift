import SwiftUI

/// A title waiting for the person to choose how large its download should be.
struct PendingDownloadChoice: Identifiable {
  let item: CatalogItemSummary
  let options: DownloadOptionsResponse
  /// Further episodes of a season, downloaded after `item` in the same quality where offered.
  var others: [CatalogItemSummary] = []

  var title: String {
    others.isEmpty
      ? item.title : "\(item.parentTitle ?? item.title) · \(others.count + 1) Episodes"
  }

  var id: UUID { item.id }
}

/// Download › choose the original or a smaller copy the server converts ("converted-downloads-v1").
struct DownloadQualitySheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @AppStorage(DownloadQualityPreference.key) private var preference = DownloadQualityPreference.ask
  let choice: PendingDownloadChoice
  @State private var quality: String
  @State private var audio: Int?
  @State private var remember = false

  init(choice: PendingDownloadChoice) {
    self.choice = choice
    _quality = State(
      initialValue: choice.options.qualities.first(where: { $0.id == "720p" })?.id
        ?? choice.options.qualities.first?.id ?? DownloadQualityPreference.original)
    _audio = State(initialValue: choice.options.audioTrack)
  }

  var body: some View {
    AureliaSheet(
      title: "Download \(choice.title)",
      subtitle: "Choose how large the copy on this Mac should be.",
      symbol: "arrow.down.circle",
      primary: AureliaSheetAction(title: "Download", action: start),
      onCancel: { dismiss() }
    ) {
      Form {
        Section {
          Picker("Quality", selection: $quality) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Original")
              Text(
                "\(DownloadText.size(choice.options.originalBytes)) · the file as it is on the server"
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            .tag(DownloadQualityPreference.original)
            ForEach(choice.options.qualities) { option in
              VStack(alignment: .leading, spacing: 2) {
                Text(option.id)
                Text(DownloadText.detail(option)).font(.caption).foregroundStyle(.secondary)
              }
              .tag(option.id)
            }
          }
          .pickerStyle(.radioGroup)
          .accessibilityIdentifier("download-quality")
          if quality != DownloadQualityPreference.original && choice.options.audioTracks.count > 1 {
            Picker("Sound", selection: $audio) {
              ForEach(choice.options.audioTracks) { track in
                Text(DownloadText.audio(track)).tag(Optional(track.index))
              }
            }
          }
          Toggle("Use This Quality from Now On", isOn: $remember)
        } footer: {
          Text(
            "A smaller copy is converted by the server while it downloads, with stereo sound; subtitles drawn as pictures are left out. Only this Mac keeps it. Settings › Playback changes the quality later."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
    }
    .frame(width: 520)
  }

  private func start() {
    if remember { preference = quality }
    let converted = quality == DownloadQualityPreference.original ? nil : quality
    model.startDownload(
      choice.item, quality: converted, audio: converted == nil ? nil : audio,
      expectedBytes: choice.options.qualities.first { $0.id == quality }?.estimatedBytes)
    let others = choice.others
    if !others.isEmpty { Task { await model.startDownloads(others, quality: converted) } }
    dismiss()
  }
}
