// The browser app's rules without a page: `node --test tests/WebApp`.

import test from "node:test";
import assert from "node:assert/strict";
import * as logic from "../../src/Aurelia.Server/WebApp/js/logic.js";

test("a PIN is 4 to 8 digits, like on every other Aurelia device", () => {
  assert.equal(logic.isPin("1234"), true);
  assert.equal(logic.isPin("12345678"), true);
  assert.equal(logic.isPin("123"), false);
  assert.equal(logic.isPin("123456789"), false);
  assert.equal(logic.isPin("12a4"), false);
  assert.equal(logic.isPin(""), false);
});

test("the device name says which browser on which system signed in", () => {
  const safariMac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";
  const safariPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
  const chromeWindows = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";
  const edge = `${chromeWindows} Edg/130.0.0.0`;
  const firefoxLinux = "Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0";
  assert.equal(logic.deviceName(safariMac, 0), "Safari on Mac");
  assert.equal(logic.deviceName(safariMac, 5), "Safari on iPad");
  assert.equal(logic.deviceName(safariPhone), "Safari on iPhone");
  assert.equal(logic.deviceName(chromeWindows), "Chrome on Windows");
  assert.equal(logic.deviceName(edge), "Edge on Windows");
  assert.equal(logic.deviceName(firefoxLinux), "Firefox on Linux");
  assert.equal(logic.deviceName(""), "Browser");
});

test("a profile gets the same color as on the Mac and the Apple TV", () => {
  // Byte sums of these UUIDs: all zero = 0, all 0x01 = 16, all 0xff = 4080.
  assert.equal(logic.profileColorIndex("00000000-0000-0000-0000-000000000000"), 0);
  assert.equal(logic.profileColorIndex("01010101-0101-0101-0101-010101010101"), 16 % 7);
  assert.equal(logic.profileColorIndex("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"), 4080 % 7);
  assert.equal(logic.profileColorIndex("not a uuid"), 0);
  assert.equal(logic.initial("  alex"), "A");
  assert.equal(logic.initial(""), "?");
});

test("times and runtimes read naturally", () => {
  assert.equal(logic.clock(0), "0:00");
  assert.equal(logic.clock(65.9), "1:05");
  assert.equal(logic.clock(3723), "1:02:03");
  assert.equal(logic.clock(Number.NaN), "0:00");
  assert.equal(logic.runtime(42), "42 min");
  assert.equal(logic.runtime(120), "2 h");
  assert.equal(logic.runtime(102), "1 h 42 min");
  assert.equal(logic.runtime(null), "");
  assert.equal(logic.remaining({ positionMilliseconds: 0, durationMilliseconds: 38 * 60000, isCompleted: false }), "38 min left");
  assert.equal(logic.remaining({ positionMilliseconds: 0, durationMilliseconds: 90 * 60000, isCompleted: false }), "1 h 30 min left");
  assert.equal(logic.remaining({ positionMilliseconds: 0, durationMilliseconds: 90 * 60000, isCompleted: true }), "");
});

test("the eyebrow names the kind and year, or the episode", () => {
  assert.equal(logic.eyebrow({ kind: "movie", year: 2019 }), "Movie · 2019");
  assert.equal(logic.eyebrow({ kind: "series", year: 2008 }), "TV Show · 2008");
  assert.equal(logic.eyebrow({ kind: "episode", parentTitle: "Cobalt Station", seasonNumber: 1, episodeNumber: 3 }), "Cobalt Station · S1 · E3");
  assert.equal(logic.episodeLabel({ kind: "episode", episodeNumber: 4, title: "Signals" }), "4. Signals");
});

test("artwork uses the prepared widths and only the server's own addresses", () => {
  const poster = { path: "/api/v1/artwork/0b7f6c4e-8f3a-4b52-9c1d-2a6e1f0d9b3c" };
  assert.equal(logic.artworkUrl(poster, 300), `${poster.path}?width=320`);
  assert.equal(logic.artworkUrl(poster, 700), `${poster.path}?width=1280`);
  assert.equal(logic.artworkUrl(poster, 5000), `${poster.path}?width=1920`);
  assert.equal(logic.artworkUrl({ path: `${poster.path}?revision=3` }, 640), `${poster.path}?revision=3&width=640`);
  assert.equal(logic.artworkUrl({ path: "https://elsewhere.example/picture.jpg" }, 640), "");
  assert.equal(logic.artworkUrl(null, 640), "");
});

