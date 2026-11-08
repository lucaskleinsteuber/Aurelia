import test from "node:test";
import assert from "node:assert/strict";
import * as logic from "../../src/Aurelia.Server/WebApp/js/logic.js";
import { PROFILE_SYMBOL_PATHS } from "../../src/Aurelia.Server/WebApp/js/profile-symbols.js";

test("built-in pictures are known symbols on known palettes", () => {
  assert.equal(logic.PICTURE_SYMBOLS.length, 12);
  assert.equal(logic.PICTURE_PALETTES.length, 8);
  assert.deepEqual(logic.parsePicture("rocket:red"), { symbol: "rocket", palette: "red", paletteIndex: 7 });
  assert.equal(logic.parsePicture("photo"), null);
  assert.equal(logic.parsePicture("unicorn:blue"), null);
  assert.equal(logic.parsePicture("star:gold"), null);
  assert.equal(logic.parsePicture(null), null);
  for (const symbol of logic.PICTURE_SYMBOLS) assert.match(PROFILE_SYMBOL_PATHS[symbol], /^M/, symbol);
});

test("profiles show their chosen name, else the sign-in name", () => {
  assert.equal(logic.shownName({ username: "lucas", displayName: "Lucas" }), "Lucas");
  assert.equal(logic.shownName({ username: "mia", displayName: "  " }), "mia");
  assert.equal(logic.shownName({ name: "Ben" }), "Ben");
  assert.equal(logic.ageLimitSummary(0), "Children's profile · FSK 0");
  assert.equal(logic.ageLimitSummary(12), "Children's profile · up to FSK 12");
  assert.equal(logic.ageLimitSummary(null), null);
});

test("the tour comes once per browser and survives missing storage", () => {
  const values = new Map();
  const storage = { getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) };
  assert.equal(logic.tourPending(storage), true);
  logic.markTourSeen(storage);
  assert.equal(logic.tourPending(storage), false);
  const refusing = { getItem: () => { throw new Error("blocked"); }, setItem: () => { throw new Error("blocked"); } };
  assert.equal(logic.tourPending(refusing), false);
  assert.doesNotThrow(() => logic.markTourSeen(refusing));
  assert.equal(logic.tourPending(null), true);
});

test("the tour note stays beside the lit place and inside the window", () => {
  const viewport = { width: 1200, height: 800 };
  assert.deepEqual(logic.tourBubblePosition({ left: 20, top: 100, right: 220, bottom: 400 }, viewport), { x: 236, y: 100 });
  const below = logic.tourBubblePosition({ left: 900, top: 100, right: 1180, bottom: 200 }, viewport);
  assert.equal(below.y, 216);
  assert.ok(below.x + 320 <= 1184);
  assert.deepEqual(logic.tourBubblePosition(null, viewport), { x: 440, y: 315 });
  const narrow = logic.tourBubblePosition({ left: 10, top: 10, right: 360, bottom: 60 }, { width: 375, height: 700 }, { width: 343, height: 170 });
  assert.ok(narrow.x >= 16 && narrow.x + 343 <= 375 - 16 + 0.001);
});
