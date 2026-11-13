import test from "node:test";
import assert from "node:assert/strict";
import { createApi } from "../../src/Aurelia.Server/WebApp/js/api.js";
import { normalizePreferences, parseRoute, PLAYBACK_DEFAULTS, routePath } from "../../src/Aurelia.Server/WebApp/js/logic.js";
import {
  BoundedFailureCache,
  describeWishError,
  formatWishNotification,
  parseYearInput,
  supportsWishes,
  wishBadgeCount,
  wishPosterUrl,
} from "../../src/Aurelia.Server/WebApp/js/wishes.js";
import { createWishesView } from "../../src/Aurelia.Server/WebApp/js/wishes-view.js";
import { all, button, flush, input, installDOM } from "./dom-fixture.mjs";

test("wishes route and sleep good-night preference preserve backwards defaults", () => {
  assert.deepEqual(parseRoute("/wishes"), { name: "wishes" });
  assert.equal(routePath({ name: "wishes" }), "/wishes");
  assert.equal(PLAYBACK_DEFAULTS.showGoodNightOnSleepTimer, false);
  assert.equal(normalizePreferences(null).showGoodNightOnSleepTimer, false);
  assert.equal(normalizePreferences({ automaticResume: true }).showGoodNightOnSleepTimer, false);
  assert.equal(normalizePreferences({ showGoodNightOnSleepTimer: true }).showGoodNightOnSleepTimer, true);
});

test("wishes helpers respect capabilities, role badges, bounded poster cache, and error codes", () => {
  assert.equal(supportsWishes({ capabilities: ["screen-time-v1"] }), false);
  assert.equal(supportsWishes({ capabilities: ["wishes-v1"] }), true);

  assert.equal(wishBadgeCount({ openCount: 4, newlyFulfilledCount: 1 }, { role: "owner" }), 5);
  assert.equal(wishBadgeCount({ openCount: 4, newlyFulfilledCount: 1 }, { role: "admin" }), 5);
  assert.equal(wishBadgeCount({ openCount: 4, newlyFulfilledCount: 2 }, { role: "user" }), 2);

  assert.equal(formatWishNotification({ openCount: 1, newlyFulfilledCount: 0 }, { openCount: 2, newlyFulfilledCount: 0 }, { role: "user" }), null);
  assert.match(formatWishNotification({ openCount: 1, newlyFulfilledCount: 0 }, { openCount: 2, newlyFulfilledCount: 0 }, { role: "admin" }).body, /new wish/i);
  assert.match(formatWishNotification({ openCount: 1, newlyFulfilledCount: 0 }, { openCount: 0, newlyFulfilledCount: 1 }, { role: "user" }).body, /now in the library/i);

  const poster = wishPosterUrl("/abc.jpg", 342);
  assert.ok(poster.startsWith("/api/v1/wishes/poster?"));
  assert.ok(!poster.includes("tmdb.org"));
  assert.equal(wishPosterUrl(" "), null);

  assert.deepEqual(parseYearInput(""), { year: null });
  assert.deepEqual(parseYearInput("2024"), { year: 2024 });
  assert.ok(parseYearInput("99").error);

  const conflict = describeWishError(Object.assign(new Error("Already here"), {
    code: "already_in_library",
    mediaId: "00000000-0000-4000-8000-000000000001",
    mediaTitle: "Already Stored Film",
    mediaKind: "movie",
  }));
  assert.equal(conflict.alreadyInLibrary.mediaId, "00000000-0000-4000-8000-000000000001");
  assert.equal(conflict.alreadyInLibrary.title, "Already Stored Film");

  const cache = new BoundedFailureCache(2);
  cache.add("a");
  cache.add("b");
  assert.equal(cache.has("a"), true);
  cache.add("c");
  assert.equal(cache.size, 2);
  assert.equal(cache.has("b"), false);
  assert.equal(cache.has("a"), true);
  assert.equal(cache.has("c"), true);
});

