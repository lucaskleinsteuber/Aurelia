import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class MetadataDraft: ObservableObject {
  @Published var document: MediaEditorDocument?
  @Published var values = MediaEditorValues()
  @Published var overrides: Set<String> = []
  @Published var year = ""
  @Published var runtime = ""
  @Published var source: String?
  @Published var busy = false
  @Published var error: String?
  var uploads: [UUID] = []

  var dirty: Bool {
    guard let document else { return false }
    return values != document.values || overrides != Set(document.overrideFields)
      || source != nil || year != document.values.releaseYear.map(String.init) ?? ""
      || runtime != document.values.runtimeMinutes.map(String.init) ?? ""
  }
  var valid: Bool {
    !values.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (year.isEmpty || Int(year).map { (1800...3000).contains($0) } == true)
      && (runtime.isEmpty || Int(runtime).map { (1...14400).contains($0) } == true)
      && values.credits.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
  }
  func load(_ document: MediaEditorDocument) {
    self.document = document
    values = document.values
    overrides = Set(document.overrideFields)
    year = values.releaseYear.map(String.init) ?? ""
    runtime = values.runtimeMinutes.map(String.init) ?? ""
    source = nil
    error = nil
  }
  func binding<Value>(_ key: WritableKeyPath<MediaEditorValues, Value>, field: String) -> Binding<
    Value
  > {
    Binding(
      get: { self.values[keyPath: key] },
      set: {
        self.values[keyPath: key] = $0
        self.overrides.insert(field)
      })
  }
  func text(_ key: WritableKeyPath<MediaEditorValues, String?>, field: String) -> Binding<String> {
    Binding(
      get: { self.values[keyPath: key] ?? "" },
      set: {
        self.values[keyPath: key] = $0
        self.overrides.insert(field)
      })
  }
  func automatic(_ field: String) {
    guard let value = document?.automaticValues else { return }
    switch field {
    case "title": values.title = value.title
    case "releaseYear":
      values.releaseYear = value.releaseYear
      year = value.releaseYear.map(String.init) ?? ""
    case "overview": values.overview = value.overview
    case "runtimeMinutes":
      values.runtimeMinutes = value.runtimeMinutes
      runtime = value.runtimeMinutes.map(String.init) ?? ""
    case "fsk": values.fskAge = value.fskAge
    case "genres": values.genres = value.genres
    case "studios": values.studios = value.studios
    case "country": values.country = value.country
    case "credits": values.credits = value.credits
    case "poster": values.poster = value.poster
    case "backdrop": values.backdrop = value.backdrop
    default: break
    }
    overrides.remove(field)
  }
}

