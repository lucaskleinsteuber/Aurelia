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

test("the tour lights the first target on screen and keeps its ring inside the window", () => {
  const viewport = { width: 1200, height: 800 };
  const below = { left: 20, top: 900, right: 220, bottom: 1200, width: 200, height: 300 };
  const visible = { left: 240, top: 300, right: 440, bottom: 600, width: 200, height: 300 };
  const hidden = { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
  assert.equal(logic.visibleTourTarget([hidden, below, visible], viewport, 64), 2);
  assert.equal(logic.visibleTourTarget([hidden, below], viewport, 64), 1);
  assert.equal(logic.visibleTourTarget([hidden], viewport), -1);
  const underBar = { left: 20, top: 30, right: 220, bottom: 330, width: 200, height: 300 };
  assert.equal(logic.visibleTourTarget([underBar, visible], viewport, 64), 1);

  assert.deepEqual(logic.tourHole(visible, viewport), { left: 232, top: 292, right: 448, bottom: 608 });
  assert.deepEqual(logic.tourHole({ left: -10, top: 500, right: 300, bottom: 1000, width: 310, height: 500 }, viewport),
    { left: 4, top: 492, right: 308, bottom: 796 });
  assert.equal(logic.tourHole(hidden, viewport), null);
});

test("Continue Watching is offered only for titles that are in the row or were hidden from it", () => {
  assert.equal(logic.continueWatchingChoice({ kind: "movie", watchState: "inProgress" }), "remove");
  assert.equal(logic.continueWatchingChoice({ kind: "episode", progress: { positionMilliseconds: 5000 } }), "remove");
  assert.equal(logic.continueWatchingChoice({ kind: "series", watchState: "unplayed" }), null);
  assert.equal(logic.continueWatchingChoice({ kind: "movie", watchState: "completed", progress: { positionMilliseconds: 9, isCompleted: true } }), null);
  assert.equal(logic.continueWatchingChoice({ kind: "movie", continueWatchingHidden: true }), "show");
  assert.equal(logic.continueWatchingChoice({ kind: "collection", watchState: "inProgress" }), null);
  assert.equal(logic.continueWatchingChoice(null), null);
});

test("the top bar keeps every section once in the chosen order", () => {
  assert.deepEqual(logic.sectionOrder(null), ["library", "watchlist", "recent", "shows", "movies", "collections"]);
  assert.deepEqual(logic.sectionOrder(["movies", "movies", "nonsense", "shows"]), ["movies", "shows", "library", "watchlist", "recent", "collections"]);
  assert.deepEqual(logic.moveSection(null, "movies", -1), ["library", "watchlist", "recent", "movies", "shows", "collections"]);
  assert.deepEqual(logic.moveSection(null, "library", -1), ["library", "watchlist", "recent", "shows", "movies", "collections"]);
  assert.deepEqual(logic.normalizeGeneralPreferences({ sectionOrder: ["collections"] }).sectionOrder[0], "collections");
});

test("the setup form takes the server's code however it is typed and checks the password", () => {
  assert.equal(logic.setupCode("abcde fghjk"), "ABCDE-FGHJK");
  assert.equal(logic.setupCode("ab-c"), "ABC");
  assert.equal(logic.setupCode("ABCDE-FGHJK-XYZ"), "ABCDE-FGHJK");
  const ok = { code: "abcdefghjk", ownerName: "Owner", password: "a long password!", repeat: "a long password!" };
  assert.equal(logic.setupProblem(ok), null);
  assert.match(logic.setupProblem({ ...ok, code: "ABC" }), /10-character/);
  assert.match(logic.setupProblem({ ...ok, ownerName: " " }), /name/);
  assert.match(logic.setupProblem({ ...ok, password: "short", repeat: "short" }), /12/);
  assert.match(logic.setupProblem({ ...ok, repeat: "different!!!!!" }), /match/);
  assert.deepEqual(logic.parseRoute("/welcome", ""), { name: "welcome" });
  assert.equal(logic.routePath({ name: "welcome" }), "/welcome");
});
