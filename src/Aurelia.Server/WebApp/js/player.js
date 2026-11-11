// The browser player, laid out like the Mac app's: back and the menus (speed, sound, subtitles,
// sleep timer, scene notes) at the top, the transport in the middle, title, volume and the
// timeline at the bottom, and "Up Next" in the last seconds of an episode.
// It plays MP4/MOV with H.264 or HEVC and AAC straight from the server with byte ranges. Other
// files (MKV, AVI) play live converted by the server (live.js), and so does an MP4 the browser
// fails to show or to hear. Without live conversion, such a file gets a clear message.
// Progress is saved with guarded updates.

import { h, icon, clear } from "./dom.js";
import { ApiError } from "./api.js";
import {
  ProgressSaver, SLEEP_MINUTES, PLAYBACK_RATES, clock, endsAt, normalizePreferences,
  playerSubtitle, rateLabel, playbackStartSeconds, sessionRefused, scrubPreviewFrameUrl, showsUpNext, upNextSeconds,
  timelineValueText, trackForLanguage, volumeValueText, audioProfile, decibels, DIALOGUE_BOOST_CHOICES, VOLUME_LEVELING_CHOICES,
} from "./logic.js";
import { createSceneNotes } from "./player-notes.js";
import { createTrackChoices, matchingTrack } from "./track-choices.js";
import { LiveSource, MediaSourceType, isTypeSupported, liveSupported } from "./live.js";
import { HlsSource } from "./hls.js";
import { QUALITY_KEY, normalizeQuality, qualityLabel } from "./hls-logic.js";
import { codecSupport, liveProblem, mimeType, selectSubtitle, startTrack, subtitleLabel, subtitleUrl, trackLabel, triesDirectPlay, videoFamily } from "./live-logic.js";

const SAVE_INTERVAL = 10_000;
const RENEW_BEFORE = 5 * 60_000;
const RENEW_RETRY_MS = 20_000;
const PREFERENCES_KEY = "aurelia.playback";

export const UNPLAYABLE =
  "This file can’t play in a browser yet. Watch it in Aurelia on the Mac or Apple TV.";

/** This browser's playback preferences (Settings › Playback). */
export function loadPreferences() {
  try {
    return normalizePreferences(JSON.parse(localStorage.getItem(PREFERENCES_KEY) ?? "null"));
  } catch {
    return normalizePreferences(null);
  }
}

export function savePreferences(value) {
  const normalized = normalizePreferences(value);
  try {
    localStorage.setItem(PREFERENCES_KEY, JSON.stringify(normalized));
  } catch {
    // Private browsing: the choice lasts for this page only.
  }
  return normalized;
}

/** The circular arrow with the interval inside, like SF Symbols' gobackward.10. */
function seekGlyph(forward, seconds) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", "24");
  svg.setAttribute("height", "24");
  svg.setAttribute("class", "icon");
  svg.setAttribute("aria-hidden", "true");
  const arc = document.createElementNS(svg.namespaceURI, "path");
  arc.setAttribute("d", forward
    ? "M12 4.5a8 8 0 1 1-7.6 5.5M12 4.5V1.8l3.2 2.7-3.2 2.7z"
    : "M12 4.5a8 8 0 1 0 7.6 5.5M12 4.5V1.8L8.8 4.5l3.2 2.7z");
  arc.setAttribute("fill", "none");
  arc.setAttribute("stroke", "currentColor");
  arc.setAttribute("stroke-width", "1.9");
  arc.setAttribute("stroke-linecap", "round");
  arc.setAttribute("stroke-linejoin", "round");
  const label = document.createElementNS(svg.namespaceURI, "text");
  label.setAttribute("x", "12");
  label.setAttribute("y", "15.6");
  label.setAttribute("text-anchor", "middle");
  label.setAttribute("font-size", "7.4");
  label.setAttribute("font-weight", "700");
  label.setAttribute("fill", "currentColor");
  label.textContent = String(seconds);
  svg.append(arc, label);
  return svg;
}

export class Player {
  /**
   * @param {object} options
   * @param {ReturnType<import("./api.js").createApi>} options.api
   * @param {object} options.item       the title to play (a catalog summary)
   * @param {() => Promise<object|null>} [options.next]  finds the episode after this one
   * @param {() => Promise<object|null>} [options.previous] finds the preceding normal episode
   * @param {"play"|"resume"} [options.intent] only Resume may use saved progress
   * @param {(item: object, options: {intent: "play"}) => void} [options.onPlayNext]
   * @param {() => void} [options.onShowShortcuts]
   * @param {() => void} options.onClose
   * @param {(error: ApiError) => void} [options.onSessionEnded]
   * @param {string} [options.preferenceScope] server/profile identity for private track choices
   * @param {boolean} [options.canConvert]  the server reports live conversion
   * @param {boolean} [options.canStreamAdaptive]  the server streams in several qualities over HLS
   */
  constructor({ api, item, next, previous, intent = "play", onPlayNext, onMediaMenu, onShowShortcuts, onClose, onSessionEnded, onFinished, canConvert = false, canScrubPreview = canConvert, canStreamAdaptive = false, preferenceScope, together }) {
    this.api = api;
    // Watch Together: { session(), start(player), leave() } from the app, or undefined.
    this.together = together;
    this.item = item;
    this.next = next;
    this.previous = previous;
    this.startIntent = intent === "resume" ? "resume" : "play";
    this.navigationPending = false;
    this.onPlayNext = onPlayNext;
    this.onMediaMenu = onMediaMenu;
    this.onShowShortcuts = onShowShortcuts;
    this.onClose = onClose;
    // Cinema mode's trailers: the end hands over to the next part instead of Up Next.
    this.onFinished = onFinished;
    this.onSessionEnded = onSessionEnded;
    this.canConvert = canConvert && liveSupported();
    this.canStreamAdaptive = this.canConvert && Boolean(canStreamAdaptive);
    this.quality = this.canStreamAdaptive ? readQuality() : "original";
    this.canScrubPreview = Boolean(canScrubPreview);
    this.preferences = loadPreferences();
    this.trackChoices = createTrackChoices({ scope: preferenceScope, item });
    this.live = null;
    this.source = null;
    this.saver = null;
    this.timers = new Set();
    this.closed = false;
    this.listeners = [];
    this.notes = [];
    this.embeddedSubtitles = [];
    this.subtitleElements = new Map();
    this.sleep = { mode: "off", until: 0 };
    this.upNextItem = undefined;
    this.upNextDismissed = false;
    this.build();
    this.sceneNotes = createSceneNotes({ api, mediaId: item.id, position: () => Math.round(this.video.currentTime * 1000),
      seek: (milliseconds) => { this.video.currentTime = milliseconds / 1000; this.closePopover(); },
      show: (content) => this.openPopover(this.notesButton, content), isOpen: () => this.popoverOwner === this.notesButton,
      onNotes: (notes) => { this.notes = notes; this.renderNoteMarks(); },
      onSessionEnded: (error) => { this.close(); this.onSessionEnded?.(error); },
    });
  }

