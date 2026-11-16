import SwiftUI

/// Titles waiting for the person to choose how large their downloads should be.
struct IOSPendingDownloadChoice: Identifiable {
  let items: [IOSCatalogItem]
  let options: IOSDownloadOptions
  let id = UUID()

  var title: String {
    items.count == 1 ? "Download \(items[0].title)?" : "Download \(items.count) Episodes?"
  }
}

/// Download › the original or a smaller copy the server converts ("converted-downloads-v1").
struct IOSDownloadQualityDialog: ViewModifier {
  @EnvironmentObject private var model: IOSAppModel

  func body(content: Content) -> some View {
    content.confirmationDialog(
      model.downloadChoice?.title ?? "Download",
      isPresented: Binding(
        get: { model.downloadChoice != nil }, set: { if !$0 { model.downloadChoice = nil } }),
      titleVisibility: .visible, presenting: model.downloadChoice
    ) { choice in
      Button("Original · \(IOSDownloadText.size(choice.options.originalBytes))") {
        model.startDownloads(choice.items, quality: nil)
      }
      ForEach(choice.options.qualities) { quality in
        Button(IOSDownloadText.button(quality)) {
          model.startDownloads(
            choice.items, quality: quality.id, audio: choice.options.audioTrack,
            options: choice.options)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { choice in
      Text(
        "A smaller copy is converted by the server while it downloads, with stereo sound; subtitles drawn as pictures are left out. Only this device keeps it."
          + (choice.items.count > 1 ? " Sizes are for the first episode." : ""))
    }
  }
}
