// Rules of the live player that need no page: which codecs this browser decodes, when to read
// more of the stream, when a seek needs a new stream and how sound tracks are named. They run
// the same in a browser and in `node --test tests/WebApp`.

/** At most a minute is kept ahead of the playhead; reading pauses beyond it, so the server waits too. */
export const AHEAD_SECONDS = 60;
/** What played more than a minute ago is removed again, so a phone's memory never fills up. */
export const BEHIND_SECONDS = 60;
/**
 * Browsers cap the video they keep (Firefox at about 100 MB), so the window is also measured in
 * bytes: a high bitrate keeps fewer seconds ahead and behind.
 */
export const AHEAD_BYTES = 48 * 1024 * 1024;
export const BEHIND_BYTES = 16 * 1024 * 1024;
/** A seek this far beyond what has arrived waits for the running stream instead of starting anew. */
export const WAIT_SECONDS = 15;

export const LIVE_FEATURE = "live-conversion-v1";

const VIDEO_PROBES = {
  h264: "avc1.640028",
  hevc: "hvc1.1.6.L120.B0",
  av1: "av01.0.08M.08",
  vp9: "vp09.00.40.08",
};
const AUDIO_PROBES = {
  aac: "mp4a.40.2",
  mp3: "mp4a.6B",
  ac3: "ac-3",
  eac3: "ec-3",
  opus: "opus",
  flac: "flac",
};

/**
 * The codec families this browser decodes from fragmented MP4, for the server's plan.
 * `without` leaves out families whose exact codec string the browser refused after all.
 */
export function codecSupport(isTypeSupported, without = []) {
  const supported = (codec) => {
    try {
      return Boolean(isTypeSupported(`video/mp4; codecs="${codec}"`));
    } catch {
      return false;
    }
  };
  const pick = (probes) => Object.entries(probes).filter(([family, codec]) => !without.includes(family) && supported(codec)).map(([family]) => family);
  return { videoCodecs: pick(VIDEO_PROBES), audioCodecs: pick(AUDIO_PROBES) };
}

/** The codec family of an MP4 codec string, such as "hevc" for "hvc1.2.4.L150.B0". */
export function videoFamily(codec) {
  const prefix = String(codec ?? "").split(".")[0];
  return { avc1: "h264", avc3: "h264", hvc1: "hevc", hev1: "hevc", av01: "av1", vp09: "vp9" }[prefix] ?? null;
}

/** Files a browser may open itself; everything else (MKV, AVI and others) goes the live way at once. */
export function triesDirectPlay(contentType) {
  return ["video/mp4", "video/quicktime", "video/x-m4v", "video/webm"].includes(String(contentType ?? "").toLowerCase());
}

/** The MediaSource type of a plan with one sound track, such as `video/mp4; codecs="avc1.640028,mp4a.40.2"`. */
export function mimeType(plan, track) {
  return `video/mp4; codecs="${[plan.videoCodec, track?.codec].filter(Boolean).join(",")}"`;
}

/** The address of a live stream for a playback ticket's stream path. */
export function streamUrl(streamPath, { start = 0, audio = null, audioMode = "aac", video = "copy" } = {}) {
  const query = new URLSearchParams();
  if (start > 0) query.set("start", String(Math.round(start * 1000) / 1000));
  if (audio != null) {
    query.set("audio", String(audio));
    query.set("audioMode", audioMode);
  }
  query.set("video", video);
  return `${streamPath}/live?${query}`;
}

/** Buffered ranges as plain pairs, from a TimeRanges object or an array. */
export function ranges(timeRanges) {
  if (Array.isArray(timeRanges)) return timeRanges;
  const result = [];
  for (let index = 0; index < (timeRanges?.length ?? 0); index += 1) result.push([timeRanges.start(index), timeRanges.end(index)]);
  return result;
}

/** The end of the buffered range that holds `time`, or null when nothing around it has arrived. */
export function bufferedEnd(buffered, time, tolerance = 0.3) {
  const range = buffered.find(([start, end]) => time >= start - tolerance && time <= end + tolerance);
  return range ? range[1] : null;
}

/**
 * Seconds to keep ahead of and behind the playhead for a stream of `bytesPerSecond`; before the
 * bitrate is known, a cautious 20 seconds ahead.
 */
export function bufferWindow(bytesPerSecond) {
  if (!(bytesPerSecond > 0)) return { ahead: 20, behind: 20 };
  const clamp = (value, low, high) => Math.min(high, Math.max(low, value));
  return {
    ahead: clamp(AHEAD_BYTES / bytesPerSecond, 10, AHEAD_SECONDS),
    behind: clamp(BEHIND_BYTES / bytesPerSecond, 5, BEHIND_SECONDS),
  };
}

