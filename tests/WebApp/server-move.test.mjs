// Moving a server to another computer in the browser (docs/SERVER_MOVE.md), with invented data only.
import test from "node:test";
import assert from "node:assert/strict";
import {
  formatMoveCode, initialChoice, isServerMoved, mappingPayload, matchText, moveAddress, moveCodeComplete, movedDestination,
  ownerMoveView, rankedSuggestions, relocateDecision, safeAddresses, setupMoveView, transferProgress,
} from "../../src/Aurelia.Server/WebApp/js/server-move.js";
import { createApi, ApiError } from "../../src/Aurelia.Server/WebApp/js/api.js";
import { createSetupMove, movedNotice } from "../../src/Aurelia.Server/WebApp/js/server-move-view.js";
import { installDOM, flush, button, input, all } from "./dom-fixture.mjs";

const json = (status, value) => ({ status, ok: status >= 200 && status < 300, text: async () => (value === undefined ? "" : JSON.stringify(value)) });

const location = (id, name, suggestions, sampled = 415) => ({ id, name, oldPath: `/synthetic/old/${name}`, sampled, suggestions });

test("move codes are twelve letters and digits in groups of four", () => {
  assert.equal(formatMoveCode("abcd efgh-jkmn"), "ABCD-EFGH-JKMN");
  assert.equal(formatMoveCode("ab"), "AB");
  assert.equal(formatMoveCode("abcde"), "ABCD-E");
  assert.equal(formatMoveCode("ABCDEFGHJKMNPQ"), "ABCD-EFGH-JKMN");
  assert.equal(formatMoveCode(null), "");
  assert.equal(moveCodeComplete("abcd-efgh-jkm"), false);
  assert.equal(moveCodeComplete("abcdefghjkmn"), true);
});

test("the old server's address gets https and Aurelia's port, and nothing else is accepted", () => {
  assert.equal(moveAddress("192.168.1.20"), "https://192.168.1.20:43111");
  assert.equal(moveAddress(" old-server.local:44000 "), "https://old-server.local:44000");
  assert.equal(moveAddress("https://192.168.1.20:443"), "https://192.168.1.20:443");
  assert.equal(moveAddress("[fd00::5]"), "https://[fd00::5]:43111");
  for (const bad of ["", "http://192.168.1.20", "https://user:secret@host", "host/path", "host?x=1", "ftp://host"]) assert.equal(moveAddress(bad), null, bad);
});

test("match counts read like the Mac's", () => {
  assert.equal(matchText(412, 415), "412 of 415 sample files found");
  assert.equal(matchText(415, 415), "All 415 sample files found");
  assert.equal(matchText(0, 1), "None of 1 sample file found");
  assert.equal(matchText(0, 0), "This location had no files to compare.");
});

test("transfer progress shows a fraction only when the size is known", () => {
  assert.deepEqual(transferProgress({ received: 50, expected: 100 }).fraction, 0.5);
  assert.match(transferProgress({ received: 5 * 1024 * 1024, expected: 10 * 1024 * 1024 }).text, /5\.0 MB of 10 MB/);
  assert.equal(transferProgress({ received: 2048 }).fraction, null);
  assert.match(transferProgress(null).text, /Waiting/);
  assert.equal(transferProgress({ received: 300, expected: 100 }).fraction, 1);
});

test("the setup's state becomes the matching step", () => {
  assert.equal(setupMoveView({ state: "idle" }).step, "start");
  assert.equal(setupMoveView(null).step, "start");
  const fetching = setupMoveView({ state: "fetching", source: { name: "Synthetic Attic" }, progress: { received: 1, expected: 4 } });
  assert.equal(fetching.step, "progress");
  assert.match(fetching.detail, /Synthetic Attic/);
  assert.equal(fetching.progress.fraction, 0.25);
  const received = setupMoveView({ state: "received", locations: [location("a", "Movies", [])] });
  assert.equal(received.step, "locations");
  assert.equal(received.locations.length, 1);
  assert.equal(setupMoveView({ state: "applying" }).step, "applying");
  assert.equal(setupMoveView({ state: "done" }).step, "done");
  const failed = setupMoveView({ state: "failed", error: "Synthetic failure" });
  assert.equal(failed.step, "failed");
  assert.equal(failed.detail, "Synthetic failure");
});