struct MetadataEditorSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @StateObject private var draft = MetadataDraft()
  let metadata: MediaMetadataSummary
  let onSaved: () async -> Void
  @State private var page = Page.general
  @State private var discard = false
  @State private var reloadConfirmation = false
  @State private var filePicker = false
  @State private var cropTarget: CropTarget?
  enum Page: String, CaseIterable {
    case general = "General"
    case production = "Production & Release"
    case people = "Cast & Crew"
    case artwork = "Artwork & File"
  }
  init(
    metadata: MediaMetadataSummary, onSaved: @escaping () async -> Void,
    previewDocument: MediaEditorDocument? = nil, page: Page = .general
  ) {
    self.metadata = metadata
    self.onSaved = onSaved
    let state = MetadataDraft()
    if let previewDocument { state.load(previewDocument) }
    _draft = StateObject(wrappedValue: state)
    _page = State(initialValue: page)
  }
  private struct CropTarget: Identifiable {
    let id = UUID()
    let field: String
    let person: UUID?
    let selection: EditorArtwork
    let image: NSImage
    var ratio: Double { person != nil ? 1 : field == "poster" ? 2.0 / 3 : 16.0 / 9 }
  }
  private var client: APIClient? { model.profile.map(APIClient.init(profile:)) }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Edit Metadata", systemImage: "pencil.and.list.clipboard").font(.title2.bold())
        Spacer()
        if draft.dirty { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
      }.padding(20)
      Picker("Editor section", selection: $page) {
        ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 16)
      Divider()
      if draft.document != nil {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            switch page {
            case .general: general
            case .production: production
            case .people: people
            case .artwork: artwork
            }
          }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(draft.busy)
      } else {
        ProgressView("Loading editor…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if let error = draft.error {
        HStack(alignment: .top) {
          Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
          Spacer()
          Button("Reload") {
            if draft.dirty { reloadConfirmation = true } else { Task { await load() } }
          }.disabled(draft.busy)
        }.padding(16)
      }
      Divider()
      HStack {
        Text("Manual changes survive scans and provider refreshes.").font(.caption).foregroundStyle(
          .secondary)
        Spacer()
        if draft.busy { ProgressView().controlSize(.small) }
        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).disabled(draft.busy)
        Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction)
          .buttonStyle(AureliaPrimaryActionButtonStyle()).disabled(
            !draft.valid || draft.busy || draft.document == nil)
      }.padding(16)
    }
    .frame(
      minWidth: 820, idealWidth: 940, maxWidth: .infinity, minHeight: 610, idealHeight: 720,
      maxHeight: .infinity
    )
    .background(AureliaBackdrop())
    .interactiveDismissDisabled(draft.dirty || draft.busy)
    .accessibilityIdentifier("metadata-editor")
    .task { if draft.document == nil { await load() } }
    .alert("Discard unsaved changes?", isPresented: $discard) {
      Button("Keep Editing", role: .cancel) {}
      Button("Discard", role: .destructive) {
        discardUploads()
        dismiss()
      }
    } message: {
      Text("Your existing metadata and images have not been changed.")
    }
    .alert("Reload and discard this draft?", isPresented: $reloadConfirmation) {
      Button("Keep Editing", role: .cancel) {}
      Button("Reload", role: .destructive) { Task { await load() } }
    } message: {
      Text(
        "Another device may have changed this title. Copy any changes you want to keep before reloading."
      )
    }
    .sheet(isPresented: $filePicker) {
      if let client {
        ServerVideoPicker(client: client, mediaId: metadata.mediaId) {
          draft.source = $0
          filePicker = false
        }
      }
    }
    .sheet(item: $cropTarget) { target in
      ArtworkCropSheet(
        image: target.image, ratio: target.ratio, roundPreview: target.person != nil,
        initial: target.selection.crop
      ) { crop in
        var selection = target.selection
        selection.crop = crop
        setArtwork(selection, field: target.field, person: target.person)
        cropTarget = nil
      }
    }
  }

  private var general: some View {
    VStack(alignment: .leading, spacing: 18) {
      field("Title", key: "title") {
        TextField("Title", text: draft.binding(\.title, field: "title")).accessibilityIdentifier(
          "metadata-title")
      }
      HStack(alignment: .top, spacing: 24) {
        field("Release Year", key: "releaseYear") {
          TextField(
            "Not specified",
            text: Binding(
              get: { draft.year },
              set: {
                draft.year = $0
                draft.values.releaseYear = Int($0)
                draft.overrides.insert("releaseYear")
              }))
        }
        field("FSK", key: "fsk") {
          Picker("FSK", selection: draft.binding(\.fskAge, field: "fsk")) {
            Text("Not specified").tag(Int?.none)
            ForEach([0, 6, 12, 16, 18], id: \.self) { Text("FSK \($0)").tag(Optional($0)) }
          }.labelsHidden()
        }
        if draft.document?.kind == .movie {
          field("Runtime in Minutes", key: "runtimeMinutes") {
            TextField(
              "Not specified",
              text: Binding(
                get: { draft.runtime },
                set: {
                  draft.runtime = $0
                  draft.values.runtimeMinutes = Int($0)
                  draft.overrides.insert("runtimeMinutes")
                }))
          }
        }
      }
      field("Description", key: "overview") {
        TextEditor(text: draft.text(\.overview, field: "overview")).frame(minHeight: 155)
          .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      }
      field("Genres", key: "genres") {
        EditorTagList(values: draft.binding(\.genres, field: "genres"), placeholder: "Add genre")
      }
    }.textFieldStyle(.roundedBorder)
  }
  private var production: some View {
    VStack(alignment: .leading, spacing: 24) {
      field("Studios", key: "studios") {
        EditorTagList(values: draft.binding(\.studios, field: "studios"), placeholder: "Add studio")
      }
      field("Country of Origin", key: "country") {
        TextField("One country", text: draft.text(\.country, field: "country"))
      }
      Text("Choose one country. Foreign content ratings are not automatically converted to FSK.")
        .font(.callout).foregroundStyle(.secondary)
    }.textFieldStyle(.roundedBorder)
  }
  private var people: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Changes apply to this title only.").foregroundStyle(.secondary)
        Spacer()
        automatic("credits")
        Button("Add Person", systemImage: "plus") {
          draft.values.credits.append(EditorCredit(id: UUID(), name: "", department: "Acting"))
          draft.overrides.insert("credits")
        }
      }
      ForEach(Array(draft.values.credits.enumerated()), id: \.element.id) { index, person in
        HStack(alignment: .top, spacing: 16) {
          VStack {
            EditorImagePreview(
              client: client, mediaId: metadata.mediaId, selection: person.profile, circular: true
            )
            .frame(width: 86, height: 86)
            Menu("Photo") {
              Button("Choose Image…") {
                Task { await chooseImage(field: "credits", person: person.id) }
              }
              Button("Crop…") {
                Task { await recrop(person.profile, field: "credits", person: person.id) }
              }.disabled(person.profile == nil)
              Button("Remove Image", role: .destructive) {
                setArtwork(nil, field: "credits", person: person.id)
              }
            }
          }
          VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: personText(person.id, key: \.name))
            HStack {
              TextField("Department", text: personText(person.id, key: \.department))
              TextField("Job / Role", text: personOptionalText(person.id, key: \.job))
            }
            TextField(
              "Character / Name in Film", text: personOptionalText(person.id, key: \.character))
          }.textFieldStyle(.roundedBorder)
          VStack {
            Button {
              movePerson(index, by: -1)
            } label: {
              Image(systemName: "chevron.up")
            }.disabled(index == 0)
            Button {
              movePerson(index, by: 1)
            } label: {
              Image(systemName: "chevron.down")
            }.disabled(index == draft.values.credits.count - 1)
            Button(role: .destructive) {
              draft.values.credits.removeAll { $0.id == person.id }
              draft.overrides.insert("credits")
            } label: {
              Image(systemName: "trash")
            }
          }.buttonStyle(.borderless)
        }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
      }
      if draft.values.credits.isEmpty {
        Text("No cast or crew. Add a person to begin.").foregroundStyle(.secondary).padding(
          .vertical, 30)
      }
    }
  }
  private var artwork: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(alignment: .top, spacing: 32) {
        artworkControl(
          "Cover", field: "poster", selection: draft.values.poster, width: 170, height: 255)
        artworkControl(
          "Background", field: "backdrop", selection: draft.values.backdrop, width: 390, height: 219
        )
      }
      Divider()
      Text(draft.document?.kind == .series ? "Series Folder" : "Video File").font(.headline)
      Text(draft.source ?? draft.document?.sourcePath ?? "").font(.callout.monospaced())
        .textSelection(.enabled)
      if draft.document?.kind == .movie || draft.document?.kind == .episode {
        Button("Choose Server File…") { filePicker = true }
        Text(
          "Select an existing video in this title's storage location. No video is uploaded, moved or modified."
        ).font(.caption).foregroundStyle(.secondary)
      } else {
        Text("Edit an individual episode to change its video file.").font(.caption).foregroundStyle(
          .secondary)
      }
    }
  }
  private func field<Content: View>(
    _ title: String, key: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        automatic(key)
      }
      content()
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func automatic(_ field: String) -> some View {
    Button("Use Automatic Value") { draft.automatic(field) }.font(.caption).buttonStyle(.borderless)
      .disabled(!draft.overrides.contains(field))
  }
  private func artworkControl(
    _ title: String, field: String, selection: EditorArtwork?, width: CGFloat, height: CGFloat
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.headline)
      EditorImagePreview(client: client, mediaId: metadata.mediaId, selection: selection).frame(
        width: width, height: height)
      HStack {
        Button("Choose…") { Task { await chooseImage(field: field) } }
        Button("Crop…") { Task { await recrop(selection, field: field) } }.disabled(
          selection == nil)
        Button("Remove", role: .destructive) { setArtwork(nil, field: field) }
      }
      automatic(field)
    }
  }
  private func personText(_ id: UUID, key: WritableKeyPath<EditorCredit, String>) -> Binding<String>
  {
    Binding(
      get: { draft.values.credits.first { $0.id == id }?[keyPath: key] ?? "" },
      set: { value in
        if let index = draft.values.credits.firstIndex(where: { $0.id == id }) {
          draft.values.credits[index][keyPath: key] = value
          draft.overrides.insert("credits")
        }
      })
  }
  private func personOptionalText(_ id: UUID, key: WritableKeyPath<EditorCredit, String?>)
    -> Binding<String>
  {
    Binding(
      get: { draft.values.credits.first { $0.id == id }?[keyPath: key] ?? "" },
      set: { value in
        if let index = draft.values.credits.firstIndex(where: { $0.id == id }) {
          draft.values.credits[index][keyPath: key] = value
          draft.overrides.insert("credits")
        }
      })
  }
  private func movePerson(_ index: Int, by offset: Int) {
    draft.values.credits.swapAt(index, index + offset)
    draft.overrides.insert("credits")
  }
  private func setArtwork(_ selection: EditorArtwork?, field: String, person: UUID? = nil) {
    if let person, let index = draft.values.credits.firstIndex(where: { $0.id == person }) {
      draft.values.credits[index].profile = selection
    } else if field == "poster" {
      draft.values.poster = selection
    } else if field == "backdrop" {
      draft.values.backdrop = selection
    }
    draft.overrides.insert(field)
  }
  private func chooseImage(field: String, person: UUID? = nil) async {
    guard let client else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.jpeg, .png, .heic]
    panel.allowsMultipleSelection = false
    guard await panel.begin() == .OK, let url = panel.url else { return }
    draft.busy = true
    defer { draft.busy = false }
    do {
      let bytes = try EditorImageImport.png(url: url)
      let upload = try await client.uploadEditorImage(id: metadata.mediaId, png: bytes)
      draft.uploads.append(upload.id)
      guard let image = NSImage(data: bytes) else { throw APIClientError.invalidResponse }
      cropTarget = CropTarget(
        field: field, person: person, selection: EditorArtwork(uploadId: upload.id), image: image)
    } catch { draft.error = error.localizedDescription }
  }
  private func recrop(_ selection: EditorArtwork?, field: String, person: UUID? = nil) async {
    guard let client, let selection else { return }
    draft.busy = true
    defer { draft.busy = false }
    do {
      guard
        let image = NSImage(
          data: try await client.editorImage(id: metadata.mediaId, selection: selection))
      else { throw APIClientError.invalidResponse }
      cropTarget = CropTarget(field: field, person: person, selection: selection, image: image)
    } catch { draft.error = error.localizedDescription }
  }
  private func load() async {
    guard let client else { return }
    draft.busy = true
    defer { draft.busy = false }
    do { draft.load(try await client.mediaEditor(id: metadata.mediaId)) } catch {
      draft.error = error.localizedDescription
    }
  }
  private func save() async {
    guard let client, let document = draft.document else { return }
    draft.busy = true
    defer { draft.busy = false }
    do {
      let saved = try await client.saveMediaEditor(
        id: metadata.mediaId,
        request: SaveMediaEditorRequest(
          revision: document.revision, values: draft.values,
          overrideFields: draft.overrides.sorted(), relativeSourcePath: draft.source))
      draft.load(saved)
      try await model.refresh()
      await onSaved()
      discardUploads()
      dismiss()
    } catch { draft.error = error.localizedDescription }
  }
  private func cancel() {
    if draft.dirty {
      discard = true
    } else {
      discardUploads()
      dismiss()
    }
  }
  private func discardUploads() {
    guard let client else { return }
    let uploads = draft.uploads
    Task {
      for id in uploads { try? await client.discardEditorImage(id: metadata.mediaId, upload: id) }
    }
  }
}

