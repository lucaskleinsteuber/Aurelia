import test from "node:test";
import assert from "node:assert/strict";
import { createCatalogView } from "../../src/Aurelia.Server/WebApp/js/catalog-view.js";
import { createApi, ApiError } from "../../src/Aurelia.Server/WebApp/js/api.js";
import { parseRoute, routePath, browseQuery, personHref } from "../../src/Aurelia.Server/WebApp/js/logic.js";
import { h } from "../../src/Aurelia.Server/WebApp/js/dom.js";
import { installDOM, flush, deferred, all, button, input } from "./dom-fixture.mjs";
const items = (start, count) => Array.from({ length: count }, (_v, i) => ({ id: `item-${start + i}`, title: `Invented ${start + i}`, kind: "movie", genres: ["Drama"], year: 2000 }));
function fixture(t, overrides = {}) {
  installDOM(t);
  const requests = [], cards = [], routes = [], messages = [];
  let changed = 0;
  const view = createCatalogView({
    api: { catalogPage: async (query, options) => { requests.push({ query, options }); return { items: items(query.offset, Math.min(100, 230 - query.offset)), total: 230, revision: "r1" }; }, collections: async () => [], ...overrides },
    navigate: (route) => routes.push(route), replaceRoute: (route) => routes.push(route),
    posterCard: (item) => { cards.push(item); return h("a", {}, item.title); },
    collectionCard: (item, offset) => h("a", { href: routePath({ name: "collection", id: item.id, ...(offset ? { offset } : {}) }) }, item.name),
    emptyState: (_symbol, title, text, action) => h("div", {}, title, text, action),
    openMenu: (_anchor, entries) => document.body.append(h("div", {}, entries)),
    menuOption: (label, _selected, action, disabled) => h("button", { onclick: action, disabled }, label),
    handleError: () => false, toast: (text) => messages.push(text), onChanged: () => { changed++; },
  });
  t.after(() => view.close());
  return { view, requests, cards, routes, messages, get changed() { return changed; }, get dialog() { return document.body.querySelector("dialog"); } };
}
test("browse requests one bounded page, retains all filters, and pages against one revision", async (t) => {
  const f = fixture(t);
  const page = await f.view.browse({ name: "movies", filters: { favorites: true, genre: "Drama", yearFrom: 1990, yearTo: 2020, watch: "inProgress", sort: "lastPlayed", descending: true } });
  assert.equal(f.requests.length, 1); assert.equal(f.cards.length, 100);
  assert.deepEqual(f.requests[0].query, { kind: "movie", favorite: "true", watchState: "inProgress", genre: "Drama", yearFrom: "1990", yearTo: "2020", sort: "lastPlayed", direction: "descending", offset: 0, limit: 100 });
  button(page, "Load More").click(); await flush();
  assert.equal(f.cards.length, 200); assert.equal(f.requests[1].query.offset, 100); assert.equal(f.requests[1].query.revision, "r1");
  button(page, "Load More").click(); await flush();
  assert.equal(f.cards.length, 230); assert.equal(button(page, "Load More").hidden, true);
});
test("catalog changes restart once without mixing snapshots", async (t) => {
  let calls = 0;
  const f = fixture(t, { catalogPage: async (query) => {
    if (++calls === 1) return { items: items(0, 100), total: 120, revision: "old" };
    if (calls === 2) { assert.equal(query.revision, "old"); throw new ApiError(409, "catalog_changed", "changed"); }
    assert.equal(query.offset, 0); assert.equal(query.revision, undefined);
    return { items: items(1000, 1), total: 1, revision: "new" };
  } });
  const page = await f.view.browse({ name: "library" }); button(page, "Load More").click(); await flush();
  assert.deepEqual(all(page).filter((n) => n.tagName === "A" && n.textContent.startsWith("Invented")).map((n) => n.textContent), ["Invented 1000"]);
  assert.equal(calls, 3);
});
test("a failed next page preserves cards and retries the same offset", async (t) => {
  let fail = true;
  const f = fixture(t, { catalogPage: async (q) => { if (q.offset && fail) { fail = false; throw new Error("Synthetic disconnect"); } return { items: items(q.offset, 100), total: 200, revision: "r1" }; } });
  const page = await f.view.browse({ name: "library" }); button(page, "Load More").click(); await flush();
  assert.equal(f.cards.length, 100); assert.match(page.textContent, /Synthetic disconnect/);
  button(page, "Try Again").click(); await flush(); assert.equal(f.cards.length, 200);
});
test("filtered search preserves section filters and immediately cancels a stale page during typing", async (t) => {
  const pending = deferred(); let signal; const searches = [];
  const f = fixture(t, { catalogPage: async (q, o) => { if (q.offset) { signal = o.signal; return pending.promise; } return { items: items(0, 100), total: 200, revision: "old" }; },
    search: async (q) => { searches.push(q); return { items: items(900, 1), total: 1, revision: "new" }; } });
  const page = await f.view.browse({ name: "shows", filters: { genre: "Drama", favorites: true } }); button(page, "Load More").click(); await flush();
  const field = input(page, "Search TV Shows"); field.value = "Quiet Harbor"; field.dispatchEvent(new Event("input")); assert.equal(signal.aborted, true);
  pending.resolve({ items: items(100, 100), total: 200, revision: "old" }); await flush(); assert.equal(f.cards.length, 100);
  await new Promise((r) => setTimeout(r, 270)); await flush();
  assert.deepEqual(searches, [{ query: "Quiet Harbor", kind: "series", favorite: "true", genre: "Drama", offset: 0, limit: 100 }]);
  assert.equal(f.routes.at(-1).filters.query, "Quiet Harbor");
});
test("search exposes Load More and navigation aborts a pending read", async (t) => {
  let signal; const pending = deferred();
  const f = fixture(t, { search: async (q, o) => { if (q.offset) { signal = o.signal; return pending.promise; } return { items: items(0, 100), total: 101, revision: "search1" }; } });
  const page = await f.view.search({ name: "search", query: "Invented" }); button(page, "Load More").click(); await flush();
  f.view.close(); assert.equal(signal.aborted, true); pending.resolve({ items: items(100, 1), total: 101, revision: "search1" }); await flush();
  assert.equal(f.cards.length, 100); assert.equal(f.messages.length, 0);
});
test("release year offers both bounds, normalizes reversed bounds and clears the range", async (t) => {
  const f = fixture(t); const page = await f.view.browse({ name: "movies", filters: {} }); button(page, "Release Year").click();
  const fields = all(f.dialog).filter((n) => n.tagName === "INPUT"); assert.equal(fields.length, 2);
  fields[0].value = "2020"; fields[1].value = "1990"; f.dialog.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }));
  assert.deepEqual(f.routes.at(-1), { name: "movies", filters: { yearFrom: 2020, yearTo: 2020 } });
  button(page, "Release Year").click(); button(f.dialog, "Any Year").click(); assert.equal(f.routes.at(-1).filters.yearFrom, undefined); assert.equal(f.routes.at(-1).filters.yearTo, undefined);
});
test("collections beyond 200 keep a bounded direct-link page hint", async (t) => {
  const requests = [], id = "0b7f6c4e-8f3a-4b52-9c1d-2a6e1f0d9b3c";
  const f = fixture(t, { collections: async (q) => { requests.push(q); return q.offset < 200 ? Array.from({ length: 100 }, (_v, i) => ({ id: `collection-${q.offset + i}`, name: "Invented", items: [] })) : [{ id, name: "Beyond 200", items: [] }]; } });
  const page = await f.view.collections(); button(page, "Load More").click(); await flush(); button(page, "Load More").click(); await flush();
  assert.equal(all(page).find((n) => n.tagName === "A" && n.textContent === "Beyond 200").getAttribute("href"), `/collection/${id}?offset=200`);
  assert.deepEqual(requests.map((q) => q.offset), [0, 100, 200]); f.view.close();
  assert.match((await f.view.collection(parseRoute(`/collection/${id}`, "?offset=200"))).textContent, /Beyond 200/); assert.deepEqual(requests.at(-1), { offset: 200, limit: 100 });
});
const state = { scope: "series", seasonNumber: null, affectedCount: 12, stateToken: "synthetic-state", continueWatchingHidden: false };
test("whole-show watch changes confirm the count and keep the exact fetched state token", async (t) => {
  const writes = []; const f = fixture(t, { watchState: async () => state, setWatchState: async (_id, body) => writes.push(body) });
  const menu = h("div", {}, f.view.watchMenu({ id: "show", kind: "series" }, "series"));
  button(menu, "Mark as Unwatched").click(); await flush(); assert.equal(writes.length, 0); assert.match(f.dialog.textContent, /Mark 12 episodes as unwatched/);
  button(f.dialog, "Cancel").click(); await flush(); assert.equal(writes.length, 0);
  button(menu, "Mark as Unwatched").click(); await flush(); button(f.dialog, "Mark as Unwatched").click(); await flush();
  assert.equal(writes.length, 1); assert.equal(writes[0].stateToken, state.stateToken); assert.equal(writes[0].scope, "series"); assert.equal(writes[0].isWatched, false);
  assert.match(writes[0].clientMutationId, /^[0-9a-f-]{36}$/); assert.equal(f.changed, 1);
});
test("route or profile change closes confirmation without issuing a watched write", async (t) => {
  let writes = 0; const f = fixture(t, { watchState: async () => state, setWatchState: async () => { writes++; } });
  const menu = h("div", {}, f.view.watchMenu({ id: "show", kind: "series" }, "series")); button(menu, "Mark as Watched").click(); await flush();
  f.view.close(); await flush(); assert.equal(f.dialog, null); assert.equal(writes, 0);
});
test("Continue Watching uses fresh title visibility and token without resetting progress", async (t) => {
  const calls = [], writes = []; const f = fixture(t, { watchState: async (...args) => { calls.push(args); return { ...state, continueWatchingHidden: true }; }, setContinueWatching: async (_id, body) => writes.push(body) });
  const menu = h("div", {}, f.view.watchMenu({ id: "episode", kind: "episode", continueWatchingHidden: true })); button(menu, "Show in Continue Watching").click(); await flush();
  assert.equal(calls[0][1], "title"); assert.equal(writes.length, 1); assert.equal(writes[0].isHidden, false); assert.equal(writes[0].stateToken, state.stateToken);
  assert.deepEqual(Object.keys(writes[0]).sort(), ["clientMutationId", "isHidden", "stateToken"]); assert.equal(f.changed, 1);
});
test("state conflicts remain visible without replaying the mutation", async (t) => {
  let writes = 0; const f = fixture(t, { watchState: async () => state, setContinueWatching: async () => { writes++; throw new ApiError(409, "library_state_conflict", "Reload before saving."); } });
  const menu = h("div", {}, f.view.watchMenu({ id: "film", kind: "movie" })); button(menu, "Remove from Continue Watching").click(); await flush();
  assert.equal(writes, 1); assert.deepEqual(f.messages, ["Reload before saving."]); assert.equal(f.changed, 0);
});
test("viewer APIs preserve same-origin cookies, encoded routes and cancellation", async () => {
  const calls = []; const api = createApi(async (path, options) => { calls.push({ path, ...options }); return { status: 204, ok: true }; });
  const controller = new AbortController(), options = { signal: controller.signal };
  await api.search({ query: "Invented", offset: 100, limit: 100, revision: "r1" }, options); await api.catalogPage({ offset: 0, limit: 100 }, options);
  await api.collections({ offset: 200, limit: 100 }, options); await api.watchState("a/b", "title", undefined, options);
  await api.setWatchState("a/b", { isWatched: true }, options); await api.setContinueWatching("a/b", { isHidden: true }, options);
  assert.match(calls[2].path, /collections\?offset=200&limit=100$/); assert.equal(calls[3].path, "/api/v1/media/a%2Fb/watch-state?scope=title");
  assert.equal(calls[5].path, "/api/v1/media/a%2Fb/continue-watching"); assert.equal(calls[5].method, "PUT");
  for (const c of calls) { assert.equal(c.signal, controller.signal); assert.equal(c.credentials, "same-origin"); assert.equal(c.headers["X-Aurelia-Web"], "profile"); assert.equal(c.headers.Authorization, undefined); }
});
test("filtered search and collection routes round-trip", () => {
  const route = { name: "movies", filters: { query: "Quiet & Harbor", yearFrom: 1990, yearTo: 2000, favorites: true } }; const [path, query] = routePath(route).split("?");
  assert.deepEqual(parseRoute(path, query), route); assert.deepEqual(browseQuery("movies", route.filters), { query: "Quiet & Harbor", kind: "movie", favorite: "true", yearFrom: "1990", yearTo: "2000" });
  assert.deepEqual(parseRoute("/collections"), { name: "collections" }); assert.equal(routePath({ name: "collections" }), "/collections");
  assert.deepEqual(parseRoute("/watchlist"), { name: "watchlist" }); assert.equal(routePath({ name: "watchlist" }), "/watchlist");
  const personRoute = { name: "person", personName: "Clara Vale", personKey: "tmdb:person:42" };
  const [personPath, personQuery] = routePath(personRoute).split("?");
  assert.deepEqual(parseRoute(personPath, personQuery), personRoute);
  assert.equal(personHref({ id: "tmdb:person:42", name: "Clara Vale" }), "/person?name=Clara+Vale&key=tmdb%3Aperson%3A42");
  assert.equal(personHref({ id: "unidentified:1", name: "Clara Vale" }), "/person?name=Clara+Vale");
});

