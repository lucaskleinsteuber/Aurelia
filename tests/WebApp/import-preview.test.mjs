// The browser's Import Preview with an invented storage location; no browser, network or files.
import test from "node:test";
import assert from "node:assert/strict";
import { createManagementEditors } from "../../src/Aurelia.Server/WebApp/js/settings-editors.js";
import { createImportPreview } from "../../src/Aurelia.Server/WebApp/js/import-preview.js";
import {
  importAssignmentChanges, importChoicesFor, importEditorStart, importPreviewRows, libraryPayload, loadImportPreview,
} from "../../src/Aurelia.Server/WebApp/js/logic.js";
import { installDOM, all, button, flush } from "./dom-fixture.mjs";

const items = [
  { relativePath: "Invented Show", title: "Invented Show", kind: "series", status: "recognized", reason: "", isDirectory: true },
  { relativePath: "Invented Show/S01E01.mkv", title: "Pilot", kind: "episode", seasonNumber: 1, episodeNumber: 1, status: "recognized", reason: "" },
  { relativePath: "Invented Show/bonus.mkv", title: "bonus", kind: null, status: "pending", reason: "No episode number." },
  { relativePath: "Invented Film (1999).mkv", title: "Invented Film", kind: "movie", status: "recognized", reason: "" },
];
const targets = [
  { relativePath: "Invented Show", title: "Invented Show", kind: "series", seasonNumbers: [1] },
  { relativePath: "Invented Film (1999).mkv", title: "Invented Film", kind: "movie", seasonNumbers: [] },
];
const counts = { files: 3, movies: 1, series: 1, episodes: 1, extras: 0, trailers: 0, pending: 1, ignored: 0, errors: 0 };

test("rows follow the folders, search and the filter, and Manual shows what a rule covers", () => {
  assert.deepEqual(importPreviewRows(items).map((row) => [row.item.title, row.depth]),
    [["Invented Film", 0], ["Invented Show", 0], ["bonus", 1], ["Pilot", 1]]);
  assert.deepEqual(importPreviewRows(items, { filter: "pending" }).map((row) => row.item.title), ["bonus"]);
  assert.deepEqual(importPreviewRows(items, { search: "PILOT" }).map((row) => row.item.title), ["Pilot"]);
  const rules = [{ relativePath: "Invented Show", isDirectory: true }];
  assert.deepEqual(importPreviewRows(items, { filter: "saved", assignments: rules }).map((row) => row.item.title), ["Invented Show", "bonus", "Pilot"]);
});

test("assignments offer only sensible kinds and check what each needs", () => {
  assert.deepEqual(importChoicesFor([items[2]]).map(([value]) => value), ["movie", "episode", "extra", "trailer", "ignore"]);
  assert.deepEqual(importChoicesFor([items[0]]).map(([value]) => value), ["movie", "series", "extra", "trailer", "ignore"]);
  assert.equal(importEditorStart([items[2]]).choice, "extra", "an unknown file starts as an extra");
  const form = { choice: "episode", parentPath: "Invented Show", entireSeries: false, season: "1", episode: "7", category: "", title: " Bonus Episode " };
  assert.deepEqual(importAssignmentChanges([items[2]], form, targets), [{
    relativePath: "Invented Show/bonus.mkv", isDirectory: false, kind: "episode", parentRelativePath: "Invented Show",
    seasonNumber: 1, episodeNumber: 7, category: null, title: "Bonus Episode" }]);
  assert.throws(() => importAssignmentChanges([items[2]], { ...form, parentPath: "" }, targets), /belongs to/);
  assert.throws(() => importAssignmentChanges([items[2]], { ...form, parentPath: "Invented Film (1999).mkv" }, targets), /series/);
  assert.throws(() => importAssignmentChanges([items[2]], { ...form, episode: "0" }, targets), /episode number/);
  assert.throws(() => importAssignmentChanges([items[2]], { ...form, season: "1e2" }, targets), /season number/);
  const ignored = importAssignmentChanges([items[2], items[3]], { ...form, choice: "ignore" }, targets);
  assert.deepEqual(ignored.map((change) => [change.kind, change.parentRelativePath, change.title]), [[null, null, null], [null, null, null]]);
  assert.equal(libraryPayload({ path: "/srv/media", review: true }).requireImportPreview, true);
});

