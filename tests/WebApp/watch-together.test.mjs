import { test } from "node:test";
import assert from "node:assert/strict";
import { clockOffset, createWatchTogether, followSteps, partyNotice, partyPosition } from "../../src/Aurelia.Server/WebApp/js/watch-together.js";

// Watch Together in the browser with an invented party, server and player; nothing is played.
const start = Date.parse("2026-11-07T20:00:00Z");
const film = "00000000-0000-4000-8000-0000000000f1";
const episode = "00000000-0000-4000-8000-0000000000f2";

function party({ playing = false, position = 0, waiting = false, revision = 2, action = "pause", media = film, buffering = false } = {}) {
  return {
    id: "00000000-0000-4000-8000-0000000000a1", mediaId: media, title: "Invented Film", isPlaying: playing, isWaiting: waiting,
    positionMilliseconds: position, updatedAt: "2026-11-07T20:00:00.0000000+00:00", serverTime: "2026-11-07T20:00:00.0000000+00:00",
    revision, lastAction: action, lastActionBy: "Mia",
    members: [{ id: "m1", name: "Browser", deviceName: "Chrome", isBuffering: buffering, isHost: false, isYou: true },
      { id: "m2", name: "Mia", deviceName: "Mac", isBuffering: false, isHost: true, isYou: false }],
  };
}

function fakePlayer(position = 0) {
  const player = { mediaId: film, at: position, isPlaying: true, isReady: true, steps: [],
    position: () => player.at, playing: () => player.isPlaying, ready: () => player.isReady,
    play: () => { player.isPlaying = true; player.steps.push("play"); },
    pause: () => { player.isPlaying = false; player.steps.push("pause"); },
    seek: (ms) => { player.at = ms; player.steps.push(`seek ${ms}`); } };
  return player;
}

function fakeApi(answer) {
  const sent = [];
  return { sent,
    createWatchParty: async () => answer, joinWatchParty: async () => answer, leaveWatchParty: async () => null,
    watchPartyCommand: async (_, body) => { sent.push(body); return answer; },
    watchParty: (_, __, ___, { signal }) => new Promise((_, reject) => signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })))) };
}

test("the shared position runs only while playing and nobody waits", () => {
  assert.equal(partyPosition(party({ playing: true }), start + 10_000), 10_000);
  assert.equal(partyPosition(party({ playing: true, waiting: true }), start + 10_000), 0);
  assert.equal(partyPosition(party({ position: 42_000 }), start + 10_000), 42_000);
  assert.equal(clockOffset("2026-11-07T20:00:10Z", start, start + 2_000), 9_000);
  assert.equal(partyNotice(party()), "Mia paused");
  assert.equal(partyNotice(party({ action: "change" })), "Mia started Invented Film");
});

test("small drift is left alone and large drift jumps", () => {
  assert.deepEqual(followSteps(party({ playing: true }), start + 10_000, 9_000, true), []);
  assert.deepEqual(followSteps(party({ playing: true }), start + 10_000, 3_000, true), [{ step: "seek", position: 10_000 }]);
  assert.deepEqual(followSteps(party({ position: 42_000 }), start, 42_800, true), [{ step: "seek", position: 42_000 }, { step: "pause" }]);
});

test("the attached player follows, ignores older answers and echoes of remote steps", async () => {
  let clock = start;
  const api = fakeApi(party({ playing: false, position: 600_000 }));
  const session = createWatchTogether({ api, deviceName: "Chrome", now: () => clock });
  const player = fakePlayer(1_200_000);
  assert.equal(await session.join("party"), true);
  session.attach(player);
  assert.deepEqual(player.steps, ["seek 600000", "pause"]);
  session.receive(party({ playing: true, position: 1_200_000, revision: 1, action: "started" }), clock, true);
  assert.deepEqual(player.steps, ["seek 600000", "pause"]);
  assert.equal(session.state.revision, 2);
  // The browser's own pause event right after the remote step is not sent back.
  session.userAction("pause", 600_000);
  clock += 1_000;
  session.userAction("seek", 700_000);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepEqual(api.sent.map((body) => body.action), ["ready", "seek"]);
  await session.leave();
  assert.equal(session.state, null);
});

test("a remote title change opens once and the player moving on changes the party", async () => {
  const opened = [];
  const api = fakeApi(party({ playing: true, revision: 4, action: "change", media: episode }));
  const session = createWatchTogether({ api, deviceName: "Chrome", now: () => start, openTitle: (id) => opened.push(id) });
  const player = fakePlayer();
  session.attach(player);
  await session.join("party");
  session.receive(party({ playing: true, revision: 5, action: "ready", media: episode }), start, false);
  assert.deepEqual(opened, [episode]);
  assert.equal(session.isChangingTitle, true);
  player.mediaId = episode;
  session.attach(player);
  assert.equal(session.isChangingTitle, false);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.ok(api.sent.some((body) => body.action === "ready"));
  await session.leave();
});