test("a late watch-state read after a profile change cannot write with the next profile's cookies", async (t) => {
  const pending = deferred(); let writes = 0, signal;
  const f = fixture(t, { watchState: async (_id, _scope, _season, options) => { signal = options.signal; return pending.promise; }, setContinueWatching: async () => { writes++; } });
  const menu = h("div", {}, f.view.watchMenu({ id: "film", kind: "movie" })); button(menu, "Remove from Continue Watching").click(); await flush();
  f.view.close(); assert.equal(signal.aborted, true); pending.resolve(state); await flush(); assert.equal(writes, 0);
});
test("a season confirms only its affected episodes while a single film applies without a dialog", async (t) => {
  const reads = [], writes = [];
  const f = fixture(t, { watchState: async (_id, scope, season) => { reads.push([scope, season]); return { ...state, scope, seasonNumber: season }; }, setWatchState: async (_id, body) => writes.push(body) });
  const season = h("div", {}, f.view.watchMenu({ id: "show", kind: "series" }, "season", 3));
  button(season, "Mark Season as Watched").click(); await flush(); button(f.dialog, "Mark as Watched").click(); await flush();
  assert.equal(writes[0].seasonNumber, 3); assert.equal(writes[0].scope, "season"); assert.deepEqual(reads[0], ["season", 3]);
  const movie = h("div", {}, f.view.watchMenu({ id: "film", kind: "movie" })); button(movie, "Mark as Watched").click(); await flush();
  assert.equal(f.dialog, null); assert.equal(writes.length, 2);
});
test("repeated clicks cannot send concurrent visibility mutations", async (t) => {
  const pending = deferred(); let reads = 0, writes = 0;
  const f = fixture(t, { watchState: async () => { reads++; return pending.promise; }, setContinueWatching: async () => { writes++; } });
  const menu = h("div", {}, f.view.watchMenu({ id: "film", kind: "movie" })); const action = button(menu, "Remove from Continue Watching");
  action.click(); action.click(); await flush(); assert.equal(reads, 1); pending.resolve(state); await flush(); assert.equal(writes, 1);
});
test("invalid year input stays editable and canceled dialogs do not navigate", async (t) => {
  const f = fixture(t); const page = await f.view.browse({ name: "movies" }); button(page, "Release Year").click();
  all(f.dialog).find((node) => node.tagName === "INPUT").value = "invalid";
  f.dialog.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }));
  assert.match(f.dialog.textContent, /Enter a year/); assert.equal(f.routes.length, 0);
  button(f.dialog, "Cancel").click(); assert.equal(f.routes.length, 0);
});
test("a missing moved collection offers the complete index rather than reporting an empty library", async (t) => {
  const f = fixture(t); const page = await f.view.collection({ id: "missing", offset: 200 });
  assert.match(page.textContent, /may have moved or been removed/);
  assert.equal(all(page).find((node) => node.tagName === "A").getAttribute("href"), "/collections");
});
test("Continue Watching honors the displayed action if another device changed visibility before the read", async (t) => {
  const writes = [];
  const f = fixture(t, { watchState: async () => ({ ...state, continueWatchingHidden: true }), setContinueWatching: async (_id, body) => writes.push(body) });
  const menu = h("div", {}, f.view.watchMenu({ id: "film", kind: "movie", continueWatchingHidden: false }));
  button(menu, "Remove from Continue Watching").click(); await flush();
  assert.equal(writes[0].isHidden, true, "Remove must not become Show because the fresh snapshot is already hidden.");
  assert.equal(writes[0].stateToken, state.stateToken);
});
