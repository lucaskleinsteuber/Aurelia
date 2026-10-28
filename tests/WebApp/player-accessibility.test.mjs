import test from "node:test";
import assert from "node:assert/strict";
import * as logic from "../../src/Aurelia.Server/WebApp/js/logic.js";
import { Player } from "../../src/Aurelia.Server/WebApp/js/player.js";
import { installDOM } from "./dom-fixture.mjs";

test("timeline and volume value texts format accessible values", () => {
  assert.equal(logic.timelineValueText(0, 0), "0:00");
  assert.equal(logic.timelineValueText(83, 2700), "1:23 of 45:00");
  assert.equal(logic.timelineValueText(3665, 7200), "1:01:05 of 2:00:00");

  assert.equal(logic.volumeValueText(0, false), "Muted");
  assert.equal(logic.volumeValueText(0.8, false), "80%");
  assert.equal(logic.volumeValueText(1.0, false), "100%");
  assert.equal(logic.volumeValueText(0.5, true), "Muted");
});

test("keyboard shortcuts overview covers playback and navigation", () => {
  assert.ok(logic.KEYBOARD_SHORTCUTS.length >= 2);
  const playback = logic.KEYBOARD_SHORTCUTS.find((s) => s.group === "Playback");
  assert.ok(playback);
  assert.ok(playback.items.some((i) => i.action.includes("Play or Pause")));
  assert.ok(playback.items.some((i) => i.action.includes("Seek Back")));
  assert.ok(playback.items.some((i) => i.action.includes("Seek Forward")));
  assert.ok(playback.items.some((i) => i.action.includes("Next Episode")));
  assert.ok(playback.items.some((i) => i.action.includes("Previous Episode")));
});

test("question mark shortcut opens keyboard shortcuts overview", (t) => {
  installDOM(t);
  const names = ["HTMLInputElement", "HTMLTextAreaElement", "HTMLButtonElement"];
  const prior = names.map((name) => globalThis[name]);
  for (const name of names) globalThis[name] = class {};
  t.after(() => names.forEach((name, i) => { globalThis[name] = prior[i]; }));

  let shortcutsShown = 0;
  const instance = Object.assign(Object.create(Player.prototype), {
    closed: false,
    preferences: { seekInterval: 10 },
    onShowShortcuts() { shortcutsShown++; },
    showControls() {},
  });
  const event = {
    key: "?",
    target: {},
    preventDefault() { this.defaultPrevented = true; },
  };
  instance.key(event);
  assert.equal(event.defaultPrevented, true);
  assert.equal(shortcutsShown, 1);
});
