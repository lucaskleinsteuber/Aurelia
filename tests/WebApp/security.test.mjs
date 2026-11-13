// Security in the browser with an invented server: the log's words, new-device notes, Block and
// "Confirm on Another Device". No browser, network or files.
import test from "node:test";
import assert from "node:assert/strict";
import {
  newDeviceNote, remoteUnlockState, securityDeviceLine, securityEventText, securityEventsQuery, securityKind, supportsSecurity,
  unansweredDevices
} from "../../src/Aurelia.Server/WebApp/js/security.js";
import { createSecurityAlerts, remoteUnlockPanel, securitySection } from "../../src/Aurelia.Server/WebApp/js/security-view.js";
import { installDOM, all, button, flush } from "./dom-fixture.mjs";

const text = (node) => node.textContent;
const device = (overrides = {}) => ({
  id: "d1", userId: "u1", userName: "Owner", deviceName: "Invented Phone", platform: "iOS", clientVersion: "2.11.0",
  ipAddress: "192.0.2.40", createdAt: "2026-11-13T10:00:00Z", lastSeenAt: "2026-11-13T10:01:00Z", isNew: true, canBlock: true, isCurrent: false,
  ...overrides,
});

test("the log's words are the same as on the other apps and unknown kinds are still shown", () => {
  assert.equal(securityKind("library_removed"), "Storage location removed");
  assert.equal(securityKind("wrong_password"), "Wrong Server Password");
  assert.equal(securityKind("something_new"), "Something New");
  assert.equal(securityDeviceLine("iOS", "192.0.2.40"), "iOS · 192.0.2.40");
  assert.equal(securityDeviceLine(null, undefined), "");
  const event = securityEventText({ kind: "signed_in", outcome: "succeeded", detail: "Server Password", userName: "Owner", deviceName: "Invented Mac", platform: "macOS" });
  assert.deepEqual(event, { title: "Signed in · Server Password", subtitle: "Owner · Invented Mac · macOS", failed: false });
  assert.equal(securityEventText({ kind: "wrong_pin", outcome: "failed" }).failed, true);
});

test("the log's query carries the filter, the page and a limit, and nothing for All", () => {
  assert.equal(securityEventsQuery(), "limit=50");
  assert.equal(securityEventsQuery({ outcome: "failed", before: "2026-11-13T10:00:00Z" }), "outcome=failed&before=2026-11-13T10%3A00%3A00Z&limit=50");
});

test("only servers with security-v1 show it", () => {
  assert.equal(supportsSecurity({ capabilities: ["security-v1"] }), true);
  assert.equal(supportsSecurity({ capabilities: [] }), false);
  assert.equal(supportsSecurity(null), false);
});

test("new-device notes name the device and leave out answered ones", () => {
  assert.equal(newDeviceNote(device()), "New device signed in: Invented Phone · iOS · 192.0.2.40");
  assert.equal(newDeviceNote(device({ platform: null, ipAddress: null })), "New device signed in: Invented Phone");
  assert.deepEqual(unansweredDevices([device(), device({ id: "d2" })], new Set(["d1"])).map((entry) => entry.id), ["d2"]);
});

test("remote unlock states say what happened and only approved unlocks", () => {
  assert.equal(remoteUnlockState({ state: "pending" }).done, false);
  assert.deepEqual(remoteUnlockState({ state: "approved" }).unlocked, true);
  assert.equal(remoteUnlockState({ state: "denied" }).unlocked, false);
  assert.match(remoteUnlockState({ state: "expired" }).text, /expired/);
});

test("Confirm on Another Device shows the code, waits and unlocks once approved", async (t) => {
  installDOM(t);
  const answers = ["pending", "approved"];
  let unlocked = 0;
  const api = {
    startRemoteUnlock: async () => ({ id: "r1", code: "4821", expiresAt: "2026-11-13T10:05:00Z" }),
    remoteUnlockStatus: async (id) => { assert.equal(id, "r1"); return { state: answers.shift() ?? "approved" }; },
  };
  const panel = remoteUnlockPanel({ api, onUnlocked: () => unlocked++, delay: 0 });
  document.body.append(panel);
  button(panel, "Confirm on Another Device").click();
  await flush();
  assert.match(text(panel), /4821/);
  for (let round = 0; round < 5 && !unlocked; round++) {
    await new Promise((resolve) => setTimeout(resolve, 1));
    await flush();
  }
  assert.equal(unlocked, 1);
  assert.match(text(panel), /unlocked for ten minutes/);
});

