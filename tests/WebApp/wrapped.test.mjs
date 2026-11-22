import { test } from "node:test";
import assert from "node:assert/strict";
import { ACCENTS, accentFor, countTarget, countValue, stepFrom, readyMonth, readyMonths, wrappedYears, monthIsNew, openWrapped } from "../../src/Aurelia.Server/WebApp/js/wrapped.js";
import { installDOM, all, flush } from "./dom-fixture.mjs";

// Wrapped's rules in the browser; the slides themselves come from the server.
test("every color the server names has a field and readable ink", () => {
  for (const name of ["night", "ember", "violet", "gold", "rose", "mint", "ocean", "lime"]) {
    assert.ok(ACCENTS[name].field && ACCENTS[name].ink && ACCENTS[name].sticker, name);
  }
  assert.equal(accentFor("invented-color"), ACCENTS.night);
});

test("plain numbers count up and land exactly; times do not", () => {
  assert.equal(countTarget("143"), 143);
  assert.equal(countTarget("02:47"), null);
  assert.equal(countTarget(null), null);
  assert.equal(countValue(143, 0), 0);
  assert.equal(countValue(143, 1), 143);
  assert.equal(countValue(143, 2), 143);
  assert.ok(countValue(100, 0.5) > 50, "the count eases out");
});

test("tapping moves through the slides and past the last one closes", () => {
  assert.equal(stepFrom(0, 3, true), 1);
  assert.equal(stepFrom(2, 3, true), null);
  assert.equal(stepFrom(0, 3, false), 0);
  assert.equal(stepFrom(2, 3, false), 1);
});

test("a month is ready from the 2nd of the next month, and new on Home for a week", () => {
  assert.deepEqual(readyMonth(new Date(2026, 10, 2)), { year: 2026, month: 10, name: "October" });
  assert.deepEqual(readyMonth(new Date(2026, 10, 1)), { year: 2026, month: 9, name: "September" });
  assert.deepEqual(readyMonth(new Date(2027, 0, 5)), { year: 2026, month: 12, name: "December" });
  assert.deepEqual(readyMonth(new Date(2027, 0, 1)), { year: 2026, month: 11, name: "November" });
  assert.equal(monthIsNew(new Date(2026, 10, 1)), false);
  assert.equal(monthIsNew(new Date(2026, 10, 2)), true);
  assert.equal(monthIsNew(new Date(2026, 10, 8)), true);
  assert.equal(monthIsNew(new Date(2026, 10, 9)), false);
});

test("past months of Wrapped are listed by year", () => {
  const today = new Date(2026, 10, 12);
  assert.deepEqual(readyMonths(2026, today), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  assert.equal(readyMonths(2025, today).length, 12);
  assert.deepEqual(readyMonths(2027, today), []);
  assert.deepEqual(wrappedYears([2024, 2026, 2027], today), [2026, 2024]);
  assert.deepEqual(wrappedYears([], today), [2026]);
});

test("app-level Reduce Motion keeps Wrapped slides still until tapped", async (t) => {
  installDOM(t);
  const previousWindow = globalThis.window;
  const previousRaf = globalThis.requestAnimationFrame;
  const previousCancelRaf = globalThis.cancelAnimationFrame;
  globalThis.window = { matchMedia: () => ({ matches: false }) };
  globalThis.requestAnimationFrame = () => 1;
  globalThis.cancelAnimationFrame = () => {};
  t.after(() => {
    globalThis.window = previousWindow;
    globalThis.requestAnimationFrame = previousRaf;
    globalThis.cancelAnimationFrame = previousCancelRaf;
  });
  document.body.dataset.heroMotion = "reduced";
  document.body.classList ??= { add() {}, remove() {}, toggle() {} };
  document.addEventListener ??= () => {};
  document.removeEventListener ??= () => {};
  const api = {
    wrapped: async () => ({
      slides: [
        { kind: "stat", accent: "night", eyebrow: "2026", headline: "First slide", bigNumber: "12", quip: "Nice" },
        { kind: "stat", accent: "gold", eyebrow: "2026", headline: "Second slide", bigNumber: "24", quip: "Still nice" },
      ],
    }),
  };
  await openWrapped({ api, year: 2026, artworkUrl: () => "" });
  await flush();
  const overlay = document.body.children.at(-1);
  assert.match(overlay.textContent, /First slide/);
  const runningBar = all(overlay).find((node) => node.tagName === "I");
  assert.ok(runningBar);
  runningBar.dispatchEvent(new Event("animationend"));
  await flush();
  assert.match(overlay.textContent, /First slide/, "animationend must not auto-advance when Settings > General Reduce Motion is active");
  const forward = all(overlay).find((node) => node.getAttribute?.("aria-label") === "Next slide");
  forward.click();
  await flush();
  assert.match(overlay.textContent, /Second slide/);
  const closeButton = all(overlay).find((node) => node.getAttribute?.("aria-label") === "Close Wrapped");
  closeButton.click();
});
