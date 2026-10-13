import Foundation
import Testing

@testable import Aurelia

@MainActor
struct SceneNotesControllerTests {
  @Test func failedSavePreservesEditableDraftAndSuccessfulRetryAcknowledgesRevision() async throws {
    let client = NotesClientProbe()
    let media = UUID()
    let controller = SceneNotesController(client: client, mediaId: media)
    controller.create(at: 330_000)
    controller.draft?.text = "Synthetic private note"
    let draft = try #require(controller.draft)
    client.failure = APIClientError.httpFailure(
      status: 503, retryAfter: nil, code: nil, message: nil)
    await controller.save()
    #expect(controller.draft == draft)
    #expect(controller.error != nil && !controller.isSaving)
    client.failure = nil
    await controller.save()
    #expect(controller.draft == nil && controller.error == nil)
    #expect(controller.notes.count == 1)
    #expect(controller.notes.first?.id == draft.id && controller.notes.first?.revision == 1)
    #expect(client.savedMedia == [media, media])
  }

  @Test func lateSaveAfterProfileOrPlayerRetirementCannotRestorePrivateState() async throws {
    let client = NotesClientProbe()
    client.delaySave = true
    let controller = SceneNotesController(client: client, mediaId: UUID())
    controller.create(at: 15_000)
    controller.draft?.text = "Retired profile note"
    let saving = Task { await controller.save() }
    try await wait { client.pendingSave != nil }
    controller.stop()
    client.completeSave()
    await saving.value
    #expect(controller.notes.isEmpty && controller.draft == nil && controller.error == nil)
    #expect(!controller.isSaving && controller.cueText == nil)
  }

  @Test func cancelDiscardsDraftButDoesNotDeleteAnExistingSavedNote() async throws {
    let client = NotesClientProbe()
    let controller = SceneNotesController(client: client, mediaId: UUID())
    controller.create(at: 17_123)
    controller.draft?.text = "Saved note"
    await controller.save()
    let note = try #require(controller.notes.first)
    controller.edit(note)
    controller.draft?.text = "Unsaved edit"
    controller.cancelDraft()
    #expect(controller.draft == nil && controller.notes == [note])
    controller.create(at: 42_000)
    controller.cancelDraft()
    #expect(controller.draft == nil && controller.notes == [note])
  }

  @Test func mediaChangeCancelsOldLoadWithoutReplacingTheNewTitlesNotes() async throws {
    let client = NotesClientProbe()
    client.delayLoads = true
    let oldMedia = UUID()
    let newMedia = UUID()
    let controller = SceneNotesController(client: client, mediaId: oldMedia)
    controller.reload()
    try await wait { client.loads[oldMedia] != nil }
    controller.create(at: 9_000)
    controller.draft?.text = "Old title draft"
    controller.changeMedia(newMedia)
    try await wait { client.loads[newMedia] != nil }
    let currentNote = note(media: newMedia, text: "Current title note")
    client.loads.removeValue(forKey: newMedia)?.resume(returning: [currentNote])
    try await wait { controller.notes == [currentNote] }
    client.loads.removeValue(forKey: oldMedia)?.resume(
      returning: [note(media: oldMedia, text: "Stale private note")])
    await Task.yield()
    #expect(controller.notes == [currentNote] && controller.draft == nil)
    #expect(!controller.isLoading && controller.error == nil)
    controller.stop()
  }

  private func note(media: UUID, text: String) -> SceneNote {
    SceneNote(
      id: UUID(), mediaId: media, startMilliseconds: 10_000,
      endMilliseconds: nil, text: text, revision: 1)
  }

  private func wait(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition() {
      try #require(ContinuousClock.now < deadline, "The controlled note request did not start.")
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

@MainActor
private final class NotesClientProbe: SceneNotesClient {
  var failure: APIClientError?
  var delaySave = false
  var delayLoads = false
  var pendingSave: CheckedContinuation<SceneNote, any Error>?
  var loads: [UUID: CheckedContinuation<[SceneNote], any Error>] = [:]
  var savedMedia: [UUID] = []
  private var savedNote: SceneNote?

  func sceneNotes(mediaId: UUID) async throws -> [SceneNote] {
    if delayLoads {
      return try await withCheckedThrowingContinuation { loads[mediaId] = $0 }
    }
    return []
  }
  func saveSceneNote(
    mediaId: UUID, id: UUID, start: Int64, end: Int64?, text: String, revision: Int64
  ) async throws -> SceneNote {
    savedMedia.append(mediaId)
    if let failure { throw failure }
    let note = SceneNote(
      id: id, mediaId: mediaId, startMilliseconds: start,
      endMilliseconds: end, text: text, revision: revision + 1)
    if delaySave {
      savedNote = note
      return try await withCheckedThrowingContinuation { pendingSave = $0 }
    }
    return note
  }
  func removeSceneNote(mediaId: UUID, note: SceneNote) async throws {}
  func completeSave() {
    if let savedNote { pendingSave?.resume(returning: savedNote) }
    pendingSave = nil
  }
}
