// Exercise the real forms with a small in-memory DOM. No browser, windows or network run.
import test from "node:test";
import assert from "node:assert/strict";
import { ApiError } from "../../src/Aurelia.Server/WebApp/js/api.js";
import { createManagementEditors } from "../../src/Aurelia.Server/WebApp/js/settings-editors.js";

class TestNode extends EventTarget {
  constructor(tag = "", text = "") {
    super();
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parentNode = null;
    this.attributes = new Map();
    this.dataset = {};
    this.style = { setProperty() {} };
    this.value = "";
    this.disabled = this.checked = this.selected = this.hidden = false;
    this.text = text;
  }
  get firstChild() { return this.children[0] ?? null; }
  get isConnected() { return this === globalThis.document?.body || Boolean(this.parentNode?.isConnected); }
  get textContent() { return this.text + this.children.map((child) => child.textContent).join(""); }
  set textContent(value) { this.replaceChildren(); this.text = String(value); }
  setAttribute(key, value) {
    this.attributes.set(key, String(value));
    if (["disabled", "checked", "selected", "hidden"].includes(key)) this[key] = true;
    if (["value", "type", "class"].includes(key)) this[key === "class" ? "className" : key] = String(value);
  }
  getAttribute(key) { return this.attributes.get(key) ?? null; }
  append(...nodes) {
    for (let node of nodes) {
      if (!(node instanceof TestNode)) node = new TestNode("", String(node));
      node.remove();
      node.parentNode = this;
      this.children.push(node);
      if (this.tagName === "SELECT" && (node.selected || this.children.length === 1)) this.value = node.value;
    }
  }
  replaceChildren(...nodes) {
    for (const child of [...this.children]) child.remove();
    this.text = "";
    this.append(...nodes);
  }
  remove() {
    if (this.parentNode) this.parentNode.children.splice(this.parentNode.children.indexOf(this), 1);
    this.parentNode = null;
  }
  replaceWith(node) {
    const parent = this.parentNode;
    if (!parent) return;
    const index = parent.children.indexOf(this);
    this.remove();
    node.parentNode = parent;
    parent.children.splice(index, 0, node);
  }
  querySelectorAll(selector) {
    const selectors = selector.split(",").map((item) => item.trim());
    const matches = (node) => selectors.some((item) => {
      const match = /^(\w+)(?:\[([^=]+)=["']?([^"'\]]+)["']?\])?$/.exec(item);
      return match && node.tagName === match[1].toUpperCase() && (!match[2] || node.getAttribute(match[2]) === match[3]);
    });
    return this.children.flatMap((child) => [...(matches(child) ? [child] : []), ...child.querySelectorAll(selector)]);
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
  focus() {}
  showModal() { this.open = true; }
  close() { this.open = false; this.dispatchEvent(new Event("close")); }
  click() { if (!this.disabled) this.dispatchEvent(new Event("click", { bubbles: true, cancelable: true })); }
  dispatchEvent(event) {
    const result = super.dispatchEvent(event);
    if (event.bubbles && this.parentNode) this.parentNode.dispatchEvent(event);
    return result;
  }
}

const flush = async () => { for (let index = 0; index < 8; index++) await new Promise(setImmediate); };
const deferred = () => { let resolve; const promise = new Promise((done) => { resolve = done; }); return { promise, resolve }; };
const values = { title: "Invented Film", releaseYear: 2024, overview: "Synthetic description", runtimeMinutes: 90, fskAge: 6,
  genres: ["Drama"], studios: ["Studio, Inc."], country: "Germany", credits: [], poster: null, backdrop: null };
const editorDocument = () => ({ mediaId: "film", kind: "movie", revision: 7, values: structuredClone(values),
  automaticValues: structuredClone(values), overrideFields: ["studios"] });

function fixture(t, overrides = {}) {
  const prior = { document: globalThis.document, Node: globalThis.Node };
  globalThis.Node = TestNode;
  globalThis.document = { body: new TestNode("body"), createElement: (tag) => new TestNode(tag), createTextNode: (text) => new TestNode("", text) };
  const toasts = [];
  let saved = 0;
  const app = {
    state: { profile: { id: "owner", role: "owner", accessMode: "entireLibrary" } },
    api: {
      request: async () => ({ items: [], total: 0, revision: "r1" }),
      mediaEditor: async () => editorDocument(), saveMediaEditor: async () => ({}),
      unlockManagement: async () => ({}), ...overrides,
    },
    toast: (text) => toasts.push(text), handleError: () => false, onSaved: () => { saved++; },
  };
  const editors = createManagementEditors(app);
  t.after(() => { editors.close(); globalThis.document = prior.document; globalThis.Node = prior.Node; });
  return { app, editors, toasts, get saved() { return saved; }, get dialog() { return globalThis.document.body.querySelector("dialog"); } };
}

function labelled(dialog, text, tag = "input") {
  const label = dialog.querySelectorAll("label").find((entry) => entry.firstChild?.textContent === text);
  assert.ok(label, `Missing label ${text}`);
  const control = label.querySelector(tag);
  assert.ok(control, `Missing ${tag} for ${text}`);
  return control;
}

test("asynchronous profile loading preserves read-only name, required PIN and owner access controls", async (t) => {
  const snapshot = { user: { id: "owner", username: "Owner", role: "owner", pinProtectionEnabled: true, needsPinSetup: false },
    isEnabled: true, access: { mode: "entireLibrary", titleIds: [], revision: 1 }, revision: 7 };
  const f = fixture(t, { profileEditor: async () => snapshot });
  f.editors.editProfile({ user: snapshot.user });
  await flush();
  assert.equal(labelled(f.dialog, "Name").disabled, true);
  assert.equal(labelled(f.dialog, "Require a Profile PIN").disabled, true);
  assert.equal(labelled(f.dialog, "Can watch", "select").disabled, true);
  assert.equal(labelled(f.dialog, "Can watch", "select").value, "entireLibrary");
});

test("an expired management save unlocks once and retries the same draft without losing hidden values", async (t) => {
  let unlocks = 0;
  const writes = [];
  const f = fixture(t, {
    saveMediaEditor: async (_id, body) => {
      writes.push(structuredClone(body));
      if (writes.length === 1) throw new ApiError(403, "management_locked", "Unlock management.");
    },
    unlockManagement: async (password) => { assert.equal(password, "synthetic password"); unlocks++; },
  });
  f.editors.editMetadata({ id: "film", title: "Invented Film" });
  await flush();
  const title = labelled(f.dialog, "Title");
  title.value = "Edited draft";
  title.dispatchEvent(new Event("input", { bubbles: true }));
  f.dialog.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }));
  await flush();
  assert.equal(unlocks, 0);
  assert.equal(title.value, "Edited draft");
  const password = labelled(f.dialog, "Server Password");
  password.value = "synthetic password";
  f.dialog.querySelectorAll("button").find((entry) => entry.textContent === "Unlock").click();
  await flush();
  assert.equal(unlocks, 1);
  assert.equal(writes.length, 2);
  assert.deepEqual(writes[1], writes[0]);
  assert.equal(writes[1].values.title, "Edited draft");
  assert.deepEqual(writes[1].values.studios, ["Studio, Inc."]);
  assert.equal(writes[1].revision, 7);
  assert.equal(password.value, "");
  assert.equal(f.dialog, null);
  assert.equal(f.saved, 1);
});

