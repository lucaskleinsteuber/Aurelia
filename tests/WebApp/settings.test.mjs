import test from "node:test";
import assert from "node:assert/strict";
import { libraryPayload, loadManagementSections, managementPermissions, metadataPayload, profilePayload, waitForLibraryOperation } from "../../src/Aurelia.Server/WebApp/js/logic.js";

test("management permissions keep owner settings and selected-title storage restrictions", () => {
  assert.deepEqual(managementPermissions({ role: "owner", accessMode: "selectedTitles" }), { owner: true, administrator: true, storage: true });
  assert.deepEqual(managementPermissions({ role: "admin", accessMode: "entireLibrary" }), { owner: false, administrator: true, storage: true });
  assert.deepEqual(managementPermissions({ role: "admin", accessMode: "selectedTitles" }), { owner: false, administrator: true, storage: false });
  assert.deepEqual(managementPermissions({ role: "user" }), { owner: false, administrator: false, storage: false });
});

function sectionApi() {
  const calls = [];
  const api = {};
  for (const name of ["metadataJobs", "devices", "libraries", "serverStatus", "serverUpdates", "serverUsers", "serverPower", "serverBackups"])
    api[name] = async () => { calls.push(name); return [name]; };
  return { api, calls };
}

test("an unlocked administrator loads its allowed sections without any owner endpoint or password", async () => {
  const { api, calls } = sectionApi();
  api.unlockManagement = () => assert.fail("An unlocked window must never ask for another password");
  const sections = await loadManagementSections(api, { role: "admin", accessMode: "entireLibrary" });
  assert.deepEqual(calls, ["metadataJobs", "devices", "libraries"]);
  assert.deepEqual(sections.libraries, ["libraries"]);
  assert.equal(sections.status, undefined);
  assert.deepEqual(sections.users, []);
});

test("a selected-title administrator can edit metadata without requesting restricted storage", async () => {
  const { api, calls } = sectionApi();
  await loadManagementSections(api, { role: "admin", accessMode: "selectedTitles" });
  assert.deepEqual(calls, ["metadataJobs", "devices"]);
});

