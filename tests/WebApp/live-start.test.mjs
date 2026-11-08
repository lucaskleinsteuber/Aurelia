// Starting live playback in the production Player with fake media objects: no decoder,
// browser or stream runs.
import test from "node:test";
import assert from "node:assert/strict";

class FakeMediaSource extends EventTarget {
  static isTypeSupported() { return true; }
  constructor() { super(); this.readyState = "closed"; queueMicrotask(() => this.dispatchEvent(new Event("sourceopen"))); }
  addSourceBuffer() { throw new DOMException("Refused after all", "NotSupportedError"); }
}
globalThis.MediaSource = FakeMediaSource;
const { Player, UNPLAYABLE } = await import("../../src/Aurelia.Server/WebApp/js/player.js");

const plan = { video: "copy", videoCodec: "avc1.640028", audioTracks: [{ index: 1, codec: "mp4a.40.2", mode: "aac" }], audioTrack: 1, durationSeconds: 600 };

function player(overrides = {}) {
  const p = Object.create(Player.prototype);
  const video = new EventTarget();
  Object.assign(video, { currentTime: 0, removeAttribute() {}, load() {}, play: async () => {} });
  Object.assign(p, { closed: false, live: null, video, item: { id: "film" }, startScreen: { hidden: true }, source: { streamPath: "/api/v1/streams/t" },
    preferences: {}, trackChoices: { audio: () => null }, preferredAudio: null, embeddedSubtitles: [],
    notices: [], showNotice(text, blocking) { this.notices.push({ text, blocking }); }, restoreTrackChoices() {}, play: async () => {}, ...overrides });
  return p;
}

test("a stream the browser refuses while opening shows the unplayable notice instead of loading forever", async (t) => {
  t.mock.method(URL, "createObjectURL", () => "blob:fake");
  t.mock.method(URL, "revokeObjectURL", () => {});
  const p = player({ api: { conversionPlan: async () => plan } });
  await p.startLive(0);
  assert.deepEqual(p.notices, [{ text: UNPLAYABLE, blocking: true }]);
  assert.equal(p.liveStarting, false);
});

test("live playback starts once while its plan is still loading", async () => {
  let plans = 0; let release;
  const p = player({ canConvert: true, resumeAt: 0, openLive: async () => { plans++; await new Promise((resolve) => { release = resolve; }); } });
  const first = p.startLive(0);
  assert.equal(p.switchToLive(), true, "a second request counts as handled, so no unplayable notice follows");
  await p.startLive(0);
  assert.equal(plans, 1);
  release(); await first;
  assert.equal(p.liveStarting, false);
});