test("addresses map to screens and back", () => {
  const id = "0b7f6c4e-8f3a-4b52-9c1d-2a6e1f0d9b3c";
  assert.deepEqual(logic.parseRoute("/"), { name: "home" });
  assert.deepEqual(logic.parseRoute("/movies", "?sort=dateAdded&order=descending"), { name: "movies", filters: { sort: "dateAdded", descending: true } });
  assert.deepEqual(logic.parseRoute("/shows"), { name: "shows", filters: {} });
  assert.deepEqual(logic.parseRoute("/library", "?kind=series&favorites=1&watch=inProgress&genre=Drama&from=2001&to=2010"),
    { name: "library", filters: { kind: "series", favorites: true, watch: "inProgress", genre: "Drama", yearFrom: 2001, yearTo: 2010 } });
  assert.deepEqual(logic.parseRoute("/library", "?kind=nonsense&watch=x&sort=y"), { name: "library", filters: {} });
  assert.deepEqual(logic.parseRoute("/search", "?q=harbor"), { name: "search", query: "harbor" });
  assert.deepEqual(logic.parseRoute("/settings/server"), { name: "settings", page: "server" });
  assert.deepEqual(logic.parseRoute("/settings/nope"), { name: "settings", page: "general" });
  assert.deepEqual(logic.parseRoute(`/title/${id.toUpperCase()}`), { name: "title", id });
  assert.deepEqual(logic.parseRoute("/title/not-an-id"), { name: "home" });
  assert.deepEqual(logic.parseRoute("/anything/else"), { name: "home" });
  for (const route of [{ name: "home" }, { name: "movies", filters: { sort: "releaseYear" } }, { name: "shows", filters: {} },
    { name: "recent", filters: { genre: "Sci-Fi & Fantasy", favorites: true } }, { name: "settings", page: "general" }, { name: "settings", page: "playback" },
    { name: "search", query: "quiet harbor" }, { name: "title", id }, { name: "collection", id }]) {
    const [path, search = ""] = logic.routePath(route).split("?");
    assert.deepEqual(logic.parseRoute(path, search ? `?${search}` : ""), route);
  }
});

test("pairing codes are shown in two halves with a countdown", () => {
  assert.equal(logic.formatCode("12345678"), "1234 5678");
  const now = Date.parse("2026-10-24T12:00:00Z");
  assert.equal(logic.countdown("2026-10-24T12:04:59Z", now), "4:59");
  assert.equal(logic.countdown("2026-10-24T12:00:00Z", now), "");
});

test("playback resumes from the saved position, not from a finished or barely begun one", () => {
  assert.equal(logic.resumeSeconds(null), 0);
  assert.equal(logic.resumeSeconds({ positionMilliseconds: 600_000, durationMilliseconds: 3_600_000, isCompleted: false }), 600);
  assert.equal(logic.resumeSeconds({ positionMilliseconds: 600_000, durationMilliseconds: 3_600_000, isCompleted: true }), 0);
  assert.equal(logic.resumeSeconds({ positionMilliseconds: 3000, durationMilliseconds: 3_600_000, isCompleted: false }), 0);
  assert.equal(logic.resumeSeconds({ positionMilliseconds: 3_590_000, durationMilliseconds: 3_600_000, isCompleted: false }), 0);
});

test("the next episode skips offline files and continues into the next season", () => {
  const episode = (id, availability = "available") => ({ item: { id, availability } });
  const seasons = [{ episodes: [episode("a"), episode("b"), episode("c", "missing")] }, { episodes: [episode("d")] }];
  assert.equal(logic.nextEpisode(seasons, "a").id, "b");
  assert.equal(logic.nextEpisode(seasons, "b").id, "d");
  assert.equal(logic.nextEpisode(seasons, "d"), null);
  assert.equal(logic.nextEpisode(seasons, "unknown"), null);
});

function recorder(responses) {
  const sent = [];
  const send = async (mediaId, body) => {
    sent.push({ mediaId, ...body });
    const next = responses.shift();
    if (next instanceof Error) throw next;
    return next;
  };
  let counter = 0;
  return { sent, send, newId: () => `mutation-${++counter}` };
}

function failure(status, code) {
  return Object.assign(new Error(code), { status, code });
}

test("progress saves name the revision they build on and adopt the server's new one", async () => {
  const { sent, send, newId } = recorder([{ revision: 8 }, { revision: 9 }]);
  const saver = new logic.ProgressSaver({ mediaId: "m", revision: 7, send, newId });
  assert.equal(await saver.save(10_000, 60_000), true);
  assert.equal(await saver.save(20_000, 60_000), true);
  assert.deepEqual(sent.map((body) => [body.clientMutationId, body.expectedRevision, body.positionMilliseconds, body.enforceRevision]),
    [["mutation-1", 7, 10_000, true], ["mutation-2", 8, 20_000, true]]);
});

