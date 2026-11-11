import test from "node:test";
import assert from "node:assert/strict";
import { createCatalogView } from "../../src/Aurelia.Server/WebApp/js/catalog-view.js";
import { createApi, ApiError } from "../../src/Aurelia.Server/WebApp/js/api.js";
import { h } from "../../src/Aurelia.Server/WebApp/js/dom.js";
import { installDOM, all, button, flush, deferred } from "./dom-fixture.mjs";

function fixture(t, api = {}) {
  installDOM(t);
  const calls = [], routes = [], edits = [], messages = [];
  let manage = true, changed = 0;
  const view = createCatalogView({ api, navigate: (route) => routes.push(route),
    play: (...args) => calls.push(args), canManage: () => manage, editMetadata: (item) => edits.push(item),
    handleError: () => false, toast: (text) => messages.push(text), onChanged: () => { changed++; } });
  t.after(() => view.close());
  const menu = (item) => h("div", {}, view.mediaMenu(item));
  return { view, menu, calls, routes, edits, messages, setManage: (value) => { manage = value; }, get changed() { return changed; } };
}
const movie = { id: "film", kind: "movie", title: "Invented Film", availability: "available", progress: { positionMilliseconds: 5000, isCompleted: false } };
const labels = (menu) => all(menu).filter((node) => node.tagName === "BUTTON").map((node) => node.textContent);

test("movie menus share ordered labels and send explicit Play versus Resume intent", (t) => {
  const f = fixture(t), menu = f.menu(movie);
  assert.deepEqual(labels(menu), ["Play", "Resume", "Mark as Watched", "Mark as Unwatched", "Add to Collection…", "Add to Favorites", "Remove from Continue Watching", "Edit Metadata…"]);
  button(menu, "Play").click(); button(menu, "Resume").click();
  assert.deepEqual(f.calls.map((call) => call[2]), [{ intent: "play" }, { intent: "resume" }]);
  assert.ok(all(menu).filter((node) => node.tagName === "SVG").length >= 7);
});

test("episodes navigate to their actual series and never offer unsupported episode favorites", (t) => {
  const f = fixture(t), item = { ...movie, id: "episode", kind: "episode", parentId: "series", progress: null };
  const menu = f.menu(item);
  assert.deepEqual(labels(menu), ["Play", "Go to Series", "Mark as Watched", "Mark as Unwatched", "Edit Metadata…"]);
  assert.ok(labels(f.menu({ ...item, watchState: "inProgress" })).includes("Remove from Continue Watching"));
  button(menu, "Go to Series").click(); assert.deepEqual(f.routes, [{ name: "title", id: "series" }]);
  assert.equal(labels(f.menu({ ...item, parentId: null })).includes("Go to Series"), false);
});

test("offline titles retain series navigation and metadata actions while playback is disabled", (t) => {
  const f = fixture(t), menu = f.menu({ ...movie, kind: "episode", parentId: "series", availability: "missing" });
  assert.equal(button(menu, "Play").disabled, true); assert.equal(button(menu, "Resume").disabled, true);
  button(menu, "Play").click(); assert.equal(f.calls.length, 0);
  button(menu, "Go to Series").click(); button(menu, "Edit Metadata…").click();
  assert.equal(f.routes.length, 1); assert.equal(f.edits.length, 1);
});

test("completed or zero-position items omit Resume, and permissions are rechecked at action time", (t) => {
  const f = fixture(t);
  assert.equal(labels(f.menu({ ...movie, progress: { positionMilliseconds: 99, isCompleted: true } })).includes("Resume"), false);
  assert.equal(labels(f.menu({ ...movie, progress: { positionMilliseconds: 0 } })).includes("Resume"), false);
  const menu = f.menu(movie); f.setManage(false); button(menu, "Edit Metadata…").click(); assert.equal(f.edits.length, 0);
  assert.equal(labels(f.menu(movie)).includes("Edit Metadata…"), false);
});

