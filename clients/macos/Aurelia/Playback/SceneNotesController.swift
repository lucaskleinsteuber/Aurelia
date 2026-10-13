import Combine
import Foundation

@MainActor
protocol SceneNotesClient: Sendable {
  func sceneNotes(mediaId: UUID) async throws -> [SceneNote]
  func saveSceneNote(
    mediaId: UUID, id: UUID, start: Int64, end: Int64?, text: String, revision: Int64
  ) async throws -> SceneNote
  func removeSceneNote(mediaId: UUID, note: SceneNote) async throws
}

extension APIClient: SceneNotesClient {}

@MainActor
final class SceneNotesController: ObservableObject {
  struct Draft: Equatable {
    let id: UUID
    let revision: Int64
    var start: String
    var end: String
    var isRange: Bool
    var text: String
  }

  @Published private(set) var notes: [SceneNote] = []
  @Published var draft: Draft?
  @Published private(set) var error: String?
  @Published private(set) var isLoading = false
  @Published private(set) var isSaving = false
  @Published private(set) var cueText: String?
  private let client: any SceneNotesClient
  private var mediaId: UUID
  private var generation = UUID()
  private var cuePolicy = SceneNoteCuePolicy()
  private var cueTask: Task<Void, Never>?
  private var loadTask: Task<Void, Never>?

  init(profile: StoredServerProfile, mediaId: UUID) {
    client = APIClient(profile: profile)
    self.mediaId = mediaId
  }

  init(client: any SceneNotesClient, mediaId: UUID) {
    self.client = client
    self.mediaId = mediaId
  }

  func changeMedia(_ id: UUID) {
    guard id != mediaId else { return }
    stop()
    mediaId = id
    notes = []
    draft = nil
    error = nil
    cuePolicy.reset()
    reload()
  }

  func reload() {
    loadTask?.cancel()
    let expected = generation
    let id = mediaId
    loadTask = Task { [weak self] in
      guard let self else { return }
      isLoading = true
      defer { if generation == expected { isLoading = false } }
      do {
        let result = try await client.sceneNotes(mediaId: id)
        guard !Task.isCancelled, generation == expected else { return }
        notes = result
        if !isSaving { error = nil }
      } catch {
        guard !Task.isCancelled, generation == expected else { return }
        if let denied = error as? APIClientError,
          denied.isAuthenticationFailure || denied.httpStatus == 404
        {
          notes = []
          draft = nil
          hideCue()
        }
        self.error = error.localizedDescription
      }
    }
  }

  func create(at milliseconds: Int64) {
    guard draft == nil else { return }
    draft = Draft(
      id: UUID(), revision: 0, start: SceneNoteTime.format(milliseconds), end: "", isRange: false,
      text: "")
    error = nil
  }

  func edit(_ note: SceneNote) {
    draft = Draft(
      id: note.id, revision: note.revision, start: SceneNoteTime.format(note.startMilliseconds),
      end: note.endMilliseconds.map(SceneNoteTime.format) ?? "",
      isRange: note.endMilliseconds != nil, text: note.text)
    error = nil
  }

  func cancelDraft() {
    draft = nil
    error = nil
  }

  func save() async {
    guard !isSaving, let current = draft, let start = SceneNoteTime.parse(current.start),
      current.text.utf16.count <= 2000,
      !current.isRange || SceneNoteTime.parse(current.end).map({ $0 > start }) == true
    else {
      error =
        "Enter a valid time (m:ss or h:mm:ss), an end after the start, and at most 2,000 characters."
      return
    }
    let expected = generation
    isSaving = true
    defer { if generation == expected { isSaving = false } }
    do {
      let saved = try await client.saveSceneNote(
        mediaId: mediaId, id: current.id, start: start,
        end: current.isRange ? SceneNoteTime.parse(current.end) : nil, text: current.text,
        revision: current.revision)
      guard generation == expected else { return }
      notes.removeAll { $0.id == saved.id }
      notes.append(saved)
      notes.sort { $0.startMilliseconds < $1.startMilliseconds }
      // A user can continue typing while the network request is in flight.
      if draft == current {
        draft = nil
      } else if var newer = draft, newer.id == saved.id {
        newer = Draft(
          id: newer.id, revision: saved.revision, start: newer.start, end: newer.end,
          isRange: newer.isRange, text: newer.text)
        draft = newer
      }
      error = nil
    } catch {
      if generation == expected { self.error = error.localizedDescription }
    }
  }

  func remove(_ note: SceneNote) async {
    guard !isSaving else { return }
    let expected = generation
    isSaving = true
    defer { if generation == expected { isSaving = false } }
    do {
      try await client.removeSceneNote(mediaId: mediaId, note: note)
      guard generation == expected else { return }
      notes.removeAll { $0.id == note.id }
      if draft?.id == note.id { draft = nil }
      error = nil
    } catch {
      if generation == expected { self.error = error.localizedDescription }
    }
  }

  func seek() {
    cuePolicy.seek()
    hideCue()
  }
  func advance(position: Int64, playing: Bool, preparing: Bool) {
    let due = cuePolicy.advance(to: position, playing: playing, preparing: preparing, notes: notes)
    guard !due.isEmpty else { return }
    hideCue()
    cueText = due.prefix(3).map { $0.text.isEmpty ? "Marked scene · \($0.timeLabel)" : $0.text }
      .joined(separator: "\n")
    if due.count > 3 { cueText? += "\n+\(due.count - 3) more notes" }
    let expected = generation
    cueTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled, self?.generation == expected else { return }
      self?.cueText = nil
    }
  }

  func stop() {
    generation = UUID()
    loadTask?.cancel()
    loadTask = nil
    isLoading = false
    isSaving = false
    notes = []
    draft = nil
    error = nil
    cuePolicy.reset()
    hideCue()
  }

  private func hideCue() {
    cueTask?.cancel()
    cueTask = nil
    cueText = nil
  }
}
