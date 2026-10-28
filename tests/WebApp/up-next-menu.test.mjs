import test from "node:test";
import assert from "node:assert/strict";
import { Player } from "../../src/Aurelia.Server/WebApp/js/player.js";
import { installDOM } from "./dom-fixture.mjs";

test("Up Next forwards its real menu item only while the player owns it", (t) => {
  installDOM(t);
  const calls = [];
  const player = new Player({ api: {}, item: { id: "current", kind: "episode", title: "Synthetic" },
    onMediaMenu: (...args) => calls.push(args), onClose() {} });
  player.showControls = () => {};
  const event = () => new Event("contextmenu", { cancelable: true });
  const empty = event(); player.upNext.dispatchEvent(empty);
  assert.equal(empty.defaultPrevented, false); assert.equal(calls.length, 0);
  const next = { id: "next", kind: "episode", title: "Next", parentId: "series", isFavorite: true };
  player.upNextItem = next;
  const menu = event(); player.upNext.dispatchEvent(menu);
  assert.equal(menu.defaultPrevented, true); assert.deepEqual(calls, [[player.upNext, next]]);
  player.closed = true; const late = event(); player.upNext.dispatchEvent(late);
  assert.equal(late.defaultPrevented, false); assert.equal(calls.length, 1);
});

test("episode shortcuts leave an external catalog menu alone", () => {
  const player = Object.assign(Object.create(Player.prototype), {
    closed: false, popover: { hidden: true }, source: {},
    navigateEpisode() { assert.fail("The catalog menu must keep this key"); },
  });
  const target = { closest: (selector) => selector.includes('role="menu"') ? {} : null };
  player.key({ key: "n", target, preventDefault() { assert.fail("The menu key was consumed"); } });
});