private struct EditorTagList: View {
  @Binding var values: [String]
  let placeholder: String
  @State private var entry = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(values.enumerated()), id: \.offset) { index, value in
        HStack {
          TextField(
            placeholder,
            text: Binding(
              get: { index < values.count ? values[index] : "" },
              set: { if index < values.count { values[index] = $0 } }))
          Button(role: .destructive) {
            values.remove(at: index)
          } label: {
            Image(systemName: "minus.circle")
          }.buttonStyle(.borderless)
        }
      }
      HStack {
        TextField(placeholder, text: $entry).onSubmit(add)
        Button("Add", action: add).disabled(
          entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.textFieldStyle(.roundedBorder)
  }
  private func add() {
    let clean = entry.trimmingCharacters(in: .whitespacesAndNewlines)
    if !clean.isEmpty
      && !values.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame })
    {
      values.append(clean)
    }
    entry = ""
  }
}

enum EditorImageImport {
  static func png(url: URL) throws -> Data {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let info = try url.resourceValues(forKeys: [.fileSizeKey])
    guard (info.fileSize ?? Int.max) <= 20 * 1024 * 1024,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, Int64(width) * Int64(height) <= 24_000_000,
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ] as CFDictionary)
    else {
      throw APIClientError.serverRejected(
        code: "invalid_image",
        message: "Choose a JPEG, PNG or HEIC image up to 20 MB and 24 megapixels.")
    }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil)
    else { throw APIClientError.invalidResponse }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination), data.length <= 20 * 1024 * 1024 else {
      throw APIClientError.serverRejected(
        code: "image_too_large", message: "The decoded image is too large. Select a smaller image.")
    }
    return data as Data
  }
}

