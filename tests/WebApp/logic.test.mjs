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
  assert.deepEqual(logic.parseRoute("/movies", "?sort=dateAdded"), { name: "movies", sort: "dateAdded" });
  assert.deepEqual(logic.parseRoute("/shows"), { name: "shows", sort: "title" });
  assert.deepEqual(logic.parseRoute("/search", "?q=harbor"), { name: "search", query: "harbor" });
  assert.deepEqual(logic.parseRoute(`/title/${id.toUpperCase()}`), { name: "title", id });
  assert.deepEqual(logic.parseRoute("/title/not-an-id"), { name: "home" });
  assert.deepEqual(logic.parseRoute("/anything/else"), { name: "home" });
  for (const route of [{ name: "home" }, { name: "movies", sort: "releaseYear" }, { name: "shows", sort: "title" },
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
