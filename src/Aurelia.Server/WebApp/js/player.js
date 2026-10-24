// The browser player: plays the original file straight from the server with byte ranges,
// saves the position with guarded progress updates and offers the next episode at the end.
// Browsers decode MP4/MOV with H.264 or HEVC and AAC; anything else gets a clear message.

import { h, icon, clear } from "./dom.js";
import { ApiError } from "./api.js";
import { ProgressSaver, clock, eyebrow, resumeSeconds } from "./logic.js";

const SAVE_INTERVAL = 10_000;
const HIDE_DELAY = 3_000;
const RENEW_BEFORE = 5 * 60_000;

export const UNPLAYABLE =
  "This file can’t play in a browser yet. Watch it in Aurelia on the Mac or Apple TV.";

export class Player {
  /**
   * @param {object} options
   * @param {ReturnType<import("./api.js").createApi>} options.api
   * @param {object} options.item       the title to play (a catalog summary)
   * @param {() => Promise<object|null>} [options.next]  finds the episode after this one
   * @param {(item: object) => void} [options.onPlayNext]
   * @param {() => void} options.onClose
   * @param {(error: ApiError) => void} [options.onSessionEnded]
   */
  constructor({ api, item, next, onPlayNext, onClose, onSessionEnded }) {
    this.api = api;
    this.item = item;
    this.next = next;
    this.onPlayNext = onPlayNext;
    this.onClose = onClose;
    this.onSessionEnded = onSessionEnded;
    this.source = null;
    this.saver = null;
    this.timers = new Set();
    this.closed = false;
    this.listeners = [];
    this.build();
  }

  build() {
    this.video = h("video", { class: "player-video", playsinline: true, preload: "auto" });
    this.title = h("div", { class: "player-title" },
      h("div", { class: "eyebrow" }, eyebrow(this.item)), h("div", { class: "player-name" }, this.item.title));
    this.closeButton = h("button", { class: "round-button", "aria-label": "Close player", onclick: () => this.close() }, icon("back"));
    this.playButton = h("button", { class: "play-toggle", "aria-label": "Play", onclick: () => this.toggle() }, icon("play", { size: 30 }));
    this.backButton = h("button", { class: "round-button", "aria-label": "Back 10 seconds", onclick: () => this.skip(-10) }, icon("replay10", { size: 24 }));
    this.forwardButton = h("button", { class: "round-button", "aria-label": "Forward 10 seconds", onclick: () => this.skip(10) }, icon("skip10", { size: 24 }));
    this.timeline = h("input", { class: "timeline", type: "range", min: "0", max: "1000", value: "0", step: "1", "aria-label": "Position" });
    this.elapsed = h("span", { class: "time" }, "0:00");
    this.left = h("span", { class: "time" }, "0:00");
    this.muteButton = h("button", { class: "icon-button", "aria-label": "Mute", onclick: () => this.toggleMute() }, icon("volume"));
    this.volume = h("input", { class: "volume", type: "range", min: "0", max: "1", step: "0.05", value: "1", "aria-label": "Volume" });
    this.captionsButton = h("button", { class: "icon-button", "aria-label": "Subtitles", hidden: true, onclick: () => this.toggleCaptions() }, icon("captions"));
    this.pipButton = h("button", { class: "icon-button", "aria-label": "Picture in Picture", hidden: !document.pictureInPictureEnabled, onclick: () => this.togglePictureInPicture() }, icon("pip"));
    this.fullscreenButton = h("button", { class: "icon-button", "aria-label": "Full Screen", onclick: () => this.toggleFullscreen() }, icon("fullscreen"));
    this.notice = h("div", { class: "player-notice", role: "status", hidden: true });
    this.spinner = h("div", { class: "spinner", "aria-hidden": "true" });
    this.endCard = h("div", { class: "end-card", hidden: true });

    this.controls = h("div", { class: "player-controls" },
      h("div", { class: "player-top" }, this.closeButton, this.title),
      h("div", { class: "player-center" }, this.backButton, this.playButton, this.forwardButton),
      h("div", { class: "player-bottom" },
        h("div", { class: "timeline-row" }, this.elapsed, this.timeline, this.left),
        h("div", { class: "player-tools" },
          h("div", { class: "volume-group" }, this.muteButton, this.volume),
          h("div", { class: "tool-group" }, this.captionsButton, this.pipButton, this.fullscreenButton))));

    this.element = h("div", { class: "player", role: "dialog", "aria-modal": "true", "aria-label": `Playing ${this.item.title}` },
      this.video, this.spinner, this.controls, this.notice, this.endCard);
  }