test("a ready unlocked editor saves directly without requesting the Server Password", async (t) => {
  let unlocks = 0;
  const f = fixture(t, { unlockManagement: async () => { unlocks++; } });
  f.editors.editMetadata({ id: "film", title: "Invented Film" });
  await flush();
  f.dialog.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }));
  await flush();
  assert.equal(unlocks, 0);
  assert.equal(f.saved, 1);
});

test("a disconnected save keeps the draft open and restores its controls for retry", async (t) => {
  const f = fixture(t, { saveMediaEditor: async () => { throw new ApiError(0, "offline", "The server isn’t answering."); } });
  f.app.handleError = () => assert.fail("A draft must not be discarded by global offline navigation");
  f.editors.editMetadata({ id: "film", title: "Invented Film" });
  await flush();
  const title = labelled(f.dialog, "Title");
  title.value = "Keep this draft";
  title.dispatchEvent(new Event("input", { bubbles: true }));
  f.dialog.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }));
  await flush();
  assert.ok(f.dialog?.open);
  assert.equal(title.value, "Keep this draft");
  assert.equal(title.disabled, false);
  assert.equal(f.dialog.querySelectorAll("button").find((entry) => entry.textContent === "Save").disabled, false);
  assert.match(f.dialog.textContent, /server isn’t answering/);
  assert.deepEqual(f.toasts, []);
  assert.equal(f.saved, 0);
});

