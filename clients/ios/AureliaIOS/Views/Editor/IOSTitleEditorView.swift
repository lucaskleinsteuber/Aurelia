import PhotosUI
import SwiftUI
import UIKit

/// Edit… on a title's page, for administrators: its metadata, poster and backdrop, the video file,
/// subtitles (OpenSubtitles and from speech) and intro and credits times, as on the Mac. Manual
/// changes survive scans; Use Found Values goes back to what the server found.
struct IOSTitleEditorView: View {
  @EnvironmentObject private var model: IOSAppModel
  @Environment(\.dismiss) private var dismiss
  @StateObject private var admin = IOSAdministrationModel()
  let mediaID: UUID
  let title: String

  @State private var draft = IOSMetadataDraft()
  @State private var loadError: String?
  @State private var saving = false
  @State private var confirmDiscard = false
  @State private var newGenre = ""
  @State private var newStudio = ""
  @State private var personQuery = ""
  @State private var peopleShown = 30
  @State private var editingCredit: IOSEditorCredit?
  @State private var posterItem: PhotosPickerItem?
  @State private var backdropItem: PhotosPickerItem?
  @State private var cropping: CropRequest?
  @State private var previews: [String: UIImage] = [:]
  @State private var uploading = false
  @State private var choosingFile = false

  private struct CropRequest: Identifiable {
    let id = UUID()
    let field: String
    let image: CGImage
    var ratio: CGFloat { field == "poster" ? 2.0 / 3.0 : 16.0 / 9.0 }
  }

  private var kind: IOSMediaKind? { draft.document?.kind }

