import test from "node:test";
import assert from "node:assert/strict";
import { createServerUpdates, updateSummary } from "../../src/Aurelia.Server/WebApp/js/server-updates.js";
import { createSettings } from "../../src/Aurelia.Server/WebApp/js/settings.js";
import { h } from "../../src/Aurelia.Server/WebApp/js/dom.js";
import { createApi, ApiError } from "../../src/Aurelia.Server/WebApp/js/api.js";
import { installDOM, flush, deferred, button, all } from "./dom-fixture.mjs";

const initial = { available: true, installed: "1.14.0 (101)", newest: "1.15.0 (102)", updateAvailable: true, state: "idle", checkedAt: "2026-10-27T00:00:00Z", message: null };
const status = (state, change = {}) => ({ ...initial, state, ...change });

const installedDOM = new WeakSet();
function fixture(t, { initialStatus = initial, api: override = {}, current = () => true } = {}) {
  if (!installedDOM.has(t)) { installDOM(t); installedDOM.add(t); }
  const timers = new Map(), delays = [], calls = [], sessions = [];
  let token = 0, unlocks = 0;
  const api = {
    serverUpdates: async (options) => { calls.push(["status", options]); return initial; },
    checkForUpdates: async (options) => { calls.push(["check", options]); return status("checking"); },
    approved: async (path, options) => { calls.push(["approved", path, options]); return status("installing"); },
    ...override,
  };
  const component = createServerUpdates({ api, initial: initialStatus, isCurrent: current,
    onLocked: () => { unlocks++; }, onSessionEnded: (error) => sessions.push(error),
    schedule: (work, delay) => { delays.push(delay); const id = ++token; timers.set(id, work); return id; }, cancel: (id) => timers.delete(id),
  });
  document.body.append(component.element);
  t.after(() => component.close());
  return { component, calls, timers, delays, sessions, get unlocks() { return unlocks; }, get dialog() { return document.body.querySelector("dialog"); },
    async tick() { const entry = timers.entries().next().value; assert.ok(entry, "An update poll should be scheduled"); timers.delete(entry[0]); entry[1](); await flush(); },
  };
}

test("status summaries use the server contract without inventing a percentage", () => {
  assert.match(updateSummary(status("checking")), /Looking for/);
  assert.match(updateSummary(status("installing")), /1\.15\.0 \(102\)/);
  assert.equal(updateSummary(status("failed", { message: "Synthetic checksum failure" })), "Synthetic checksum failure");
  assert.match(updateSummary(status("idle", { updateAvailable: false })), /up to date/);
  assert.match(updateSummary(status("idle", { available: false })), /Linux/);
});

test("a check polls only status every two seconds and keeps installed/newest versions visible", async (t) => {
  let reads = 0;
  const f = fixture(t, { api: { serverUpdates: async (options) => { f.calls.push(["status", options]); return ++reads === 1 ? status("checking") : status("idle", { updateAvailable: false, newest: initial.installed, checkedAt: "2026-10-27T00:01:00Z" }); } } });
  assert.match(f.component.element.textContent, /1\.14\.0 \(101\)/);
  button(f.component.element, "Check for Updates").click(); await flush();
  assert.equal(f.calls[0][0], "check"); assert.equal(f.timers.size, 1);
  assert.equal(button(f.component.element, "Check for Updates").disabled, true);
  assert.equal(all(f.component.element).find((node) => node.tagName === "PROGRESS").getAttribute("value"), null);
  await f.tick(); await f.tick();
  assert.deepEqual(f.calls.map((call) => call[0]), ["check", "status", "status"]);
  assert.deepEqual(f.delays, [2000, 2000]); assert.equal(f.timers.size, 0);
  assert.match(f.component.element.textContent, /Update check complete\. The server is up to date/);
  assert.equal(button(f.component.element, "Check for Updates").disabled, false);
});

test("installation confirms once and duplicate clicks cannot obtain another approval", async (t) => {
  const pending = deferred(); let installs = 0;
  const f = fixture(t, { api: { approved: async (path, options) => { installs++; assert.equal(path, "/api/v1/server/updates/install"); assert.equal(options.signal.aborted, false); return pending.promise; } } });
  button(f.component.element, "Install Update…").click();
  assert.equal(installs, 0); assert.match(f.dialog.textContent, /Accounts, library and settings stay/);
  button(f.dialog, "Cancel").click(); assert.equal(installs, 0);
  button(f.component.element, "Install Update…").click();
  const confirm = button(f.dialog, "Install Update"); confirm.click(); confirm.click(); await flush();
  assert.equal(installs, 1); assert.equal(f.timers.size, 0);
  assert.equal(button(f.component.element, "Install Update…").disabled, true);
  pending.resolve(status("installing")); await flush();
  assert.equal(f.timers.size, 1); assert.equal(installs, 1);
});

