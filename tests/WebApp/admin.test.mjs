// The browser's server administration with an invented server; no browser, network or files.
import test from "node:test";
import assert from "node:assert/strict";
import { createManagementEditors } from "../../src/Aurelia.Server/WebApp/js/settings-editors.js";
import { createAdminTools } from "../../src/Aurelia.Server/WebApp/js/settings-admin.js";
import { codeCountdown, folderCrumbs, subtitleLanguages } from "../../src/Aurelia.Server/WebApp/js/logic.js";
import { installDOM, all, button, flush } from "./dom-fixture.mjs";

function fixture(t, api) {
  installDOM(t);
  const toasts = [];
  const app = { api, state: { profile: { id: "owner", role: "owner" }, route: { name: "settings" } }, toast: (text) => toasts.push(text),
    handleError: () => false, navigate: () => {} };
  const editors = createManagementEditors({ ...app, onSaved: () => {} });
  const admin = createAdminTools({ api, app, editors });
  t.after(() => editors.close());
  const sheet = () => document.body.children.at(-1);
  return { admin, toasts, sheet };
}
const text = (node) => node.textContent;

test("a code for a new device is shown in two groups and can be replaced", async (t) => {
  let made = 0;
  const api = { createPairingCode: async () => ({ code: made++ ? "87654321" : "12345678", expiresAt: new Date(Date.now() + 300_000).toISOString() }) };
  const { admin, sheet } = fixture(t, api);
  admin.createCode();
  await flush();
  assert.match(text(sheet()), /1234 5678/);
  assert.match(text(sheet()), /left/);
  button(sheet(), "New Code").click();
  await flush();
  assert.match(text(sheet()), /8765 4321/);
  sheet().close();
});

test("a device's own code is looked up first, then allowed or denied", async (t) => {
  const calls = [];
  const api = {
    lookupDevicePairing: async (code) => { calls.push(`lookup ${code}`); return { id: "p1", deviceName: "Invented TV", serverName: "Home Server" }; },
    approveDevicePairing: async (id) => calls.push(`approve ${id}`),
    denyDevicePairing: async (id) => calls.push(`deny ${id}`),
  };
  const { admin, sheet, toasts } = fixture(t, api);
  admin.enterCode();
  const field = all(sheet()).find((node) => node.getAttribute?.("aria-label") === "Code");
  field.value = "1234";
  button(sheet(), "Look Up").click();
  await flush();
  assert.deepEqual(calls, [], "four digits are not looked up");
  field.value = "1234 5678";
  button(sheet(), "Look Up").click();
  await flush();
  assert.match(text(sheet()), /Invented TV/);
  button(sheet(), "Allow").click();
  await flush();
  assert.deepEqual(calls, ["lookup 12345678", "approve p1"]);
  assert.deepEqual(toasts, ["Invented TV is connected."]);
});

test("the folder picker walks the server's folders and hands back the chosen one", async (t) => {
  const listings = {
    "": { path: null, parent: null, folders: [{ name: "mnt", path: "/mnt" }] },
    "/mnt": { path: "/mnt", parent: "/", folders: [{ name: "media", path: "/mnt/media" }] },
    "/mnt/media": { path: "/mnt/media", parent: "/mnt", folders: [] },
  };
  const asked = [];
  const api = { serverFolders: async (path) => { asked.push(path); return listings[path ?? ""]; } };
  const { admin, sheet } = fixture(t, api);
  let picked = null;
  admin.chooseServerFolder((path) => { picked = path; });
  await flush();
  const choose = button(sheet(), "Choose This Folder");
  assert.equal(choose.disabled, true, "the list of places is not a folder");
  button(sheet(), "mnt").click();
  await flush();
  button(sheet(), "media").click();
  await flush();
  assert.match(text(sheet()), /No folders inside/);
  const dialog = sheet();
  button(dialog, "Choose This Folder").click();
  assert.equal(picked, "/mnt/media");
  assert.equal(dialog.open, false);
  assert.deepEqual(asked, [null, "/mnt", "/mnt/media"]);
});