private struct EditorImagePreview: View {
  let client: APIClient?
  let mediaId: UUID
  let selection: EditorArtwork?
  var circular = false
  @State private var image: NSImage?
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10).fill(.quaternary)
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        Image(systemName: circular ? "person.crop.circle" : "photo").font(.largeTitle)
          .foregroundStyle(.secondary)
      }
    }.clipped().clipShape(RoundedRectangle(cornerRadius: circular ? 1000 : 10))
      .task(id: selection) {
        image = nil
        guard let selection, let client,
          let bytes = try? await client.editorImage(id: mediaId, selection: selection),
          let original = NSImage(data: bytes)
        else { return }
        image = CropImage.render(original, crop: selection.crop)
      }
  }
}

enum CropImage {
  @MainActor static func rotated(_ image: NSImage, degrees: Int) -> NSImage {
    guard degrees != 0 else { return image }
    let size =
      degrees % 180 == 0 ? image.size : NSSize(width: image.size.height, height: image.size.width)
    let result = NSImage(size: size)
    result.lockFocus()
    let transform = AffineTransform(translationByX: size.width / 2, byY: size.height / 2)
    let mutable = (transform as NSAffineTransform)
    mutable.rotate(byDegrees: CGFloat(-degrees))
    mutable.concat()
    image.draw(
      in: NSRect(
        x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width,
        height: image.size.height))
    result.unlockFocus()
    return result
  }
  @MainActor static func render(_ image: NSImage, crop: ArtworkCrop?) -> NSImage {
    guard let crop else { return image }
    let rotated = rotated(image, degrees: crop.rotation)
    let size = rotated.size
    let result = NSImage(
      size: NSSize(width: size.width * crop.width, height: size.height * crop.height))
    result.lockFocus()
    rotated.draw(
      in: NSRect(origin: .zero, size: result.size),
      from: NSRect(
        x: size.width * crop.x,
        y: size.height * (1 - crop.y - crop.height), width: result.size.width,
        height: result.size.height), operation: .copy, fraction: 1)
    result.unlockFocus()
    return result
  }
}