test("a denied remote unlock does not unlock and offers to ask again", async (t) => {
  installDOM(t);
  let unlocked = 0;
  const api = {
    startRemoteUnlock: async () => ({ id: "r2", code: "1111" }),
    remoteUnlockStatus: async () => ({ state: "denied" }),
  };
  const panel = remoteUnlockPanel({ api, onUnlocked: () => unlocked++, delay: 0 });
  document.body.append(panel);
  button(panel, "Confirm on Another Device").click();
  for (let round = 0; round < 5; round++) { await new Promise((resolve) => setTimeout(resolve, 1)); await flush(); }
  assert.equal(unlocked, 0);
  assert.ok(button(panel, "Ask Again"));
  assert.match(text(panel), /denied/);
});

test("the owner's Security section lists devices, acknowledges, blocks after asking and unblocks", async (t) => {
  installDOM(t);
  const calls = [];
  const api = {
    securitySettings: async () => ({ securityLogDays: 90, requirePasskeysForAdministrators: false, passkeyCount: 0 }),
    securityDevices: async () => [device(), device({ id: "d2", deviceName: "This Browser", isNew: false, canBlock: false, isCurrent: true })],
    blockedDevices: async () => [{ id: "b1", deviceName: "Old Tablet", platform: "Android", ipAddress: null, blockedAt: "2026-11-01T10:00:00Z" }],
    acknowledgeDevice: async (id) => calls.push(`ack ${id}`),
    blockDevice: async (id) => { calls.push(`block ${id}`); return { listed: true, signedOut: 1 }; },
    unblockDevice: async (id) => calls.push(`unblock ${id}`),
    saveSecuritySettings: async (body) => calls.push(`save ${JSON.stringify(body)}`),
  };
  const toasts = [];
  const app = { toast: (message) => toasts.push(message), handleError: () => false };
  const kit = {
    section: (title, _symbol, _description, ...children) => { const element = document.createElement("section"); element.append(title, ...children.filter(Boolean)); return element; },
    row: (label, control) => { const element = document.createElement("div"); element.append(label, control); return element; },
    value: (shown) => { const element = document.createElement("span"); element.textContent = shown; return element; },
    select: (options, current, onChange) => {
      const element = document.createElement("select");
      for (const [value, label] of options) { const option = document.createElement("option"); option.value = String(value); option.textContent = label; element.append(option); }
      element.value = String(current);
      element.addEventListener("change", () => onChange(element.value));
      return element;
    },
  };
  let refreshed = 0;
  const element = securitySection({ api, app, kit, refresh: () => refreshed++ });
  document.body.append(element);
  await flush();
  assert.match(text(element), /Invented Phone/);
  assert.match(text(element), /New/);
  assert.match(text(element), /Old Tablet/);
  assert.match(text(element), /Optional/);
  assert.equal(all(element).filter((node) => node.tagName === "BUTTON" && node.textContent === "Block…").length, 1, "this browser can't block itself");

  button(element, "That Was Me").click();
  await flush();
  button(element, "Block…").click();
  await flush();
  const sheet = document.body.children.at(-1);
  assert.match(text(sheet), /Block “Invented Phone”/);
  button(sheet, "Block").click();
  await flush();
  button(element, "Unblock").click();
  await flush();
  const days = all(element).find((node) => node.tagName === "SELECT");
  days.value = "180";
  days.dispatchEvent(new Event("change"));
  await flush();
  assert.deepEqual(calls, ["ack d1", "block d1", "unblock b1", `save {"securityLogDays":180,"requirePasskeysForAdministrators":false}`]);
  assert.ok(toasts.includes("Invented Phone is blocked and signed out."));
  assert.equal(refreshed, 4);
});

test("new-device notes appear for the owner and leave after That Was Me", async (t) => {
  installDOM(t);
  const calls = [];
  let reads = 0;
  const api = {
    securityAlerts: async (version, wait, { signal }) => {
      reads++;
      if (reads === 1) return { version: 3, newDevices: [device()], unlockRequests: [] };
      return new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(Object.assign(new Error("Cancelled"), { name: "AbortError" }))));
    },
    acknowledgeDevice: async (id) => calls.push(`ack ${id}`),
  };
  const alerts = createSecurityAlerts({ api, toast: () => {}, handleError: () => false });
  alerts.start();
  await flush();
  const note = document.body.children.at(-1);
  assert.match(text(note), /New device signed in: Invented Phone/);
  button(note, "That Was Me").click();
  await flush();
  assert.deepEqual(calls, ["ack d1"]);
  assert.equal(note.isConnected, false);
  alerts.stop();
});