test("a save that failed is repeated unchanged before a newer position", async () => {
  const { sent, send, newId } = recorder([failure(0, "offline"), { revision: 2 }, { revision: 3 }]);
  const saver = new logic.ProgressSaver({ mediaId: "m", revision: 1, send, newId });
  assert.equal(await saver.save(5000, 60_000), false);
  await saver.save(9000, 60_000);
  assert.deepEqual(sent.map((body) => [body.clientMutationId, body.expectedRevision, body.positionMilliseconds]),
    [["mutation-1", 1, 5000], ["mutation-1", 1, 5000], ["mutation-2", 2, 9000]]);
});

test("an offline player keeps only the newest waiting position and does not loop", async () => {
  const { sent, send, newId } = recorder([failure(0, "offline"), failure(0, "offline"), { revision: 2 }, { revision: 3 }]);
  const saver = new logic.ProgressSaver({ mediaId: "m", revision: 1, send, newId });
  await saver.save(5000, 60_000);
  await saver.save(9000, 60_000);
  assert.equal(sent.length, 2);
  await saver.save(12_000, 60_000);
  assert.deepEqual(sent.map((body) => body.positionMilliseconds), [5000, 5000, 5000, 12_000]);
});

test("another device's newer progress wins and this player stops saving quietly", async () => {
  const { sent, send, newId } = recorder([failure(409, "playback_progress_conflict")]);
  const saver = new logic.ProgressSaver({ mediaId: "m", revision: 3, send, newId });
  assert.equal(await saver.save(5000, 60_000), false);
  assert.equal(saver.stopped, true);
  assert.equal(await saver.save(9000, 60_000), false);
  assert.equal(sent.length, 1);
});

test("an outdated revision is sent again when this player has the later position", async () => {
  const { sent, send, newId } = recorder([failure(409, "playback_progress_conflict"), { revision: 10 }, { revision: 11 }]);
  const saver = new logic.ProgressSaver({
    mediaId: "m", revision: 3, send, newId, now: () => Date.parse("2026-11-06T20:00:00Z"),
    read: async () => ({ revision: 9, updatedAt: "2026-11-06T19:40:00Z" }),
  });
  assert.equal(await saver.save(1_200_000, 2_800_000), true);
  assert.equal(saver.stopped, false);
  assert.equal(await saver.save(1_215_000, 2_800_000), true);
  assert.deepEqual(sent.map((body) => [body.expectedRevision, body.positionMilliseconds]),
    [[3, 1_200_000], [9, 1_200_000], [10, 1_215_000]]);
});

test("a position another device saved later stays, and this player stops", async () => {
  const { sent, send, newId } = recorder([failure(409, "playback_progress_conflict")]);
  const saver = new logic.ProgressSaver({
    mediaId: "m", revision: 3, send, newId, now: () => Date.parse("2026-11-06T20:00:00Z"),
    read: async () => ({ revision: 9, updatedAt: "2026-11-06T20:30:00Z" }),
  });
  assert.equal(await saver.save(5000, 60_000), false);
  assert.equal(saver.stopped, true);
  assert.equal(sent.length, 1);
  assert.equal(logic.keepsLocalProgress(Date.parse("2026-11-06T20:00:00Z"), "2026-11-06T20:00:04Z"), true);
  assert.equal(logic.keepsLocalProgress(Date.parse("2026-11-06T20:00:00Z"), null), true);
});

test("positions arriving while a save runs are coalesced to the newest one", async () => {
  let release;
  const gate = new Promise((resolve) => (release = resolve));
  const sent = [];
  let revision = 0;
  const saver = new logic.ProgressSaver({
    mediaId: "m",
    send: async (_, body) => {
      sent.push(body.positionMilliseconds);
      if (sent.length === 1) await gate;
      return { revision: ++revision };
    },
  });
  const first = saver.save(1000, 60_000);
  saver.save(2000, 60_000);
  saver.save(3000, 60_000);
  release();
  await first;
  assert.deepEqual(sent, [1000, 3000]);
});

test("a title without a known duration is not saved", async () => {
  const { sent, send, newId } = recorder([]);
  const saver = new logic.ProgressSaver({ mediaId: "m", send, newId });
  assert.equal(await saver.save(1000, 0), false);
  assert.equal(sent.length, 0);
});