test("wish API wrappers forward cookies and parse already_in_library details", async () => {
  const calls = [];
  const api = createApi(async (path, options) => {
    calls.push({ path, ...options });
    if (path === "/api/v1/wishes" && options.method === "POST") {
      return {
        ok: false,
        status: 409,
        text: async () => JSON.stringify({
          code: "already_in_library",
          message: "Already in library",
          mediaId: "00000000-0000-4000-8000-000000000010",
          title: "Synthetic Library Film",
          kind: "movie",
        }),
      };
    }
    if (path === "/api/v1/playback/sleep-timer-ended") {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ powerMode: "sleep", afterSleepTimer: true, minutes: 5 }),
      };
    }
    return { ok: true, status: 204, text: async () => "" };
  });

  await api.wishes("open");
  await api.wishSummary();
  await api.wishSearch("Sky", "movie");
  await api.setWishSupport("id-1", true);
  await api.updateWishState("id-1", { state: "fulfilled" });
  await api.deleteWish("id-1");
  await api.markWishesSeen();
  const sleepResult = await api.sleepTimerEnded();
  assert.deepEqual(sleepResult, { powerMode: "sleep", afterSleepTimer: true, minutes: 5 });

  await assert.rejects(
    () => api.createWish({ kind: "movie", title: "Synthetic Library Film" }),
    (err) => err.code === "already_in_library" && err.mediaId === "00000000-0000-4000-8000-000000000010" && err.mediaTitle === "Synthetic Library Film",
  );
  assert.ok(calls.some((c) => c.path === "/api/v1/wishes?state=open"));
  assert.ok(calls.some((c) => c.path === "/api/v1/wishes/search?query=Sky&kind=movie"));
});

test("wishes view supports TMDB search, Me Too, manual fallback, and marking fulfilled seen", async (t) => {
  installDOM(t);
  let seenCalls = 0;
  let stateUpdates = [];
  let created = [];
  let wishes = [
    {
      id: "w-1",
      userId: "user-2",
      userName: "Mia",
      kind: "movie",
      title: "Invented Adventure",
      year: 2024,
      posterPath: "/inv.jpg",
      overview: "Synthetic plot",
      state: "open",
      createdAt: "2026-11-12T10:00:00Z",
      canSupport: true,
      supportedByCaller: false,
      supporters: [],
      suggestions: [{ mediaId: "m-99", title: "Invented Adventure", year: 2024, kind: "movie" }],
    },
  ];
  const api = {
    wishes: async () => ({ wishes, openCount: wishes.length, newlyFulfilledCount: 1, providerEnabled: false }),
    setWishSupport: async () => ({}),
    updateWishState: async (id, body) => { stateUpdates.push({ id, body }); return {}; },
    createWish: async (body) => { created.push(body); return { wish: { title: body.title }, mergedIntoExistingSupport: false }; },
    deleteWish: async () => {},
    markWishesSeen: async () => { seenCalls++; },
  };
  const summaryUpdates = [];
  const view = createWishesView({
    api,
    profile: () => ({ id: "admin-1", role: "admin", name: "Alex" }),
    navigate: () => {},
    toast: () => {},
    handleError: () => false,
    onSummaryChanged: (summary) => summaryUpdates.push(summary),
  });

  const el = view.screen();
  document.body.append(el);
  await flush();

  assert.match(el.textContent, /Invented Adventure/);
  assert.match(el.textContent, /Is this that wish/i);
  const img = all(el).find((n) => n.tagName === "IMG");
  assert.ok(img.getAttribute("src").startsWith("/api/v1/wishes/poster?"));
  assert.equal(img.getAttribute("loading"), "lazy");

  // Open composer -> falls back to manual form because providerEnabled is false.
  button(el, "Add Wish").click();
  input(el, "Title").value = "Paper Planes";
  input(el, "Year").value = "2023";
  all(el).find((n) => n.tagName === "FORM").dispatchEvent(new Event("submit"));
  await flush();
  assert.equal(created[0].title, "Paper Planes");
  assert.equal(created[0].year, 2023);

  // Admin matches suggested library title.
  button(el, "Match & Fulfill").click();
  await flush();
  assert.deepEqual(stateUpdates[0], { id: "w-1", body: { state: "fulfilled", fulfilledMediaItemId: "m-99" } });

  // Switching to In Library marks fulfilled wishes seen.
  button(el, "In Library").click();
  await flush();
  assert.equal(seenCalls, 1);
  assert.equal(summaryUpdates.at(-1).newlyFulfilledCount, 0);
});
