// The adaptive player: plays a title the server converts in several qualities over HLS. Safari
// would play the playlists itself, but Chrome and Firefox cannot, so this small loader reads them
// with fetch and hands the init and media segments to the video element through Media Source
// Extensions, like the live player. It keeps about a minute ahead of the playhead, removes what
// played earlier, and before each segment chooses the quality the measured speed carries.
// Segments keep the title's own timestamps, so qualities and seeks line up without offsets.

import * as rules from "./live-logic.js";
import * as hls from "./hls-logic.js";
import { MediaSourceType, isTypeSupported } from "./live.js";

const RETRIES = 3;
const SEEK_SETTLE_MS = 250;

function videoMime(variant) {
  return `video/mp4; codecs="${variant.codecs}"`;
}

export class HlsSource {
  /**
   * @param {object} options
   * @param {HTMLVideoElement} options.video
   * @param {object} options.plan          the server's conversion plan, for its sound tracks and length
   * @param {string} options.streamPath    the playback ticket's stream path
   * @param {number|null} options.audio    the stream index of the sound track
   * @param {string} options.quality       "auto" or a quality such as "720p"
   * @param {(status: number, code: string) => void} options.onFailure
   * @param {(variants: object[], current: object) => void} [options.onVariant]
   */
  constructor({ video, plan, streamPath, audio, quality = "auto", onFailure, onVariant }) {
    this.video = video;
    this.plan = plan;
    this.streamPath = streamPath;
    this.onFailure = onFailure;
    this.onVariant = onVariant;
    this.quality = quality;
    this.track = plan.audioTracks.find((track) => track.index === audio) ?? null;
    this.generation = 0;
    this.variants = [];
    this.current = -1;
    this.playlists = new Map();
    this.throughput = null;
    this.stable = 0;
    this.retries = 0;
    this.destroyed = false;
    this.waiters = new Set();
    this.listeners = [];
    const on = (target, type, handler) => {
      target.addEventListener(type, handler);
      this.listeners.push(() => target.removeEventListener(type, handler));
    };
    on(video, "seeking", () => this.seeking());
    on(video, "timeupdate", () => this.wake());
    on(video, "playing", () => this.wake());
  }

  get audio() {
    return this.track?.index ?? null;
  }

  /** The quality playing now, such as "720p". */
  get variant() {
    return this.variants[this.current] ?? null;
  }

  async request(path, signal, type = "text") {
    const response = await fetch(path, {
      credentials: "same-origin",
      cache: "no-store",
      signal,
      headers: { "X-Aurelia-Web": "profile" },
    });
    if (!response.ok) {
      let code = `http_${response.status}`;
      try {
        code = (await response.json())?.code ?? code;
      } catch {
        // No problem details.
      }
      const error = new Error(code);
      error.status = response.status;
      error.code = code;
      throw error;
    }
    return type === "text" ? response.text() : new Uint8Array(await response.arrayBuffer());
  }

  /** Reads the qualities, attaches a new MediaSource and starts at `at` seconds. */
  async open(at = 0) {
    const generation = ++this.generation;
    this.detach();
    const master = new URL(hls.masterUrl(this.streamPath, this.track?.index ?? null), location.origin);
    this.master = master;
    this.playlists.clear();
    this.variants = hls.parseMaster(await this.request(master.href)).filter((variant) => isTypeSupported(videoMime(variant)));
    if (generation !== this.generation) return;
    if (!this.variants.length) throw new Error("This browser can't play any of the qualities.");
    this.current = hls.initialVariant(this.variants, this.quality);
    this.onVariant?.(this.variants, this.variant);

    const mediaSource = new MediaSourceType();
    this.mediaSource = mediaSource;
    this.buffer = null;
    if (MediaSourceType !== globalThis.MediaSource) this.video.disableRemotePlayback = true;
    this.url = URL.createObjectURL(mediaSource);
    this.video.src = this.url;
    await new Promise((resolve) => mediaSource.addEventListener("sourceopen", resolve, { once: true }));
    if (generation !== this.generation) return;
    URL.revokeObjectURL(this.url);
    this.url = null;
    this.buffer = mediaSource.addSourceBuffer(videoMime(this.variant));
    this.bufferCodecs = this.variant.codecs;
    const playlist = await this.playlist(this.current);
    if (generation !== this.generation) return;
    mediaSource.duration = this.plan.durationSeconds > 0 ? this.plan.durationSeconds : playlist.total;
    mediaSource.addEventListener("startstreaming", () => this.wake());
    if (at > 0) {
      this.video.addEventListener("loadedmetadata", () => {
        if (generation === this.generation) this.video.currentTime = at;
      }, { once: true });
    }
    this.run(hls.segmentAt(playlist.segments, at), generation);
  }