test("the player says when a title ends, in the viewer's time and at the chosen speed", () => {
  const now = new Date(2026, 9, 25, 1, 10, 52);
  assert.equal(logic.endsAt(36, 3895, 1, now, "de-DE"), "Ends at 2:15");
  assert.equal(logic.endsAt(0, 3600, 2, now, "de-DE"), "Ends at 1:40");
  assert.equal(logic.endsAt(0, 0, 1, now), "");
  assert.equal(logic.rateLabel(1), "1x");
  assert.equal(logic.rateLabel(0.75), "0.75x");
});

test("Up Next shows in the last 20 seconds of an episode-length title only", () => {
  const base = { duration: 2400, hasNext: true, autoplay: true, stopsAtEnd: false, dismissed: false };
  assert.equal(logic.showsUpNext({ ...base, position: 2385 }), true);
  assert.equal(logic.showsUpNext({ ...base, position: 2300 }), false);
  assert.equal(logic.showsUpNext({ ...base, position: 2385, hasNext: false }), false);
  assert.equal(logic.showsUpNext({ ...base, position: 2385, stopsAtEnd: true }), false);
  assert.equal(logic.showsUpNext({ ...base, position: 2385, dismissed: true }), false);
  assert.equal(logic.showsUpNext({ ...base, duration: 200, position: 190 }), false);
  assert.equal(logic.upNextSeconds(2385.2, 2400), 15);
});

test("the player's subtitle line names the show, season and episode like the Mac", () => {
  assert.equal(logic.playerSubtitle({ kind: "episode", parentTitle: "Mr. Robot", seasonNumber: 1, episodeNumber: 1 }), "Mr. Robot · Season 1 · Episode 1");
  assert.equal(logic.playerSubtitle({ kind: "episode", parentTitle: "Top Gear", seasonNumber: 0, episodeNumber: 3 }), "Top Gear · Specials · Episode 3");
  assert.equal(logic.playerSubtitle({ kind: "movie", title: "Heat" }), "NOW PLAYING");
});

test("playback preferences stay within the Mac's limits", () => {
  assert.deepEqual(logic.normalizePreferences(null), { ...logic.PLAYBACK_DEFAULTS });
  const odd = logic.normalizePreferences({ defaultPlaybackRate: 3, seekInterval: 2, controlsAutoHideDelay: 99, defaultVolume: -1, nightMode: true });
  assert.equal(odd.defaultPlaybackRate, 1);
  assert.equal(odd.seekInterval, 5);
  assert.equal(odd.controlsAutoHideDelay, 10);
  assert.equal(odd.defaultVolume, 0);
  assert.equal(odd.nightMode, true);
});

test("cast and crew follow the Mac: actors with their roles, crew with their jobs, billing order", () => {
  const credits = [
    { name: "Aaron Paul", department: "Acting", character: "Jesse Pinkman", order: 1, personKey: "p2", profile: { path: "/api/v1/artwork/b" } },
    { name: "Bryan Cranston", department: "Acting", character: "Walter White", order: 0, personKey: "p1" },
    { name: "Bryan Cranston", department: "Directing", job: "Director", order: 9, personKey: "p1", profile: { path: "/api/v1/artwork/a" } },
    { name: "Vince Gilligan", department: "Writing", job: "Creator", order: 20, personKey: "p3" },
    { name: "Aaron Paul", department: "Acting", character: "Jesse Pinkman", order: 1, personKey: "p2" },
  ];
  assert.deepEqual(logic.starring(credits), ["Bryan Cranston", "Aaron Paul"]);
  const cards = logic.people(credits);
  assert.deepEqual(cards.map((card) => [card.name, card.subtitle]), [["Bryan Cranston", "Walter White"], ["Aaron Paul", "Jesse Pinkman"], ["Vince Gilligan", "Creator"]]);
  assert.equal(cards[0].profile.path, "/api/v1/artwork/a");
});

test("information fields match the Mac for shows and movies", () => {
  const show = logic.informationFields({ item: { kind: "series" }, metadata: { year: 2008, studios: ["Sony"], countries: ["", "US"], genres: ["Drama", "Crime"] }, seasons: [{ episodes: [1, 2] }, { episodes: [1] }] });
  assert.deepEqual(show.map((field) => [field.title, field.value]), [["Seasons", "2"], ["Episodes", "3"], ["Studio", "Sony"], ["Released", "2008"], ["Country of Origin", "US"], ["Genres", "Drama, Crime"], ["FSK", null]]);
  const movie = logic.informationFields({ item: { kind: "movie" }, metadata: { runtimeMinutes: 132, fskAge: 16 } });
  assert.deepEqual(movie.map((field) => field.title), ["Runtime", "Release Year", "Genres", "Studio", "Country of Origin", "FSK"]);
  assert.equal(movie[0].value, "132 min");
  assert.equal(movie[5].value, "FSK 16");
});