  build() {
    const seconds = this.preferences.seekInterval;
    this.video = h("video", { class: "player-video", playsinline: true, preload: "auto" });
    this.startScreen = h("div", { class: "player-start", "aria-label": "Loading" }, h("div", { class: "start-ring" }));

    // Top: back, then one glass capsule with the menus.
    this.backButton = h("button", { class: "player-round glass", "aria-label": "Back", onclick: () => this.close() }, icon("back", { size: 20 }));
    this.rateButton = this.menuButton("Playback Rate", h("span", { class: "rate-label" }, rateLabel(this.preferences.defaultPlaybackRate)), () => this.rateMenu());
    this.audioButton = this.menuButton("Audio", icon("audio", { size: 18 }), () => this.audioMenu());
    this.subtitleButton = this.menuButton("Subtitles", icon("captions", { size: 18 }), () => this.subtitleMenu());
    this.sleepButton = this.menuButton("Sleep Timer", icon("moon", { size: 18 }), () => this.sleepMenu());
    this.notesButton = this.menuButton("Scene Notes", icon("bookmark", { size: 18 }), () => this.notesPanel());
    this.togetherButton = this.menuButton("Watch Together", icon("people", { size: 18 }), () => this.togetherMenu());
    this.qualityLabel = h("span", { class: "rate-label" }, this.quality === "original" ? "Orig" : this.quality === "auto" ? "Auto" : this.quality);
    this.qualityButton = this.menuButton("Streaming Quality", this.qualityLabel, () => this.qualityMenu());
    this.top = h("div", { class: "player-top" }, this.backButton,
      h("div", { class: "player-menus glass" }, this.rateButton, this.canStreamAdaptive ? this.qualityButton : null, this.audioButton,
        this.subtitleButton, this.sleepButton, this.notesButton, this.together ? this.togetherButton : null));

    // Middle: back, play and forward in one capsule.
    this.playButton = h("button", { class: "transport-play", "aria-label": "Play", onclick: () => this.toggle() }, icon("play", { size: 22 }));
    this.previousButton = h("button", { class: "transport-seek", "aria-label": "Previous Episode", title: "Previous Episode (P)", disabled: true,
      onclick: () => this.navigateEpisode("previous") }, icon("previous", { size: 18 }));
    this.nextButton = h("button", { class: "transport-seek", "aria-label": "Next Episode", title: "Next Episode (N)", disabled: true,
      onclick: () => this.navigateEpisode("next") }, icon("next", { size: 18 }));
    this.transport = h("div", { class: "player-transport glass" }, this.previousButton,
      h("button", { class: "transport-seek", "aria-label": `Back ${seconds} Seconds`, onclick: () => this.skip(-seconds) }, seekGlyph(false, seconds)),
      this.playButton,
      h("button", { class: "transport-seek", "aria-label": `Forward ${seconds} Seconds`, onclick: () => this.skip(seconds) }, seekGlyph(true, seconds)), this.nextButton);

    // Bottom: title on the left, sound and window controls on the right, then the timeline.
    this.subtitleLine = h("div", { class: "player-subtitle" }, playerSubtitle(this.item));
    this.titleLine = h("div", { class: "player-name" }, this.item.title);
    this.muteButton = h("button", { class: "player-icon", "aria-label": "Mute", onclick: () => this.toggleMute() }, icon("volume", { size: 18 }));
    this.volume = h("input", { class: "volume", type: "range", min: "0", max: "1", step: "0.02", value: String(this.preferences.defaultVolume), "aria-label": "Volume", "aria-valuetext": volumeValueText(this.preferences.defaultVolume, false) });
    this.pipButton = h("button", { class: "player-icon", "aria-label": "Enter Picture in Picture", hidden: !document.pictureInPictureEnabled, onclick: () => this.togglePictureInPicture() }, icon("pip", { size: 18 }));
    this.airplayButton = h("button", { class: "player-icon airplay-btn", "aria-label": "AirPlay", hidden: true, onclick: () => this.showAirPlayPicker() }, icon("airplay", { size: 18 }));
    this.fullscreenButton = h("button", { class: "player-icon", "aria-label": "Enter Full Screen", onclick: () => this.toggleFullscreen() }, icon("fullscreen", { size: 18 }));
    this.trailing = h("div", { class: "player-trailing glass" }, this.muteButton, this.volume, this.airplayButton, this.pipButton, this.fullscreenButton);
    this.timeline = h("input", { class: "timeline", type: "range", min: "0", max: "1000", value: "0", step: "1", "aria-label": "Playback Position", "aria-valuetext": timelineValueText(0, 0) });
    this.noteMarks = h("div", { class: "note-marks", "aria-hidden": "true" });
    this.previewImg = h("img", { class: "scrub-preview-img", alt: "" });
    this.previewTime = h("span", { class: "scrub-preview-time" }, "0:00");
    this.scrubPreview = h("div", { class: "scrub-preview", hidden: true, "aria-hidden": "true" },
      h("div", { class: "scrub-preview-frame" }, this.previewImg),
      this.previewTime);
    this.elapsed = h("span", { class: "time elapsed" }, "0:00");
    this.total = h("span", { class: "time" }, "0:00");
    this.endsAt = h("div", { class: "ends-at" });
    this.bottom = h("div", { class: "player-bottom" },
      h("div", { class: "player-info-row" }, h("div", { class: "player-info" }, this.subtitleLine, this.titleLine), this.trailing),
      h("div", { class: "timeline-row" }, this.elapsed, h("div", { class: "timeline-track" }, this.timeline, this.noteMarks, this.scrubPreview), this.total),
      this.endsAt);

    this.controls = h("div", { class: "player-controls" }, h("div", { class: "player-shade" }), this.top, this.transport, this.bottom);
    this.popover = h("div", { class: "player-popover glass", role: "menu", hidden: true });
    this.upNext = h("div", { class: "up-next glass", hidden: true });
    this.upNext.addEventListener("contextmenu", (event) => {
      if (this.closed || !this.upNextItem || !this.onMediaMenu) return;
      event.preventDefault();
      event.stopPropagation();
      this.showControls();
      this.onMediaMenu(this.upNext, this.upNextItem);
    });
    this.cue = h("div", { class: "note-cue glass", hidden: true, "aria-live": "polite" });
    this.notice = h("div", { class: "player-notice glass", role: "status", hidden: true });
    this.togetherNotice = h("div", { class: "together-notice glass", role: "status", hidden: true });

    this.element = h("div", { class: "player controls-visible paused", role: "dialog", "aria-modal": "true", "aria-label": `Playing ${this.item.title}`, tabindex: "-1" },
      this.video, this.startScreen, this.controls, this.cue, this.upNext, this.popover, this.notice, this.togetherNotice);
    // What a Watch Together party sees of this player.
    this.partyPlayer = {
      mediaId: this.item.id,
      position: () => Math.round(this.video.currentTime * 1000),
      playing: () => !this.video.paused && !this.video.ended,
      ready: () => Boolean(this.source) && !this.closed && this.video.readyState >= 3 && !this.element.classList.contains("waiting"),
      play: () => this.video.play().catch(() => {}),
      pause: () => this.video.pause(),
      seek: (milliseconds) => { this.video.currentTime = milliseconds / 1000; },
    };
  }

