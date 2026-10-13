import SwiftUI

struct MediaActionsModifier: ViewModifier {
  @EnvironmentObject private var model: AppModel
  let item: CatalogItemSummary
  var onRemoved: (() -> Void)?
  @State private var editing: MediaMetadataSummary?
  @State private var removing = false
  @State private var error: String?
  func body(content: Content) -> some View {
    content.contextMenu {
      if item.kind == .movie || item.kind == .series {
        Button(
          item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
          systemImage: item.isFavorite ? "star.slash" : "star"
        ) {
          Task { _ = await model.setFavorite(mediaId: item.id, isFavorite: !item.isFavorite) }
        }
      }
      if model.canManageMedia {
        Button("Edit Metadata…", systemImage: "pencil") {
          Task {
            guard let profile = model.profile else { return }
            do { editing = try await APIClient(profile: profile).mediaMetadata(id: item.id) } catch
            { self.error = error.localizedDescription }
          }
        }
        Divider()
        Button("Remove from Library…", systemImage: "trash", role: .destructive) { removing = true }
      }
    }
    .sheet(item: $editing) { metadata in
      MetadataEditorSheet(metadata: metadata) { try? await model.refresh() }.environmentObject(
        model)
    }
    .confirmationDialog("Remove \(item.title)?", isPresented: $removing, titleVisibility: .visible)
    {
      Button("Remove from Library", role: .destructive) {
        Task {
          do {
            try await model.removeMedia(id: item.id)
            onRemoved?()
          } catch { self.error = error.localizedDescription }
        }
      }
    } message: {
      Text(
        "Aurelia metadata, images, favorites and playback history for this title and its associated content will be removed for all users. Video files are never changed. Future scans will keep this source excluded."
      )
    }
    .alert(
      "Library Action Failed",
      isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
    ) {
      Button("OK") { error = nil }
    } message: {
      Text(error ?? "")
    }
  }
}

extension View {
  func mediaActions(item: CatalogItemSummary, onRemoved: (() -> Void)? = nil) -> some View {
    modifier(MediaActionsModifier(item: item, onRemoved: onRemoved))
  }
}
