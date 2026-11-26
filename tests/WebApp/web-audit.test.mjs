// The browser audit of 16.11.2026: inline styles, the Mac-style sheet, reads the page makes by
// itself and where the change feed starts. Synthetic data only; no browser is opened.
import test from "node:test";
import assert from "node:assert/strict";
import { cssName, h, openPopupMenu, closePopupMenu, createSidebarResizeHandle } from "../../src/Aurelia.Server/WebApp/js/dom.js";
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

test("closing a sheet removes its aurelia:page listener instead of leaking until navigation", (t) => {
  installDOM(t);
  const listeners = new Set();
  const priorAdd = globalThis.addEventListener;
  const priorRemove = globalThis.removeEventListener;
  globalThis.addEventListener = (type, fn) => { if (type === "aurelia:page") listeners.add(fn); };
  globalThis.removeEventListener = (type, fn) => { if (type === "aurelia:page") listeners.delete(fn); };
  t.after(() => { globalThis.addEventListener = priorAdd; globalThis.removeEventListener = priorRemove; });

  const sheet = openSheet({ title: "Inspect", primary: "Done" });
  assert.equal(listeners.size, 1);
  sheet.close();
  assert.equal(listeners.size, 0);
});

test("openPopupMenu supports arrow/Home/End navigation and cleans up listeners when replaced", async (t) => {
  installDOM(t);
  const docTarget = new EventTarget();
  let keydownCount = 0;
  let clickCount = 0;
  globalThis.document.activeElement = null;
  globalThis.document.addEventListener = (type, fn, opts) => {
    if (type === "keydown") keydownCount++;
    if (type === "click") clickCount++;
    docTarget.addEventListener(type, fn, opts);
  };
  globalThis.document.removeEventListener = (type, fn, opts) => {
    if (type === "keydown") keydownCount--;
    if (type === "click") clickCount--;
    docTarget.removeEventListener(type, fn, opts);
  };
  const trackFocus = (node) => {
    node.focus = () => { globalThis.document.activeElement = node; };
    return node;
  };
  const anchor1 = trackFocus(h("button", {}, "Anchor 1"));
  const anchor2 = trackFocus(h("button", {}, "Anchor 2"));
  const itemA = trackFocus(h("button", { class: "menu-item" }, "First"));
  const itemB = trackFocus(h("button", { class: "menu-item", disabled: true }, "Disabled"));
  const itemC = trackFocus(h("button", { class: "menu-item" }, "Third"));
  const itemD = trackFocus(h("button", { class: "menu-item" }, "Fourth"));

  openPopupMenu(anchor1, [itemA]);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(keydownCount, 1);
  assert.equal(clickCount, 1);

  // Opening a second menu must remove the first menu and its listeners.
  const second = openPopupMenu(anchor2, [itemA, itemB, itemC, itemD]);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(globalThis.document.body.children.length, 1);
  assert.equal(keydownCount, 1);
  assert.equal(clickCount, 1);
  assert.equal(globalThis.document.activeElement, itemA);
  assert.equal(itemA.getAttribute("role"), "menuitem");

  const press = (key) => {
    const event = Object.assign(new Event("keydown", { cancelable: true }), { key });
    docTarget.dispatchEvent(event);
    return event;
  };
  press("ArrowDown");
  assert.equal(globalThis.document.activeElement, itemC, "skips disabled items");
  press("End");
  assert.equal(globalThis.document.activeElement, itemD);
  press("ArrowDown");
  assert.equal(globalThis.document.activeElement, itemA, "wraps to first item");
  press("ArrowUp");
  assert.equal(globalThis.document.activeElement, itemD, "wraps to last item");
  press("Home");
  assert.equal(globalThis.document.activeElement, itemA);

  const esc = press("Escape");
  assert.equal(esc.defaultPrevented, true);
  assert.equal(second.menu.isConnected, false);
  assert.equal(globalThis.document.activeElement, anchor2, "Escape focuses only the current anchor, never the replaced one");
  assert.equal(keydownCount, 0);
  assert.equal(clickCount, 0);
  closePopupMenu();
});

test("sidebar resize separator exposes ARIA bounds and responds to keyboard and pointer resizing", (t) => {
  installDOM(t);
  const previews = [];
  const commits = [];
  const handle = createSidebarResizeHandle({
    width: 240,
    onPreview: (value) => previews.push(value),
    onCommit: (value) => commits.push(value),
  });
  assert.equal(handle.getAttribute("role"), "separator");
  assert.equal(handle.getAttribute("tabindex"), "0");
  assert.equal(handle.getAttribute("aria-orientation"), "vertical");
  assert.equal(handle.getAttribute("aria-valuemin"), "210");
  assert.equal(handle.getAttribute("aria-valuemax"), "300");
  assert.equal(handle.getAttribute("aria-valuenow"), "240");

  const key = (name, shiftKey = false) => handle.dispatchEvent(Object.assign(new Event("keydown", { cancelable: true }), { key: name, shiftKey }));
  key("ArrowRight");
  assert.equal(handle.getAttribute("aria-valuenow"), "250");
  key("ArrowLeft", true);
  assert.equal(handle.getAttribute("aria-valuenow"), "230");
  key("Home");
  assert.equal(handle.getAttribute("aria-valuenow"), "210");
  key("ArrowLeft");
  assert.equal(handle.getAttribute("aria-valuenow"), "210", "clamps at minimum");
  key("End");
  assert.equal(handle.getAttribute("aria-valuenow"), "300");
  assert.deepEqual(commits, [250, 230, 210, 210, 300]);

  handle.dispatchEvent(Object.assign(new Event("pointerdown", { cancelable: true }), { pointerId: 1 }));
  handle.dispatchEvent(Object.assign(new Event("pointermove"), { clientX: 265 }));
  assert.equal(handle.getAttribute("aria-valuenow"), "265");
  handle.dispatchEvent(new Event("pointerup"));
  assert.equal(commits.at(-1), 265);
  assert.equal(previews.at(-1), 265);
});
