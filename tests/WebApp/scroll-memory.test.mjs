import test from "node:test";
import assert from "node:assert/strict";
import { ScrollMemory, isTitleOffline, OFFLINE_FILE_NOTICE } from "../../src/Aurelia.Server/WebApp/js/logic.js";

test("scroll memory remembers and recalls scroll positions", () => {
  const memory = new ScrollMemory(4);
  assert.equal(memory.recall("/library"), 0);

  memory.remember("/library", 450);
  memory.remember("/movies", 120.7);
  memory.remember("/shows", 0);

  assert.equal(memory.recall("/library"), 450);
  assert.equal(memory.recall("/movies"), 120);
  assert.equal(memory.recall("/shows"), 0);
  assert.equal(memory.recall("/unknown"), 0);
});

test("scroll memory rejects invalid paths and negative positions", () => {
  const memory = new ScrollMemory(4);
  memory.remember("", 300);
  memory.remember(null, 300);
  memory.remember("/library", -50);
  memory.remember("/library", NaN);
  memory.remember("/library", "not a number");

  assert.equal(memory.recall(""), 0);
  assert.equal(memory.recall(null), 0);
  assert.equal(memory.recall("/library"), 0);
});

test("scroll memory is bounded and evicts oldest entries", () => {
  const memory = new ScrollMemory(3);
  memory.remember("/a", 10);
  memory.remember("/b", 20);
  memory.remember("/c", 30);
  assert.equal(memory.recall("/a"), 10);

  // Inserting fourth entry evicts /a
  memory.remember("/d", 40);
  assert.equal(memory.recall("/a"), 0);
  assert.equal(memory.recall("/b"), 20);
  assert.equal(memory.recall("/c"), 30);
  assert.equal(memory.recall("/d"), 40);

  // Clearing resets all
  memory.clear();
  assert.equal(memory.recall("/b"), 0);
  assert.equal(memory.recall("/c"), 0);
  assert.equal(memory.recall("/d"), 0);
});

test("offline file notice identifies missing media and provides clear text", () => {
  assert.equal(OFFLINE_FILE_NOTICE, "This file is offline; its details and progress are kept.");
  assert.equal(isTitleOffline({ kind: "movie", availability: "missing" }, null), true);
  assert.equal(isTitleOffline({ kind: "movie", availability: "available" }, null), false);
  assert.equal(isTitleOffline({ kind: "series", availability: "available" }, { availability: "missing" }), true);
  assert.equal(isTitleOffline({ kind: "series", availability: "available" }, { availability: "available" }), false);
});

