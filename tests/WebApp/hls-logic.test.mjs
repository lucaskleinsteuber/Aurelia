import test from "node:test";
import assert from "node:assert/strict";
import {
  initialVariant, masterUrl, nextVariant, normalizeQuality, parseMaster, parseMedia, qualityLabel, segmentAt, smoothed,
  startsAdaptive, stallsCallForAdaptive,
} from "../../src/Aurelia.Server/WebApp/js/hls-logic.js";

const MASTER = `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=12160000,AVERAGE-BANDWIDTH=8160000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
1080p/index.m3u8?audio=2
#EXT-X-STREAM-INF:BANDWIDTH=6160000,AVERAGE-BANDWIDTH=4160000,RESOLUTION=1280x720,CODECS="avc1.64001F,mp4a.40.2"
720p/index.m3u8?audio=2
#EXT-X-STREAM-INF:BANDWIDTH=2828000,AVERAGE-BANDWIDTH=1928000,RESOLUTION=854x480,CODECS="avc1.64001E,mp4a.40.2"
480p/index.m3u8?audio=2
#EXT-X-STREAM-INF:BANDWIDTH=1478000,AVERAGE-BANDWIDTH=1028000,RESOLUTION=640x360,CODECS="avc1.64001E,mp4a.40.2"
360p/index.m3u8?audio=2
`;

const MEDIA = `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MAP:URI="init.mp4?audio=2"
#EXTINF:4.000,
0.m4s?audio=2
#EXTINF:4.000,
1.m4s?audio=2
#EXTINF:2.500,
2.m4s?audio=2
#EXT-X-ENDLIST
`;

test("the master playlist lists every quality with its rate, size and codecs", () => {
  const variants = parseMaster(MASTER);
  assert.deepEqual(variants.map((variant) => variant.id), ["1080p", "720p", "480p", "360p"]);
  assert.deepEqual(variants[1], {
    id: "720p", uri: "720p/index.m3u8?audio=2", bandwidth: 6160000, averageBandwidth: 4160000, width: 1280, height: 720,
    codecs: "avc1.64001F,mp4a.40.2",
  });
  assert.throws(() => parseMaster("<html>"), /not an HLS playlist/);
  assert.equal(masterUrl("/api/v1/streams/abc", 2), "/api/v1/streams/abc/hls/master.m3u8?audio=2");
  assert.equal(masterUrl("/api/v1/streams/abc"), "/api/v1/streams/abc/hls/master.m3u8");
});

test("a media playlist gives the init segment and each segment's place in the title", () => {
  const playlist = parseMedia(MEDIA);
  assert.equal(playlist.init, "init.mp4?audio=2");
  assert.deepEqual(playlist.segments.map((segment) => [segment.uri, segment.start, segment.duration]),
    [["0.m4s?audio=2", 0, 4], ["1.m4s?audio=2", 4, 4], ["2.m4s?audio=2", 8, 2.5]]);
  assert.equal(playlist.total, 10.5);
  assert.equal(segmentAt(playlist.segments, 0), 0);
  assert.equal(segmentAt(playlist.segments, 3.99), 0);
  assert.equal(segmentAt(playlist.segments, 4), 1);
  assert.equal(segmentAt(playlist.segments, 9), 2);
  assert.equal(segmentAt(playlist.segments, 400), 2);
  assert.equal(segmentAt([], 5), 0);
});

test("playback starts at the chosen quality or automatically at the best one up to 5 Mbit/s", () => {
  const variants = parseMaster(MASTER);
  assert.equal(initialVariant(variants, "auto"), 1);
  assert.equal(initialVariant(variants, "480p"), 2);
  assert.equal(initialVariant(variants, "2160p"), 1);
  assert.equal(initialVariant([variants[0]], "auto"), 0);
  assert.equal(initialVariant([], "auto"), -1);
});

test("automatic quality steps down at once and up only after stable segments with room", () => {
  const variants = parseMaster(MASTER);
  const base = { variants, quality: "auto", stable: 5, bufferAhead: 30 };
  // No measurement yet: stay.
  assert.equal(nextVariant({ ...base, current: 1, throughput: null }), 1);
  // 720p needs 4.16 Mbit/s; 3 Mbit/s carries 480p (1.93 × 1.1) but not 720p.
  assert.equal(nextVariant({ ...base, current: 1, throughput: 3_000_000 }), 2);
  // Hardly anything gets through: the lowest quality.
  assert.equal(nextVariant({ ...base, current: 0, throughput: 500_000 }), 3);
  // A low buffer steps down even when the speed looks fine.
  assert.equal(nextVariant({ ...base, current: 1, throughput: 9_000_000, bufferAhead: 4 }), 2);
  // Plenty of speed and room: one step up, never two.
  assert.equal(nextVariant({ ...base, current: 2, throughput: 30_000_000 }), 1);
  assert.equal(nextVariant({ ...base, current: 2, throughput: 30_000_000, stable: 2 }), 2);
  assert.equal(nextVariant({ ...base, current: 1, throughput: 12_000_000 }), 1); // 1080p needs 1.5 × 8.16
  assert.equal(nextVariant({ ...base, current: 0, throughput: 50_000_000 }), 0);
  // A fixed choice stays whatever the speed.
  assert.equal(nextVariant({ ...base, quality: "360p", current: 1, throughput: 50_000_000 }), 3);
});

test("speed measurements are smoothed and choices are read safely", () => {
  assert.equal(smoothed(null, 9_000_000), 9_000_000);
  assert.equal(Math.round(smoothed(9_000_000, 3_000_000)), 7_000_000);
  assert.equal(smoothed(9_000_000, 0), 9_000_000);
  assert.equal(normalizeQuality("auto"), "auto");
  assert.equal(normalizeQuality("720p"), "720p");
  assert.equal(normalizeQuality("../720p"), "original");
  assert.equal(normalizeQuality(null), "original");
  assert.equal(qualityLabel("720p", parseMaster(MASTER)), "720p · 4.2 Mbit/s");
  assert.equal(qualityLabel("auto"), "Automatic");
  assert.equal(qualityLabel("original"), "Original");
});

test("Automatic starts with the repackaged picture and streams qualities only when the server encodes or playback stalls", () => {
  assert.equal(startsAdaptive({ quality: "auto", video: "copy" }), false, "a picture that can be copied costs a weak server nothing");
  assert.equal(startsAdaptive({ quality: "auto", video: "copy", stalled: true }), true);
  assert.equal(startsAdaptive({ quality: "auto", video: "h264" }), true);
  assert.equal(startsAdaptive({ quality: "720p", video: "copy" }), true, "a chosen quality is honored");
  assert.equal(startsAdaptive({ quality: "original", video: "copy" }), false);
  assert.equal(startsAdaptive({ quality: "original", video: "h264" }), true);
  const now = 100_000;
  assert.equal(stallsCallForAdaptive([{ start: now - 5_000, end: now - 3_000 }], now), false, "one short stall is a hiccup");
  assert.equal(stallsCallForAdaptive([{ start: 1, end: 2 }, { start: 3, end: 4 }, { start: now - 2_000, end: now - 1_000 }], now), false,
    "stalls older than a minute are forgotten");
  assert.equal(stallsCallForAdaptive([0, 1, 2].map((index) => ({ start: now - 10_000 + index * 2_000, end: now - 9_500 + index * 2_000 })), now), true);
  assert.equal(stallsCallForAdaptive([{ start: now - 9_000, end: now }], now), true, "eight seconds of waiting");
});
