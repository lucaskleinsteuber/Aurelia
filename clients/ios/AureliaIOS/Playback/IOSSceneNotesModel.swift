import Foundation

/// Scene notes of the playing title: loaded when it opens, shown at their moment, added, edited
/// and deleted with the server's revisions. A conflict never overwrites another device's edit.
@MainActor
final class IOSSceneNotesModel: ObservableObject {
  @Published private(set) var notes: [IOSSceneNote] = []
  @Published private(set) var message: String?
  @Published private(set) var working = false
  private let api: IOSAPIClient
  private(set) var mediaID: UUID

  init(api: IOSAPIClient, mediaID: UUID) {
    self.api = api
    self.mediaID = mediaID
  }

  var sorted: [IOSSceneNote] { notes.sorted { $0.startMilliseconds < $1.startMilliseconds } }

  func cue(at position: Int64) -> IOSSceneNote? { IOSSceneNotePolicy.cue(notes, position: position) }

  /// Another title opened in the player (the next episode).
  func show(mediaID: UUID) async {
    guard mediaID != self.mediaID || notes.isEmpty else { return }
    self.mediaID = mediaID
    notes = []
    await reload()
  }

  func reload() async {
    do {
      notes = try await api.sceneNotes(mediaID: mediaID)
      message = nil
    } catch {
      message = "Scene notes could not be loaded."
    }
  }

  /// A note at `start` (a moment) or from `start` to `end`.
  func add(text: String, start: Int64, end: Int64?) async -> Bool {
    guard let text = IOSSceneNotePolicy.cleaned(text) else { return false }
    return await save(
      id: UUID(),
      IOSSaveSceneNote(
        startMilliseconds: max(0, start), endMilliseconds: end.map { max(start, $0) }, text: text,
        revision: 0))
  }

  func update(_ note: IOSSceneNote, text: String) async -> Bool {
    guard let text = IOSSceneNotePolicy.cleaned(text) else { return false }
    return await save(
      id: note.id,
      IOSSaveSceneNote(
        startMilliseconds: note.startMilliseconds, endMilliseconds: note.endMilliseconds,
        text: text, revision: note.revision))
  }

  func delete(_ note: IOSSceneNote) async {
    working = true
    defer { working = false }
    do {
      try await api.deleteSceneNote(mediaID: mediaID, noteID: note.id, revision: note.revision)
      notes.removeAll { $0.id == note.id }
      message = nil
    } catch {
      message = "The note could not be deleted. It may have changed on another device; Reload shows the latest."
    }
  }

  private func save(id: UUID, _ request: IOSSaveSceneNote) async -> Bool {
    working = true
    defer { working = false }
    do {
      let saved = try await api.saveSceneNote(mediaID: mediaID, noteID: id, request)
      notes.removeAll { $0.id == saved.id }
      notes.append(saved)
      message = nil
      return true
    } catch {
      message = "The note could not be saved. It may have changed on another device; Reload shows the latest."
      return false
    }
  }
}