test("retired menu callbacks cannot navigate, edit, play or mutate the next profile", async (t) => {
  let writes = 0; const f = fixture(t, { setFavorite: async () => { writes++; } }); const menu = f.menu(movie);
  f.view.close();
  for (const label of ["Play", "Resume", "Edit Metadata…", "Add to Favorites", "Mark as Watched", "Remove from Continue Watching"]) button(menu, label).click();
  await flush(); assert.equal(writes, 0); assert.equal(f.calls.length, 0); assert.equal(f.edits.length, 0); assert.equal(f.routes.length, 0);
});

test("favorite mutations are single-flight and preserve refusal codes without replay", async (t) => {
  const pending = deferred(); const writes = [];
  const f = fixture(t, { setFavorite: async (...args) => { writes.push(args); await pending.promise; throw new ApiError(403, "forbidden", "Not permitted."); } });
  const menu = f.menu({ ...movie, isFavorite: true }); const action = button(menu, "Remove from Favorites");
  action.click(); action.click(); await flush(); assert.equal(writes.length, 1); assert.equal(writes[0][1], false);
  pending.resolve(); await flush(); assert.deepEqual(f.messages, ["Not permitted."]); assert.equal(f.changed, 0);
});

test("favorite API keeps encoded identity, same-origin cookies and route cancellation", async () => {
  const calls = [], controller = new AbortController();
  const api = createApi(async (path, options) => { calls.push({ path, ...options }); return { ok: true, status: 204 }; });
  await api.setFavorite("a/b", true, { signal: controller.signal });
  assert.equal(calls[0].path, "/api/v1/media/a%2Fb/favorite"); assert.equal(calls[0].signal, controller.signal);
  assert.equal(calls[0].credentials, "same-origin"); assert.equal(calls[0].headers["X-Aurelia-Web"], "profile");
  assert.equal(calls[0].body, '{"isFavorite":true}');
});


test("player series navigation uses the supplied close boundary instead of navigating underneath it", (t) => {
  const f = fixture(t), received = [];
  const menu = h("div", {}, f.view.mediaMenu({ ...movie, kind: "episode", parentId: "series" }, { onGoToSeries: (id) => received.push(id) }));
  button(menu, "Go to Series").click();
  assert.deepEqual(received, ["series"]); assert.deepEqual(f.routes, []);
});

test("watchlist actions toggle shared state for movies and series when provided", async (t) => {
  installDOM(t);
  const toggles = [];
  let watchlisted = false, changed = 0;
  const view = createCatalogView({
    api: {}, navigate: () => {}, play: () => {}, canManage: () => false,
    handleError: () => false, toast: () => {}, onChanged: () => { changed++; },
    isWatchlisted: () => watchlisted,
    toggleWatchlist: async (id, next) => { toggles.push([id, next]); watchlisted = next; },
  });
  t.after(() => view.close());
  const firstMenu = h("div", {}, view.mediaMenu(movie));
  assert.equal(labels(firstMenu).includes("Add to Watchlist"), true);
  button(firstMenu, "Add to Watchlist").click();
  await flush();
  assert.deepEqual(toggles, [["film", true]]);
  assert.equal(changed, 1);
  const secondMenu = h("div", {}, view.mediaMenu(movie));
  assert.equal(labels(secondMenu).includes("Remove from Watchlist"), true);
});

test("each menu marks only its own title: an episode the episode, a show the whole show", (t) => {
  const f = fixture(t);
  const episode = labels(f.menu({ ...movie, id: "episode", kind: "episode", parentId: "series", seasonNumber: 2 }));
  assert.equal(episode.some((label) => /Season|Series/.test(label) && label.startsWith("Mark")), false);
  const series = labels(f.menu({ id: "series", kind: "series", title: "Invented Show" }));
  assert.ok(series.includes("Mark Series as Watched") && series.includes("Mark Series as Unwatched"));
  assert.equal(series.some((label) => label.startsWith("Mark Season")), false);
  assert.equal(series.includes("Remove from Continue Watching"), false);
});