test("restart outages retain progress and success reports the installed version read back", async (t) => {
  let reads = 0;
  const f = fixture(t, { initialStatus: status("installing"), api: { serverUpdates: async () => {
    if (++reads === 1) throw new ApiError(0, "offline", "Synthetic restart outage");
    return status("idle", { installed: initial.newest, updateAvailable: false });
  } } });
  await f.tick(); assert.match(f.component.element.textContent, /Waiting to reconnect/); assert.equal(f.timers.size, 1);
  await f.tick(); assert.match(f.component.element.textContent, /now running 1\.15\.0 \(102\)/);
  assert.equal(f.timers.size, 0); assert.equal(f.calls.length, 0);
});

test("idle without a changed installed version is not reported as an installed update", async (t) => {
  const f = fixture(t, { initialStatus: status("installing") });
  await f.tick(); assert.match(f.component.element.textContent, /installed version has not changed/);
  assert.doesNotMatch(f.component.element.textContent, /now running/); assert.equal(f.timers.size, 0);
});

test("an updater failure stays visible and does not retry the install", async (t) => {
  const f = fixture(t, { initialStatus: status("installing"), api: { serverUpdates: async () => status("failed", { message: "Synthetic disk full" }) } });
  await f.tick(); assert.match(f.component.element.textContent, /Synthetic disk full/);
  assert.equal(f.timers.size, 0); assert.equal(f.calls.length, 0);
  assert.equal(button(f.component.element, "Install Update…").disabled, false);
});

test("management expiry stops polling and offers the existing unlock flow without requesting a password", async (t) => {
  const f = fixture(t, { initialStatus: status("installing"), api: {
    serverUpdates: async () => { throw new ApiError(403, "management_locked", "Unlock management"); },
    unlockManagement: () => assert.fail("Only the explicit existing password form may unlock management"),
  } });
  await f.tick(); assert.equal(f.timers.size, 0); assert.match(f.component.element.textContent, /Server management is locked/);
  button(f.component.element, "Unlock Server Management").click(); assert.equal(f.unlocks, 1);
  f.component.close();
  const resumed = fixture(t, { initialStatus: status("installing") });
  assert.equal(resumed.timers.size, 1); assert.equal(resumed.calls.length, 0);
});

test("a retired profile after restart is explicit and is handed to session flow only after the user's click", async (t) => {
  const expired = new ApiError(401, "invalid_session", "Synthetic restart retired the profile");
  const f = fixture(t, { initialStatus: status("installing"), api: { serverUpdates: async () => { throw expired; } } });
  await f.tick(); assert.match(f.component.element.textContent, /server restarted/);
  assert.equal(f.sessions.length, 0); assert.equal(f.timers.size, 0);
  button(f.component.element, "Choose Profile Again").click(); assert.deepEqual(f.sessions, [expired]);
});

test("leaving the route aborts an outstanding request and cannot publish late progress", async (t) => {
  const pending = deferred(); let signal;
  const f = fixture(t, { initialStatus: status("checking"), api: { serverUpdates: async (options) => { signal = options.signal; return pending.promise; } } });
  const poll = f.tick(); await flush(); assert.equal(signal.aborted, false);
  const prior = f.component.element.textContent;
  f.component.close(); assert.equal(signal.aborted, true);
  pending.resolve(status("idle", { installed: initial.newest, updateAvailable: false })); await poll;
  assert.equal(f.component.element.textContent, prior); assert.equal(f.timers.size, 0);
});

test("profile changes cancel pending confirmation and late approval results", async (t) => {
  let current = true; const pending = deferred(); let signal;
  const f = fixture(t, { current: () => current, api: { approved: async (_path, options) => { signal = options.signal; return pending.promise; } } });
  button(f.component.element, "Install Update…").click();
  f.component.close(); assert.equal(f.dialog, null);
  const next = fixture(t, { api: { approved: async (_path, options) => { signal = options.signal; return pending.promise; } } });
  button(next.component.element, "Install Update…").click(); button(next.dialog, "Install Update").click(); await flush();
  next.component.close(); current = false; assert.equal(signal.aborted, true);
  const prior = next.component.element.textContent; pending.resolve(status("installing")); await flush();
  assert.equal(next.component.element.textContent, prior); assert.equal(next.timers.size, 0);
});

