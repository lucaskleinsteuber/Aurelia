import SwiftUI

struct SceneNotesPopover: View {
  @ObservedObject var notes: SceneNotesController
  let currentPosition: () -> Int64
  let seek: (Int64) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Scene Notes", systemImage: "bookmark").font(.headline)
        Spacer()
        if notes.isLoading { ProgressView().controlSize(.small) }
        Button {
          notes.reload()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain).help("Reload scene notes without replacing your draft")
      }
      if notes.draft != nil {
        editor
      } else {
        Button("Mark Current Position", systemImage: "plus") { notes.create(at: currentPosition()) }
          .accessibilityIdentifier("scene-note-create")
      }
      if let error = notes.error {
        Text(error).font(.caption).foregroundStyle(.orange).fixedSize(
          horizontal: false, vertical: true)
      }
      Divider()
      if notes.notes.isEmpty {
        Text(notes.isLoading ? "Loading your notes…" : "No scene notes yet.")
          .font(.callout).foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(notes.notes) { note in
              HStack(alignment: .top) {
                Button {
                  seek(note.startMilliseconds)
                } label: {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(note.timeLabel).font(.caption.monospacedDigit()).foregroundStyle(
                      .secondary)
                    Text(note.text.isEmpty ? "Marked scene" : note.text).font(.callout).lineLimit(3)
                  }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).help("Jump to this scene")
                .accessibilityLabel(
                  "\(note.timeLabel), \(note.text.isEmpty ? "Marked scene" : note.text)"
                )
                .accessibilityIdentifier("scene-note-\(note.id.uuidString)")
                Menu {
                  Button("Edit") { notes.edit(note) }.disabled(notes.draft != nil)
                  Button("Remove", role: .destructive) { Task { await notes.remove(note) } }
                } label: {
                  Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).frame(width: 22).disabled(notes.isSaving)
              }
            }
          }
        }.frame(height: min(CGFloat(notes.notes.count) * 72, 180)).scrollIndicators(.hidden)
      }
      Text("Private to your profile. Playback keeps running.")
        .font(.caption2).foregroundStyle(.secondary)
    }
    .padding(16).frame(width: 330)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("scene-notes-popover")
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 9) {
      Picker("Mark", selection: binding(\.isRange, fallback: false)) {
        Text("Moment").tag(false)
        Text("Time Range").tag(true)
      }.pickerStyle(.segmented)
      timeInput("Start", value: binding(\.start, fallback: ""), id: "scene-note-start")
      if notes.draft?.isRange == true {
        timeInput("End", value: binding(\.end, fallback: ""), id: "scene-note-end")
      }
      TextField("Note (optional)", text: binding(\.text, fallback: ""), axis: .vertical)
        .lineLimit(3...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("scene-note-text")
      HStack {
        Button("Cancel") { notes.cancelDraft() }
        Spacer()
        Button("Save") { Task { await notes.save() } }
          .buttonStyle(.borderedProminent).disabled(notes.isSaving)
          .accessibilityIdentifier("scene-note-save")
      }
    }
    .disabled(notes.isSaving)
  }

  private func timeInput(_ label: String, value: Binding<String>, id: String) -> some View {
    HStack {
      Text(label).frame(width: 38, alignment: .leading).font(.caption)
      TextField("m:ss or h:mm:ss", text: value).textFieldStyle(.roundedBorder)
        .font(.body.monospacedDigit()).accessibilityIdentifier(id)
      Button {
        value.wrappedValue = SceneNoteTime.format(currentPosition())
      } label: {
        Image(systemName: "clock.arrow.circlepath")
      }.buttonStyle(.plain).help("Use current playback position")
    }
  }

  private func binding<Value>(
    _ keyPath: WritableKeyPath<SceneNotesController.Draft, Value>, fallback: Value
  ) -> Binding<Value> {
    Binding(
      get: { notes.draft?[keyPath: keyPath] ?? fallback },
      set: { value in
        guard var draft = notes.draft else { return }
        draft[keyPath: keyPath] = value
        notes.draft = draft
      })
  }
}