test("locked management stops before section reads and is explicitly reported to the unlock form", async () => {
  const { api, calls } = sectionApi();
  const locked = Object.assign(new Error("Unlock management"), { status: 403, code: "management_locked" });
  api.metadataJobs = async () => { throw locked; };
  await assert.rejects(loadManagementSections(api, { role: "admin" }), (error) => error === locked);
  assert.deepEqual(calls, []);
  await assert.rejects(loadManagementSections(api, { role: "user" }), /Only the server's owner/);
});

test("owner sections load independently but expiry during the load is never hidden as an empty list", async () => {
  const { api, calls } = sectionApi();
  api.serverUsers = async () => { throw Object.assign(new Error("Cannot load profiles"), { status: 500 }); };
  const sections = await loadManagementSections(api, { role: "owner" });
  assert.ok(calls.includes("serverStatus"));
  assert.deepEqual(sections.libraries, ["libraries"]);
  assert.deepEqual(sections.issues, [{ section: "users", message: "Cannot load profiles" }]);
  api.serverBackups = async () => { throw Object.assign(new Error("Expired"), { code: "management_locked" }); };
  await assert.rejects(loadManagementSections(api, { role: "owner" }), /Expired/);
});

test("storage forms pass an absolute server path unchanged and never combine existing locations", () => {
  const payload = libraryPayload({ name: " Archive ", path: "/server/Invented Media/ ", kind: "tvShows" });
  assert.deepEqual(payload, { name: "Archive", path: "/server/Invented Media/ ", kind: "tvShows", combineExisting: false, requireImportPreview: false });
  assert.equal(libraryPayload({ path: "/server/Films" }).name, null);
  assert.throws(() => libraryPayload({ path: "~/Movies" }), /absolute/);
  assert.throws(() => libraryPayload({ path: "relative/path" }), /absolute/);
  assert.throws(() => libraryPayload({ path: "/server/Films\0other" }), /absolute/);
  assert.throws(() => libraryPayload({ path: "/server/Films", kind: "unknown" }), /type/);
  assert.throws(() => libraryPayload({ path: "/server/Films", name: "bad\nname" }), /visible/);
});

test("an asynchronous removal waits for completion and reports a failed operation instead of success", async () => {
  const events = [];
  let reads = 0;
  const api = { libraryOperation: async (id) => { assert.equal(id, "invented-operation"); reads += 1; return { id, state: reads === 1 ? "running" : "completed" }; } };
  const result = await waitForLibraryOperation(api, { id: "invented-operation", state: "queued" }, { wait: async () => {}, onProgress: (operation) => events.push(operation.state) });
  assert.equal(result.state, "completed");
  assert.deepEqual(events, ["queued", "running"]);
  assert.equal(reads, 2);
  assert.equal(await waitForLibraryOperation(api, null), null);
  await assert.rejects(waitForLibraryOperation(api, { state: "failed", error: "Location still in use" }), /still in use/);
  const controller = new AbortController(); controller.abort();
  await assert.rejects(waitForLibraryOperation(api, { id: "op", state: "running" }, { signal: controller.signal }), { name: "AbortError" });
});

const snapshot = {
  revision: 7,
  user: { username: "Invented Profile", role: "user", pinProtectionEnabled: true, needsPinSetup: false },
  isEnabled: true,
  access: { mode: "legacyLibraries", titleIds: [] },
};
const draft = { username: "Invented Profile", role: "user", pinProtectionEnabled: true, isEnabled: true, pin: "", pinConfirmation: "", accessMode: "legacyLibraries", titleIds: [] };

test("profile edits preserve the existing PIN and legacy grants while saving against the snapshot revision", () => {
  assert.deepEqual(profilePayload(snapshot, draft), { revision: 7, role: "user", isEnabled: true, pinProtectionEnabled: true });
  const changed = profilePayload(snapshot, { ...draft, accessMode: "selectedTitles", titleIds: ["title-b", "title-a", "title-a"] });
  assert.deepEqual(changed.titleIds, ["title-a", "title-b"]);
  assert.equal(changed.accessMode, "selectedTitles");
  assert.equal("username" in changed, false);
  assert.equal("password" in changed, false);
});

test("profile creation and role changes enforce matching PINs, owner access and explicit enablement", () => {
  const created = profilePayload(null, { ...draft, username: " New Profile ", accessMode: "selectedTitles", pin: "1234", pinConfirmation: "1234", isEnabled: false });
  assert.equal(created.username, "New Profile");
  assert.equal(created.isEnabled, false);
  assert.equal(created.pin, "1234");
  const owner = profilePayload(snapshot, { ...draft, role: "owner", pinProtectionEnabled: false, accessMode: "selectedTitles", titleIds: ["title-a"] });
  assert.equal(owner.pinProtectionEnabled, true);
  assert.equal(owner.accessMode, "entireLibrary");
  assert.deepEqual(owner.titleIds, []);
  for (const values of [{ pin: "123", pinConfirmation: "123" }, { pin: "1234", pinConfirmation: "4321" }, { pin: "1234", pinConfirmation: "" }])
    assert.throws(() => profilePayload(snapshot, { ...draft, ...values }), /matching PIN/);
  assert.throws(() => profilePayload({ ...snapshot, user: { ...snapshot.user, needsPinSetup: true } }, draft), /matching PIN/);
  assert.throws(() => profilePayload(null, { ...draft, pinProtectionEnabled: false }), /access mode/);
  assert.throws(() => profilePayload(null, { ...draft, accessMode: "entireLibrary", pin: "1234", pinConfirmation: "1234", username: "ab" }), /profile name/);
  assert.equal(profilePayload(null, { ...draft, accessMode: "selectedTitles", pinProtectionEnabled: false }).pinProtectionEnabled, false);
});

const document = {
  revision: 19, kind: "movie", overrideFields: ["title", "poster", "credits"],
  values: { title: "Invented Film", releaseYear: 2025, overview: "Existing description", runtimeMinutes: 123, fskAge: 12, genres: ["Drama"], studios: ["Studio, Inc."], country: "US", credits: [{ id: "person", name: "Invented Actor", profile: { assetId: "portrait" } }], poster: { assetId: "poster", crop: { x: 0, y: 0, width: 1, height: 1 } }, backdrop: { assetId: "backdrop" } },
  automaticValues: { title: "Automatic Title", releaseYear: 2024, overview: "Automatic description", runtimeMinutes: 120, fskAge: 6, genres: ["Comedy"], studios: ["Other Studio"], country: "GB" },
};

test("metadata edits preserve hidden artwork, cast and overrides and never mutate the server snapshot", () => {
  const before = structuredClone(document);
  const saved = metadataPayload(document, { overview: "New description", releaseYear: "2026", fsk: "16" });
  assert.equal(saved.revision, 19);
  assert.equal(saved.values.title, "Invented Film");
  assert.equal(saved.values.overview, "New description");
  assert.equal(saved.values.releaseYear, 2026);
  assert.equal(saved.values.fskAge, 16);
  assert.deepEqual(saved.values.poster, document.values.poster);
  assert.deepEqual(saved.values.credits, document.values.credits);
  assert.deepEqual(saved.values.studios, ["Studio, Inc."]);
  assert.deepEqual(saved.overrideFields, ["credits", "fsk", "overview", "poster", "releaseYear", "title"]);
  assert.equal("relativeSourcePath" in saved, false);
  assert.deepEqual(document, before);
});

test("automatic reset removes only its field's override and list editing preserves commas within names", () => {
  const saved = metadataPayload(document, { studios: ["Studio, Inc.", " Second Studio ", "Studio, Inc."] }, ["title"]);
  assert.equal(saved.values.title, "Automatic Title");
  assert.equal(saved.overrideFields.includes("title"), false);
  assert.equal(saved.overrideFields.includes("poster"), true);
  assert.deepEqual(saved.values.studios, ["Studio, Inc.", "Second Studio"]);
  assert.deepEqual(metadataPayload(document, { studios: "Studio, Inc.\nSecond Studio" }).values.studios, ["Studio, Inc.", "Second Studio"]);
  const cleared = metadataPayload(document, { overview: "", releaseYear: "", fsk: "", runtimeMinutes: "" });
  assert.equal(cleared.values.overview, "");
  assert.equal(cleared.values.releaseYear, null);
  assert.equal(cleared.values.runtimeMinutes, null);
  assert.equal(cleared.values.fskAge, null);
});

test("metadata validation rejects invalid years, runtimes, FSK, long lists and empty titles before a write", () => {
  for (const changes of [{ title: " " }, { releaseYear: "2025tail" }, { releaseYear: "1799" }, { releaseYear: "3001" }, { runtimeMinutes: "1.5" }, { runtimeMinutes: "0" }, { runtimeMinutes: "14401" }, { fsk: "7" }, { genres: Array.from({ length: 51 }, (_, index) => `Genre ${index}`) }, { overview: "a".repeat(8193) }])
    assert.throws(() => metadataPayload(document, changes));
  assert.throws(() => metadataPayload(document, { unknownField: "value" }), /Unknown/);
  assert.throws(() => metadataPayload(document, {}, ["credits"]), /Unknown/);
});
