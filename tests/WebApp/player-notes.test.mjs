import test from "node:test";
import assert from "node:assert/strict";
import { createSceneNotes, formatNoteTime, parseNoteTime, notePayload } from "../../src/Aurelia.Server/WebApp/js/player-notes.js";
import { ApiError } from "../../src/Aurelia.Server/WebApp/js/api.js";
import { installDOM, flush, deferred, all, button, input } from "./dom-fixture.mjs";
const note = { id: "note", revision: 7, startMilliseconds: 1500, endMilliseconds: 2500, text: "Synthetic scene" };
function fixture(t, overrides = {}) {
  installDOM(t);
  let panel, opened = false, notes = [], ended = 0;
  const seeks = [];
  const controller = createSceneNotes({ api: { sceneNotes: async () => [note], saveSceneNote: async () => ({}), removeSceneNote: async () => {}, ...overrides }, mediaId: "film",
    position: () => 123456, seek: (position) => seeks.push(position), show: (content) => { panel = content; opened = true; }, isOpen: () => opened,
    onNotes: (next) => { notes = next; }, onSessionEnded: () => { ended++; },
  });
  t.after(() => controller.close());
  return { controller, seeks, get panel() { return panel; }, get notes() { return notes; }, get ended() { return ended; } };
}
const change = (control, value, event = "input") => { control.value = value; control.dispatchEvent(new Event(event)); };
test("scene times round-trip moments and millisecond ranges with strict safe parsing", () => {
  for (const ms of [0, 1, 1234, 61000, 3599999, 3600000, 987654321]) assert.equal(parseNoteTime(formatNoteTime(ms)), ms);
  assert.equal(parseNoteTime(" 1:02:03.4 "), 3723400); assert.equal(parseNoteTime("12.05"), 12050);
  for (const value of ["", "-1", "1:60", "1:2:60", "1:60:00", "1::2", "1.0000", "1.", "1e3", "Infinity", "99999999999999999999"]) assert.equal(parseNoteTime(value), null, value);
  assert.throws(() => notePayload({ start: "1:00", end: "0:30", isRange: true }), /end after/);
  assert.throws(() => notePayload({ start: "0", text: "\0" }), /control/);
});
test("the real note editor creates a time range and saves exact times and revision", async (t) => {
  const writes = []; const f = fixture(t, { saveSceneNote: async (...args) => writes.push(args) });
  f.controller.open(); button(f.panel, "Mark Current Position").click();
  change(all(f.panel).find((node) => node.tagName === "SELECT"), "range", "change");
  change(input(f.panel, "Start"), "1:02.345"); change(input(f.panel, "End"), "1:10.005");
  change(all(f.panel).find((node) => node.tagName === "TEXTAREA"), " Private draft "); button(f.panel, "Save").click(); await flush();
  assert.equal(writes.length, 1); assert.equal(writes[0][0], "film");
  assert.deepEqual(writes[0][2], { startMilliseconds: 62345, endMilliseconds: 70005, text: "Private draft", revision: 0 });
  assert.equal(writes[0][3].signal.aborted, false);
});
test("reload preserves an unsaved text/time draft while updating the note list", async (t) => {
  let reads = 0; const f = fixture(t, { sceneNotes: async () => [{ ...note, text: `version ${++reads}` }] });
  await f.controller.reload(); f.controller.open(); button(f.panel, "Edit").click();
  change(input(f.panel, "Start"), "2:00.125"); change(all(f.panel).find((n) => n.tagName === "TEXTAREA"), "Unsaved wording");
  button(f.panel, "Reload").click(); await flush();
  assert.equal(input(f.panel, "Start").value, "2:00.125"); assert.equal(all(f.panel).find((n) => n.tagName === "TEXTAREA").value, "Unsaved wording");
  assert.equal(f.notes[0].text, "version 2");
});
test("load and delete failures stay visible and do not masquerade as an empty successful list", async (t) => {
  let fail = true; const f = fixture(t, { sceneNotes: async () => { if (fail) throw new Error("Synthetic load failure"); return [note]; }, removeSceneNote: async () => { throw new Error("Synthetic delete failure"); } });
  await f.controller.reload(); f.controller.open(); assert.match(f.panel.textContent, /Synthetic load failure/); assert.equal(f.panel.textContent.includes("No scene notes yet"), false);
  fail = false; button(f.panel, "Reload").click(); await flush(); button(f.panel, "Remove").click(); await flush();
  assert.match(f.panel.textContent, /Synthetic delete failure/); assert.equal(f.notes.length, 1);
});
test("a revision conflict retains the edited draft and never silently retries against a newer revision", async (t) => {
  const writes = []; const f = fixture(t, { saveSceneNote: async (_id, _note, body) => { writes.push(body); throw new ApiError(409, "scene_note_conflict", "The note changed on another device. Reload before saving."); } });
  await f.controller.reload(); f.controller.open(); button(f.panel, "Edit").click();
  change(all(f.panel).find((n) => n.tagName === "TEXTAREA"), "My unsaved wording"); button(f.panel, "Save").click(); await flush();
  assert.equal(writes.length, 1); assert.equal(writes[0].revision, 7); assert.match(f.panel.textContent, /another device/);
  assert.equal(all(f.panel).find((n) => n.tagName === "TEXTAREA").value, "My unsaved wording");
  button(f.panel, "Reload").click(); await flush(); assert.equal(writes.length, 1); assert.equal(input(f.panel, "Start").value, "0:01.500");
});
test("closing the Player aborts reads and writes and ignores late note responses", async (t) => {
  const pending = deferred(); let signal;
  const f = fixture(t, { sceneNotes: async (_id, options) => { signal = options.signal; return pending.promise; } });
  const load = f.controller.reload(); f.controller.open(); f.controller.close(); assert.equal(signal.aborted, true);
  pending.resolve([note]); await load; assert.deepEqual(f.notes, []);
});
test("removing a different note preserves the open draft and sends the listed revision", async (t) => {
  const deletes = []; const f = fixture(t, { removeSceneNote: async (...args) => deletes.push(args) });
  await f.controller.reload(); f.controller.open(); button(f.panel, "Mark Current Position").click();
  change(all(f.panel).find((n) => n.tagName === "TEXTAREA"), "Still drafting"); button(f.panel, "Remove").click(); await flush();
  assert.equal(deletes[0][2], 7); assert.equal(all(f.panel).find((n) => n.tagName === "TEXTAREA").value, "Still drafting");
});
test("profile session expiry leaves the notes controller for the app's existing sign-in flow", async (t) => {
  const f = fixture(t, { sceneNotes: async () => { throw new ApiError(401, "profile_expired", "Sign in again"); } });
  await f.controller.reload(); assert.equal(f.ended, 1);
});
test("closing during a save aborts the write and a late completion cannot reload or reopen notes", async (t) => {
  const pending = deferred(); let signal, reads = 0;
  const f = fixture(t, { sceneNotes: async () => { reads++; return [note]; }, saveSceneNote: async (_id, _note, _body, options) => { signal = options.signal; return pending.promise; } });
  await f.controller.reload(); f.controller.open(); button(f.panel, "Edit").click(); button(f.panel, "Save").click(); await flush();
  f.controller.close(); assert.equal(signal.aborted, true); pending.resolve({}); await flush(); assert.equal(reads, 1);
});
test("a newer reload cancels the prior read and its late completion cannot replace the list or draft", async (t) => {
  const first = deferred(); let reads = 0, oldSignal;
  const f = fixture(t, { sceneNotes: async (_id, options) => { if (++reads === 1) { oldSignal = options.signal; return first.promise; } return [{ ...note, text: "Fresh list" }]; } });
  const old = f.controller.reload(); f.controller.open(); button(f.panel, "Mark Current Position").click();
  change(all(f.panel).find((n) => n.tagName === "TEXTAREA"), "Private draft"); await f.controller.reload(); assert.equal(oldSignal.aborted, true);
  first.resolve([{ ...note, text: "Stale list" }]); await old;
  assert.equal(f.notes[0].text, "Fresh list"); assert.equal(all(f.panel).find((n) => n.tagName === "TEXTAREA").value, "Private draft");
});