test("review matches lists only open reviews and applies the chosen candidate", async (t) => {
  const chosen = [];
  let reviews = [
    { id: "r1", mediaId: "m1", title: "Invented Film", reason: "Two films share this name.", state: "needsReview",
      candidates: [{ providerMediaId: "11", mediaType: "movie", title: "Invented Film", year: 1999, confidence: 0.61 }] },
    { id: "r2", mediaId: "m2", title: "Settled Film", reason: "", state: "matched", candidates: [] },
  ];
  const api = {
    metadataReviews: async () => reviews,
    selectMetadataMatch: async (mediaId, body) => { chosen.push([mediaId, body]); reviews = []; },
  };
  const { admin, sheet } = fixture(t, api);
  admin.reviewMatches();
  await flush();
  assert.match(text(sheet()), /Invented Film/);
  assert.doesNotMatch(text(sheet()), /Settled Film/);
  assert.match(text(sheet()), /61% sure/);
  button(sheet(), "Use This").click();
  await flush();
  assert.deepEqual(chosen, [["m1", { providerMediaId: "11", mediaType: "movie" }]]);
  assert.match(text(sheet()), /Nothing to review/);
});

test("an encrypted backup is made, downloaded and its server copy removed", async (t) => {
  const calls = [];
  const api = {
    exportBackup: async (passphrase) => { calls.push(`export ${passphrase.length}`); return { id: "x1", bytes: 10 }; },
    backupTransfer: async (id) => { calls.push(`download ${id}`); return new Blob(["secret"]); },
    discardBackupTransfer: async (id) => calls.push(`discard ${id}`),
  };
  const { admin, sheet } = fixture(t, api);
  const created = [];
  const original = URL.createObjectURL;
  URL.createObjectURL = (blob) => { created.push(blob.size); return "blob:invented"; };
  t.after(() => { URL.createObjectURL = original; });
  admin.exportBackup();
  const [first, second] = all(sheet()).filter((node) => node.tagName === "INPUT");
  first.value = "a long invented passphrase";
  second.value = "a different passphrase!!";
  first.dispatchEvent(new Event("input", { bubbles: true }));
  const save = button(sheet(), "Create and Download");
  assert.equal(save.disabled, true, "different passphrases can't be saved");
  second.value = first.value;
  second.dispatchEvent(new Event("input", { bubbles: true }));
  assert.equal(save.disabled, false);
  all(sheet()).find((node) => node.tagName === "FORM").dispatchEvent(new Event("submit", { cancelable: true }));
  await flush();
  assert.deepEqual(calls, ["export 26", "download x1", "discard x1"]);
  assert.deepEqual(created, [6]);
});

test("administration helpers count down codes, split folders and clean language lists", () => {
  assert.equal(codeCountdown("2026-11-11T10:05:00Z", Date.parse("2026-11-11T10:00:01Z")), "4:59 left");
  assert.equal(codeCountdown("2026-11-11T10:05:00Z", Date.parse("2026-11-11T10:05:00Z")), null);
  assert.deepEqual(folderCrumbs("/srv/media").map((crumb) => crumb.path), ["/", "/srv", "/srv/media"]);
  assert.deepEqual(folderCrumbs(null), []);
  assert.deepEqual(subtitleLanguages("EN; de, en, deu, fr"), ["en", "de", "fr"]);
});

test("Edit Metadata shows a picture choice and its crop without decoding anything", async () => {
  const { pictureAddress, cropStyle } = await import("../../src/Aurelia.Server/WebApp/js/metadata-extras.js");
  assert.equal(pictureAddress("m 1", { uploadId: "u/1" }), "/api/v1/media/m%201/editor/uploads/u%2F1");
  assert.equal(pictureAddress("m", { assetId: "a" }), "/api/v1/media/m/editor/artwork/a");
  assert.equal(pictureAddress("m", null), "");
  assert.deepEqual(cropStyle(null), { "background-size": "cover", "background-position": "center" });
  assert.deepEqual(cropStyle({ x: 0.25, y: 0, width: 0.5, height: 1 }), { "background-size": "200.000% 100.000%", "background-position": "50.000% 0%" });
});