test("an approval refusal never reaches the install endpoint and permits an explicit retry", async (t) => {
  const calls = []; const api = createApi(async (path, options) => {
    calls.push({ path, ...options });
    return { status: 403, ok: false, text: async () => JSON.stringify({ code: "approval_denied", message: "Synthetic approval refused" }) };
  });
  const f = fixture(t, { api });
  button(f.component.element, "Install Update…").click(); button(f.dialog, "Install Update").click(); await flush();
  assert.deepEqual(calls.map((call) => call.path), ["/api/v1/management/approval"]);
  assert.match(f.component.element.textContent, /Synthetic approval refused/);
  assert.equal(button(f.component.element, "Install Update…").disabled, false);
  assert.equal(f.timers.size, 0);
});

test("malformed responses and bounded offline waits preserve explicit retry without false success", async (t) => {
  const malformed = fixture(t, { api: { checkForUpdates: async () => ({ state: "idle" }) } });
  button(malformed.component.element, "Check for Updates").click(); await flush();
  assert.match(malformed.component.element.textContent, /unreadable update status/);
  assert.doesNotMatch(malformed.component.element.textContent, /check complete/);
  assert.equal(malformed.timers.size, 0); malformed.component.close();
  const f = fixture(t, { initialStatus: status("checking"), api: { serverUpdates: async () => { throw new ApiError(0, "offline", "Synthetic offline"); } } });
  for (let index = 0; index < 90; index++) await f.tick();
  assert.equal(f.timers.size, 0); assert.match(f.component.element.textContent, /taking longer than expected/);
  assert.ok(f.delays.every((delay) => delay === 2000));
  button(f.component.element, "Check Status Again").click(); await flush(); assert.equal(f.timers.size, 1);
});

test("update checks use the existing POST route with the caller's cancellation signal", async () => {
  const calls = [], controller = new AbortController();
  const api = createApi(async (path, options) => { calls.push({ path, ...options }); return { status: 200, ok: true, text: async () => JSON.stringify(status("checking")) }; });
  await api.checkForUpdates({ signal: controller.signal });
  assert.equal(calls[0].path, "/api/v1/server/updates/check"); assert.equal(calls[0].method, "POST");
  assert.equal(calls[0].signal, controller.signal); assert.equal(calls[0].credentials, "same-origin");
  assert.equal(calls[0].headers["X-Aurelia-Web"], "profile");
});


test("the real Settings hook aborts an update action on navigation without reloading other sections", async (t) => {
  installDOM(t);
  const pending = deferred(), reads = [];
  let signal;
  const api = {};
  for (const name of ["metadataJobs", "devices", "libraries", "serverUsers", "serverBackups"])
    api[name] = async () => { reads.push(name); return []; };
  api.serverStatus = async () => { reads.push("serverStatus"); return { state: "ok" }; };
  api.serverPower = async () => { reads.push("serverPower"); return { available: false }; };
  api.serverUpdates = async () => { reads.push("serverUpdates"); return initial; };
  api.checkForUpdates = async (options) => { signal = options.signal; return pending.promise; };
  const state = { profile: { id: "synthetic-owner", role: "owner", accessMode: "entireLibrary" }, server: { name: "Synthetic" }, route: { name: "settings", page: "server" } };
  const settings = createSettings({ api, state, navigate: () => {}, toast: () => {}, handleError: () => false,
    profilePicture: () => h("span"), switchProfile: () => {}, confirmSignOut: () => {} });
  t.after(() => settings.closeEditors());
  const page = await settings.settingsScreen(state.route); document.body.append(page);
  const initialReads = [...reads];
  button(page, "Check for Updates").click(); await flush(); assert.equal(signal.aborted, false);
  settings.closeEditors(); assert.equal(signal.aborted, true);
  const prior = page.textContent; pending.resolve(status("checking")); await flush();
  assert.equal(page.textContent, prior); assert.deepEqual(reads, initialReads);
});


test("an installation discovered during a check switches to installation progress and verifies the resulting version", async (t) => {
  let reads = 0;
  const f = fixture(t, { initialStatus: status("checking"), api: { serverUpdates: async () => ++reads === 1
    ? status("installing") : status("idle", { installed: initial.newest, updateAvailable: false }) } });
  await f.tick(); assert.match(f.component.element.textContent, /Installing/);
  await f.tick(); assert.match(f.component.element.textContent, /now running 1\.15\.0 \(102\)/);
  assert.equal(f.timers.size, 0);
});