struct ArtworkCropSheet: View {
  @Environment(\.dismiss) private var dismiss
  let image: NSImage
  let ratio: Double
  let roundPreview: Bool
  let initial: ArtworkCrop?
  let onSave: (ArtworkCrop) -> Void
  @State private var zoom = 1.0
  @State private var rotation = 0
  @State private var offset = CGSize.zero
  @State private var dragStart = CGSize.zero
  private var size: CGSize { CGSize(width: 360, height: 360 / ratio) }
  private var rotated: NSImage { CropImage.rotated(image, degrees: rotation) }
  private var scale: Double {
    max(size.width / rotated.size.width, size.height / rotated.size.height) * zoom
  }
  var body: some View {
    VStack(spacing: 20) {
      Text("Crop Image").font(.title2.bold())
      Text("Drag to move. Adjust zoom or rotate in 90° steps.").foregroundStyle(.secondary)
      ZStack {
        Color.black
        Image(nsImage: rotated).resizable().frame(
          width: rotated.size.width * scale, height: rotated.size.height * scale
        ).offset(offset)
      }.frame(width: size.width, height: size.height).clipped()
        .clipShape(RoundedRectangle(cornerRadius: roundPreview ? 1000 : 0))
        .overlay {
          RoundedRectangle(cornerRadius: roundPreview ? 1000 : 0).stroke(
            .white.opacity(0.6), lineWidth: 1)
        }
        .gesture(
          DragGesture().onChanged { value in
            offset = clamped(
              CGSize(
                width: dragStart.width + value.translation.width,
                height: dragStart.height + value.translation.height))
          }
          .onEnded { _ in dragStart = offset })
      HStack {
        Text("Zoom")
        Slider(value: $zoom, in: 1...8).onChange(of: zoom) { _, _ in
          offset = clamped(offset)
          dragStart = offset
        }
        Button("Rotate 90°", systemImage: "rotate.right") {
          rotation = (rotation + 90) % 360
          zoom = 1
          offset = .zero
          dragStart = .zero
        }
      }
      HStack {
        Text("The uncropped original is retained for future changes.").font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Use Crop") { onSave(crop) }.buttonStyle(AureliaPrimaryActionButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 640).background(AureliaBackdrop())
      .onAppear {
        guard let initial else { return }
        rotation = initial.rotation
        let base = max(size.width / rotated.size.width, size.height / rotated.size.height)
        zoom = min(8, max(1, size.width / (initial.width * rotated.size.width) / base))
        offset = clamped(
          CGSize(
            width: (0.5 - initial.x - initial.width / 2) * rotated.size.width * scale,
            height: (0.5 - initial.y - initial.height / 2) * rotated.size.height * scale))
        dragStart = offset
      }
  }
  private func clamped(_ value: CGSize) -> CGSize {
    let x = max(0, (rotated.size.width * scale - size.width) / 2)
    let y = max(0, (rotated.size.height * scale - size.height) / 2)
    return CGSize(width: min(x, max(-x, value.width)), height: min(y, max(-y, value.height)))
  }
  private var crop: ArtworkCrop {
    let width = size.width / scale / rotated.size.width
    let height = size.height / scale / rotated.size.height
    return ArtworkCrop(
      x: max(0, min(1 - width, 0.5 - width / 2 - offset.width / scale / rotated.size.width)),
      y: max(0, min(1 - height, 0.5 - height / 2 - offset.height / scale / rotated.size.height)),
      width: min(1, width), height: min(1, height), rotation: rotation)
  }
}

private struct ServerVideoPicker: View {
  @Environment(\.dismiss) private var dismiss
  let client: APIClient
  let mediaId: UUID
  let onSelect: (String) -> Void
  @State private var listing: ServerFileListing?
  @State private var error: String?
  @State private var path = "."
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Choose Server Video").font(.title2.bold())
      Text("Storage location / \(path)").font(.callout.monospaced())
      Button("Parent Folder", systemImage: "arrow.up") {
        path = (path as NSString).deletingLastPathComponent
        if path.isEmpty { path = "." }
      }.disabled(path == ".")
      List(listing?.entries ?? []) { entry in
        Button {
          if entry.isDirectory { path = entry.relativePath } else { onSelect(entry.relativePath) }
        } label: {
          Label(entry.name, systemImage: entry.isDirectory ? "folder" : "film").frame(
            maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
      }
      if let error { Text(error).foregroundStyle(.orange) }
      HStack {
        Text("Only files in this title's server storage are available.").font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { dismiss() }
      }
    }.padding(24).frame(width: 650, height: 550).background(AureliaBackdrop())
      .task(id: path) {
        do {
          listing = try await client.editorFiles(id: mediaId, path: path)
          error = nil
        } catch {
          listing = nil
          self.error = error.localizedDescription
        }
      }
  }
}