  var body: some View {
    NavigationStack {
      Group {
        if draft.document != nil {
          form
        } else if let loadError {
          ContentUnavailableView {
            Label("Can't Open the Editor", systemImage: "exclamationmark.triangle")
          } description: {
            Text(loadError)
          } actions: {
            Button("Try Again") { Task { await load() } }
          }
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .scrollContentBackground(.hidden)
      .background(IOSDesign.canvas.ignoresSafeArea())
      .navigationTitle("Edit")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            if draft.isDirty { confirmDiscard = true } else { close() }
          }
          .disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
          if saving {
            ProgressView()
          } else {
            Button("Save") { Task { await save() } }
              .disabled(!draft.canSave || uploading)
              .accessibilityIdentifier("editor-save")
          }
        }
      }
    }
    .interactiveDismissDisabled(draft.isDirty || saving)
    .task {
      admin.attach(model)
      if draft.document == nil { await load() }
    }
    .confirmationDialog(
      "Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible
    ) {
      Button("Discard Changes", role: .destructive) { close() }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text("The title stays as it was.")
    }
    .sheet(isPresented: $admin.unlockRequested, onDismiss: { admin.cancelUnlock() }) {
      IOSManagementUnlockSheet(admin: admin, serverName: model.connection?.name ?? "Aurelia")
    }
    .alert(
      "Edit",
      isPresented: Binding(get: { admin.alert != nil }, set: { if !$0 { admin.alert = nil } })
    ) {
      Button("OK") { admin.alert = nil }
    } message: {
      Text(admin.alert ?? "")
    }
    .sheet(item: $cropping) { request in
      IOSArtworkCropSheet(
        image: request.image, aspectRatio: request.ratio,
        title: request.field == "poster" ? "Crop Poster" : "Crop Backdrop"
      ) { crop in
        cropping = nil
        guard let crop else { return }
        Task { await upload(request.image, field: request.field, crop: crop) }
      }
    }
    .sheet(item: $editingCredit) { credit in
      IOSCreditEditor(credit: credit) { edited in
        var credits = draft.values.credits
        if let index = credits.firstIndex(where: { $0.id == edited.id }) {
          credits[index] = edited
        } else {
          credits.append(edited)
        }
        draft.set(\.credits, credits, field: "credits")
      }
    }
    .sheet(isPresented: $choosingFile) {
      IOSServerVideoPicker(mediaID: mediaID, admin: admin) { path in
        draft.source = path
        choosingFile = false
      }
    }
    .onChange(of: posterItem) { _, item in pick(item, field: "poster") }
    .onChange(of: backdropItem) { _, item in pick(item, field: "backdrop") }
  }

  // MARK: Form

  private var form: some View {
    Form {
      Section {
        TextField(
          "Title",
          text: Binding(
            get: { draft.values.title }, set: { draft.set(\.title, $0, field: "title") })
        )
        .accessibilityIdentifier("editor-title")
        TextField("Year", text: Binding(get: { draft.year }, set: { draft.setYear($0) }))
          .keyboardType(.numberPad)
        if kind == .movie {
          TextField(
            "Runtime in Minutes",
            text: Binding(get: { draft.runtime }, set: { draft.setRuntime($0) })
          )
          .keyboardType(.numberPad)
        }
        Picker(
          "FSK",
          selection: Binding(
            get: { draft.values.fskAge }, set: { draft.set(\.fskAge, $0, field: "fsk") })
        ) {
          Text("Not Specified").tag(Int?.none)
          ForEach(IOSMetadataDraft.ageRatings, id: \.self) { Text("FSK \($0)").tag(Optional($0)) }
        }
      } header: {
        Text(title)
      } footer: {
        problems(["title", "releaseYear", "runtimeMinutes"])
        automaticButton(["title", "releaseYear", "runtimeMinutes", "fsk"])
      }

      Section {
        TextField(
          "Overview",
          text: Binding(
            get: { draft.values.overview ?? "" },
            set: { draft.set(\.overview, $0, field: "overview") }),
          axis: .vertical
        )
        .lineLimit(4...12)
      } header: {
        Text("Overview")
      } footer: {
        automaticButton(["overview"])
      }

      tagSection(
        "Genres", key: \.genres, field: "genres", entry: $newGenre, placeholder: "Add Genre")
      tagSection(
        "Studios", key: \.studios, field: "studios", entry: $newStudio, placeholder: "Add Studio")
      Section {
        TextField(
          "Country",
          text: Binding(
            get: { draft.values.country ?? "" },
            set: { draft.set(\.country, $0.isEmpty ? nil : $0, field: "country") }))
      } footer: {
        automaticButton(["country"])
      }

      peopleSection
      artworkSection
      fileSection

      if kind == .movie || kind == .episode {
        Section {
          NavigationLink {
            IOSTitleSubtitlesView(mediaID: mediaID, admin: admin)
          } label: {
            Label("Subtitles", systemImage: "captions.bubble")
          }
          .accessibilityIdentifier("editor-subtitles")
          if model.capabilities?.supportsMediaSegments == true {
            NavigationLink {
              IOSTitleSegmentsView(mediaID: mediaID, admin: admin)
            } label: {
              Label("Intro and Credits", systemImage: "forward.end")
            }
            .accessibilityIdentifier("editor-segments")
          }
        } footer: {
          Text("These change the title right away, without Save.")
        }
      }
    }
    .disabled(saving)
  }

  private func tagSection(
    _ title: String, key: WritableKeyPath<IOSMediaEditorValues, [String]>, field: String,
    entry: Binding<String>, placeholder: String
  ) -> some View {
    Section {
      ForEach(draft.values[keyPath: key], id: \.self) { value in Text(value) }
        .onDelete { offsets in
          var values = draft.values[keyPath: key]
          values.remove(atOffsets: offsets)
          draft.set(key, values, field: field)
        }
      HStack {
        TextField(placeholder, text: entry)
          .onSubmit {
            draft.add(entry.wrappedValue, to: key, field: field)
            entry.wrappedValue = ""
          }
        Button("Add") {
          draft.add(entry.wrappedValue, to: key, field: field)
          entry.wrappedValue = ""
        }
        .disabled(entry.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    } header: {
      Text(title)
    } footer: {
      automaticButton([field])
    }
  }

  private var shownCredits: [IOSEditorCredit] {
    let query = personQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let matching =
      query.isEmpty
      ? draft.values.credits
      : draft.values.credits.filter {
        $0.name.localizedCaseInsensitiveContains(query)
          || ($0.character ?? "").localizedCaseInsensitiveContains(query)
      }
    return Array(matching.prefix(peopleShown))
  }

  private var peopleSection: some View {
    Section {
      if draft.values.credits.count > 10 {
        TextField("Find a Person", text: $personQuery).textInputAutocapitalization(.never)
      }
      ForEach(shownCredits) { credit in
        Button {
          editingCredit = credit
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(credit.name.isEmpty ? "No Name" : credit.name).foregroundStyle(.primary)
            Text(credit.role).font(.footnote).foregroundStyle(.secondary)
          }
        }
        .swipeActions {
          Button("Remove", role: .destructive) {
            draft.set(
              \.credits, draft.values.credits.filter { $0.id != credit.id }, field: "credits")
          }
        }
      }
      if draft.values.credits.count > peopleShown, personQuery.isEmpty {
        Button("Show More") { peopleShown += 50 }
      }
      Button("Add Person", systemImage: "person.badge.plus") {
        editingCredit = IOSEditorCredit(
          id: UUID(), name: "", department: "Acting", job: nil, character: nil, profile: nil)
      }
    } header: {
      Text("Cast and Crew")
    } footer: {
      problems(["credits"])
      automaticButton(["credits"])
    }
  }

  private var artworkSection: some View {
    Section {
      artworkRow("Poster", field: "poster", selection: $posterItem)
      artworkRow("Backdrop", field: "backdrop", selection: $backdropItem)
      if uploading {
        HStack {
          ProgressView()
          Text("Uploading…").foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Artwork")
    } footer: {
      Text("Choose a photo and crop it. JPEG or PNG, made smaller here when needed.")
      automaticButton(["poster", "backdrop"])
    }
  }

  private func artworkRow(_ label: String, field: String, selection: Binding<PhotosPickerItem?>)
    -> some View
  {
    HStack(spacing: 14) {
      Group {
        if let image = previews[field] {
          Image(uiImage: image).resizable().scaledToFill()
        } else {
          Rectangle().fill(IOSDesign.raised)
            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
      }
      .frame(width: field == "poster" ? 48 : 96, height: field == "poster" ? 72 : 54)
      .clipShape(RoundedRectangle(cornerRadius: 6))
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
        Text(draft.isManual(field) ? "Chosen here" : "Found by the server")
          .font(.footnote).foregroundStyle(.secondary)
      }
      Spacer()
      PhotosPicker(selection: selection, matching: .images) {
        Text("Choose…")
      }
      .disabled(uploading)
      .accessibilityIdentifier("editor-\(field)")
    }
    .task(id: artworkKey(field)) { await loadPreview(field) }
  }

  private var fileSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Text(draft.source ?? draft.document?.relativeSourcePath ?? "")
          .font(.footnote.monospaced()).textSelection(.enabled)
        if draft.source != nil {
          Text("Saved with the other changes.").font(.footnote).foregroundStyle(.secondary)
        }
      }
      if kind == .movie || kind == .episode {
        Button("Choose Another File…", systemImage: "doc.badge.arrow.up") { choosingFile = true }
      }
    } header: {
      Text("Video File")
    } footer: {
      Text("Aurelia only reads the file; it is never moved or changed.")
    }
  }

  @ViewBuilder
  private func problems(_ fields: [String]) -> some View {
    let messages = fields.compactMap { draft.problems[$0] }
    if !messages.isEmpty {
      Text(messages.joined(separator: " ")).foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private func automaticButton(_ fields: [String]) -> some View {
    let manual = fields.filter(draft.isManual)
    if !manual.isEmpty {
      Button("Use Found Values") {
        for field in manual { draft.useAutomatic(field) }
      }
      .font(.footnote)
    }
  }

  // MARK: Actions

  private func load() async {
    loadError = nil
    do {
      let document = try await admin.run { try await $0.mediaEditor(id: mediaID) }
      draft.load(document)
    } catch is CancellationError {
      loadError = "Management stayed locked."
    } catch {
      loadError = IOSAdministrationModel.message(error)
    }
  }

  private func save() async {
    guard let request = draft.request else { return }
    saving = true
    defer { saving = false }
    let id = mediaID
    do {
      let saved = try await admin.run { try await $0.saveMediaEditor(id: id, request) }
      draft.uploads.removeAll()
      draft.load(saved)
      model.scheduleLibraryRefresh()
      dismiss()
    } catch is CancellationError {
    } catch let failure as IOSCoreError where failure.problemCode == "editor_conflict" {
      admin.alert =
        "This title was changed on another device. Copy what you want to keep, then cancel and open Edit again."
    } catch {
      admin.alert = IOSAdministrationModel.message(error)
    }
  }

  private func close() {
    let uploads = draft.uploads
    let id = mediaID
    if !uploads.isEmpty, let client = model.client {
      Task {
        for upload in uploads { try? await client.discardMediaEditorImage(id: id, upload: upload) }
      }
    }
    dismiss()
  }

  private func pick(_ item: PhotosPickerItem?, field: String) {
    guard let item else { return }
    if field == "poster" { posterItem = nil } else { backdropItem = nil }
    Task {
      guard let data = try? await item.loadTransferable(type: Data.self),
        let image = IOSPhotoCrop.uprightImage(data)
      else {
        admin.alert = "This picture could not be opened."
        return
      }
      cropping = CropRequest(field: field, image: IOSEditorImage.scaled(image))
    }
  }

  private func upload(_ image: CGImage, field: String, crop: IOSArtworkCrop) async {
    guard let jpeg = IOSRectCrop.jpegUploadData(image), jpeg.count <= IOSEditorImage.maximumBytes
    else {
      admin.alert = "This picture is too large. Choose a smaller one."
      return
    }
    uploading = true
    defer { uploading = false }
    let id = mediaID
    do {
      let uploaded = try await admin.run { try await $0.uploadMediaEditorImage(id: id, jpeg: jpeg) }
      draft.uploads.append(uploaded.id)
      let artwork = IOSEditorArtwork(
        assetId: nil, uploadId: uploaded.id,
        crop: IOSEditorCrop(x: crop.x, y: crop.y, width: crop.width, height: crop.height))
      if field == "poster" {
        draft.set(\.poster, artwork, field: "poster")
      } else {
        draft.set(\.backdrop, artwork, field: "backdrop")
      }
      if let cropped = image.cropping(
        to: CGRect(
          x: Double(image.width) * crop.x, y: Double(image.height) * crop.y,
          width: Double(image.width) * crop.width, height: Double(image.height) * crop.height))
      {
        previews[field] = UIImage(cgImage: cropped)
      }
    } catch is CancellationError {
    } catch {
      admin.alert = IOSAdministrationModel.message(error)
    }
  }

  private func artworkKey(_ field: String) -> String {
    let artwork = field == "poster" ? draft.values.poster : draft.values.backdrop
    return "\(field)-\(artwork?.assetId?.uuidString ?? "")-\(artwork?.uploadId?.uuidString ?? "")"
  }

  /// The stored artwork's picture; a fresh upload shows its cropped preview instead.
  private func loadPreview(_ field: String) async {
    let artwork = field == "poster" ? draft.values.poster : draft.values.backdrop
    guard let artwork, artwork.uploadId == nil, artwork.assetId != nil, let client = model.client
    else {
      if artwork == nil { previews[field] = nil }
      return
    }
    let id = mediaID
    if let data = try? await client.mediaEditorImage(id: id, artwork: artwork),
      let image = UIImage(data: data)
    {
      previews[field] = image
    }
  }
}

/// One person of Cast and Crew: name, department and their character or job.
private struct IOSCreditEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State var credit: IOSEditorCredit
  let done: (IOSEditorCredit) -> Void

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $credit.name).accessibilityIdentifier("credit-name")
        Picker("Department", selection: $credit.department) {
          ForEach(
            IOSMetadataDraft.departments
              + (IOSMetadataDraft.departments.contains(credit.department)
                ? [] : [credit.department]),
            id: \.self
          ) { Text($0).tag($0) }
        }
        if credit.department == "Acting" {
          TextField(
            "Character",
            text: Binding(
              get: { credit.character ?? "" }, set: { credit.character = $0.isEmpty ? nil : $0 }))
        } else {
          TextField(
            "Job",
            text: Binding(get: { credit.job ?? "" }, set: { credit.job = $0.isEmpty ? nil : $0 }))
        }
      }
      .navigationTitle(credit.name.isEmpty ? "Add Person" : credit.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            done(credit)
            dismiss()
          }
          .disabled(credit.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
    .presentationDetents([.medium])
  }
}

