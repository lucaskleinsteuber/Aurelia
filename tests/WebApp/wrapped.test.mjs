import { test } from "node:test";
import assert from "node:assert/strict";
import { ACCENTS, accentFor, countTarget, countValue, stepFrom } from "../../src/Aurelia.Server/WebApp/js/wrapped.js";

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
