import SwiftUI

/// Titles waiting for the person to choose how large their downloads should be.
struct IOSPendingDownloadChoice: Identifiable {
  let items: [IOSCatalogItem]
  let options: IOSDownloadOptions
  let sessionID: UUID
  let id: UUID

  var title: String {
    items.count == 1 ? "Download \(items[0].title)?" : "Download \(items.count) Episodes?"
  }
}

/// Download › the original or a smaller copy the server converts ("converted-downloads-v1").
struct IOSDownloadQualityDialog: ViewModifier {
  @EnvironmentObject private var model: IOSAppModel
  @State private var pendingError: String?
  @State private var presentedError: String?

  func body(content: Content) -> some View {
    content.confirmationDialog(
      model.downloadChoice?.title ?? "Download",
      isPresented: Binding(
        get: { model.downloadChoice != nil }, set: { if !$0 { model.downloadChoice = nil } }),
      titleVisibility: .visible, presenting: model.downloadChoice
    ) { choice in
      Button("Original · \(IOSDownloadText.size(choice.options.originalBytes))") {
        model.confirmDownloads(choice, quality: nil)
      }
      ForEach(choice.options.qualities) { quality in
        Button(IOSDownloadText.button(quality)) {
          model.confirmDownloads(choice, quality: quality)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { choice in
      Text(
        "A smaller copy is converted by the server while it downloads, with stereo sound; subtitles drawn as pictures are left out. Only this device keeps it."
          + (choice.items.count > 1 ? " Sizes are for the first episode." : ""))
    }
    .onReceive(model.offline.$errorMessage) { message in
      guard let message, !message.isEmpty else {
        pendingError = nil
        return
      }
      pendingError = message
      model.downloadChoice = nil
    }
    .onChange(of: model.session?.sessionId) { _, _ in
      pendingError = nil
      presentedError = nil
    }
    .task(id: ErrorPresentation(message: pendingError, choiceID: model.downloadChoice?.id)) {
      guard let message = pendingError, model.downloadChoice == nil else { return }
      // Let an open quality confirmation finish dismissing before presenting its error.
      do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
      guard !Task.isCancelled, model.downloadChoice == nil, pendingError == message else {
        return
      }
      presentedError = message
      pendingError = nil
    }
    .alert(
      "Download Could Not Start",
      isPresented: Binding(
        get: { presentedError != nil }, set: { if !$0 { dismissError() } })
    ) {
      Button("OK") { dismissError() }
    } message: {
      Text(presentedError ?? "")
    }
  }

  private struct ErrorPresentation: Equatable {
    let message: String?
    let choiceID: UUID?
  }

  private func dismissError() {
    if model.offline.errorMessage == presentedError { model.offline.errorMessage = nil }
    presentedError = nil
  }
}
