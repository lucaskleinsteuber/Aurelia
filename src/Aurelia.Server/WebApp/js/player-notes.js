// Private scene-note editing, tied to one Player lifetime. Reload changes the list while keeping
// the draft and its revision; conflicts require an explicit new edit, never a silent overwrite.
import { h, icon } from "./dom.js";
import { sessionRefused } from "./logic.js";

export function formatNoteTime(milliseconds) {
  const value = Number.isSafeInteger(milliseconds) && milliseconds > 0 ? milliseconds : 0;
  const seconds = Math.floor(value / 1000);
  const pad = (number) => String(number).padStart(2, "0");
  const base = seconds >= 3600 ? `${Math.floor(seconds / 3600)}:${pad(Math.floor(seconds / 60) % 60)}:${pad(seconds % 60)}` : `${Math.floor(seconds / 60)}:${pad(seconds % 60)}`;
  return value % 1000 ? `${base}.${String(value % 1000).padStart(3, "0")}` : base;
}
export function parseNoteTime(text) {
  const parts = String(text).trim().split(":");
  if (parts.length < 1 || parts.length > 3) return null;
  let seconds = 0;
  for (let index = 0; index < parts.length; index++) {
    const final = index === parts.length - 1;
    const match = (final ? /^(\d+)(?:\.(\d{1,3}))?$/ : /^(\d+)$/).exec(parts[index]);
    if (!match) return null;
    const whole = Number(match[1]);
    if (!Number.isSafeInteger(whole) || (index > 0 && whole >= 60)) return null;
    seconds = seconds * 60 + whole;
    if (!Number.isSafeInteger(seconds)) return null;
    if (final) {
      const value = seconds * 1000 + Number((match[2] ?? "").padEnd(3, "0"));
      return Number.isSafeInteger(value) ? value : null;
    }
  }
  return null;
}
export function notePayload(draft) {
  const start = parseNoteTime(draft.start);
  const end = draft.isRange ? parseNoteTime(draft.end) : null;
  if (start == null || (draft.isRange && (end == null || end <= start))) throw new Error("Enter a valid start time and an end after the start (m:ss or h:mm:ss).");
  const text = String(draft.text ?? "").trim();
  if (text.length > 2000 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/.test(text)) throw new Error("Use a note of up to 2000 characters without control characters.");
  return { startMilliseconds: start, endMilliseconds: end, text, revision: draft.revision ?? 0 };
}
export function createSceneNotes({ api, mediaId, position, seek, show, isOpen, onNotes, onSessionEnded }) {
  const lifetime = new AbortController();
  let generation = 0;
  let request;
  let draft = null;
  let notes = [];
  let error = "";
  let loading = false;
  let saving = false;
  const alive = () => !lifetime.signal.aborted;
  const redraw = () => { if (alive() && isOpen()) open(); };
  function problem(value) {
    if (!alive() || value?.name === "AbortError") return;
    if (sessionRefused(value?.status, value?.code)) { onSessionEnded?.(value); return; }
    error = value.message || "Scene notes could not be loaded. Try again.";
  }
  async function reload() {
    if (!alive()) return;
    request?.abort();
    const own = new AbortController(); request = own;
    const mine = ++generation;
    loading = true; error = ""; redraw();
    try {
      const result = await api.sceneNotes(mediaId, { signal: own.signal });
      if (!alive() || own.signal.aborted || mine !== generation) return;
      if (!Array.isArray(result)) throw new Error("The server returned unreadable scene notes. Try again.");
      notes = result;
      onNotes(notes);
    } catch (value) { if (mine === generation && !own.signal.aborted) problem(value); }
    finally { if (alive() && mine === generation) { loading = false; redraw(); } }
  }
  async function write(work, finishDraft = false) {
    if (!alive() || saving) return;
    saving = true; error = ""; redraw();
    try {
      await work(lifetime.signal);
      if (!alive()) return;
      if (finishDraft) draft = null;
      await reload();
    } catch (value) { problem(value); }
    finally { if (alive()) { saving = false; redraw(); } }
  }
  function edit(note) {
    if (saving || !alive()) return;
    draft = { id: note.id, revision: note.revision ?? 0, start: formatNoteTime(note.startMilliseconds), end: note.endMilliseconds == null ? "" : formatNoteTime(note.endMilliseconds), isRange: note.endMilliseconds != null, text: note.text ?? "" };
    error = ""; open();
  }
  function open() {
    if (!alive()) return;
    const reloadButton = h("button", { class: "text-button", disabled: saving || loading, onclick: () => reload() }, loading ? "Loading…" : "Reload");
    const content = [h("div", { class: "notes-header" }, h("span", {}, icon("bookmark", { size: 16 }), " Scene Notes"), reloadButton)];
    if (error) content.push(h("p", { class: "error-text", role: "alert" }, error));
    if (draft) {
      const field = (label, key) => {
        const input = h("input", { class: "text-field", value: draft[key], placeholder: "m:ss or h:mm:ss", disabled: saving, "aria-label": label, maxlength: "30", oninput: () => { draft[key] = input.value; } });
        return h("label", { class: "editor-field" }, h("span", { class: "editor-field-title" }, label),
          h("div", { class: "button-row" }, input, h("button", { class: "text-button", disabled: saving, onclick: () => { draft[key] = formatNoteTime(Math.round(position())); open(); }, "aria-label": `Use current position for ${label}` }, "Use Current")));
      };
      const kind = h("select", { class: "select", disabled: saving, "aria-label": "Mark", onchange: () => { draft.isRange = kind.value === "range"; open(); } },
        h("option", { value: "moment", selected: !draft.isRange }, "Moment"), h("option", { value: "range", selected: draft.isRange }, "Time Range"));
      const text = h("textarea", { class: "notes-text", rows: "3", maxlength: "2000", placeholder: "Note (optional)", disabled: saving, "aria-label": "Note", oninput: () => { draft.text = text.value; } }, draft.text);
      // Set the value explicitly as well: a freshly rendered textarea must keep an unsaved draft.
      text.value = draft.text;
      const save = () => {
        try {
          const body = notePayload(draft), id = draft.id;
          write((signal) => api.saveSceneNote(mediaId, id, body, { signal }), true);
        } catch (value) { problem(value); open(); }
      };
      content.push(h("div", { class: "notes-editor" }, kind, field("Start", "start"), draft.isRange ? field("End", "end") : null, text,
        h("div", { class: "notes-actions" }, h("button", { class: "secondary-button small", disabled: saving, onclick: () => { draft = null; error = ""; open(); } }, "Cancel"),
          h("button", { class: "primary-button small", disabled: saving, onclick: save }, saving ? "Saving…" : "Save"))));
    } else content.push(h("button", { class: "secondary-button small notes-create", disabled: saving, onclick: () => edit({ id: crypto.randomUUID(), startMilliseconds: Math.round(position()), revision: 0 }) }, icon("plus", { size: 15 }), "Mark Current Position"));
    content.push(h("div", { class: "menu-divider" }));
    if (!notes.length) content.push(h("p", { class: "notes-empty" }, loading ? "Loading your notes…" : error ? "Your notes could not be refreshed." : "No scene notes yet."));
    const rows = [];
    for (const note of notes) {
      const label = `${formatNoteTime(note.startMilliseconds)}${note.endMilliseconds == null ? "" : `–${formatNoteTime(note.endMilliseconds)}`}`;
      rows.push(h("div", { class: "note-row" }, h("button", { class: "note-jump", onclick: () => seek(note.startMilliseconds) }, h("span", { class: "note-when" }, label), h("span", { class: "note-text" }, note.text || "Scene note")),
        h("div", { class: "notes-actions" }, h("button", { class: "text-button", disabled: saving, onclick: () => edit(note) }, "Edit"),
          h("button", { class: "text-button", disabled: saving, onclick: () => write((signal) => api.removeSceneNote(mediaId, note.id, note.revision, { signal })) }, "Remove"))));
    }
    if (rows.length) content.push(h("div", { class: "notes-list" }, rows));
    content.push(h("p", { class: "notes-footnote" }, "Private to your profile. Playback keeps running."));
    show(h("div", { class: "notes-panel" }, content));
  }
  return { reload, open, close: () => { lifetime.abort(); request?.abort(); generation++; } };
}