/// Another video file in the title's storage location, browsed folder by folder.
private struct IOSServerVideoPicker: View {
  @Environment(\.dismiss) private var dismiss
  let mediaID: UUID
  let admin: IOSAdministrationModel
  let chosen: (String) -> Void

  var body: some View {
    NavigationStack {
      IOSServerVideoFolder(mediaID: mediaID, path: "", admin: admin, chosen: chosen)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }
  }
}

private struct IOSServerVideoFolder: View {
  let mediaID: UUID
  let path: String
  let admin: IOSAdministrationModel
  let chosen: (String) -> Void
  @State private var listing: IOSServerFileListing?
  @State private var error: String?

  var body: some View {
    List {
      if let error { Text(error).foregroundStyle(.orange) }
      if let listing {
        if listing.entries.isEmpty { Text("This folder is empty.").foregroundStyle(.secondary) }
        ForEach(listing.entries) { entry in
          if entry.isDirectory {
            NavigationLink {
              IOSServerVideoFolder(
                mediaID: mediaID, path: entry.relativePath, admin: admin, chosen: chosen)
            } label: {
              Label(entry.name, systemImage: "folder")
            }
          } else {
            Button {
              chosen(entry.relativePath)
            } label: {
              HStack {
                Label(entry.name, systemImage: "film")
                Spacer()
                if let bytes = entry.bytes {
                  Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.footnote).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      } else if error == nil {
        ProgressView()
      }
    }
    .navigationTitle(path.isEmpty ? "Storage Location" : (path as NSString).lastPathComponent)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      let id = mediaID
      let folder = path
      do {
        listing = try await admin.run { try await $0.mediaEditorFiles(id: id, path: folder) }
      } catch is CancellationError {
      } catch {
        self.error = IOSAdministrationModel.message(error)
      }
    }
  }
}
