import test from "node:test";
import assert from "node:assert/strict";
import { createReadCache, createPrefetcher } from "../../src/Aurelia.Server/WebApp/js/logic.js";
import { createApi } from "../../src/Aurelia.Server/WebApp/js/api.js";

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a remembered page answers at once and is asked again in the background once it is old", async () => {
  let clock = 0, loads = 0, changed = 0, answer = { title: "First" };
  const cache = createReadCache({ freshMs: 1000, now: () => clock });
  const load = async () => { loads++; return structuredClone(answer); };
  assert.deepEqual(await cache.read("home", load, () => changed++), { title: "First" });
  assert.equal(loads, 1);
  // Still fresh: no second request.
  clock = 500;
  assert.deepEqual(await cache.read("home", load, () => changed++), { title: "First" });
  assert.equal(loads, 1);
  // Old: the remembered answer comes first, the new one replaces it and says it changed.
  clock = 2000;
  answer = { title: "Second" };
  assert.deepEqual(await cache.read("home", load, () => changed++), { title: "First" });
  await settle();
  assert.equal(loads, 2);
  assert.equal(changed, 1);
  assert.deepEqual(await cache.read("home", load, () => changed++), { title: "Second" });
  // An unchanged answer does not ask the page to draw again.
  clock = 4000;
  await cache.read("home", load, () => changed++);
  await settle();
  assert.equal(changed, 1);
});

test("every read gets its own copy and the oldest pages are forgotten first", async () => {
  const cache = createReadCache({ max: 2, freshMs: 1e9, now: () => 0 });
  const first = await cache.read("a", async () => ({ list: [1] }));
  first.list.push(2);
  assert.deepEqual(await cache.read("a", async () => ({ list: [9] })), { list: [1] });
  await cache.read("b", async () => 2);
  await cache.read("a", async () => 1); // a is now the newest
  await cache.read("c", async () => 3);
  assert.equal(cache.has("b"), false);
  assert.equal(cache.has("a"), true);
  assert.equal(cache.size, 2);
});

test("forgetting drops pages and answers that were still on their way", async () => {
  const cache = createReadCache({ freshMs: 0, now: () => 0 });
  let release;
  const pending = cache.read("detail:1", () => new Promise((resolve) => { release = resolve; }));
  cache.clear();
  release({ title: "Old" });
  assert.deepEqual(await pending, { title: "Old" });
  assert.equal(cache.has("detail:1"), false);

  await cache.read("detail:2", async () => ({ v: 1 }));
  let refresh;
  let changed = 0;
  await cache.read("detail:2", () => new Promise((resolve) => { refresh = resolve; }), () => changed++);
  cache.clear();
  refresh({ v: 2 });
  await settle();
  assert.equal(cache.has("detail:2"), false);
  assert.equal(changed, 0);
});

test("a failed background refresh keeps the remembered page and may try again", async () => {
  let clock = 0, loads = 0;
  const cache = createReadCache({ freshMs: 10, now: () => clock });
  await cache.read("k", async () => "kept");
  clock = 20;
  assert.equal(await cache.read("k", async () => { loads++; throw new Error("offline"); }), "kept");
  await settle();
  assert.equal(await cache.read("k", async () => { loads++; return "new"; }), "kept");
  await settle();
  assert.equal(loads, 2);
  assert.equal(await cache.read("k", async () => "unused"), "new");
});

test("warm-up loads run at most two at a time and each title once", async () => {
  const prefetch = createPrefetcher({ limit: 2 });
  const releases = [];
  const slow = () => new Promise((resolve) => releases.push(resolve));
  assert.equal(prefetch.start("a", slow), true);
  assert.equal(prefetch.start("a", slow), false);
  assert.equal(prefetch.start("b", slow), true);
  await settle();
  assert.equal(prefetch.start("c", slow), false, "a third would exceed the limit");
  releases.forEach((release) => release());
  await settle(); await settle();
  assert.equal(prefetch.running, 0);
  assert.equal(prefetch.start("a", slow), false, "a finished title is not loaded again");
  prefetch.forget();
  assert.equal(prefetch.start("a", async () => {}), true);
  // A failed warm-up may be tried again.
  assert.equal(prefetch.start("x", async () => { throw new Error("no"); }), true);
  await settle(); await settle();
  assert.equal(prefetch.start("x", async () => {}), true);
});

test("the API reports every request that may change the server, never a read", async () => {
  const changes = [];
  const api = createApi(async () => new Response(null, { status: 204 }), { onChange: (path, method) => changes.push(`${method} ${path}`) });
  await api.home();
  await api.request("/api/v1/media/1/favorite", { method: "PUT", body: { isFavorite: true } });
  await api.request("/api/v1/history/2", { method: "DELETE" });
  assert.deepEqual(changes, ["PUT /api/v1/media/1/favorite", "DELETE /api/v1/history/2"]);
});
