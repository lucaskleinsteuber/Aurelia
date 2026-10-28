// Production player logic with in-memory media objects; no browser or media engine.
import test from "node:test";
import assert from "node:assert/strict";
import { Player } from "../../src/Aurelia.Server/WebApp/js/player.js";

test("episode navigation explicitly requests a new play from zero", () => {
  const item = { id: "episode-11" };
  const calls = [];
  const player = Object.assign(Object.create(Player.prototype), {
    closed: false, close() { this.closed = true; },
    onPlayNext: (...args) => calls.push(args),
  });
  player.playNext(item);
  assert.deepEqual(calls, [[item, { intent: "play" }]]);
  assert.equal(player.closed, true);
});

import * as logic from "../../src/Aurelia.Server/WebApp/js/logic.js";
import { deferred, flush } from "./dom-fixture.mjs";

test("Play starts at zero for saved native and converted titles; only Resume reads progress", async (t) => {
  const prior = globalThis.document;
  globalThis.document = { body: { classList: { add() {} } } };
  t.after(() => { globalThis.document = prior; });
  for (const intent of ["play", "resume"]) for (const converted of [false, true]) {
    let openedAt;
    const instance = Object.assign(Object.create(Player.prototype), {
      element: {}, item: { id: "episode-10" }, startIntent: intent, closed: false,
      preferences: { automaticResume: true, defaultVolume: 1 }, video: {},
      canConvert: converted,
      api: { createPlayback: async () => ({ streamPath: "/synthetic", contentType: converted ? "video/x-matroska" : "video/mp4",
        progress: { positionMilliseconds: 42_000, durationMilliseconds: 600_000, isCompleted: false } }) },
      bind() {}, showControls() {}, updateVolume() {}, scheduleRenewal() {}, loadNotes() {}, updateEpisodeButtons() {},
      async play() { openedAt = this.resumeAt; }, async startLive(at) { openedAt = at; },
    });
    await instance.open({ append() {} });
    assert.equal(openedAt, intent === "resume" ? 42 : 0);
  }
  const saved = { positionMilliseconds: 42_000, durationMilliseconds: 600_000, isCompleted: false };
  assert.equal(logic.playbackStartSeconds("play", saved), 0);
  assert.equal(logic.playbackStartSeconds("resume", { ...saved, isCompleted: true }), 0);
  assert.equal(logic.playbackStartSeconds("resume", saved, false), 0);
});

test("previous and next use ordered normal episodes, cross seasons and skip unavailable files", () => {
  const entry = (id, number, availability = "available") => ({ episodeNumber: number, item: { id, availability } });
  const seasons = [
    { number: 2, episodes: [entry("last", 2), entry("middle", 1)] },
    { number: 0, episodes: [entry("special", 1)] },
    { number: 1, episodes: [entry("offline", 2, "missing"), entry("first", 1)] },
  ];
  assert.equal(logic.previousEpisode(seasons, "first"), null);
  assert.equal(logic.nextEpisode(seasons, "first").id, "middle");
  assert.equal(logic.previousEpisode(seasons, "middle").id, "first");
  assert.equal(logic.nextEpisode(seasons, "middle").id, "last");
  assert.equal(logic.previousEpisode(seasons, "last").id, "middle");
  assert.equal(logic.nextEpisode(seasons, "last"), null);
  assert.equal(logic.previousEpisode(seasons, "special"), null);
  assert.equal(logic.previousEpisode(seasons, "unknown"), null);
});

function navigating(overrides = {}) {
  const calls = [];
  const instance = Object.assign(Object.create(Player.prototype), {
    source: {}, closed: false, navigationPending: false,
    close() { this.closed = true; }, onPlayNext: (...args) => calls.push(args),
    showNotice(message) { this.message = message; }, showControls() {}, preferences: {},
    ...overrides,
  });
  return { instance, calls };
}

test("repeated navigation is coalesced and a late lookup cannot reopen a closed player", async () => {
  for (const close of [false, true]) {
    const reply = deferred(); let reads = 0;
    const { instance, calls } = navigating({ previous: async () => { reads++; return reply.promise; } });
    const pending = instance.navigateEpisode("previous");
    await instance.navigateEpisode("previous");
    if (close) instance.close();
    reply.resolve({ id: "previous" }); await pending;
    assert.equal(reads, 1);
    assert.equal(calls.length, close ? 0 : 1);
    if (!close) assert.deepEqual(calls[0], [{ id: "previous" }, { intent: "play" }]);
  }
});

test("navigation boundaries and failures preserve this episode and allow retry", async () => {
  const { instance, calls } = navigating({ next: async () => null });
  await instance.navigateEpisode("next");
  assert.equal(instance.closed, false); assert.equal(calls.length, 0);
  instance.next = async () => { throw new Error("Synthetic offline"); };
  await instance.navigateEpisode("next");
  assert.equal(instance.closed, false); assert.equal(instance.navigationPending, false);
  assert.match(instance.message, /could not be opened/);
  instance.next = async () => ({ id: "next" }); await instance.navigateEpisode("next");
  assert.equal(calls.length, 1);
});

test("N/P route through navigation while text, select, content-editable and modifiers keep their keys", async (t) => {
  const names = ["HTMLInputElement", "HTMLTextAreaElement", "HTMLButtonElement"];
  const prior = names.map((name) => globalThis[name]);
  for (const name of names) globalThis[name] = class {};
  t.after(() => names.forEach((name, i) => { globalThis[name] = prior[i]; }));
  const moves = [];
  const { instance } = navigating({ navigateEpisode: async (direction) => moves.push(direction) });
  function key(value, target = {}, extras = {}) {
    const event = { key: value, target, preventDefault() { this.defaultPrevented = true; }, ...extras };
    instance.key(event); return event;
  }
  assert.equal(key("n").defaultPrevented, true); assert.equal(key("P").defaultPrevented, true);
  key("n", new HTMLInputElement()); key("p", new HTMLTextAreaElement());
  key("n", { tagName: "SELECT" }); key("p", { isContentEditable: true });
  key("n", { closest: () => ({}) }); key("p", {}, { repeat: true });
  let closedMenus = 0;
  instance.popover = { hidden: false }; key("n");
  instance.closePopover = () => { closedMenus++; instance.popover.hidden = true; };
  key("Escape"); assert.equal(closedMenus, 1, "Escape keeps closing an open menu");
  let skips = 0; instance.skip = () => { skips++; };
  key("ArrowLeft", {}, { repeat: true }); assert.equal(skips, 1, "Holding a seek key keeps seeking");
  key("n", {}, { metaKey: true }); key("p", {}, { ctrlKey: true }); key("n", {}, { altKey: true });
  instance.closed = true; key("p");
  await flush(); assert.deepEqual(moves, ["next", "previous"]);
});

test("episode buttons expose first/middle/last boundaries and reject late closed updates", async () => {
  for (const [previous, next] of [[null, { id: "next" }], [{ id: "previous" }, { id: "next" }], [{ id: "previous" }, null]]) {
    const { instance } = navigating({ previous: async () => previous, next: async () => next,
      previousButton: { disabled: true }, nextButton: { disabled: true } });
    await instance.updateEpisodeButtons();
    assert.equal(instance.previousButton.disabled, !previous); assert.equal(instance.nextButton.disabled, !next);
  }
  const reply = deferred();
  const { instance } = navigating({ previous: async () => reply.promise, previousButton: { disabled: true } });
  const pending = instance.updateEpisodeButtons(); instance.close(); reply.resolve({ id: "previous" }); await pending;
  assert.equal(instance.previousButton.disabled, true);
});