  async open(parent) {
    parent.append(this.element);
    document.body.classList.add("playing");
    this.bind();
    this.showControls();
    this.element.focus?.();
    try {
      this.source = await this.api.createPlayback(this.item.id);
    } catch (error) {
      this.fail(error);
      return;
    }
    if (this.closed) return this.revoke();
    this.saver = new ProgressSaver({
      mediaId: this.item.id,
      revision: this.source.progress?.revision ?? 0,
      send: (mediaId, body, options) => this.api.saveProgress(mediaId, body, options),
    });
    this.resumeAt = resumeSeconds(this.source.progress);
    this.video.src = this.source.streamPath;
    this.scheduleRenewal();
    try {
      await this.video.play();
    } catch {
      // Autoplay can be refused until the viewer taps; the play button stays ready.
      this.updatePlayState();
    }
  }

  bind() {
    const on = (target, type, handler, options) => {
      target.addEventListener(type, handler, options);
      this.listeners.push(() => target.removeEventListener(type, handler, options));
    };
    const video = this.video;
    on(video, "loadedmetadata", () => {
      if (this.resumeAt > 0 && this.resumeAt < video.duration) video.currentTime = this.resumeAt;
      this.resumeAt = 0;
      this.updateTime();
      this.updateCaptions();
      // A file the browser opens but cannot show (for example HEVC in some browsers) has no picture.
      if (video.videoWidth === 0 && video.videoHeight === 0 && this.item.kind !== "trailer") this.check(() => video.videoWidth === 0, 1500);
    });
    on(video, "timeupdate", () => this.updateTime());
    on(video, "play", () => this.updatePlayState());
    on(video, "pause", () => {
      this.updatePlayState();
      this.saveNow();
    });
    on(video, "playing", () => {
      this.spinner.classList.remove("visible");
      this.checkAudio();
    });
    on(video, "waiting", () => this.spinner.classList.add("visible"));
    on(video, "seeked", () => this.saveNow());
    on(video, "volumechange", () => this.updateVolume());
    on(video, "ended", () => this.finish());
    on(video, "error", () => this.videoFailed());
    on(this.timeline, "input", () => {
      if (Number.isFinite(video.duration)) video.currentTime = (this.timeline.value / 1000) * video.duration;
    });
    on(this.volume, "input", () => {
      video.volume = Number(this.volume.value);
      video.muted = video.volume === 0;
    });
    on(this.element, "pointermove", () => this.showControls());
    on(this.element, "pointerdown", () => this.showControls());
    on(video, "click", () => this.toggle());
    on(video, "dblclick", () => this.toggleFullscreen());
    on(document, "keydown", (event) => this.key(event));
    on(document, "fullscreenchange", () => this.updateFullscreen());
    on(document, "visibilitychange", () => {
      if (document.visibilityState === "hidden") this.saveNow({ keepalive: true });
    });
    on(window, "pagehide", () => this.saveNow({ keepalive: true }));
    this.every(() => {
      if (!video.paused && !video.ended) this.saveNow();
    }, SAVE_INTERVAL);
  }

  key(event) {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
    const target = event.target;
    if (target instanceof HTMLInputElement && target.type !== "range") return;
    switch (event.key) {
      case " ":
      case "k":
      case "K":
        if (target instanceof HTMLButtonElement) return;
        event.preventDefault();
        this.toggle();
        break;
      case "ArrowLeft":
      case "j":
        event.preventDefault();
        this.skip(-10);
        break;
      case "ArrowRight":
      case "l":
        event.preventDefault();
        this.skip(10);
        break;
      case "f":
      case "F":
        event.preventDefault();
        this.toggleFullscreen();
        break;
      case "m":
      case "M":
        event.preventDefault();
        this.toggleMute();
        break;
      case "Escape":
        if (!document.fullscreenElement) {
          event.preventDefault();
          this.close();
        }
        break;
      default:
        return;
    }
    this.showControls();
  }

  toggle() {
    if (!this.source) return;
    if (this.video.paused || this.video.ended) this.video.play().catch(() => {});
    else this.video.pause();
  }

  skip(seconds) {
    const video = this.video;
    if (!Number.isFinite(video.duration)) return;
    video.currentTime = Math.min(Math.max(0, video.currentTime + seconds), video.duration);
  }

