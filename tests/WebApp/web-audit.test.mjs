// The browser audit of 16.11.2026: inline styles, the Mac-style sheet, reads the page makes by
// itself and where the change feed starts. Synthetic data only; no browser is opened.
import test from "node:test";
import assert from "node:assert/strict";
import { cssName, h } from "../../src/Aurelia.Server/WebApp/js/dom.js";
import { createApi } from "../../src/Aurelia.Server/WebApp/js/api.js";
import { confirmSheet, openSheet } from "../../src/Aurelia.Server/WebApp/js/sheet.js";
import { openTrimEditor } from "../../src/Aurelia.Server/WebApp/js/segments-view.js";
import { installDOM, flush, deferred, button, all } from "./dom-fixture.mjs";

test("inline styles written as in scripts reach the element (audit L2)", (t) => {
  installDOM(t);
  assert.equal(cssName("minWidth"), "min-width");
  assert.equal(cssName("flexDirection"), "flex-direction");
  assert.equal(cssName("--fill"), "--fill");
  assert.equal(cssName("max-height"), "max-height");
  const set = [];
  const create = globalThis.document.createElement;
  globalThis.document.createElement = (tag) => {
    const node = create(tag);
    node.style = { setProperty: (name, value) => set.push([name, String(value)]) };
    return node;
  };
  h("div", { style: { minWidth: "0", overflowY: "auto", "--fill": "40%" } });
  assert.deepEqual(set, [["min-width", "0"], ["overflow-y", "auto"], ["--fill", "40%"]]);
});

test("a confirmation sheet answers true for its button and false for Cancel (audit D7, S11)", async (t) => {
  installDOM(t);
  const first = confirmSheet({ title: "Delete the Collection?", message: "Titles stay.", confirm: "Delete" });
  const sheet = globalThis.document.body.children.at(-1);
  assert.equal(sheet.tagName, "DIALOG");
  assert.match(sheet.textContent, /Delete the Collection\?/);
  button(sheet, "Delete").click();
  assert.equal(await first, true);

  const second = confirmSheet({ title: "Remove?", confirm: "Remove" });
  button(globalThis.document.body.children.at(-1), "Cancel").click();
  assert.equal(await second, false);
});

test("a sheet's work that fails keeps it open with the error inside it (audit D8)", async (t) => {
  installDOM(t);
  let closed = false;
  openSheet({ title: "Save", primary: "Save", onPrimary: async () => { throw new Error("The server said no."); }, onClose: () => { closed = true; } });
  const sheet = globalThis.document.body.children.at(-1);
  button(sheet, "Save").click();
  await flush();
  assert.equal(closed, false);
  assert.ok(all(sheet).some((node) => node.textContent === "The server said no."));
  assert.equal(button(sheet, "Save").disabled, false);
});

test("reads the page makes by itself say so, and the feed starts at the newest change (audit W4, W7)", async () => {
  const requests = [];
  let quiet = false;
  const api = createApi(async (path, options) => {
    requests.push({ path, headers: options.headers, method: options.method });
    return { status: 200, ok: true, text: async () => JSON.stringify({ cursor: 7, resetRequired: false, changedAreas: [], changedMediaIds: [] }) };
  }, { isBackground: () => quiet });
  await api.changes(0, undefined, undefined);
  assert.match(requests.at(-1).path, /latest=true/);
  await api.changes(7, "generation-a", undefined);
  assert.doesNotMatch(requests.at(-1).path, /latest/);

  await api.home();
  assert.equal(requests.at(-1).headers["X-Aurelia-Background"], undefined);
  await api.background(() => api.serverFileChecks());
  assert.equal(requests.at(-1).headers["X-Aurelia-Background"], "1");
  quiet = true;
  await api.home();
  assert.equal(requests.at(-1).headers["X-Aurelia-Background"], "1");
  // A change the person makes always counts, even during a quiet refresh.
  await api.request("/api/v1/server/file-checks", { method: "PUT", body: { enabled: true } });
  assert.equal(requests.at(-1).headers["X-Aurelia-Background"], undefined);
});

test("closing the segment trim sheet before playback creation resolves revokes the ticket and skips video loading", async (t) => {
  installDOM(t);
  const pending = deferred();
  const revoked = [];
  const api = {
    createPlayback: () => pending.promise,
    revokePlayback: async (id) => { revoked.push(id); },
  };
  openTrimEditor({
    api,
    item: { id: "ep-1", title: "Pilot" },
    part: "intro",
    times: { introStartMilliseconds: 1000, introEndMilliseconds: 30_000 },
    canPreview: false,
  });
  const sheet = globalThis.document.body.children.at(-1);
  const video = all(sheet).find((node) => node.tagName === "VIDEO");
  video.pause = () => {};
  video.load = () => {};
  sheet.close();
  assert.equal(sheet.isConnected, false);
  pending.resolve({ id: "ticket-1", contentType: "video/mp4", streamPath: "/api/v1/streams/ticket-1", progress: { durationMilliseconds: 600_000 } });
  await flush();
  assert.deepEqual(revoked, ["ticket-1"]);
  assert.equal(video.src, undefined);
});
