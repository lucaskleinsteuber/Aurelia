// The live player's rules without a page: `node --test tests/WebApp`.

import test from "node:test";
import assert from "node:assert/strict";
import * as live from "../../src/Aurelia.Server/WebApp/js/live-logic.js";

test("codec support asks the browser for each family and leaves out refused ones", () => {
  const chrome = (type) => /avc1|vp09|av01|mp4a\.40|opus|flac|mp4a\.6B/.test(type);
  assert.deepEqual(live.codecSupport(chrome), { videoCodecs: ["h264", "av1", "vp9"], audioCodecs: ["aac", "mp3", "opus", "flac"] });
  const safari = (type) => /avc1|hvc1|mp4a\.40|ac-3|ec-3/.test(type);
  assert.deepEqual(live.codecSupport(safari), { videoCodecs: ["h264", "hevc"], audioCodecs: ["aac", "ac3", "eac3"] });
  assert.deepEqual(live.codecSupport(safari, ["hevc", "ac3"]), { videoCodecs: ["h264"], audioCodecs: ["aac", "eac3"] });
  const throwing = () => {
    throw new Error("not available");
  };
  assert.deepEqual(live.codecSupport(throwing), { videoCodecs: [], audioCodecs: [] });
});

test("MP4, MOV and WebM try the browser first; MKV and AVI go live at once", () => {
  for (const type of ["video/mp4", "video/quicktime", "video/x-m4v", "video/webm", "VIDEO/MP4"]) assert.equal(live.triesDirectPlay(type), true, type);
  for (const type of ["video/x-matroska", "video/x-msvideo", "", undefined]) assert.equal(live.triesDirectPlay(type), false, String(type));
});

test("the MediaSource type names the picture and the chosen sound", () => {
  const plan = { videoCodec: "avc1.640028" };
  assert.equal(live.mimeType(plan, { codec: "mp4a.40.2" }), 'video/mp4; codecs="avc1.640028,mp4a.40.2"');
  assert.equal(live.mimeType(plan, null), 'video/mp4; codecs="avc1.640028"');
  assert.equal(live.videoFamily("hvc1.2.4.L150.B0"), "hevc");
  assert.equal(live.videoFamily("avc1.640028"), "h264");
  assert.equal(live.videoFamily("mp4v.20.9"), null);
});

test("the stream address carries start, sound track and modes", () => {
  assert.equal(live.streamUrl("/api/v1/streams/abc", {}), "/api/v1/streams/abc/live?video=copy");
  assert.equal(
    live.streamUrl("/api/v1/streams/abc", { start: 600.123456, audio: 2, audioMode: "copy", video: "h264" }),
    "/api/v1/streams/abc/live?start=600.123&audio=2&audioMode=copy&video=h264");
});

test("reading pauses with a minute ahead and old parts are trimmed a minute behind", () => {
  assert.equal(live.shouldRead([], 0), true);
  assert.equal(live.shouldRead([[0, 30]], 10), true);
  assert.equal(live.shouldRead([[0, 75]], 10), false);
  // A playhead outside every range always needs data.
  assert.equal(live.shouldRead([[0, 75]], 200), true);
  assert.equal(live.trimRange([[0, 300]], 50), null);
  assert.deepEqual(live.trimRange([[0, 300]], 200), [0, 140]);
  assert.equal(live.trimRange([[138, 300]], 200), null);
  assert.deepEqual(live.ranges({ length: 2, start: (index) => index * 100, end: (index) => index * 100 + 50 }), [[0, 50], [100, 150]]);
});

test("the buffer window shrinks for high bitrates so a browser's cap is never reached", () => {
  assert.deepEqual(live.bufferWindow(null), { ahead: 20, behind: 20 });
  // 4 Mbit/s: a full minute ahead and behind fits.
  assert.deepEqual(live.bufferWindow(500_000), { ahead: 60, behind: 33.554432 });
  // A 40 Mbit/s 4K remux keeps about ten seconds ahead and five behind.
  const remux = live.bufferWindow(5_000_000);
  assert.equal(remux.ahead, 10.0663296);
  assert.equal(remux.behind, 5);
  // Ahead plus behind stays well below Firefox's 100 MB at every bitrate.
  for (const rate of [250_000, 1_000_000, 2_500_000, 10_000_000]) {
    const window = live.bufferWindow(rate);
    assert.ok((window.ahead + window.behind) * rate <= 70 * 1024 * 1024 || window.ahead === 10, String(rate));
  }
});