  /** A quality's media playlist, read once and kept with its address. */
  async playlist(index) {
    if (this.playlists.has(index)) return this.playlists.get(index);
    const address = new URL(this.variants[index].uri, this.master);
    const parsed = hls.parseMedia(await this.request(address.href));
    const playlist = { ...parsed, address };
    this.playlists.set(index, playlist);
    return playlist;
  }

  /** Plays another sound track from the current position. */
  async setAudio(index) {
    const track = this.plan.audioTracks.find((candidate) => candidate.index === index);
    if (!track || track === this.track) return;
    const position = this.video.currentTime;
    const paused = this.video.paused;
    this.track = track;
    await this.open(position);
    if (!paused) this.video.play().catch(() => {});
  }

  /** "auto" or a quality: takes effect with the next segment. */
  setQuality(quality) {
    this.quality = quality;
    this.stable = 0;
    this.wake();
  }

  async run(next, generation) {
    this.controller?.abort();
    const controller = new AbortController();
    this.controller = controller;
    this.next = next;
    this.loaded = -1;
    this.streaming = true;
    this.nudge = true;
    try {
      while (generation === this.generation && !this.destroyed) {
        await this.room(generation);
        if (generation !== this.generation) return;
        const time = this.video.currentTime;
        const end = rules.bufferedEnd(rules.ranges(this.buffer.buffered), time);
        const chosen = hls.nextVariant({
          variants: this.variants, current: this.current, quality: this.quality, throughput: this.throughput,
          bufferAhead: end == null ? 0 : end - time, stable: this.stable,
        });
        if (chosen !== this.current) {
          this.current = chosen;
          this.stable = 0;
          this.onVariant?.(this.variants, this.variant);
        }
        const playlist = await this.playlist(this.current);
        if (generation !== this.generation) return;
        if (this.next >= playlist.segments.length) {
          this.streaming = false;
          await this.idle();
          if (generation === this.generation && this.mediaSource.readyState === "open") this.mediaSource.endOfStream();
          return;
        }
        if (this.loaded !== this.current) {
          // A new quality begins with its own init segment; a different profile needs changeType.
          const init = await this.request(new URL(playlist.init, playlist.address).href, controller.signal, "bytes");
          if (generation !== this.generation) return;
          if (this.variant.codecs !== this.bufferCodecs && typeof this.buffer.changeType === "function") {
            await this.idle();
            this.buffer.changeType(videoMime(this.variant));
            this.bufferCodecs = this.variant.codecs;
          }
          await this.append(init, generation);
          this.loaded = this.current;
        }
        const segment = playlist.segments[this.next];
        const started = performance.now();
        const bytes = await this.request(new URL(segment.uri, playlist.address).href, controller.signal, "bytes");
        if (generation !== this.generation) return;
        const seconds = Math.max(0.05, (performance.now() - started) / 1000);
        this.throughput = hls.smoothed(this.throughput, (bytes.byteLength * 8) / seconds);
        this.stable += 1;
        await this.append(bytes, generation);
        this.next += 1;
        this.retries = 0;
      }
    } catch (error) {
      if (generation !== this.generation || error?.name === "AbortError") return;
      this.streaming = false;
      if (error?.status) {
        this.onFailure?.(error.status, error.code);
        return;
      }
      this.interrupted(generation);
    }
  }