  menuButton(label, content, open) {
    const button = h("button", { class: "menu-control", "aria-label": label, "aria-haspopup": "menu", "aria-expanded": "false" }, content);
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      if (this.popoverOwner === button) this.closePopover();
      else open();
    });
    return button;
  }

  async open(parent) {
    parent.append(this.element);
    document.body.classList.add("playing");
    this.bind();
    this.showControls();
    this.element.focus?.();
    this.video.volume = this.preferences.defaultVolume;
    this.updateVolume();
    // Opening the player is a click, so the browser allows sound processing to start now.
    if (audioProfile(this.preferences).active) this.applySound();
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
      read: (mediaId) => this.api.progress(mediaId),
    });
    this.resumeAt = playbackStartSeconds(this.startIntent, this.source.progress, this.preferences.automaticResume,
      this.preferences.resumeThresholdSeconds);
    this.scheduleRenewal();
    this.loadNotes();
    void this.updateEpisodeButtons();
    if (this.canConvert && (!triesDirectPlay(this.source.contentType) || this.quality !== "original")) {
      const at = this.resumeAt;
      this.resumeAt = 0;
      await this.startLive(at);
      return;
    }
    this.video.src = this.source.streamPath;
    this.api.streamSubtitles?.(this.source.id).then((tracks) => {
      if (this.closed || !Array.isArray(tracks)) return;
      this.embeddedSubtitles = tracks;
      this.restoreTrackChoices();
    }).catch(() => {});
    await this.play();
  }

  async play() {
    this.video.playbackRate = this.preferences.defaultPlaybackRate;
    try {
      await this.video.play();
    } catch {
      // Autoplay can be refused until the viewer taps; the play button stays ready.
      this.updatePlayState();
    }
  }

  /**
   * Plays the title converted live from `at` seconds. The plan names what the server repackages
   * or converts; a codec string the browser refuses after all is left out and planned again.
   */
  async startLive(at) {
    // The picture check, the sound check and a video error can each ask for live playback
    // while the plan is still loading; only the first one starts it.
    if (this.live || this.liveStarting || this.closed) return;
    this.liveStarting = true;
    try {
      await this.openLive(at);
    } finally {
      this.liveStarting = false;
    }
  }

  async openLive(at) {
    this.startScreen.hidden = false;
    this.video.removeAttribute("src");
    this.video.load();
    const without = [];
    let plan = null;
    let track = null;
    try {
      for (let attempt = 0; attempt < 3 && !plan; attempt += 1) {
        const candidate = await this.api.conversionPlan(this.item.id, codecSupport((type) => MediaSourceType.isTypeSupported(type), without));
        const remembered = matchingTrack(candidate.audioTracks, this.trackChoices.audio())
          ?? (this.preferredAudio == null ? trackForLanguage(candidate.audioTracks, this.preferences.defaultAudioLanguage) : null);
        const chosen = remembered ?? candidate.audioTracks.find((entry) => entry.index === startTrack(candidate, this.preferredAudio)) ?? null;
        if (isTypeSupported(mimeType(candidate, chosen))) {
          plan = candidate;
          track = chosen;
        } else if (candidate.video === "copy" && !isTypeSupported(mimeType(candidate, null))) {
          without.push(videoFamily(candidate.videoCodec));
        } else if (chosen?.mode === "copy") {
          without.push(chosen.format);
        } else break;
      }
    } catch (error) {
      if (error instanceof ApiError && (error.code === "conversion_unavailable" || error.code === "conversion_not_possible")) {
        this.showNotice(UNPLAYABLE, true);
      } else {
        this.fail(error);
      }
      return;
    }
    if (this.closed) return;
    if (!plan) {
      this.showNotice(UNPLAYABLE, true);
      return;
    }
    this.embeddedSubtitles = plan.subtitleTracks ?? [];
    // A picture the server has to encode anyway comes in the quality the connection carries.
    if (this.canStreamAdaptive && (this.quality !== "original" || plan.video === "h264")) {
      this.live = new HlsSource({
        video: this.video,
        plan,
        streamPath: this.source.streamPath,
        audio: track?.index ?? null,
        quality: this.quality === "original" ? "auto" : this.quality,
        onFailure: (status, code) => this.liveFailed(status, code),
        onVariant: (variants, current) => this.showVariant(variants, current),
      });
      try {
        await this.live.open(at);
        if (this.closed) return;
        this.restoreTrackChoices();
        await this.play();
        return;
      } catch {
        // The server or this browser can't stream qualities after all: the plain live stream plays.
        this.live.destroy();
        this.live = null;
        if (this.closed) return;
      }
    }
    this.live = new LiveSource({
      video: this.video,
      plan,
      streamPath: this.source.streamPath,
      audio: track?.index ?? null,
      onFailure: (status, code) => this.liveFailed(status, code),
    });
    try {
      await this.live.open(at);
    } catch {
      // The browser refused the stream after all (for example addSourceBuffer threw).
      if (!this.closed) this.showNotice(UNPLAYABLE, true);
      return;
    }
    if (this.closed) return;
    this.restoreTrackChoices();
    await this.play();
  }

  liveFailed(status, code) {
    if (this.closed) return;
    if (sessionRefused(status, code)) {
      this.close();
      this.onSessionEnded?.(new ApiError(status, code, "The profile session ended."));
      return;
    }
    this.showNotice(liveProblem(status, code) ?? UNPLAYABLE, true);
  }

  /** A file the browser opened but cannot show or hear plays live converted from where it is. */
  switchToLive() {
    if (this.liveStarting && !this.closed) return true;
    if (!this.canConvert || this.live || this.closed) return false;
    const at = Math.max(this.resumeAt, this.video.currentTime || 0);
    this.resumeAt = 0;
    this.startLive(at);
    return true;
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
      this.renderNoteMarks();
      this.restoreTrackChoices();
      // A file the browser opens but cannot show (for example HEVC in some browsers) has no picture.
      if (!this.live && video.videoWidth === 0 && video.videoHeight === 0 && this.item.kind !== "trailer") this.check(() => video.videoWidth === 0, 1500);
    });
    for (const tracks of [video.audioTracks, video.textTracks]) {
      if (tracks?.addEventListener) on(tracks, "addtrack", () => this.after(() => this.restoreTrackChoices(), 0));
    }
    on(video, "timeupdate", () => this.tick());
    on(video, "play", () => this.updatePlayState());
    on(video, "pause", () => {
      this.updatePlayState();
      this.saveNow();
    });
    on(video, "playing", () => {
      this.startScreen.hidden = true;
      this.element.classList.remove("waiting");
      this.checkAudio();
      this.together?.session()?.playerChanged();
    });
    on(video, "canplay", () => this.together?.session()?.playerChanged());
    on(video, "waiting", () => {
      this.element.classList.add("waiting");
      this.together?.session()?.playerChanged();
    });
    on(this.timeline, "change", () => this.reportToParty("seek"));
    on(video, "seeked", () => this.saveNow());
    on(video, "volumechange", () => this.updateVolume());
    on(video, "ratechange", () => this.updateRate());
    if (typeof window !== "undefined" && window.WebKitPlaybackTargetAvailabilityEvent) {
      on(video, "webkitplaybacktargetavailabilitychanged", (event) => {
        this.airplayButton.hidden = (event.availability !== "available");
      });
    } else if (video.remote && typeof video.remote.watchAvailability === "function") {
      video.remote.watchAvailability((available) => {
        this.airplayButton.hidden = !available;
      }).catch(() => {});
    }
    on(video, "ended", () => this.finish());
    on(video, "error", () => this.videoFailed());
    on(this.timeline, "input", () => {
      if (Number.isFinite(video.duration)) {
        const fraction = Math.min(1, Math.max(0, Number(this.timeline.value) / 1000));
        video.currentTime = fraction * video.duration;
        this.showScrubPreview(fraction);
      }
      this.updateTime();
    });
    on(this.timeline, "pointermove", (event) => {
      if (!Number.isFinite(video.duration) || video.duration <= 0) return;
      const rect = this.timeline.getBoundingClientRect();
      const fraction = rect.width > 0 ? Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width)) : 0;
      this.showScrubPreview(fraction);
    });
    on(this.timeline, "pointerleave", () => this.hideScrubPreview());
    on(this.timeline, "pointercancel", () => this.hideScrubPreview());
    on(this.volume, "input", () => {
      video.volume = Number(this.volume.value);
      video.muted = video.volume === 0;
    });
    on(this.element, "pointermove", () => this.showControls());
    on(this.element, "pointerdown", () => this.showControls());
    on(this.element, "focusin", () => this.showControls());
    on(video, "click", () => {
      if (!this.popover.hidden) return this.closePopover();
      this.toggle();
    });
    on(video, "dblclick", () => this.toggleFullscreen());
    on(document, "click", (event) => {
      // The click's path is fixed when it starts, so a menu that redraws itself stays open.
      if (!this.popover.hidden && !event.composedPath().includes(this.popover)) this.closePopover();
    });
    on(document, "keydown", (event) => this.key(event));
    on(document, "fullscreenchange", () => this.updateFullscreen());
    on(video, "enterpictureinpicture", () => this.updatePictureInPicture());
    on(video, "leavepictureinpicture", () => this.updatePictureInPicture());
    on(document, "visibilitychange", () => {
      if (document.visibilityState === "hidden") this.saveNow({ keepalive: true });
      // The browser releases the screen wake lock while the tab is hidden; take it again.
      else if (!video.paused && !video.ended) this.keepAwake(true);
    });
    on(window, "pagehide", () => this.saveNow({ keepalive: true }));
    this.every(() => {
      if (!video.paused && !video.ended) this.saveNow();
    }, SAVE_INTERVAL);
    this.every(() => this.checkSleep(), 1000);
  }

  key(event) {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
    if (this.closed || (event.repeat && /^[np]$/i.test(event.key))) return;
    const target = event.target;
    const dialog = target?.closest?.('dialog, [role="dialog"]');
    if (dialog && dialog !== this.element) return;
    if (/^[np]$/i.test(event.key) && (this.popover?.hidden === false || target?.closest?.('[role="menu"]'))) return;
    if (target?.isContentEditable || target?.tagName === "SELECT") return;
    if ((target instanceof HTMLInputElement && target.type !== "range") || target instanceof HTMLTextAreaElement) return;
    const seconds = this.preferences.seekInterval;
    switch (event.key) {
      case " ":
      case "k":
      case "K":
        if (target instanceof HTMLButtonElement) return;
        event.preventDefault();
        this.toggle();
        break;
      case "n":
      case "N":
        event.preventDefault();
        void this.navigateEpisode("next");
        break;
      case "p":
      case "P":
        event.preventDefault();
        void this.navigateEpisode("previous");
        break;
      case "ArrowLeft":
      case "j":
        event.preventDefault();
        this.skip(-seconds);
        break;
      case "ArrowRight":
      case "l":
        event.preventDefault();
        this.skip(seconds);
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
        event.preventDefault();
        if (!this.popover.hidden) this.closePopover();
        else if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});
        else if (!document.fullscreenElement) this.close();
        break;
      case "?":
        event.preventDefault();
        this.onShowShortcuts?.();
        break;
      default:
        return;
    }
    this.showControls();
  }

  toggle() {
    if (!this.source) return;
    if (this.video.paused || this.video.ended) {
      this.video.play().catch(() => {});
      this.reportToParty("play");
    } else {
      this.video.pause();
      this.reportToParty("pause");
    }
    this.showControls();
  }

  skip(seconds) {
    const video = this.video;
    if (!Number.isFinite(video.duration)) return;
    video.currentTime = Math.min(Math.max(0, video.currentTime + seconds), video.duration);
    this.reportToParty("seek");
    this.showControls();
  }

  /** Sends play, pause or seek done here to the Watch Together party, if this browser is in one. */
  reportToParty(action) {
    const session = this.together?.session();
    if (session?.isFollowing(this.partyPlayer)) session.userAction(action, this.video.currentTime * 1000);
  }

  /** Watch Together: start a party for this title, or see who watches along and leave. */
  togetherMenu() {
    const session = this.together?.session();
    const state = session?.state;
    const content = [h("div", { class: "popover-title" }, "Watch Together")];
    if (state) {
      for (const member of state.members ?? []) {
        content.push(h("div", { class: "together-member" },
          h("div", {}, member.isYou ? `${member.name} (You)` : member.name, member.isHost ? " · Host" : "", member.isBuffering ? " · Loading…" : ""),
          h("div", { class: "muted" }, member.deviceName)));
      }
      if (state.isWaiting) content.push(h("div", { class: "muted" }, "Waiting until everyone is ready…"));
      content.push(h("button", { class: "secondary-button", onclick: async () => { this.closePopover(); await this.together.leave(); } }, "Leave Watch Together"));
    } else {
      content.push(h("p", { class: "muted together-hint" }, "Watch this title in step with other devices at home. They join from the title’s page, and play, pause and jumps apply to everyone."));
      content.push(h("button", { class: "primary-button", onclick: async () => { this.closePopover(); await this.together.start(this); } }, "Start Watch Together"));
      if (session?.error) content.push(h("div", { class: "muted" }, session.error));
    }
    this.openPopover(this.togetherButton, h("div", { class: "together-panel" }, ...content));
  }

  /** "Mia paused" and similar, shown briefly at the top of the picture. */
  showPartyNotice(session) {
    const text = session?.notice ?? (session?.state?.isWaiting ? "Waiting until everyone is ready…" : null);
    clear(this.togetherNotice);
    if (text) this.togetherNotice.append(icon("people", { size: 18 }), h("span", {}, text));
    this.togetherNotice.hidden = !text;
  }

  toggleMute() {
    this.video.muted = !this.video.muted;
    if (!this.video.muted && this.video.volume === 0) this.video.volume = 1;
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
    this.fullscreenButton.replaceChildren(icon(full ? "exitFullscreen" : "fullscreen", { size: 18 }));
    this.fullscreenButton.setAttribute("aria-label", full ? "Exit Full Screen" : "Enter Full Screen");
  }

  showAirPlayPicker() {
    if (typeof this.video.webkitShowPlaybackTargetPicker === "function") {
      this.video.webkitShowPlaybackTargetPicker();
    } else if (this.video.remote && typeof this.video.remote.prompt === "function") {
      this.video.remote.prompt().catch(() => {});
    }
  }

  updatePictureInPicture() {
    const active = document.pictureInPictureElement === this.video;
    this.pipButton.classList.toggle("active", active);
    this.pipButton.setAttribute("aria-label", active ? "Exit Picture in Picture" : "Enter Picture in Picture");
  }

  updatePlayState() {
    const playing = !this.video.paused && !this.video.ended;
    this.keepAwake(playing);
    this.playButton.replaceChildren(icon(playing ? "pause" : "play", { size: 22 }));
    this.playButton.classList.toggle("is-paused", !playing);
    this.playButton.setAttribute("aria-label", playing ? "Pause" : "Play");
    this.element.classList.toggle("paused", !playing);
    this.showControls();
  }

  tick() {
    this.updateTime();
    this.updateUpNext();
    this.updateCue();
  }

  updateTime() {
    const video = this.video;
    const duration = Number.isFinite(video.duration) ? video.duration : 0;
    this.elapsed.textContent = clock(video.currentTime);
    this.total.textContent = duration ? clock(duration) : "0:00";
    if (document.activeElement !== this.timeline) this.timeline.value = duration ? String(Math.round((video.currentTime / duration) * 1000)) : "0";
    this.timeline.setAttribute("aria-valuetext", timelineValueText(video.currentTime, duration));
    this.timeline.style.setProperty("--fill", duration ? `${(video.currentTime / duration) * 100}%` : "0%");
    this.endsAt.textContent = endsAt(video.currentTime, duration, video.playbackRate || 1);
  }

  updateVolume() {
    const muted = this.video.muted || this.video.volume === 0;
    this.muteButton.replaceChildren(icon(muted ? "mute" : "volume", { size: 18 }));
    this.muteButton.setAttribute("aria-label", muted ? "Unmute" : "Mute");
    this.volume.value = muted ? "0" : String(this.video.volume);
    this.volume.setAttribute("aria-valuetext", volumeValueText(this.video.volume, muted));
    this.volume.style.setProperty("--fill", `${(muted ? 0 : this.video.volume) * 100}%`);
  }

  updateRate() {
    this.rateButton.firstChild.textContent = rateLabel(this.video.playbackRate);
    this.updateTime();
  }

  showScrubPreview(fraction) {
    const duration = Number.isFinite(this.video.duration) ? this.video.duration : 0;
    if (!duration || !this.scrubPreview || !this.canScrubPreview) return;
    const clamped = Math.min(1, Math.max(0, fraction));
    const seconds = clamped * duration;
    this.previewTime.textContent = clock(seconds);
    this.scrubPreview.style.left = `clamp(88px, ${(clamped * 100).toFixed(2)}%, calc(100% - 88px))`;
    this.scrubPreview.hidden = false;
    const url = scrubPreviewFrameUrl(this.item.id, seconds, duration);
    if (!url || this.requestedPreviewUrl === url) return;
    this.requestedPreviewUrl = url;
    clearTimeout(this.previewDebounce);
    this.previewDebounce = setTimeout(() => {
      if (!this.closed && this.previewImg) this.previewImg.src = url;
    }, 90);
  }

  hideScrubPreview() {
    clearTimeout(this.previewDebounce);
    if (this.scrubPreview) this.scrubPreview.hidden = true;
  }

  /** Keeps the screen on while a title plays, like "Prevent Sleep During Playback" on the Mac. */
  async keepAwake(playing) {
    if (playing && this.preferences.keepScreenOn && !this.wakeLock && navigator.wakeLock && document.visibilityState === "visible") {
      try {
        this.wakeLock = await navigator.wakeLock.request("screen");
        this.wakeLock.addEventListener("release", () => (this.wakeLock = null), { once: true });
      } catch {
        // Not allowed here (for example on plain HTTP); the screen follows its own settings.
      }
    } else if (!playing && this.wakeLock) {
      this.wakeLock.release().catch(() => {});
      this.wakeLock = null;
    }
  }

  /** Controls fade out after the chosen delay while playing, unless a menu is open. */
  showControls() {
    this.element.classList.add("controls-visible");
    clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => {
      const focusInControls = this.controls.contains(document.activeElement);
      if (!this.video.paused && !this.video.ended && this.popover.hidden && !focusInControls) {
        this.element.classList.remove("controls-visible");
      }
    }, this.preferences.controlsAutoHideDelay * 1000);
  }

  // MARK: Menus

  openPopover(owner, content, { align = "end" } = {}) {
    this.closePopover();
    clear(this.popover);
    this.popover.append(...[content].flat());
    this.popover.hidden = false;
    this.popoverOwner = owner;
    owner.setAttribute("aria-expanded", "true");
    owner.classList.add("selected");
    const box = owner.getBoundingClientRect();
    const frame = this.element.getBoundingClientRect();
    const below = box.top < frame.height / 2;
    this.popover.style.top = below ? `${box.bottom - frame.top + 8}px` : "";
    this.popover.style.bottom = below ? "" : `${frame.bottom - box.top + 8}px`;
    const right = frame.right - box.right;
    this.popover.style.right = align === "end" ? `${Math.max(12, right)}px` : "";
    this.popover.classList.toggle("from-top", below);
    this.popover.querySelector("[aria-checked=true], button, input, textarea")?.focus({ preventScroll: true });
    this.showControls();
  }

  closePopover() {
    if (this.popover.hidden) return;
    this.popover.hidden = true;
    clear(this.popover);
    this.popoverOwner?.setAttribute("aria-expanded", "false");
    this.popoverOwner?.classList.remove("selected");
    this.popoverOwner = null;
    this.showControls();
  }

  menuItems(options) {
    return options.map((option) => {
      if (option === "divider") return h("div", { class: "menu-divider", role: "separator" });
      if (option.heading) return h("div", { class: "menu-heading", role: "presentation" }, option.heading);
      return h("button", {
        class: "menu-item check-item",
        role: "menuitemradio",
        "aria-checked": String(Boolean(option.selected)),
        disabled: option.enabled === false,
        onclick: () => {
          this.closePopover();
          option.action?.();
        },
      }, h("span", { class: "check-mark" }, option.selected ? icon("check", { size: 15 }) : null), option.title);
    });
  }

  showVariant(variants, current) {
    this.variants = variants;
    if (this.quality === "original" || this.quality === "auto") this.qualityLabel.textContent = current ? `Auto ${current.id}` : "Auto";
    else this.qualityLabel.textContent = this.quality;
  }

  qualityMenu() {
    const variants = this.variants ?? [];
    const choices = ["original", "auto", ...variants.map((variant) => variant.id)];
    this.openPopover(this.qualityButton, this.menuItems(choices.map((choice) => ({
      title: choice === "original" ? "Original (no conversion when possible)" : qualityLabel(choice, variants),
      selected: this.quality === choice,
      action: () => this.chooseQuality(choice),
    }))));
  }

  async chooseQuality(quality) {
    if (quality === this.quality || this.closed) return;
    const previous = this.quality;
    this.quality = quality;
    writeQuality(quality);
    this.qualityLabel.textContent = quality === "original" ? "Orig" : quality === "auto" ? "Auto" : quality;
    // Within adaptive streaming the next segment changes; to or from the original, playback starts again here.
    if (this.live instanceof HlsSource && quality !== "original") {
      this.live.setQuality(quality);
      return;
    }
    if (previous === quality || !this.source) return;
    const position = this.video.currentTime;
    const paused = this.video.paused;
    this.live?.destroy();
    this.live = null;
    if (quality === "original" && triesDirectPlay(this.source.contentType)) {
      this.video.src = this.source.streamPath;
      this.video.addEventListener("loadedmetadata", () => { this.video.currentTime = position; }, { once: true });
    } else {
      await this.startLive(position);
    }
    if (!paused && !this.closed) await this.play();
  }

  rateMenu() {
    const current = this.video.playbackRate || 1;
    this.openPopover(this.rateButton, this.menuItems(PLAYBACK_RATES.map((rate) => ({
      title: rate === 1 ? "Standard" : rateLabel(rate),
      selected: current === rate,
      action: () => (this.video.playbackRate = rate),
    }))));
  }

  audioMenu() {
    const tracks = this.live?.plan.audioTracks ?? [];
    const native = Array.from(this.video.audioTracks ?? []);
    const options = tracks.length ? tracks.map((track, position) => ({
      title: trackLabel(track, position), selected: track.index === this.live.audio, action: () => this.chooseAudio(track.index),
    })) : native.length ? native.map((track, position) => ({
      title: trackLabel({ ...track, title: track.label, language: track.language }, position), selected: track.enabled, action: () => this.chooseNativeAudio(track),
    })) : [{ title: "Original sound", selected: true, enabled: false }];
    options.push("divider", { heading: "Dialogue Boost" },
      ...DIALOGUE_BOOST_CHOICES.map(([value, title]) => ({ title, selected: this.preferences.dialogueBoost === value, action: () => this.setSound({ dialogueBoost: value }) })),
      "divider", { heading: "Volume Leveling" },
      ...VOLUME_LEVELING_CHOICES.map(([value, title]) => ({ title, selected: this.preferences.volumeLeveling === value, action: () => this.setSound({ volumeLeveling: value }) })));
    this.openPopover(this.audioButton, this.menuItems(options));
  }

  async chooseAudio(index) {
    const track = this.live?.plan.audioTracks.find((entry) => entry.index === index);
    if (!track || this.closed) return;
    this.preferredAudio = index;
    this.trackChoices.rememberAudio(track);
    try { await this.live.setAudio(index); if (!this.closed) this.restoreTrackChoices(); }
    catch { if (!this.closed) this.showNotice("This sound track couldn’t be loaded. Try selecting it again.", false); }
  }

  chooseNativeAudio(track, remember = true) {
    const tracks = Array.from(this.video.audioTracks ?? []);
    if (this.closed || !tracks.includes(track)) return;
    for (const candidate of tracks) candidate.enabled = candidate === track;
    if (remember) this.trackChoices.rememberAudio(track);
  }

  restoreTrackChoices() {
    if (this.closed || this.restoringTracks) return;
    this.restoringTracks = true;
    try {
      if (!this.live) {
        const tracks = Array.from(this.video.audioTracks ?? []);
        const audio = matchingTrack(tracks, this.trackChoices.audio())
          ?? (this.trackChoices.audio() ? null : trackForLanguage(tracks, this.preferences.defaultAudioLanguage));
        if (audio) this.chooseNativeAudio(audio, false);
      }
      const preference = this.trackChoices.subtitle();
      if (!preference.chosen) {
        // Without a remembered choice for this series, Settings › Playback picks the language.
        const wanted = this.preferences.defaultSubtitleLanguage;
        if (wanted === "off") return;
        const embedded = trackForLanguage(this.embeddedSubtitles.filter((track) => track.supported), wanted);
        if (embedded) { this.chooseSubtitle(embedded, false); return; }
        const native = trackForLanguage(Array.from(this.video.textTracks).filter((track) => ["subtitles", "captions"].includes(track.kind)), wanted);
        if (native) selectSubtitle(Array.from(this.video.textTracks), native);
        return;
      }
      const tracks = Array.from(this.video.textTracks);
      if (!preference.track) { selectSubtitle(tracks, null); return; }
      const embedded = matchingTrack(this.embeddedSubtitles.filter((track) => track.supported), preference.track);
      if (embedded) { this.chooseSubtitle(embedded, false); return; }
      const extracted = new Set([...this.subtitleElements.values()].map((element) => element.track));
      const native = matchingTrack(tracks.filter((track) => !extracted.has(track) && ["subtitles", "captions"].includes(track.kind)), preference.track);
      if (native) selectSubtitle(tracks, native);
    } finally { this.restoringTracks = false; }
  }

  /** Dialogue Boost and Volume Leveling, as in the other apps; the choice is kept in this browser. */
  setSound(change) {
    this.preferences = savePreferences({ ...this.preferences, ...change });
    this.applySound();
  }

  /**
   * Routes the picture's sound through an equalizer for speech and a compressor that evens out
   * loud and quiet scenes. Nothing is built until one of them is on; Off plays the sound as it is.
   */
  applySound() {
    const profile = audioProfile(this.preferences);
    if (!profile.active && !this.audioGraph) return;
    try {
      if (!this.audioGraph) {
        const context = new AudioContext();
        const source = context.createMediaElementSource(this.video);
        this.audioGraph = { context, source, nodes: [] };
      }
      const graph = this.audioGraph;
      graph.source.disconnect();
      for (const node of graph.nodes) node.disconnect();
      const { context } = graph;
      const nodes = [];
      if (profile.equalizer) {
        const preamp = context.createGain();
        preamp.gain.value = decibels(profile.preampDb);
        nodes.push(preamp);
        profile.equalizer.forEach((band, index, all) => {
          const filter = context.createBiquadFilter();
          filter.type = index === 0 ? "lowshelf" : index === all.length - 1 ? "highshelf" : "peaking";
          filter.frequency.value = band.frequency;
          filter.Q.value = 1.1;
          filter.gain.value = band.gain;
          nodes.push(filter);
        });
      }
      if (profile.compressor) {
        const compressor = context.createDynamicsCompressor();
        compressor.threshold.value = profile.compressor.threshold;
        compressor.knee.value = profile.compressor.knee;
        compressor.ratio.value = profile.compressor.ratio;
        compressor.attack.value = profile.compressor.attack;
        compressor.release.value = profile.compressor.release;
        const makeup = context.createGain();
        makeup.gain.value = decibels(profile.compressor.makeupDb);
        nodes.push(compressor, makeup);
      }
      graph.nodes = nodes;
      [graph.source, ...nodes].reduce((from, to) => from.connect(to)).connect(context.destination);
      context.resume().catch(() => {});
    } catch {
      // Web Audio is not available; the sound plays unchanged.
    }
    this.audioButton.classList.toggle("active", profile.active);
  }

  subtitleMenu() {
    const tracks = Array.from(this.video.textTracks);
    const showing = tracks.find((track) => track.mode === "showing");
    const options = [{ title: "Off", selected: !showing, action: () => { this.trackChoices.rememberSubtitle(null); selectSubtitle(tracks, null); } }, "divider"];
    if (tracks.length === 0 && this.embeddedSubtitles.length === 0) options.push({ title: "No subtitles available", enabled: false });
    const embedded = new Set([...this.subtitleElements.values()].map((element) => element.track));
    tracks.filter((track) => !embedded.has(track)).forEach((track, position) => options.push({
      title: track.label || (track.language ? trackLabel({ language: track.language }, position) : `Subtitle ${position + 1}`),
      selected: track === showing,
      action: () => { this.trackChoices.rememberSubtitle(track); selectSubtitle(tracks, track); },
    }));
    // Embedded tracks are listed before they are loaded. Selecting one starts a single bounded
    // extraction; native WebVTT cues then remain valid across every seek and sound-track change.
    this.embeddedSubtitles.forEach((track, position) => options.push({
      title: subtitleLabel(track, position),
      selected: Boolean(showing && this.subtitleElements.get(track.index)?.track === showing),
      enabled: track.supported,
      action: () => this.chooseSubtitle(track),
    }));
    this.openPopover(this.subtitleButton, this.menuItems(options));
  }

  chooseSubtitle(track, remember = true) {
    if (!track.supported || !this.source || this.closed) return;
    if (remember) this.trackChoices.rememberSubtitle(track);
    let element = this.subtitleElements.get(track.index);
    if (!element) {
      // Keep only the selected extracted track; each can contain up to 8 MiB of cues.
      for (const previous of this.subtitleElements.values()) previous.remove();
      this.subtitleElements.clear();
      element = h("track", { kind: "subtitles", label: subtitleLabel(track), srclang: track.language || "und" });
      element.src = subtitleUrl(this.source.streamPath, track.index);
      element.addEventListener("error", () => {
        if (this.closed || this.subtitleElements.get(track.index) !== element) return;
        element.remove();
        this.subtitleElements.delete(track.index);
        this.showNotice("This subtitle track couldn’t be loaded. Try selecting it again.", false);
      });
      this.subtitleElements.set(track.index, element);
      this.video.append(element);
    }
    selectSubtitle(Array.from(this.video.textTracks), element.track);
  }

  sleepMenu() {
    const options = [
      { title: "Off", selected: this.sleep.mode === "off", action: () => this.setSleep("off") },
      "divider",
      { title: "At end of episode", selected: this.sleep.mode === "end", action: () => this.setSleep("end") },
      ...SLEEP_MINUTES.map((minutes) => ({
        title: `${minutes} minutes`,
        selected: this.sleep.mode === "minutes" && this.sleep.minutes === minutes,
        action: () => this.setSleep("minutes", minutes),
      })),
    ];
    this.openPopover(this.sleepButton, this.menuItems(options));
  }

  setSleep(mode, minutes = 0) {
    this.sleep = { mode, minutes, notified: false, until: mode === "minutes" ? Date.now() + minutes * 60_000 : 0 };
    this.sleepButton.replaceChildren(icon(mode === "off" ? "moon" : "moonFill", { size: 18 }));
    this.sleepButton.classList.toggle("active", mode !== "off");
  }

  /** The sleep timer pauses and closes the player, as the Mac app does. */
  checkSleep() {
    if (this.closed) return;
    if (this.sleep.mode === "minutes" && Date.now() >= this.sleep.until) {
      this.signalSleepEnded();
      this.video.pause();
      this.close();
    }
  }

  signalSleepEnded() {
    if (this.closed || this.sleep.notified) return;
    this.sleep.notified = true;
    this.api.sleepTimerEnded().catch(() => {});
  }

  // MARK: Scene notes

  loadNotes() { return this.sceneNotes.reload(); }

  renderNoteMarks() {
    clear(this.noteMarks);
    const duration = this.video.duration;
    if (!Number.isFinite(duration) || duration <= 0) return;
    for (const note of this.notes) {
      const start = Math.min(1, Math.max(0, note.startMilliseconds / 1000 / duration));
      const end = Math.min(1, Math.max(start, (note.endMilliseconds ?? note.startMilliseconds) / 1000 / duration));
      this.noteMarks.append(h("span", { class: "note-mark", style: { left: `${start * 100}%`, width: `max(3px, ${(end - start) * 100}%)` } }));
    }
  }

  /** A note's text appears at its moment, top right, while the title plays on. */
  updateCue() {
    const now = this.video.currentTime * 1000;
    const note = this.notes.find((entry) => entry.text && now >= entry.startMilliseconds && now <= (entry.endMilliseconds ?? entry.startMilliseconds + 6000));
    this.cue.hidden = !note;
    if (note && this.cue.textContent !== note.text) this.cue.textContent = note.text;
  }

  notesPanel() { this.sceneNotes.open(); }

  // MARK: Up Next and the end

  async updateUpNext() {
    const video = this.video;
    const duration = Number.isFinite(video.duration) ? video.duration : 0;
    if (this.upNextItem === undefined && this.next && duration >= 300 && duration - video.currentTime < 60) {
      this.upNextItem = null;
      this.upNextItem = await this.next().catch(() => null);
    }
    const visible = showsUpNext({
      position: video.currentTime,
      duration,
      hasNext: Boolean(this.upNextItem),
      autoplay: this.preferences.automaticallyPlayNextEpisode,
      stopsAtEnd: this.sleep.mode === "end",
      dismissed: this.upNextDismissed,
      lead: this.preferences.upNextCountdownSeconds,
    });
    if (!visible) {
      this.upNext.hidden = true;
      return;
    }
    const seconds = upNextSeconds(video.currentTime, duration);
    if (this.upNext.hidden || this.upNext.dataset.id !== this.upNextItem.id) {
      clear(this.upNext);
      this.upNextCount = h("span", {}, `Play Now · ${seconds}`);
      this.upNext.dataset.id = this.upNextItem.id;
      this.upNext.append(
        h("div", { class: "eyebrow" }, "Up Next"),
        h("div", { class: "up-next-title" }, this.upNextItem.title),
        h("div", { class: "up-next-subtitle" }, playerSubtitle(this.upNextItem)),
        h("div", { class: "button-row" },
          h("button", { class: "primary-button", onclick: () => this.playNext(this.upNextItem) }, icon("play", { size: 15 }), this.upNextCount),
          h("button", { class: "secondary-button", onclick: () => this.dismissUpNext() }, "Cancel")));
      this.upNext.hidden = false;
    }
    this.upNextCount.textContent = `Play Now · ${seconds}`;
  }

  dismissUpNext() {
    this.upNextDismissed = true;
    this.upNext.hidden = true;
  }

  async finish() {
    if (this.closed) return;
    if (this.sleep.mode === "end") this.signalSleepEnded();
    this.updatePlayState();
    const video = this.video;
    if (this.saver && Number.isFinite(video.duration)) await this.saver.save(video.duration * 1000, video.duration * 1000, true);
    if (this.closed) return;
    if (this.onFinished) {
      const finished = this.onFinished;
      this.onFinished = null;
      this.close();
      finished();
      return;
    }
    const next = this.sleep.mode === "end" || this.upNextDismissed || !this.preferences.automaticallyPlayNextEpisode
      ? null
      : this.upNextItem ?? (this.next ? await this.next().catch(() => null) : null);
    if (next) this.playNext(next);
    else this.close();
  }

  async updateEpisodeButtons() {
    const lookups = [[this.previous, this.previousButton], [this.next, this.nextButton]];
    await Promise.all(lookups.map(async ([lookup, button]) => {
      const item = lookup ? await lookup().catch(() => null) : null;
      if (!this.closed && button) button.disabled = !item;
    }));
  }

  async navigateEpisode(direction) {
    if (this.closed || this.navigationPending || !this.source) return;
    const lookup = direction === "previous" ? this.previous : this.next;
    if (!lookup) return;
    this.navigationPending = true;
    try {
      const item = await lookup();
      if (!this.closed && item) this.playNext(item);
    } catch {
      if (!this.closed) this.showNotice("The episode could not be opened. Try again.");
    } finally {
      this.navigationPending = false;
    }
  }

  playNext(next) {
    if (this.closed || !next) return;
    this.close();
    this.onPlayNext?.(next, { intent: "play" });
  }

  // MARK: Problems

  /** The browser reported an error; ask the server whether the stream itself is at fault. */
  async videoFailed() {
    if (this.closed || !this.source || !this.video.error) return;
    const code = this.video.error.code;
    if (this.live) {
      this.showNotice(UNPLAYABLE, true);
      return;
    }
    let message = UNPLAYABLE;
    try {
      const response = await fetch(this.source.streamPath, { method: "HEAD", credentials: "same-origin", cache: "no-store" });
      if (response.status === 503) message = "This title’s storage is offline. Connect the drive, then try again.";
      else if (response.status === 401 || response.status === 403) message = "The profile session ended. Choose your profile again.";
      else if (response.status === 404 || response.status === 409) message = "This file isn’t available on the server.";
      else if (!response.ok) message = "The server couldn’t send this title. Try again.";
      else if (code === 2) message = "The connection to the server was interrupted. Try again.";
      else if (this.switchToLive()) return;
    } catch {
      message = "The server isn’t answering. Check that it is switched on, then try again.";
    }
    this.showNotice(message, true);
  }

  /** Looks once more after a moment, so a slow start is not mistaken for a missing picture. */
  check(stillWrong, delay) {
    this.after(() => {
      if (stillWrong() && !this.closed && !this.live && !this.switchToLive()) this.showNotice(UNPLAYABLE, true);
    }, delay);
  }

  /** Chrome and Edge play a file with an audio format they cannot decode silently. */
  checkAudio() {
    if (this.audioChecked || this.live || !("webkitAudioDecodedByteCount" in this.video)) return;
    this.audioChecked = true;
    this.after(() => {
      const video = this.video;
      if (!this.closed && !this.live && !video.paused && video.webkitAudioDecodedByteCount === 0 && video.webkitVideoDecodedByteCount > 0
        && !this.switchToLive())
        this.showNotice("No sound: this file’s audio format can’t play in a browser yet.", false);
    }, 4000);
  }

  showNotice(text, blocking) {
    clear(this.notice);
    this.notice.append(icon("warning", { size: 22 }), h("span", {}, text));
    if (blocking) {
      this.live?.destroy();
      this.video.pause();
      this.video.removeAttribute("src");
      this.video.load();
      this.startScreen.hidden = true;
      this.notice.append(h("button", { class: "secondary-button", onclick: () => this.close() }, "Back"));
      this.element.classList.add("failed");
    } else {
      this.after(() => (this.notice.hidden = true), 8000);
    }
    this.notice.hidden = false;
  }

  fail(error) {
    if (error instanceof ApiError && sessionRefused(error.status, error.code)) {
      this.close();
      this.onSessionEnded?.(error);
      return;
    }
    const message = error instanceof ApiError
      ? error.offline ? "The server isn’t answering. Check that it is switched on, then try again." : error.message
      : "This title couldn’t be opened.";
    this.showNotice(message, true);
  }

  // MARK: Lifetime

  saveNow(options = {}) {
    const video = this.video;
    if (!this.saver || !Number.isFinite(video.duration) || video.duration <= 0 || this.resumeAt > 0) return;
    this.saver.save(video.currentTime * 1000, video.duration * 1000, false, options);
  }

  /** Tickets last hours; a very long session gets a fresh one before the old one ends. */
  scheduleRenewal(retryIn = null) {
    const expires = new Date(this.source.expiresAt).getTime();
    const due = retryIn ?? expires - Date.now() - RENEW_BEFORE;
    if (!Number.isFinite(due)) return;
    this.after(async () => {
      if (this.closed) return;
      try {
        const renewed = await this.api.createPlayback(this.item.id);
        if (this.closed) return this.api.revokePlayback(renewed.id).catch(() => {});
        const old = this.source;
        this.source = renewed;
        if (this.live) {
          // The running stream continues; the next seek or track change uses the new ticket.
          this.live.streamPath = renewed.streamPath;
          for (const [index, element] of this.subtitleElements) {
            // Loaded cues are already in memory; a pending or failed fetch needs the fresh ticket.
            if (element.readyState !== 2) element.src = subtitleUrl(renewed.streamPath, index);
          }
          this.api.revokePlayback(old.id).catch(() => {});
          this.scheduleRenewal();
          return;
        }
        const position = this.video.currentTime;
        const paused = this.video.paused;
        this.video.src = renewed.streamPath;
        this.video.currentTime = position;
        if (!paused) this.video.play().catch(() => {});
        this.api.revokePlayback(old.id).catch(() => {});
        this.scheduleRenewal();
      } catch (error) {
        if (this.closed) return;
        // The old ticket still plays for a few minutes: a dropped answer or a busy server is
        // tried again until shortly before it ends. A refused profile ends the session at once.
        const left = expires - Date.now();
        const sessionEnded = error instanceof ApiError && sessionRefused(error.status, error.code);
        if (!sessionEnded && left > RENEW_RETRY_MS * 2) this.scheduleRenewal(RENEW_RETRY_MS);
        else this.fail(error);
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
    this.sceneNotes.close();
    for (const timer of this.timers) {
      clearTimeout(timer);
      clearInterval(timer);
    }
    clearTimeout(this.hideTimer);
    clearTimeout(this.previewDebounce);
    this.previewImg?.removeAttribute("src");
    this.listeners.forEach((remove) => remove());
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});
    this.live?.destroy();
    for (const element of this.subtitleElements.values()) element.remove();
    this.subtitleElements.clear();
    this.video.pause();
    this.video.removeAttribute("src");
    this.video.load();
    this.audioGraph?.context.close().catch(() => {});
    this.wakeLock?.release().catch(() => {});
    this.revoke();
    this.element.remove();
    document.body.classList.remove("playing");
    this.onClose?.();
  }
}

function readQuality() {
  try {
    return normalizeQuality(globalThis.localStorage?.getItem(QUALITY_KEY));
  } catch {
    return "original";
  }
}

function writeQuality(quality) {
  try {
    globalThis.localStorage?.setItem(QUALITY_KEY, quality);
  } catch {
    // Without storage the choice lasts for this title.
  }
}