/** Whether to read more of the stream now: less than a minute is ready ahead of the playhead. */
export function shouldRead(buffered, time, ahead = AHEAD_SECONDS) {
  const end = bufferedEnd(buffered, time);
  return end == null || end - time < ahead;
}

/** The part to remove because it played more than a minute ago, as [start, end], or null. */
export function trimRange(buffered, time, behind = BEHIND_SECONDS) {
  if (buffered.length === 0) return null;
  const first = buffered[0][0];
  const cut = time - behind;
  // A few seconds of slack, so the buffer is not trimmed on every append.
  return cut - first > 5 ? [first, cut] : null;
}

/**
 * What a seek to `target` needs: "play" when it has arrived, "wait" when the running stream
 * reaches it soon, and "restart" when a new stream must begin there.
 */
export function seekAction({ buffered, target, streaming, streamStart }) {
  if (bufferedEnd(buffered, target) != null) return "play";
  if (streaming && target >= streamStart - 0.5) {
    const reached = Math.max(streamStart, ...buffered.filter(([, end]) => end >= streamStart).map(([, end]) => end));
    if (target <= reached + WAIT_SECONDS) return "wait";
  }
  return "restart";
}

/** The track to start with: the one played before when it still exists, else the plan's choice. */
export function startTrack(plan, preferred) {
  const tracks = plan?.audioTracks ?? [];
  if (preferred != null && tracks.some((track) => track.index === preferred)) return preferred;
  return plan?.audioTrack ?? tracks[0]?.index ?? null;
}

const FORMATS = { aac: "AAC", ac3: "Dolby Digital", eac3: "Dolby Digital Plus", truehd: "Dolby TrueHD", dts: "DTS", mp3: "MP3", opus: "Opus", flac: "FLAC", vorbis: "Vorbis", pcm_s16le: "PCM", pcm_s24le: "PCM" };

/** A language code from the file ("eng", "ger") as a name ("English", "German"). */
export function languageName(code, locale = "en") {
  if (!code) return "";
  try {
    const name = new Intl.DisplayNames([locale], { type: "language", fallback: "none" }).of(code);
    if (name && name !== "root") return name;
  } catch {
    // Not a language code a browser knows.
  }
  return String(code).toUpperCase();
}

function layout(channels) {
  if (channels === 1) return "Mono";
  if (channels === 2) return "Stereo";
  if (channels === 6) return "5.1";
  if (channels === 8) return "7.1";
  return channels > 0 ? `${channels} channels` : "";
}

/** "English · Director’s Commentary · Dolby Digital 5.1", or "Track 2 · DTS 5.1" without a language. */
export function trackLabel(track, position = 0, locale = "en") {
  const language = languageName(track.language, locale);
  const format = [FORMATS[track.format] ?? String(track.format ?? "").toUpperCase(), layout(track.channels)].filter(Boolean).join(" ");
  const title = track.title && track.title !== language ? track.title : "";
  return [language || `Track ${position + 1}`, title, format].filter(Boolean).join(" · ");
}

/** Embedded subtitle labels include formats and make unsupported bitmap tracks explicit. */
export function subtitleLabel(track, position = 0, locale = "en") {
  const language = languageName(track.language, locale);
  const title = track.title && track.title !== language ? track.title : "";
  const format = { subrip: "SubRip", srt: "SubRip", ass: "ASS", ssa: "SSA", mov_text: "Text", webvtt: "WebVTT", hdmv_pgs_subtitle: "PGS", dvd_subtitle: "VobSub" }[track.format]
    ?? String(track.format ?? "").toUpperCase();
  return [language || `Subtitle ${position + 1}`, title, format, track.isForced ? "Forced" : "", track.isSdh ? "SDH" : "", track.supported === false ? "Not supported in this browser" : ""].filter(Boolean).join(" · ");
}

/** A complete WebVTT track uses title timestamps, independent of the video's current seek offset. */
export function subtitleUrl(streamPath, index) {
  return `${streamPath}/subtitles/${encodeURIComponent(index)}`;
}

/** Native WebVTT cues stay on the title timeline when selecting a track or seeking the video. */
export function selectSubtitle(tracks, selected) {
  for (const track of tracks) track.mode = track === selected ? "showing" : "disabled";
}

/** What the player says when a live stream fails, from the server's answer. */
export function liveProblem(status, code) {
  if (status === 0) return "The server isn’t answering. Check that it is switched on, then try again.";
  if (status === 401 || status === 403) return "The profile session ended. Choose your profile again.";
  if (status === 503) return "This title’s storage is offline. Connect the drive, then try again.";
  if (status === 429) return "The server is converting other titles right now. Try again in a moment.";
  if (status === 404) return "This file isn’t available on the server.";
  if (code === "conversion_unavailable" || code === "conversion_not_possible" || code === "media_probe_failed") return null;
  return "The server couldn’t convert this title. Try again.";
}