  /** A broken connection tries the same segment again a few times before giving up. */
  interrupted(generation) {
    if (this.destroyed || generation !== this.generation) return;
    if (this.retries >= RETRIES) {
      this.onFailure?.(0, "offline");
      return;
    }
    this.retries += 1;
    // The connection was too slow for this quality: try a lower one.
    this.throughput = this.throughput ? this.throughput / 2 : null;
    setTimeout(() => {
      if (generation === this.generation) this.continueAt(this.next);
    }, 1000 * this.retries);
  }

  async continueAt(segment) {
    const generation = ++this.generation;
    this.controller?.abort();
    await this.idle();
    if (generation !== this.generation || !this.buffer) return;
    try {
      if (this.mediaSource.readyState === "open") this.buffer.abort();
    } catch {
      // Nothing to reset.
    }
    if (generation === this.generation) this.run(segment, generation);
  }

  async append(bytes, generation) {
    for (let attempt = 0; ; attempt += 1) {
      await this.idle();
      if (generation !== this.generation) return;
      try {
        this.buffer.appendBuffer(bytes);
        await this.idle();
        break;
      } catch (error) {
        if (error?.name !== "QuotaExceededError") throw error;
        await this.trim(attempt === 0 ? 5 : 2);
        await this.sleep(1000);
      }
    }
    if (generation !== this.generation) return;
    const buffered = rules.ranges(this.buffer.buffered);
    if (this.nudge && buffered.length > 0) {
      this.nudge = false;
      const start = buffered[0][0];
      if (this.video.currentTime < start && start - this.video.currentTime < 2) this.video.currentTime = start;
    }
    await this.trim(rules.BEHIND_SECONDS);
  }

  async trim(behind) {
    if (!this.buffer || this.mediaSource.readyState !== "open") return;
    const cut = rules.trimRange(rules.ranges(this.buffer.buffered), this.video.currentTime, behind);
    if (!cut) return;
    await this.idle();
    try {
      this.buffer.remove(cut[0], cut[1]);
      await this.idle();
    } catch {
      // The buffer changed meanwhile; the next append trims again.
    }
  }

  async room(generation) {
    while (generation === this.generation && !this.destroyed) {
      const allowed = this.mediaSource.streaming !== false;
      if (allowed && rules.shouldRead(rules.ranges(this.buffer.buffered), this.video.currentTime, rules.AHEAD_SECONDS)) return;
      await this.sleep(1000);
    }
  }

  seeking() {
    if (this.destroyed || !this.buffer) return;
    if (rules.bufferedEnd(rules.ranges(this.buffer.buffered), this.video.currentTime) != null) {
      this.wake();
      return;
    }
    clearTimeout(this.seekTimer);
    this.seekTimer = setTimeout(async () => {
      this.seekTimer = null;
      if (this.destroyed || !this.buffer) return;
      const time = this.video.currentTime;
      if (rules.bufferedEnd(rules.ranges(this.buffer.buffered), time) != null) return this.wake();
      const playlist = await this.playlist(this.current);
      // After abort the parser starts over, so the quality's init segment is sent again.
      this.loaded = -1;
      this.continueAt(hls.segmentAt(playlist.segments, time));
    }, SEEK_SETTLE_MS);
  }

  idle() {
    const buffer = this.buffer;
    if (!buffer || !buffer.updating) return Promise.resolve();
    return new Promise((resolve) => buffer.addEventListener("updateend", resolve, { once: true }));
  }

  sleep(delay) {
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(timer);
        this.waiters.delete(done);
        resolve();
      };
      const timer = setTimeout(done, delay);
      this.waiters.add(done);
    });
  }

  wake() {
    for (const waiter of [...this.waiters]) waiter();
  }

  detach() {
    this.controller?.abort();
    this.streaming = false;
    if (this.url) URL.revokeObjectURL(this.url);
    this.url = null;
  }

  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    this.generation += 1;
    clearTimeout(this.seekTimer);
    this.detach();
    this.wake();
    this.listeners.forEach((remove) => remove());
  }
}
