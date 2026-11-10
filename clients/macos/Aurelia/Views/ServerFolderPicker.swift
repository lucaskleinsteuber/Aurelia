import SwiftUI

/// Chooses a folder on the connected server when it runs on another computer, such as a Linux
/// server without a screen. It shows the server's folders, never this Mac's, and only reads
/// their names.
struct ServerFolderPicker: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let onChoose: (String) -> Void
  @State private var listing: ServerFolderListing?
  @State private var errorMessage: String?
  @State private var isLoading = false

  var body: some View {
    VStack(spacing: 0) {
      header
      folders
      Divider()
      HStack {
        Text("Folders are listed from the server. Their media files are only read.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(chooseTitle) {
          if let path = listing?.path {
            onChoose(path)
            dismiss()
          }
        }
        .buttonStyle(AureliaPrimaryActionButtonStyle())
        .disabled(listing?.path == nil || isLoading)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("server-folder-choose")
      }
      .padding(16)
    }
    .frame(width: 580, height: 500)
    .task { await load(nil) }
  }

  private var chooseTitle: String {
    guard let path = listing?.path else { return "Choose" }
    let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    return name.isEmpty || name == "/" ? "Choose This Folder" : "Choose “\(name)”"
  }

  private var header: some View {
    HStack(spacing: 12) {
      Button {
        Task { await load(listing?.parent) }
      } label: {
        Image(systemName: "chevron.left")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(AureliaPressableButtonStyle())
      .disabled(listing?.path == nil || isLoading)
      .accessibilityLabel("Up")
      .accessibilityIdentifier("server-folder-up")
      VStack(alignment: .leading, spacing: 2) {
        Text("Folders on \(model.profile?.name ?? "the Server")")
          .font(.headline)
        Text(listing?.path ?? "Places")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
      Spacer()
      if isLoading {
        ProgressView().controlSize(.small)
      }
    }
    .padding(16)
  }

  @ViewBuilder
  private var folders: some View {
    if let errorMessage {
      Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    } else if let listing, listing.folders.isEmpty {
      Text("No folders here.")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(listing?.folders ?? [], id: \.path) { folder in
            Button {
              Task { await load(folder.path) }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: listing?.path == nil ? "externaldrive.fill" : "folder.fill")
                  .foregroundStyle(.secondary)
                  .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                  Text(folder.name)
                  if listing?.path == nil {
                    Text(folder.path)
                      .font(.caption.monospaced())
                      .foregroundStyle(.secondary)
                  }
                }
                Spacer()
                Image(systemName: "chevron.right")
                  .foregroundStyle(.tertiary)
              }
              .padding(.horizontal, 16)
              .frame(minHeight: AureliaDesign.minimumControlSize)
              .contentShape(Rectangle())
            }
            .buttonStyle(AureliaPressableButtonStyle())
            .disabled(isLoading)
            .accessibilityIdentifier("server-folder-\(folder.name)")
            Divider().padding(.leading, 50)
          }
        }
      }
    }
  }

  private func load(_ path: String?) async {
    isLoading = true
    defer { isLoading = false }
    do {
      listing = try await model.serverFolders(at: path)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
