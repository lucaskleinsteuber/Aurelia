// Rules of adaptive streaming that need no page: reading the server's HLS playlists, finding the
// segment for a time and choosing a quality from the measured speed. They run the same in a
// browser and in `node --test tests/WebApp`.

export const ADAPTIVE_FEATURE = "adaptive-streaming-v1";

/** Where the player's quality choice is remembered in this browser. */
export const QUALITY_KEY = "aurelia.streamingQuality";

/** Below this much video ahead of the playhead, the next segment comes in a lower quality. */
export const LOW_BUFFER_SECONDS = 8;
/** Stable segments needed before stepping up to a better quality. */
export const STABLE_SEGMENTS = 3;
/** Without a measurement yet, playback starts at the best quality up to this rate. */
export const START_BITS_PER_SECOND = 5_000_000;

/** "original" (the file, or its plain live stream), "auto", or a quality such as "720p". */
export function normalizeQuality(value) {
  const text = String(value ?? "").trim();
  if (text === "auto" || text === "original") return text;
  return /^[1-9][0-9]{2,3}p$/.test(text) ? text : "original";
}

/** The master playlist's address for a playback ticket's stream path and sound track. */
export function masterUrl(streamPath, audio = null) {
  return `${streamPath}/hls/master.m3u8${audio == null ? "" : `?audio=${encodeURIComponent(audio)}`}`;
}

function attributes(text) {
  const values = {};
  for (const match of text.matchAll(/([A-Z0-9-]+)=("[^"]*"|[^,]*)/g)) {
    values[match[1]] = match[2].startsWith("\"") ? match[2].slice(1, -1) : match[2];
  }
  return values;
}

/**
 * The qualities of a master playlist, best first as the server lists them:
 * `{ id, uri, bandwidth, averageBandwidth, width, height, codecs }`.
 */
export function parseMaster(text) {
  const lines = String(text ?? "").split(/\r?\n/).map((line) => line.trim());
  if (lines[0] !== "#EXTM3U") throw new Error("This is not an HLS playlist.");
  const variants = [];
  for (let index = 0; index < lines.length; index += 1) {
    if (!lines[index].startsWith("#EXT-X-STREAM-INF:")) continue;
    const values = attributes(lines[index].slice("#EXT-X-STREAM-INF:".length));
    const uri = lines.slice(index + 1).find((line) => line && !line.startsWith("#"));
    if (!uri) continue;
    const [width, height] = String(values.RESOLUTION ?? "").split("x").map(Number);
    variants.push({
      id: uri.split("/")[0],
      uri,
      bandwidth: Number(values.BANDWIDTH) || 0,
      averageBandwidth: Number(values["AVERAGE-BANDWIDTH"]) || Number(values.BANDWIDTH) || 0,
      width: width || 0,
      height: height || 0,
      codecs: values.CODECS ?? "",
    });
  }
  return variants;
}

/** A media playlist: its init segment and its segments with start and length in title time. */
export function parseMedia(text) {
  const lines = String(text ?? "").split(/\r?\n/).map((line) => line.trim());
  if (lines[0] !== "#EXTM3U") throw new Error("This is not an HLS playlist.");
  let init = null;
  let duration = null;
  let start = 0;
  const segments = [];
  for (const line of lines) {
    if (line.startsWith("#EXT-X-MAP:")) init = attributes(line.slice("#EXT-X-MAP:".length)).URI ?? null;
    else if (line.startsWith("#EXTINF:")) duration = Number.parseFloat(line.slice("#EXTINF:".length));
    else if (line && !line.startsWith("#") && duration != null) {
      segments.push({ uri: line, start, duration });
      start += duration;
      duration = null;
    }
  }
  return { init, segments, total: start };
}

/** The index of the segment that holds `time`, within the playlist. */
export function segmentAt(segments, time) {
  if (!segments.length) return 0;
  let low = 0;
  let high = segments.length - 1;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (segments[middle].start <= time + 0.001) low = middle;
    else high = middle - 1;
  }
  return low;
}

function rate(variant) {
  return variant.averageBandwidth || variant.bandwidth;
}

/** The quality to start with: the chosen one, or automatically the best one up to about 5 Mbit/s. */
export function initialVariant(variants, quality) {
  if (!variants.length) return -1;
  const chosen = variants.findIndex((variant) => variant.id === quality);
  if (chosen >= 0) return chosen;
  const fitting = variants.findIndex((variant) => rate(variant) <= START_BITS_PER_SECOND);
  return fitting >= 0 ? fitting : variants.length - 1;
}

/**
 * The quality for the next segment. A fixed choice stays. Automatic steps down at once when the
 * buffer runs low or the measured speed (bits a second) no longer carries the current quality,
 * to the best one it does carry; it steps up one quality only after a few stable segments with
 * plenty of room.
 */
export function nextVariant({ variants, current, quality, throughput, bufferAhead, stable }) {
  if (!variants.length) return -1;
  if (quality !== "auto") {
    const chosen = variants.findIndex((variant) => variant.id === quality);
    if (chosen >= 0) return chosen;
  }
  if (!(throughput > 0)) return current;
  const last = variants.length - 1;
  if ((bufferAhead < LOW_BUFFER_SECONDS || throughput < rate(variants[current]) * 1.1) && current < last) {
    const carried = variants.findIndex((variant, index) => index > current && rate(variant) * 1.1 <= throughput);
    return carried >= 0 ? carried : last;
  }
  if (stable >= STABLE_SEGMENTS && current > 0 && bufferAhead >= LOW_BUFFER_SECONDS && throughput > rate(variants[current - 1]) * 1.5) {
    return current - 1;
  }
  return current;
}

/** A smoothed speed: each new measurement counts for a third. */
export function smoothed(previous, sample, weight = 1 / 3) {
  if (!(sample > 0)) return previous ?? null;
  return previous > 0 ? previous * (1 - weight) + sample * weight : sample;
}

/** The menu's label of a quality choice. */
export function qualityLabel(quality, variants = []) {
  if (quality === "original") return "Original";
  if (quality === "auto") return "Automatic";
  const variant = variants.find((candidate) => candidate.id === quality);
  return variant ? `${variant.id} · ${(rate(variant) / 1_000_000).toFixed(1)} Mbit/s` : quality;
}