test("a seek plays what arrived, waits for a running stream nearby and restarts elsewhere", () => {
  const buffered = [[598, 640]];
  assert.equal(live.seekAction({ buffered, target: 620, streaming: true, streamStart: 600 }), "play");
  assert.equal(live.seekAction({ buffered, target: 650, streaming: true, streamStart: 600 }), "wait");
  assert.equal(live.seekAction({ buffered, target: 700, streaming: true, streamStart: 600 }), "restart");
  assert.equal(live.seekAction({ buffered, target: 100, streaming: true, streamStart: 600 }), "restart");
  assert.equal(live.seekAction({ buffered, target: 650, streaming: false, streamStart: 600 }), "restart");
  // Right after a new stream starts, nothing has arrived yet: its own start point waits.
  assert.equal(live.seekAction({ buffered: [], target: 1200, streaming: true, streamStart: 1200 }), "wait");
});

test("the first sound track is the one chosen before, else the plan's", () => {
  const plan = { audioTrack: 1, audioTracks: [{ index: 1 }, { index: 3 }] };
  assert.equal(live.startTrack(plan, 3), 3);
  assert.equal(live.startTrack(plan, 7), 1);
  assert.equal(live.startTrack({ audioTrack: null, audioTracks: [] }, null), null);
});

test("sound tracks are named by language, title and format", () => {
  assert.equal(live.trackLabel({ language: "eng", format: "dts", channels: 6 }), "English · DTS 5.1");
  assert.equal(live.trackLabel({ language: "ger", title: "Kommentar", format: "ac3", channels: 2 }), "German · Kommentar · Dolby Digital Stereo");
  assert.equal(live.trackLabel({ language: null, format: "aac", channels: 8 }, 1), "Track 2 · AAC 7.1");
  assert.equal(live.trackLabel({ language: "eng", title: "English", format: "truehd", channels: 8 }), "English · Dolby TrueHD 7.1");
});

test("live failures explain themselves; formats the server cannot convert fall back to the usual message", () => {
  assert.match(live.liveProblem(429, "conversion_busy"), /converting other titles/);
  assert.match(live.liveProblem(503, "media_unavailable"), /storage is offline/);
  assert.match(live.liveProblem(0, "offline"), /isn’t answering/);
  assert.equal(live.liveProblem(422, "conversion_not_possible"), null);
  assert.match(live.liveProblem(500, "conversion_failed"), /couldn’t convert/);
});

test("subtitle labels distinguish text, forced and unsupported bitmap tracks", () => {
  assert.equal(live.subtitleLabel({ language: "eng", format: "subrip", supported: true }), "English · SubRip");
  assert.equal(live.subtitleLabel({ language: "deu", title: "Signs", format: "ass", isForced: true, supported: true }), "German · Signs · ASS · Forced");
  assert.equal(live.subtitleLabel({ format: "dvd_subtitle", supported: false }, 2), "Subtitle 3 · VobSub · Not supported in this browser");
  assert.match(live.subtitleLabel({ format: "hdmv_pgs_subtitle", supported: false }), /PGS · Not supported/);
});

test("subtitle selection preserves absolute cue times before and after a resumed seek", () => {
  assert.equal(live.subtitleUrl("/api/v1/streams/ticket", 4), "/api/v1/streams/ticket/subtitles/4");
  const first = { mode: "disabled", cues: [{ startTime: 6, endTime: 9, text: "Second cue" }] };
  const second = { mode: "showing", cues: [{ startTime: 10, endTime: 12, text: "Later cue" }] };
  live.selectSubtitle([first, second], first);
  assert.deepEqual([first.mode, second.mode], ["showing", "disabled"]);
  assert.equal(first.cues[0].startTime, 6);
  assert.equal(first.cues[0].endTime, 9);
  live.selectSubtitle([first, second], null);
  live.selectSubtitle([first, second], first);
  assert.equal(first.cues[0].startTime, 6);
  assert.deepEqual([first.mode, second.mode], ["showing", "disabled"]);
});

test("dragging across unbuffered time starts one new stream where the playhead comes to rest", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { LiveSource, SEEK_SETTLE_MS } = await import("../../src/Aurelia.Server/WebApp/js/live.js");
  const source = Object.create(LiveSource.prototype);
  const restarts = [];
  Object.assign(source, { destroyed: false, streaming: true, streamStart: 0, waiters: new Set(),
    buffer: { buffered: [[0, 30]] }, video: { currentTime: 0 }, restart: (at) => restarts.push(at) });
  for (const time of [200, 400, 600, 800]) { source.video.currentTime = time; source.seeking(); t.mock.timers.tick(50); }
  assert.deepEqual(restarts, []);
  t.mock.timers.tick(SEEK_SETTLE_MS);
  assert.deepEqual(restarts, [800]);
  source.video.currentTime = 900; source.seeking(); source.video.currentTime = 10; source.seeking();
  t.mock.timers.tick(SEEK_SETTLE_MS * 2);
  assert.deepEqual(restarts, [800], "a seek back into what has arrived cancels the pending restart");
  source.video.currentTime = 700; source.seeking(); source.destroyed = true; t.mock.timers.tick(SEEK_SETTLE_MS);
  assert.deepEqual(restarts, [800]);
});
