// The live player: plays a title the server converts while it plays. The server sends
// fragmented MP4; this reads it with fetch and hands it to the video element through Media
// Source Extensions (ManagedMediaSource on iPhone). About a minute is kept ahead of the
// playhead: beyond that it stops reading, so the server's ffmpeg waits as well. What played
// more than a minute ago is removed again. A seek outside what has arrived starts a new stream
// at that point; the stream keeps the title's own timestamps, so positions stay correct.

import * as rules from "./live-logic.js";

export const MediaSourceType = globalThis.MediaSource ?? globalThis.ManagedMediaSource ?? null;

/** Whether this browser can play live converted titles at all. */
export function liveSupported() {
  return Boolean(MediaSourceType && typeof MediaSourceType.isTypeSupported === "function" && globalThis.ReadableStream);
}

export function isTypeSupported(type) {
  try {
    return Boolean(MediaSourceType?.isTypeSupported(type));
  } catch {
    return false;
  }
}

const RETRIES = 3;

export class LiveSource {
  /**
   * @param {object} options
   * @param {HTMLVideoElement} options.video
   * @param {object} options.plan            the server's conversion plan
   * @param {string} options.streamPath      the playback ticket's stream path
   * @param {number|null} options.audio      the stream index of the sound track
   * @param {(status: number, code: string) => void} options.onFailure
   */
  constructor({ video, plan, streamPath, audio, onFailure }) {
    this.video = video;
    this.plan = plan;
    this.streamPath = streamPath;
    this.onFailure = onFailure;
    this.track = plan.audioTracks.find((track) => track.index === audio) ?? null;
    this.generation = 0;
    this.streaming = false;
    this.streamStart = 0;
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

  /** Attaches a new MediaSource to the video element and starts a stream at `at` seconds. */
  async open(at = 0) {
    const generation = ++this.generation;
    this.detach();
    const mediaSource = new MediaSourceType();
    this.mediaSource = mediaSource;
    this.buffer = null;
    // ManagedMediaSource opens only when the page offers no AirPlay alternative.
    if (MediaSourceType !== globalThis.MediaSource) this.video.disableRemotePlayback = true;
    this.url = URL.createObjectURL(mediaSource);
    this.video.src = this.url;
    await new Promise((resolve) => mediaSource.addEventListener("sourceopen", resolve, { once: true }));
    if (generation !== this.generation) return;
    URL.revokeObjectURL(this.url);
    this.url = null;
    this.buffer = mediaSource.addSourceBuffer(rules.mimeType(this.plan, this.track));
    if (this.plan.durationSeconds > 0) mediaSource.duration = this.plan.durationSeconds;
    mediaSource.addEventListener("startstreaming", () => this.wake());
    if (at > 0) {
      this.video.addEventListener("loadedmetadata", () => {
        if (generation === this.generation) this.video.currentTime = at;
      }, { once: true });
    }
    this.run(at, generation);
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

  /** Leaves what has arrived and starts a new stream at `at` seconds. */
  async restart(at) {
    const generation = ++this.generation;
    this.controller?.abort();
    this.streaming = false;
    await this.idle();
    if (generation !== this.generation || !this.buffer) return;
    try {
      // The new stream begins with its own header, so the parser starts over.
      if (this.mediaSource.readyState === "open") this.buffer.abort();
      if (this.buffer.buffered.length > 0) {
        this.buffer.remove(0, Infinity);
        await this.idle();
      }
    } catch {
      // A closed source has nothing left to remove.
    }
    if (generation === this.generation) this.run(at, generation);
  }

  async run(at, generation) {
    this.controller?.abort();
    const controller = new AbortController();
    this.controller = controller;
    this.streamStart = at;
    this.streaming = true;
    this.nudge = true;
    let response;
    try {
      response = await fetch(rules.streamUrl(this.streamPath, {
        start: at,
        audio: this.track?.index ?? null,
        audioMode: this.track?.mode ?? "aac",
        video: this.plan.video,
      }), {
        credentials: "same-origin",
        cache: "no-store",
        signal: controller.signal,
        headers: { "X-Aurelia-Web": "profile" },
      });
    } catch {
      if (generation === this.generation) this.interrupted(generation);
      return;
    }
    if (generation !== this.generation) return;
    if (!response.ok) {
      let code = `http_${response.status}`;
      try {
        code = (await response.json())?.code ?? code;
      } catch {
        // No problem details.
      }
      this.streaming = false;
      if (generation === this.generation) this.onFailure?.(response.status, code);
      return;
    }

    const reader = response.body.getReader();
    try {
      for (;;) {
        await this.room(generation);
        if (generation !== this.generation) break;
        const { value, done } = await reader.read();
        if (generation !== this.generation) break;
        if (done) {
          this.streaming = false;
          await this.idle();
          if (generation === this.generation && this.mediaSource.readyState === "open") this.mediaSource.endOfStream();
          break;
        }
        await this.append(value, generation);
        this.retries = 0;
      }
    } catch (error) {
      if (generation === this.generation && error?.name !== "AbortError") this.interrupted(generation);
    } finally {
      reader.cancel().catch(() => {});
    }
  }

  /** A broken connection continues where the arrived part ends, a few times, before giving up. */
  interrupted(generation) {
    this.streaming = false;
    if (this.destroyed || generation !== this.generation) return;
    if (this.retries >= RETRIES) {
      this.onFailure?.(0, "offline");
      return;
    }
    this.retries += 1;
    const time = this.video.currentTime;
    const end = this.buffer ? rules.bufferedEnd(rules.ranges(this.buffer.buffered), time) : null;
    setTimeout(() => {
      if (generation === this.generation) this.restart(end ?? time);
    }, 1000 * this.retries);
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
        // A full buffer frees what already played, then waits for the playhead to move on.
        if (error?.name !== "QuotaExceededError" || attempt >= 30) throw error;
        await this.trim(10);
        await this.sleep(1000);
      }
    }
    if (generation !== this.generation) return;
    const buffered = rules.ranges(this.buffer.buffered);
    // A converted stream may begin a frame after the requested point; step over that gap.
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

  /** Waits while enough is ready ahead, or while iPhone asks the page not to stream. */
  async room(generation) {
    while (generation === this.generation && !this.destroyed) {
      const allowed = this.mediaSource.streaming !== false;
      if (allowed && rules.shouldRead(rules.ranges(this.buffer.buffered), this.video.currentTime)) return;
      await this.sleep(1000);
    }
  }

  seeking() {
    if (this.destroyed || !this.buffer) return;
    const target = this.video.currentTime;
    const action = rules.seekAction({
      buffered: rules.ranges(this.buffer.buffered),
      target,
      streaming: this.streaming,
      streamStart: this.streamStart,
    });
    if (action === "restart") this.restart(target);
    else this.wake();
  }

  /** Resolves when the source buffer is not busy. */
  idle() {
    const buffer = this.buffer;
    if (!buffer || !buffer.updating) return Promise.resolve();
    return new Promise((resolve) => buffer.addEventListener("updateend", resolve, { once: true }));
  }

  /** Waits up to `delay` milliseconds, or until the playhead moves. */
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
    this.detach();
    this.wake();
    this.listeners.forEach((remove) => remove());
  }
}