for (const action of ["cancel", "profile switch"]) {
  test(`${action} aborts a pending editor load and ignores its stale completion`, async (t) => {
    const pending = deferred();
    let signal;
    const f = fixture(t, { mediaEditor: (_id, options) => { signal = options.signal; return pending.promise; } });
    f.editors.editMetadata({ id: "film", title: "Invented Film" });
    await flush();
    if (action === "cancel") {
      const cancel = f.dialog.querySelectorAll("button").find((entry) => entry.textContent === "Cancel");
      assert.equal(cancel.disabled, false, "Reading metadata must remain cancellable");
      cancel.click();
    } else {
      f.app.state.profile = { id: "another", role: "user" };
      f.editors.close();
    }
    assert.equal(signal.aborted, true);
    pending.resolve(editorDocument());
    await flush();
    assert.equal(f.dialog, null);
    assert.deepEqual(f.toasts, []);
    assert.equal(f.saved, 0);
  });
}

test("metadata editor follows native settings sections and preserves read-only source, cast and artwork", async (t) => {
  const document = editorDocument();
  document.sourcePath = "/invented/Quiet Harbor/Quiet Harbor.mkv";
  document.values.credits = [{ id: "person", name: "Morgan Vale", department: "Acting", character: "Alex" }];
  document.values.poster = { assetId: "poster" };
  const f = fixture(t, { mediaEditor: async () => document });
  f.editors.editMetadata({ id: "film", title: "Invented Film", poster: { path: "/api/v1/artwork/invented" } }); await flush();
  assert.deepEqual(f.dialog.querySelectorAll("h3").map((node) => node.textContent),
    ["Title and Year", "Overview", "Genres", "Production and Release", "Cast and Crew", "Artwork", "Match with TMDB", "Source"]);
  assert.match(f.dialog.textContent, /Morgan Vale/); assert.match(f.dialog.textContent, /\/invented\/Quiet Harbor/);
  const images = f.dialog.querySelectorAll("img");
  assert.equal(images[0].getAttribute("src"), "/api/v1/artwork/invented?width=320");
  assert.equal(images[1].getAttribute("src"), "/api/v1/media/film/editor/artwork/poster");
  assert.equal(f.dialog.querySelectorAll("h2")[0].textContent, "Edit Metadata");
  assert.ok(f.dialog.querySelectorAll("button").some((node) => node.textContent === "Cancel"));
});

test("invalid metadata stays beside its field, blocks writes and becomes saveable after correction", async (t) => {
  let writes = 0; const f = fixture(t, { saveMediaEditor: async () => { writes++; } });
  f.editors.editMetadata({ id: "film", title: "Invented Film" }); await flush();
  const year = labelled(f.dialog, "Release Year"); year.value = "invalid";
  year.dispatchEvent(new Event("input", { bubbles: true }));
  const save = f.dialog.querySelectorAll("button").find((node) => node.textContent === "Save");
  assert.equal(save.disabled, true); assert.match(f.dialog.textContent, /year/i);
  f.dialog.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true })); await flush(); assert.equal(writes, 0);
  year.value = "2020"; year.dispatchEvent(new Event("input", { bubbles: true }));
  assert.equal(save.disabled, false);
  f.dialog.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true })); await flush(); assert.equal(writes, 1);
});

test("metadata Escape preserves the draft until explicit discard", async (t) => {
  const f = fixture(t); f.editors.editMetadata({ id: "film", title: "Invented Film" }); await flush();
  const title = labelled(f.dialog, "Title"); title.value = "Private draft"; title.dispatchEvent(new Event("input", { bubbles: true }));
  f.dialog.dispatchEvent(new Event("cancel", { cancelable: true }));
  assert.equal(title.value, "Private draft"); assert.ok(f.dialog);
  f.dialog.querySelectorAll("button").find((node) => node.textContent === "Keep Editing").click();
  assert.equal(title.value, "Private draft"); assert.ok(f.dialog);
});
