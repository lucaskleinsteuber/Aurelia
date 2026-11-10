import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Chooses a profile picture: one of the built-in symbols in one of the palettes, an own photo,
/// or the initial. `key` is what the server stores (`symbol:palette`, `photo` or nil); `photo`
/// holds a newly chosen photo, prepared for upload, until it is saved. A chosen photo opens the
/// crop sheet at once, and Adjust Photo opens it again later.
struct ProfilePicturePicker: View {
  let id: UUID?
  let name: String
  var pictureRevision: Int64 = 0
  @Binding var key: String?
  @Binding var photo: Data?
  @State private var palette = "blue"
  @State private var preview: NSImage?
  @State private var problem: String?
  /// The chosen photo before cropping, kept while this picker shows so it can be cropped again.
  @State private var original: NSImage?
  @State private var lastCrop: ArtworkCrop?
  @State private var cropping: PhotoCropTarget?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 16) {
        Group {
          if let preview {
            Image(nsImage: preview).resizable().scaledToFill()
              .frame(width: 72, height: 72).clipShape(Circle())
              .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
          } else {
            AureliaProfileAvatar(
              id: id, name: name.isEmpty ? "?" : name, size: 72, pictureKey: key,
              pictureRevision: pictureRevision)
          }
        }
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 8) {
          Button("Choose Photo…") { choosePhoto() }
            .accessibilityIdentifier("profile-picture-photo")
          if key == ProfilePictureCatalog.photoKey {
            Button("Adjust Photo…") { adjustPhoto() }
              .help("Choose which part of the photo shows in the circle")
              .accessibilityIdentifier("profile-picture-adjust")
          }
          Button("Use Initial") {
            key = nil
            photo = nil
            preview = nil
            problem = nil
            original = nil
            lastCrop = nil
          }
          .accessibilityIdentifier("profile-picture-initial")
        }
      }
      HStack(spacing: 6) {
        ForEach(ProfilePictureCatalog.symbols, id: \.self) { symbol in
          let candidate = ProfilePictureCatalog.builtin(symbol: symbol, palette: palette)
          Button {
            key = candidate
            photo = nil
            preview = nil
            problem = nil
            original = nil
            lastCrop = nil
          } label: {
            let colors = AureliaProfileAvatar.namedPalette(palette)
            Circle()
              .fill(
                LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom)
              )
              .overlay { ProfileSymbolView(symbol: symbol, size: 32) }
              .overlay {
                Circle().strokeBorder(key == candidate ? Color.white : .clear, lineWidth: 2)
              }
              .frame(width: 32, height: 32)
              .contentShape(Circle())
          }
          .buttonStyle(AureliaPressableButtonStyle())
          .help(symbol.capitalized)
          .accessibilityLabel("Picture \(symbol)")
          .accessibilityIdentifier("profile-picture-\(symbol)")
        }
      }
      HStack(spacing: 8) {
        ForEach(ProfilePictureCatalog.palettes, id: \.self) { candidate in
          Button {
            palette = candidate
            if let builtin = ProfilePictureCatalog.parse(key) {
              key = ProfilePictureCatalog.builtin(symbol: builtin.symbol, palette: candidate)
            }
          } label: {
            let colors = AureliaProfileAvatar.namedPalette(candidate)
            Circle()
              .fill(
                LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom)
              )
              .overlay {
                Circle().strokeBorder(palette == candidate ? Color.white : .clear, lineWidth: 2)
              }
              .frame(width: 22, height: 22)
              .contentShape(Circle())
          }
          .buttonStyle(AureliaPressableButtonStyle())
          .help(candidate.capitalized)
          .accessibilityLabel("Color \(candidate)")
          .accessibilityIdentifier("profile-picture-color-\(candidate)")
        }
      }
      if let problem {
        Text(problem).font(.caption).foregroundStyle(.orange)
      }
    }
    .onAppear {
      if let builtin = ProfilePictureCatalog.parse(key) { palette = builtin.palette }
    }
    .sheet(item: $cropping) { target in
      ArtworkCropSheet(
        image: target.image, ratio: 1, roundPreview: true, initial: target.initial,
        title: "Adjust Profile Photo",
        previewAccessibilityLabel: "Circular Profile Preview",
        note: "Only the square shown goes to the server."
      ) { crop in
        apply(target.image, crop: crop)
        cropping = nil
      }
    }
  }

  private func choosePhoto() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.jpeg, .png, .heic, .webP, .image]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message =
      "Choose a photo for this profile. Next you choose the part that shows in the circle."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let data = try? Data(contentsOf: url), let image = ProfilePictureCatalog.editablePhoto(data)
    else {
      problem = "This file is not a picture Aurelia can read."
      return
    }
    // Cancel in the crop sheet keeps the picture the profile had.
    cropping = PhotoCropTarget(image: image, initial: nil)
  }

  /// Crops the photo again: the one chosen here, else the profile's saved photo. The saved photo
  /// is already a square, so it can only be framed tighter; choose the photo again to widen it.
  private func adjustPhoto() {
    if let original {
      cropping = PhotoCropTarget(image: original, initial: lastCrop)
    } else if let id, let saved = ProfilePhotoCache.shared.image(id: id, revision: pictureRevision)
    {
      cropping = PhotoCropTarget(image: saved, initial: nil)
    } else {
      problem = "The saved photo hasn’t loaded yet. Choose the photo again to crop it."
    }
  }

  private func apply(_ image: NSImage, crop: ArtworkCrop) {
    guard let data = ProfilePictureCatalog.croppedPhoto(image, crop: crop), use(data) else {
      problem = "This photo could not be cropped. Try another one."
      return
    }
    original = image
    lastCrop = crop
  }

  /// Takes a photo for the profile. Returns false when it is not a readable picture.
  @discardableResult
  func use(_ data: Data) -> Bool {
    guard let prepared = ProfilePictureCatalog.preparedPhoto(data),
      let image = NSImage(data: prepared)
    else { return false }
    photo = prepared
    preview = image
    key = ProfilePictureCatalog.photoKey
    problem = nil
    return true
  }
}

/// A photo waiting in the crop sheet.
private struct PhotoCropTarget: Identifiable {
  let id = UUID()
  let image: NSImage
  let initial: ArtworkCrop?
}