test("each location starts with its best suggestion, or Later when nothing matched", () => {
  const movies = location("m", "Movies", [{ path: "/mnt/b", matched: 3 }, { path: "/mnt/a", matched: 412 }, { path: "/mnt/c", matched: 412 }]);
  assert.deepEqual(rankedSuggestions(movies).map((s) => s.path), ["/mnt/a", "/mnt/c", "/mnt/b"]);
  assert.deepEqual(initialChoice(movies), { kind: "suggestion", path: "/mnt/a" });
  assert.deepEqual(initialChoice(location("s", "Shows", [{ path: "/mnt/x", matched: 0 }])), { kind: "later", path: null });
  assert.deepEqual(initialChoice(location("e", "Empty", [])), { kind: "later", path: null });
});

test("the finish payload maps every location to a folder or to null for Later", () => {
  const locations = [location("m", "Movies", [{ path: "/mnt/media/Movies", matched: 412 }]), location("s", "Shows", []), location("k", "Kids", [])];
  assert.deepEqual(mappingPayload(locations, { k: { kind: "custom", path: " /srv/kids " } }), {
    mappings: [{ id: "m", path: "/mnt/media/Movies" }, { id: "s", path: null }, { id: "k", path: "/srv/kids" }],
  });
  assert.throws(() => mappingPayload(locations, { k: { kind: "custom", path: "" } }), /Kids/);
  assert.throws(() => mappingPayload(locations, { k: { kind: "custom", path: "relative/kids" } }), /starting with \//);
  assert.deepEqual(mappingPayload([], {}), { mappings: [] });
});

test("the old server's move state offers only the actions that fit", (t) => {
  const now = Date.parse("2026-11-15T10:00:00Z");
  assert.deepEqual(ownerMoveView({ state: "none" }).actions, ["start"]);
  assert.deepEqual(ownerMoveView(null).actions, ["start"]);
  const network = ownerMoveView({ state: "waiting", method: "network", expiresAt: "2026-11-15T10:14:30Z" }, now);
  assert.match(network.summary, /14:30/);
  assert.deepEqual(network.actions, ["start", "cancel"]);
  assert.match(ownerMoveView({ state: "waiting", method: "network", expiresAt: "2026-11-15T09:00:00Z" }, now).summary, /expired/);
  assert.deepEqual(ownerMoveView({ state: "waiting", method: "file" }, now).actions, ["markMoved", "cancel"]);
  assert.deepEqual(ownerMoveView({ state: "transferring" }).actions, ["cancel"]);
  const moved = ownerMoveView({ state: "moved", movedTo: { serverId: "s", name: "Synthetic Basement", addresses: [] } });
  assert.deepEqual(moved.actions, ["undo"]);
  assert.match(moved.summary, /Synthetic Basement/);
});

test("a moved server's destination comes from the 409 or the public info, with only safe links", () => {
  const error = new ApiError(409, "server_moved", "Moved");
  error.movedTo = { serverId: "id-1", name: "Synthetic Basement", addresses: ["https://192.168.1.40:43111/", "javascript:alert(1)", "https://u:p@evil", "https://192.168.1.40:43111"] };
  assert.equal(isServerMoved(error), true);
  assert.equal(isServerMoved(new ApiError(409, "catalog_changed")), false);
  assert.deepEqual(movedDestination(error), { serverId: "id-1", name: "Synthetic Basement", addresses: ["https://192.168.1.40:43111"] });
  assert.deepEqual(movedDestination({ name: "Old", moved: { serverId: "id-1", name: "New", addresses: ["http://10.0.0.2:43110"] } }).addresses, ["http://10.0.0.2:43110"]);
  assert.equal(movedDestination({ name: "Not moved" }), null);
  assert.deepEqual(safeAddresses(null), []);
});

test("a folder without any matching file needs an explicit second confirmation and then force", () => {
  assert.equal(relocateDecision(null).canConfirm, false);
  assert.deepEqual(relocateDecision({ sampled: 10, matched: 9 }), { canConfirm: true, force: false, text: "9 of 10 sample files found" });
  const empty = relocateDecision({ sampled: 10, matched: 0 });
  assert.equal(empty.canConfirm, false);
  assert.equal(empty.needsSecondConfirmation, true);
  const confirmed = relocateDecision({ sampled: 10, matched: 0 }, { confirmedEmpty: true });
  assert.equal(confirmed.canConfirm, true);
  assert.equal(confirmed.force, true);
});

test("setup move calls carry the setup code header and no token, and a 409 server_moved reaches the app", async () => {
  const calls = [];
  const moved = [];
  const api = createApi(async (path, options) => {
    calls.push({ path, ...options });
    if (path === "/api/v1/profiles") return json(409, { code: "server_moved", message: "Moved", movedTo: { serverId: "id", name: "New", addresses: ["https://10.0.0.9:43111"] } });
    if (path === "/api/v1/setup/move/file") return json(200, { uploadId: "upload-1" });
    return json(200, { state: "fetching" });
  }, { onMoved: (error) => moved.push(error) });
  await api.startNetworkMove("ABCDE-FGHJK", "https://192.168.1.20:43111", "ABCD-EFGH-JKMN");
  assert.equal(calls[0].headers["X-Aurelia-Setup-Code"], "ABCDE-FGHJK");
  assert.equal(calls[0].headers["X-Aurelia-Web"], "device");
  assert.deepEqual(JSON.parse(calls[0].body), { address: "https://192.168.1.20:43111", code: "ABCD-EFGH-JKMN" });
  assert.equal((await api.uploadMovingFile("ABCDE-FGHJK", { type: "" })).uploadId, "upload-1");
  assert.equal(calls[1].method, "PUT");
  assert.equal(calls[1].headers["X-Aurelia-Setup-Code"], "ABCDE-FGHJK");
  assert.equal(calls[1].headers["Content-Type"], "application/octet-stream");
  await api.finishMove("ABCDE-FGHJK", { mappings: [{ id: "a", path: null }] });
  assert.equal(calls[2].path, "/api/v1/setup/move/finish");
  for (const call of calls) assert.equal("Authorization" in call.headers, false);
  await assert.rejects(api.profiles(), (error) => error.code === "server_moved" && error.movedTo.name === "New");
  assert.equal(moved.length, 1);
  assert.equal(moved[0].movedTo.addresses[0], "https://10.0.0.9:43111");
});

test("Storage Location Moved sends force only when asked", async () => {
  const calls = [];
  const api = createApi(async (path, options) => {
    calls.push({ path, ...options });
    if (path === "/api/v1/management/approval") return json(200, { token: "synthetic-approval" });
    return json(200, {});
  });
  globalThis.crypto ??= (await import("node:crypto")).webcrypto;
  await api.relocateLibrary("lib-1", "/srv/new");
  await api.relocateLibrary("lib-1", "/srv/empty", true);
  const sent = calls.filter((call) => call.path === "/api/v1/libraries/lib-1/relocate").map((call) => JSON.parse(call.body));
  assert.deepEqual(sent, [{ path: "/srv/new" }, { path: "/srv/empty", force: true }]);
  assert.ok(calls.every((call) => call.path !== "/api/v1/libraries/lib-1/relocate" || call.headers["X-Aurelia-Approval"] === "synthetic-approval"));
});

test("the location step previews a typed folder and finishes with the chosen mappings", async (t) => {
  installDOM(t);
  const calls = [];
  const shown = [];
  let token = 0;
  const api = {
    previewMoveLocation: async (setup, id, path) => { calls.push(["preview", setup, id, path]); return { sampled: 20, matched: 18 }; },
    finishMove: async (setup, body) => { calls.push(["finish", setup, body]); },
    serverInfo: async () => ({ isSetup: true }),
  };
  const pairing = [];
  const screens = createSetupMove({
    api, show: (element) => { shown.push(element); return ++token; }, current: (value) => value === token,
    showPairing: (note) => pairing.push(note), showServerOff: () => {}, newServerSetup: () => {}, serverName: () => "Synthetic",
    schedule: (work) => { queueMicrotask(work); return 0; },
  });
  const view = setupMoveView({ state: "received", source: { name: "Synthetic Attic" }, locations: [
    location("m", "Movies", [{ path: "/mnt/media/Movies", matched: 412 }, { path: "/mnt/other", matched: 2 }]),
    location("s", "Shows", [], 20),
  ] });
  screens.locations("ABCDE-FGHJK", view);
  const page = shown.at(-1);
  assert.ok(all(page).some((node) => node.textContent === "412 of 415 sample files found"));
  const typed = input(page, "Other folder for Shows");
  typed.value = "/srv/shows";
  typed.dispatchEvent(new Event("input"));
  const previews = all(page).filter((node) => node.tagName === "BUTTON" && node.textContent === "Preview");
  previews[1].click();
  await flush();
  assert.deepEqual(calls[0], ["preview", "ABCDE-FGHJK", "s", "/srv/shows"]);
  assert.ok(all(page).some((node) => node.textContent === "18 of 20 sample files found"));
  button(page, "Finish Move").click();
  await flush();
  assert.deepEqual(calls[1], ["finish", "ABCDE-FGHJK", { mappings: [{ id: "m", path: "/mnt/media/Movies" }, { id: "s", path: "/srv/shows" }] }]);
  // The moved screen waits for the server, then asks to sign in at this address.
  await flush();
  assert.equal(pairing.length, 1);
  assert.match(pairing[0], /Sign in/);
});

test("Undo Move is sent as it is and asks for an approval only when the server wants one", async () => {
  globalThis.crypto ??= (await import("node:crypto")).webcrypto;
  const calls = [];
  let asked = false;
  const api = createApi(async (path, options) => {
    calls.push({ path, ...options });
    if (path === "/api/v1/management/approval") return json(200, { token: "synthetic-approval" });
    if (path === "/api/v1/server/move" && !options.headers["X-Aurelia-Approval"] && asked) return json(403, { code: "approval_required", message: "Approve" });
    return json(204);
  });
  // A moved server answers only its move: no approval is fetched.
  await api.endServerMove();
  assert.deepEqual(calls.map((call) => call.path), ["/api/v1/server/move"]);
  assert.equal(calls[0].method, "DELETE");
  // A server that wants an approval gets one for exactly this change.
  asked = true;
  calls.length = 0;
  await api.endServerMove();
  assert.deepEqual(calls.map((call) => call.path), ["/api/v1/server/move", "/api/v1/management/approval", "/api/v1/server/move"]);
  assert.equal(calls[2].headers["X-Aurelia-Approval"], "synthetic-approval");
});

test("a move that was just started may report idle for a moment before it fetches", async (t) => {
  installDOM(t);
  const shown = [];
  let token = 0;
  const answers = [{ state: "idle" }, { state: "idle" }, { state: "fetching", progress: { received: 1, expected: 2 } },
    { state: "received", source: { name: "Synthetic Attic" }, locations: [location("m", "Movies", [{ path: "/mnt/media/Movies", matched: 9 }], 10)] }];
  const api = { setupMove: async () => answers.shift() ?? { state: "received", locations: [] } };
  const screens = createSetupMove({
    api, show: (element) => { shown.push(element); return ++token; }, current: (value) => value === token,
    showPairing: () => {}, showServerOff: () => {}, newServerSetup: () => {}, serverName: () => "Synthetic",
    schedule: (work) => { queueMicrotask(work); return 0; },
  });
  screens.follow("ABCDE-FGHJK");
  for (let round = 0; round < 10; round += 1) await flush();
  const page = shown.at(-1);
  assert.ok(all(page).some((node) => node.textContent === "Where Are Your Media Files Now?"));
  assert.ok(all(page).some((node) => node.textContent === "9 of 10 sample files found"));
  assert.ok(!all(page).some((node) => node.textContent === "The move stopped. Start it again."));
});

test("the moved notice links to the new addresses and lets the owner unlock and undo", async (t) => {
  installDOM(t);
  const calls = [];
  let locked = true;
  const api = {
    serverMove: async () => ({ state: "moved", movedTo: { serverId: "id", name: "Synthetic Basement", addresses: [] } }),
    unlockManagement: async (password) => { calls.push(["unlock", password]); locked = false; },
    endServerMove: async () => {
      calls.push(["end"]);
      if (locked) throw new ApiError(403, "management_locked", "Locked");
    },
  };
  let undone = 0;
  const notice = movedNotice({ api, destination: { name: "Synthetic Basement", addresses: ["https://192.168.1.40:43111"] }, onUndone: () => { undone += 1; } });
  await flush();
  assert.ok(all(notice).some((node) => node.textContent === "This Server Moved to “Synthetic Basement”"));
  assert.ok(all(notice).some((node) => node.tagName === "A" && node.getAttribute("href") === "https://192.168.1.40:43111/"));
  // Undo waits for the confirmation that the new server is off.
  button(notice, "Undo Move").click();
  await flush();
  assert.deepEqual(calls, []);
  input(notice, "The new server is turned off").checked = true;
  button(notice, "Undo Move").click();
  await flush();
  assert.deepEqual(calls, [["end"]]);
  assert.ok(all(notice).some((node) => node.textContent === "Enter the Server Password to undo the move."));
  input(notice, "Server Password").value = "synthetic server password";
  button(notice, "Undo Move").click();
  await flush();
  assert.deepEqual(calls, [["end"], ["unlock", "synthetic server password"], ["end"]]);
  assert.equal(undone, 1);
});