test("supplements split into Trailers and Extras; play labels and metadata lines match the Mac", () => {
  const groups = logic.supplementGroups([{ item: { kind: "trailer" }, category: "Trailer" }, { item: { kind: "extra" }, category: "Behind the Scenes" }, { item: { kind: "extra" }, category: "Teaser Trailer" }]);
  assert.deepEqual(groups.map((group) => [group.title, group.items.length]), [["Trailers", 2], ["Extras", 1]]);
  assert.equal(logic.detailPlayLabel({ kind: "series" }, { action: "resume", target: { seasonNumber: 2, episodeNumber: 10 } }), "Resume S02 E10");
  assert.equal(logic.detailPlayLabel({ kind: "movie" }, { action: "playAgain" }), "Play Again");
  assert.equal(logic.detailMetadataLine({ kind: "movie", year: 2019 }, { runtimeMinutes: 132 }), "MOVIE  ·  2019  ·  132 MIN");
  assert.equal(logic.detailMetadataLine({ kind: "series" }, { year: 2008 }), "TV SHOW  ·  2008");
  assert.equal(logic.seasonTitle(0), "Specials");
});

test("library browsing builds the server's query like the Mac's filters", () => {
  assert.deepEqual(logic.browseQuery("library", {}), {});
  assert.deepEqual(logic.browseQuery("movies", { kind: "series", favorites: true, watch: "unplayed" }), { kind: "movie", favorite: "true", watchState: "unplayed" });
  assert.deepEqual(logic.browseQuery("recent", {}), { sort: "dateAdded", direction: "descending" });
  assert.deepEqual(logic.browseQuery("library", { genre: "Drama", yearFrom: 2010, yearTo: 2005, sort: "releaseYear" }),
    { genre: "Drama", yearFrom: "2010", yearTo: "2010", sort: "releaseYear", direction: "ascending" });
  assert.deepEqual(logic.browseFacets([{ genres: ["Drama", "Crime"], year: 2008 }, { genres: ["Comedy", "Drama"], year: 2015 }]),
    { genres: ["Comedy", "Crime", "Drama"], years: [2015, 2008] });
});

test("watch time reads in minutes, hours and days like the Mac app", () => {
  assert.equal(logic.watchTime(0), "0 min");
  assert.equal(logic.watchTime(20), "Under 1 min");
  assert.equal(logic.watchTime(45 * 60), "45 min");
  assert.equal(logic.watchTime(125 * 60), "2 h 5 min");
  assert.equal(logic.watchTime(24 * 3600), "1 day");
  assert.equal(logic.watchTime(76 * 3600), "3 days 4 h");
  assert.equal(logic.watchHours(0.5), "30 min");
  assert.equal(logic.watchHours(10 / 60), "10 min");
  assert.equal(logic.watchHours(undefined), "0 min");
});

test("ISO weeks start on their Monday", () => {
  const start = logic.weekStart("2026-W43");
  assert.deepEqual([start.getFullYear(), start.getMonth(), start.getDate(), start.getDay()], [2026, 9, 19, 1]);
  assert.equal(logic.weekStart("2021-W01").getDate(), 4);
  assert.equal(logic.weekStart("October"), null);
});

test("smart list rules travel in the protocol's names and old lists still open", () => {
  const json = logic.smartRulesJson({
    kind: "movie", genres: ["Drama"], yearMin: null, yearMax: 2020, watchedState: "inProgress",
    addedWithinDays: null, favoritesOnly: true, textContains: "", matchAny: true,
  });
  assert.deepEqual(JSON.parse(json), {
    kind: "movie", genres: ["Drama"], yearMax: 2020, watchedState: "inProgress", favoritesOnly: true, combination: "or",
  });
  assert.deepEqual(logic.readSmartRules(json), {
    kind: "movie", genres: ["Drama"], yearMin: null, yearMax: 2020, watchedState: "inProgress",
    addedWithinDays: null, favoritesOnly: true, textContains: "", matchAny: true,
  });
  // Saved by the earlier browser app and by the Mac app.
  const web = logic.readSmartRules('{"watchState":"completed","matchAny":true,"textContains":"x"}');
  assert.equal(web.watchedState, "watched");
  assert.equal(web.matchAny, true);
  const mac = logic.readSmartRules('{"kind":"movies","watched":"unwatched","search":"Alien","match":"all"}');
  assert.equal(mac.kind, "movie");
  assert.equal(mac.watchedState, "unwatched");
  assert.equal(mac.textContains, "Alien");
  assert.equal(mac.matchAny, false);
  assert.equal(logic.readSmartRules("not json").kind, "");
});