test("every page of a preview is read, and a preview that changed meanwhile is refused", async () => {
  const pages = [{ summary: { revision: "1" }, items: items.slice(0, 2), totalCount: 4 }, { summary: { revision: "1" }, items: items.slice(2), totalCount: 4 }];
  const offsets = [];
  const api = { importPreviewItems: async (_library, _preview, offset) => { offsets.push(offset); return pages[offset === 0 ? 0 : 1]; } };
  assert.equal((await loadImportPreview(api, "l", { previewId: "p", revision: "1" })).length, 4);
  assert.deepEqual(offsets, [0, 2]);
  pages[0] = { ...pages[0], summary: { revision: "1" } };
  await assert.rejects(loadImportPreview(api, "l", { previewId: "p", revision: "2" }), /changed/);
  const short = { importPreviewItems: async () => ({ summary: { revision: "1" }, items: [], totalCount: 3 }) };
  await assert.rejects(loadImportPreview(short, "l", { previewId: "p", revision: "1" }), /incomplete/);
});

test("the preview is analyzed, a file is assigned and the recognized items are imported", async (t) => {
  installDOM(t);
  const calls = [];
  let current = items;
  const summary = (revision) => ({ previewId: "p1", revision, counts, issues: [], targets });
  const api = {
    analyzeImport: async (library) => { calls.push(`analyze ${library}`); return summary("1"); },
    importPreviewItems: async (_library, _preview, offset) => ({ summary: summary(current === items ? "1" : "2"), items: current.slice(offset), totalCount: current.length }),
    importAssignments: async () => ({ revision: "1", assignments: [] }),
    updateImportPreview: async (_library, _preview, revision, changes) => {
      calls.push(`assign ${revision} ${changes.map((change) => `${change.relativePath}=${change.kind}`).join(",")}`);
      current = items.map((item) => item.relativePath === "Invented Show/bonus.mkv" ? { ...item, kind: "extra", status: "recognized", parentRelativePath: "Invented Show" } : item);
      return summary("2");
    },
    confirmImportPreview: async (_library, _preview, revision) => calls.push(`confirm ${revision}`),
  };
  const toasts = [];
  const app = { api, state: { profile: { id: "owner", role: "owner" } }, toast: (text) => toasts.push(text), handleError: () => false };
  const editors = createManagementEditors({ ...app, onSaved: () => {} });
  t.after(() => editors.close());
  let done = 0;
  createImportPreview({ api, app, kit: editors.kit }).open({ id: "lib", name: "Invented Media", path: "/srv/invented", importPreviewRequired: true }, { onDone: () => done++ });
  await flush();
  const preview = document.body.children.at(-1);
  assert.match(preview.textContent, /1 need review/);
  assert.match(preview.textContent, /bonus/);
  const bonusRow = all(preview).find((node) => node.className?.startsWith?.("import-row") && node.textContent.includes("bonus"));
  button(bonusRow, "Edit").click();
  const sheet = document.body.children.at(-1);
  const [kind, parent] = all(sheet).filter((node) => node.tagName === "SELECT");
  assert.equal(kind.value, "extra");
  parent.value = "Invented Show";
  parent.dispatchEvent(new Event("change", { bubbles: true }));
  all(sheet).find((node) => node.tagName === "FORM").dispatchEvent(new Event("submit", { cancelable: true }));
  await flush();
  assert.equal(sheet.open, false);
  button(preview, "Import Recognized Items").click();
  await flush();
  assert.deepEqual(calls, ["analyze lib", "assign 1 Invented Show/bonus.mkv=extra", "confirm 2"]);
  assert.deepEqual(toasts, ["Importing Invented Media…"]);
  assert.equal(done, 1);
  assert.equal(preview.open, false);
});
