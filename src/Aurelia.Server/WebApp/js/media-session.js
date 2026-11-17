// The system's media controls for the browser player (Media Session API): media keys on a
// keyboard, Chrome's and Edge's media controls, and the lock screen on Android and in Safari on
// iPhone and iPad. The title, its show and episode and the poster appear there; play, pause,
// skipping, seeking and the previous or next episode work from there. Without the API nothing
// happens.

/** Whether this browser offers the system's media controls. */
export function supportsMediaSession(nav = globalThis.navigator, Metadata = globalThis.MediaMetadata) {
  return Boolean(nav?.mediaSession && typeof Metadata === "function");
}

/**
 * What the system shows: the title, "Show · S1 E3" for an episode or the year for a movie, and the
 * poster in two sizes. `artworkUrl(image, width)` gives an address the browser may load.
 */
export function mediaMetadataFor(item, artworkUrl = () => "") {
  if (!item) return null;
  const code = [
    item.seasonNumber != null ? `S${item.seasonNumber}` : "",
    item.episodeNumber != null ? `E${item.episodeNumber}` : "",
  ].filter(Boolean).join(" ");
  const artist = item.kind === "episode"
    ? [item.parentTitle, code].filter(Boolean).join(" · ")
    : item.year != null ? String(item.year) : "";
  const image = item.poster ?? item.backdrop ?? null;
  const artwork = [320, 640]
    .map((width) => ({ src: artworkUrl(image, width), sizes: `${width}x${Math.round(width * 1.5)}` }))
    .filter((entry) => entry.src);
  return { title: item.title ?? "", artist, album: "Aurelia", artwork };
}

/** The position the system shows, or null while it isn't known yet. */
export function positionStateFor(video) {
  const duration = Number(video?.duration);
  const position = Number(video?.currentTime);
  if (!Number.isFinite(duration) || duration <= 0 || !Number.isFinite(position)) return null;
  const rate = Number(video?.playbackRate);
  return {
    duration,
    position: Math.min(Math.max(0, position), duration),
    playbackRate: Number.isFinite(rate) && rate > 0 ? rate : 1,
  };
}

export const MEDIA_ACTIONS = Object.freeze(["play", "pause", "stop", "seekbackward", "seekforward", "seekto", "previoustrack", "nexttrack"]);

/**
 * Shows `metadata` in the system's media controls and answers its buttons with `handlers`
 * (`play`, `pause`, `stop`, `seekBy(seconds)`, `seekTo(seconds)`, `previous`, `next`). The step
 * of the skip buttons is `seekSeconds`. Returns what the player calls: `update(video, playing)`
 * keeps the position and state current, `setEpisodes(previous, next)` offers or hides the
 * episode buttons, and `detach()` clears everything when the player closes.
 */
export function attachMediaSession({ metadata, handlers, seekSeconds = 10, nav = globalThis.navigator, Metadata = globalThis.MediaMetadata }) {
  if (!supportsMediaSession(nav, Metadata) || !metadata) {
    return { update() {}, setEpisodes() {}, detach() {} };
  }
  const session = nav.mediaSession;
  const set = (action, handler) => {
    // A browser that doesn't know an action throws; the others still work.
    try { session.setActionHandler(action, handler); } catch { /* unsupported action */ }
  };
  try { session.metadata = new Metadata(metadata); } catch { session.metadata = null; }
  set("play", () => handlers.play?.());
  set("pause", () => handlers.pause?.());
  set("stop", () => handlers.stop?.());
  set("seekbackward", (details) => handlers.seekBy?.(-(details?.seekOffset || seekSeconds)));
  set("seekforward", (details) => handlers.seekBy?.(details?.seekOffset || seekSeconds));
  set("seekto", (details) => { if (Number.isFinite(details?.seekTime)) handlers.seekTo?.(details.seekTime); });
  let detached = false;
  return {
    update(video, playing) {
      if (detached) return;
      session.playbackState = playing ? "playing" : "paused";
      const state = positionStateFor(video);
      if (state && typeof session.setPositionState === "function") {
        try { session.setPositionState(state); } catch { /* a position the browser refuses */ }
      }
    },
    setEpisodes(hasPrevious, hasNext) {
      if (detached) return;
      set("previoustrack", hasPrevious ? () => handlers.previous?.() : null);
      set("nexttrack", hasNext ? () => handlers.next?.() : null);
    },
    detach() {
      if (detached) return;
      detached = true;
      for (const action of MEDIA_ACTIONS) set(action, null);
      session.metadata = null;
      session.playbackState = "none";
    },
  };
}