  toggleMute() {
    this.video.muted = !this.video.muted;
    if (!this.video.muted && this.video.volume === 0) this.video.volume = 1;
  }

  toggleCaptions() {
    const tracks = [...this.video.textTracks];
    const showing = tracks.find((track) => track.mode === "showing");
    tracks.forEach((track) => (track.mode = "disabled"));
    if (!showing) tracks[0].mode = "showing";
    else {
      const next = tracks[tracks.indexOf(showing) + 1];
      if (next) next.mode = "showing";
    }
    this.captionsButton.classList.toggle("active", tracks.some((track) => track.mode === "showing"));
  }

  async togglePictureInPicture() {
    try {
      if (document.pictureInPictureElement) await document.exitPictureInPicture();
      else await this.video.requestPictureInPicture();
    } catch {
      // Not available for this video right now.
    }
  }

  async toggleFullscreen() {
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else if (this.element.requestFullscreen) await this.element.requestFullscreen();
      else if (this.video.webkitEnterFullscreen) this.video.webkitEnterFullscreen(); // iPhone
    } catch {
      // The browser refused; the player still fills the window.
    }
  }

  updateFullscreen() {
    const full = Boolean(document.fullscreenElement);
    this.fullscreenButton.replaceChildren(icon(full ? "exitFullscreen" : "fullscreen"));
    this.fullscreenButton.setAttribute("aria-label", full ? "Exit Full Screen" : "Full Screen");
  }

  updatePlayState() {
    const playing = !this.video.paused && !this.video.ended;
    this.playButton.replaceChildren(icon(playing ? "pause" : "play", { size: 30 }));
    this.playButton.setAttribute("aria-label", playing ? "Pause" : "Play");
    this.element.classList.toggle("paused", !playing);
    this.showControls();
  }

  updateTime() {
    const video = this.video;
    const duration = Number.isFinite(video.duration) ? video.duration : 0;
    this.elapsed.textContent = clock(video.currentTime);
    this.left.textContent = duration ? `-${clock(duration - video.currentTime)}` : "0:00";
    if (document.activeElement !== this.timeline) this.timeline.value = duration ? String(Math.round((video.currentTime / duration) * 1000)) : "0";
    this.timeline.style.setProperty("--fill", duration ? `${(video.currentTime / duration) * 100}%` : "0%");
  }

  updateVolume() {
    const muted = this.video.muted || this.video.volume === 0;
    this.muteButton.replaceChildren(icon(muted ? "mute" : "volume"));
    this.muteButton.setAttribute("aria-label", muted ? "Unmute" : "Mute");
    this.volume.value = muted ? "0" : String(this.video.volume);
  }

  updateCaptions() {
    this.captionsButton.hidden = this.video.textTracks.length === 0;
  }

  showControls() {
    this.element.classList.add("controls-visible");
    clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => {
      if (!this.video.paused && !this.video.ended) this.element.classList.remove("controls-visible");
    }, HIDE_DELAY);
  }

  saveNow(options = {}) {
    const video = this.video;
    if (!this.saver || !Number.isFinite(video.duration) || video.duration <= 0 || this.resumeAt > 0) return;
    this.saver.save(video.currentTime * 1000, video.duration * 1000, false, options);
  }

  async finish() {
    this.updatePlayState();
    const video = this.video;
    if (this.saver && Number.isFinite(video.duration)) await this.saver.save(video.duration * 1000, video.duration * 1000, true);
    const next = this.next ? await this.next().catch(() => null) : null;
    if (this.closed) return;
    clear(this.endCard);
    if (next) {
      this.endCard.append(
        h("div", { class: "eyebrow" }, "Up Next"),
        h("div", { class: "end-title" }, eyebrow(next)),
        h("div", { class: "end-name" }, next.title),
        h("div", { class: "button-row" },
          h("button", { class: "primary-button", onclick: () => this.playNext(next) }, icon("play", { size: 16 }), "Play Next Episode"),
          h("button", { class: "secondary-button", onclick: () => this.close() }, "Close")));
    } else {
      this.endCard.append(
        h("div", { class: "end-name" }, "Finished"),
        h("div", { class: "button-row" }, h("button", { class: "primary-button", onclick: () => this.close() }, "Close")));
    }
    this.endCard.hidden = false;
    this.endCard.querySelector("button")?.focus();
  }

  playNext(next) {
    this.close();
    this.onPlayNext?.(next);
  }

  /** The browser reported an error; ask the server whether the stream itself is at fault. */
  async videoFailed() {
    if (this.closed || !this.source) return;
    const code = this.video.error?.code;
    let message = UNPLAYABLE;
    try {
      const response = await fetch(this.source.streamPath, { method: "HEAD", credentials: "same-origin", cache: "no-store" });
      if (response.status === 503) message = "This title’s storage is offline. Connect the drive, then try again.";
      else if (response.status === 401 || response.status === 403) message = "The profile session ended. Choose your profile again.";
      else if (response.status === 404 || response.status === 409) message = "This file isn’t available on the server.";
      else if (!response.ok) message = "The server couldn’t send this title. Try again.";
      else if (code === 2) message = "The connection to the server was interrupted. Try again.";
    } catch {
      message = "The server isn’t answering. Check that it is switched on, then try again.";
    }
    this.showNotice(message, true);
  }

  /** Looks once more after a moment, so a slow start is not mistaken for a missing picture. */
  check(stillWrong, delay) {
    this.after(() => {
      if (stillWrong() && !this.closed) this.showNotice(UNPLAYABLE, true);
    }, delay);
  }

  /** Chrome and Edge play a file with an audio format they cannot decode silently. */
  checkAudio() {
    if (this.audioChecked || !("webkitAudioDecodedByteCount" in this.video)) return;
    this.audioChecked = true;
    this.after(() => {
      const video = this.video;
      if (!this.closed && !video.paused && video.webkitAudioDecodedByteCount === 0 && video.webkitVideoDecodedByteCount > 0)
        this.showNotice("No sound: this file’s audio format can’t play in a browser yet.", false);
    }, 4000);
  }

  showNotice(text, blocking) {
    clear(this.notice);
    this.notice.append(icon("warning", { size: 22 }), h("span", {}, text));
    if (blocking) {
      this.video.pause();
      this.video.removeAttribute("src");
      this.video.load();
      this.notice.append(h("button", { class: "secondary-button", onclick: () => this.close() }, "Close"));
      this.element.classList.add("failed");
    } else {
      this.after(() => (this.notice.hidden = true), 8000);
    }
    this.notice.hidden = false;
    this.spinner.classList.remove("visible");
  }

  fail(error) {
    if (error instanceof ApiError && error.status === 401) {
      this.close();
      this.onSessionEnded?.(error);
      return;
    }
    const message = error instanceof ApiError
      ? error.offline ? "The server isn’t answering. Check that it is switched on, then try again." : error.message
      : "This title couldn’t be opened.";
    this.showNotice(message, true);
  }

  /** Tickets last hours; a very long session gets a fresh one before the old one ends. */
  scheduleRenewal() {
    const due = new Date(this.source.expiresAt).getTime() - Date.now() - RENEW_BEFORE;
    if (!Number.isFinite(due)) return;
    this.after(async () => {
      if (this.closed) return;
      try {
        const renewed = await this.api.createPlayback(this.item.id);
        const position = this.video.currentTime;
        const paused = this.video.paused;
        const old = this.source;
        this.source = renewed;
        this.video.src = renewed.streamPath;
        this.video.currentTime = position;
        if (!paused) this.video.play().catch(() => {});
        this.api.revokePlayback(old.id).catch(() => {});
        this.scheduleRenewal();
      } catch (error) {
        this.fail(error);
      }
    }, Math.max(0, due));
  }

  after(work, delay) {
    const timer = setTimeout(() => {
      this.timers.delete(timer);
      work();
    }, delay);
    this.timers.add(timer);
  }

  every(work, interval) {
    const timer = setInterval(work, interval);
    this.timers.add(timer);
  }

  revoke() {
    if (this.source) this.api.revokePlayback(this.source.id).catch(() => {});
  }

  close() {
    if (this.closed) return;
    this.saveNow({ keepalive: true });
    this.closed = true;
    for (const timer of this.timers) {
      clearTimeout(timer);
      clearInterval(timer);
    }
    clearTimeout(this.hideTimer);
    this.listeners.forEach((remove) => remove());
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});
    this.video.pause();
    this.video.removeAttribute("src");
    this.video.load();
    this.revoke();
    this.element.remove();
    document.body.classList.remove("playing");
    this.onClose?.();
  }
}
