// Intro and credits in the browser, as on the Mac: Edit Metadata's times with where they came
// from, the trim editor with a picture, a film strip and yellow handles, and the server settings'
// overview of the detection with its progress and each series.

import { h, clear } from "./dom.js";
import {
  segmentOrigin, segmentRequest, segmentTimeText, segmentTrimClamp, segmentTrimInitial, segmentTrimLabel,
  segmentTrimSpan, segmentProgress, segmentRemaining, scrubPreviewFrameUrl,
} from "./logic.js";
import { triesDirectPlay } from "./live-logic.js";

export const SEGMENTS_FEATURE = "media-segments-v2";
const STRIP_FRAMES = 10;
const NUDGE = 100;

function button(label, onclick, { kind = "secondary-button", title, disabled = false } = {}) {
  return h("button", { type: "button", class: kind, title, "aria-label": title ? `${label}. ${title}` : label, onclick, disabled }, label);
}

/** Edit Metadata › Intro and Credits for an episode, or Re-analyze for a series. */
export function segmentsSection({ api, item, kind, canPreview }) {
  const message = h("p", { class: "muted small", role: "status", "aria-live": "polite" });
  const body = h("div", { class: "segments-panel" }, h("p", { class: "muted" }, "Loading…"));
  const element = h("section", { class: "editor-section settings-section metadata-section" }, h("h3", {}, "Intro and Credits"), body, message);
  const say = (text, failed = false) => { message.textContent = text; message.classList.toggle("error-text", failed); };

  if (kind === "series") {
    clear(body);
    body.append(h("p", { class: "muted small" }, "The server compares a season’s episodes to find the intro and the credits. Times set by hand stay."),
      button("Re-analyze All Seasons", async () => {
        try { await api.reanalyzeMediaSegments(item.id); say("The server examines the episodes again in the background."); }
        catch (error) { say(error.message, true); }
      }, { title: "Has the server compare the episodes of every season again in the background. Times set by hand stay." }));
    return element;
  }

  let times = null;
  const introStart = h("input", { class: "text-field narrow", placeholder: "0:00", "aria-label": "Intro Starts" });
  const introEnd = h("input", { class: "text-field narrow", placeholder: "1:30", "aria-label": "Intro Ends" });
  const creditsStart = h("input", { class: "text-field narrow", placeholder: "42:10", "aria-label": "Credits Start" });
  const introOrigin = h("span", { class: "muted small" });
  const creditsOrigin = h("span", { class: "muted small" });
  const save = button("Save Times", () => run(async () => {
    const request = segmentRequest(introStart.value, introEnd.value, creditsStart.value);
    if (!request) throw new Error("Enter times like 1:24 or 1:02:30.");
    // A field that still shows the stored time keeps its exact value, so only real changes become corrections.
    const keep = (value, stored) => (stored != null && value === Math.floor(stored / 1000) * 1000 ? stored : value);
    request.introStartMilliseconds = keep(request.introStartMilliseconds, times.introStartMilliseconds);
    request.introEndMilliseconds = keep(request.introEndMilliseconds, times.introEndMilliseconds);
    request.creditsStartMilliseconds = keep(request.creditsStartMilliseconds, times.creditsStartMilliseconds);
    apply(await api.saveMediaSegments(item.id, request));
    say("Saved. These times are used the next time the episode starts.");
  }), { kind: "primary-button", title: "Saves the typed times as corrections; detection never replaces them." });
  const reset = button("Reset to Detected", () => run(async () => {
    apply(await api.resetMediaSegments(item.id));
    say("The server examines the episode again; its times appear here shortly.");
  }), { title: "Removes the times set by hand; the server examines the episode again and fills in what it finds." });
  const reanalyze = button("Re-analyze Season", () => run(async () => {
    await api.reanalyzeMediaSegments(item.id);
    say("The server examines the episodes again in the background.");
  }), { title: "Has the server compare this season’s episodes again in the background. Times set by hand stay." });
  const editIntro = button("Edit Intro…", () => openTrim("intro"), { title: "Opens the episode’s beginning with a film strip: drag the yellow handles to where the intro begins and ends, play it to check, then save." });
  const editCredits = button("Edit Credits…", () => openTrim("credits"), { title: "Opens the episode’s ending with a film strip: drag the handle to where the credits begin, play it to check, then save." });
  const pending = h("p", { class: "muted small", hidden: true }, "The server has not examined this episode yet.");

  async function run(action) {
    for (const control of [save, reset, reanalyze, editIntro, editCredits]) control.disabled = true;
    try { say(""); await action(); }
    catch (error) { say(error.message, true); }
    finally { refreshButtons(); editIntro.disabled = editCredits.disabled = false; }
  }
  function refreshButtons() {
    save.disabled = !times;
    reset.disabled = !(times && (times.introSource === "manual" || times.creditsSource === "manual"));
    reanalyze.hidden = !times?.canAnalyze;
    reanalyze.disabled = false;
  }
  function apply(value) {
    times = value;
    introStart.value = segmentTimeText(value.introStartMilliseconds);
    introEnd.value = segmentTimeText(value.introEndMilliseconds);
    creditsStart.value = segmentTimeText(value.creditsStartMilliseconds);
    introOrigin.textContent = segmentOrigin(value.introSource, value.introConfidence);
    creditsOrigin.textContent = segmentOrigin(value.creditsSource, value.creditsConfidence);
    pending.hidden = !(value.canAnalyze && !value.analyzed);
    refreshButtons();
  }
  function openTrim(part) {
    if (!times) return;
    openTrimEditor({ api, item, part, times, canPreview, onSaved: (saved) => { apply(saved); say("Saved. These times are used the next time the episode starts."); } });
  }

  api.mediaSegments(item.id).then((value) => {
    clear(body);
    const line = (label, control, origin) => h("label", { class: "segments-row" }, h("span", {}, label), control, origin ?? h("span", {}));
    body.append(
      h("div", { class: "button-row" }, editIntro, editCredits),
      h("p", { class: "muted small" }, "Or type the times as minutes:seconds, for example 1:24. Leave a field empty when there is nothing to skip."),
      line("Intro Starts", introStart, introOrigin), line("Intro Ends", introEnd), line("Credits Start", creditsStart, creditsOrigin),
      pending, h("div", { class: "button-row" }, save, reset, reanalyze));
    apply(value);
  }).catch((error) => { clear(body); say(error.message, true); });
  return element;
}

/**
 * The trim editor: the episode's picture, a film strip of where the intro (first minutes) or the
 * credits (last minutes) are, and yellow handles. Plays the selection in a loop when the browser
 * can play the file itself; otherwise the picture follows the handles from the server's stills.
 */
export function openTrimEditor({ api, item, part, times, canPreview, onSaved }) {
  const intro = part === "intro";
  let source = null;
  let duration = 0;
  let span = { lower: 0, upper: 1 };
  let start = 0;
  let end = 1;
  let looping = false;
  let saved = false;
  const video = h("video", { class: "trim-video", playsinline: true, muted: true, preload: "auto", hidden: true });
  const still = h("img", { class: "trim-video", alt: "", hidden: true });
  const picture = h("div", { class: "trim-picture" }, video, still, h("p", { class: "muted trim-loading" }, "Opening the episode…"));
  const strip = h("div", { class: "trim-strip", role: "group", "aria-label": `${intro ? "Intro" : "Credits"} on the film strip` });
  const frames = h("div", { class: "trim-frames", "aria-hidden": "true" });
  const selection = h("div", { class: "trim-selection", "aria-hidden": "true" });
  const handle = (label) => h("div", { class: "trim-handle", role: "slider", tabindex: "0", "aria-label": label, "aria-valuemin": "0" });
  const startHandle = handle(intro ? "Intro starts" : "Credits start");
  const endHandle = intro ? handle("Intro ends") : null;
  const playhead = h("div", { class: "trim-playhead", "aria-hidden": "true" });
  strip.append(frames, selection, startHandle, ...(endHandle ? [endHandle] : []), playhead);
  const startLabel = h("span", { class: "trim-time" });
  const endLabel = h("span", { class: "trim-time" });
  const message = h("p", { class: "muted small", role: "status", "aria-live": "polite" });

  const play = button("Play Selection", () => togglePlay(), { title: "Plays only the yellow part, over and over, so you can check it (Space)." });
  const mute = button("Mute", () => { video.muted = !video.muted; mute.textContent = video.muted ? "Unmute" : "Mute"; }, { title: "Turns the sound of the preview off or on; the episode itself is not changed." });
  const nudge = (which, delta, label) => button(label, () => { move(which, which === "start" ? start + delta : end + delta); }, { title: `Moves the ${which === "start" ? (intro ? "intro’s start" : "credits’ start") : "intro’s end"} by a tenth of a second.` });
  const none = button(intro ? "No Intro" : "No Credits", () => commit(true), { title: intro ? "Saves that this episode has no intro, so nothing is skipped." : "Saves that this episode has no credits; Up Next then appears in the last seconds." });
  const cancel = button("Cancel", () => sheet.close(), { title: "Closes without saving anything." });
  const saveButton = button("Save", () => commit(false), { kind: "primary-button", title: intro ? "Saves where the intro begins and ends; Skip Intro jumps to its end." : "Saves where the credits begin; Up Next appears there." });

  const sheet = h("dialog", { class: "sheet trim-sheet", "aria-label": `Edit ${intro ? "Intro" : "Credits"}` },
    h("h2", {}, `Edit ${intro ? "Intro" : "Credits"}`),
    h("p", { class: "muted small" }, intro ? "Drag the yellow handles to where the intro begins and ends. Arrow keys move a handle by a tenth of a second, with Shift by a second."
      : "Drag the yellow handle to where the credits begin. Arrow keys move it by a tenth of a second, with Shift by a second."),
    picture, strip,
    h("div", { class: "trim-times" },
      h("span", { class: "inline-control" }, intro ? "Starts" : "Credits start", startLabel, nudge("start", -NUDGE, "−0.1 s"), nudge("start", NUDGE, "+0.1 s")),
      intro ? h("span", { class: "inline-control" }, "Ends", endLabel, nudge("end", -NUDGE, "−0.1 s"), nudge("end", NUDGE, "+0.1 s")) : null),
    h("div", { class: "button-row" }, play, mute),
    message,
    h("div", { class: "button-row end" }, none, cancel, saveButton));

  const position = (milliseconds) => `${((milliseconds - span.lower) / Math.max(1, span.upper - span.lower)) * 100}%`;
  function draw() {
    startHandle.style.left = position(start);
    startHandle.setAttribute("aria-valuetext", segmentTrimLabel(start));
    startLabel.textContent = segmentTrimLabel(start);
    if (endHandle) {
      endHandle.style.left = position(end);
      endHandle.setAttribute("aria-valuetext", segmentTrimLabel(end));
      endLabel.textContent = segmentTrimLabel(end);
    }
    selection.style.left = position(start);
    selection.style.width = `calc(${position(intro ? end : span.upper)} - ${position(start)})`;
  }
  function show(milliseconds) {
    playhead.style.left = position(milliseconds);
    if (!video.hidden) { if (!looping) video.currentTime = milliseconds / 1000; }
    else if (canPreview) {
      still.src = scrubPreviewFrameUrl(item.id, milliseconds / 1000, duration / 1000);
      still.hidden = false;
    }
  }
  function move(which, value) {
    const next = which === "start" ? segmentTrimClamp(value, intro ? end : span.upper, span) : segmentTrimClamp(start, value, span);
    start = next.start;
    if (intro) end = next.end;
    draw();
    show(which === "start" ? start : end);
  }
  function togglePlay() {
    if (video.hidden) { message.textContent = "This browser can’t play this file directly; the picture follows the handles instead."; return; }
    looping = !looping;
    play.textContent = looping ? "Pause" : "Play Selection";
    if (looping) { video.currentTime = start / 1000; video.play().catch(() => {}); } else video.pause();
  }
  video.addEventListener("timeupdate", () => {
    const now = video.currentTime * 1000;
    playhead.style.left = position(now);
    if (looping && now >= (intro ? end : Math.min(span.upper, start + 30_000))) video.currentTime = start / 1000;
  });
  for (const [element, which] of [[startHandle, "start"], [endHandle, "end"]]) {
    if (!element) continue;
    element.addEventListener("pointerdown", (event) => { element.setPointerCapture?.(event.pointerId); element.dataset.dragging = "1"; });
    element.addEventListener("pointermove", (event) => {
      if (!element.dataset.dragging) return;
      const box = strip.getBoundingClientRect();
      const fraction = Math.min(1, Math.max(0, (event.clientX - box.left) / box.width));
      move(which, Math.round(span.lower + fraction * (span.upper - span.lower)));
    });
    const stop = () => { delete element.dataset.dragging; };
    element.addEventListener("pointerup", stop);
    element.addEventListener("pointercancel", stop);
    element.addEventListener("keydown", (event) => {
      const step = event.shiftKey ? 1000 : NUDGE;
      if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
        event.preventDefault();
        move(which, (which === "start" ? start : end) + (event.key === "ArrowLeft" ? -step : step));
      }
    });
  }
  sheet.addEventListener("keydown", (event) => {
    if (event.key === " " && !(event.target instanceof HTMLButtonElement)) { event.preventDefault(); togglePlay(); }
  });

  async function commit(clearPart) {
    const request = {
      introStartMilliseconds: times.introStartMilliseconds ?? null,
      introEndMilliseconds: times.introEndMilliseconds ?? null,
      creditsStartMilliseconds: times.creditsStartMilliseconds ?? null,
    };
    if (intro) {
      request.introStartMilliseconds = clearPart ? null : start;
      request.introEndMilliseconds = clearPart ? null : end;
    } else request.creditsStartMilliseconds = clearPart ? null : start;
    saveButton.disabled = none.disabled = true;
    try {
      const value = await api.saveMediaSegments(item.id, request);
      saved = true;
      sheet.close();
      onSaved?.(value);
    } catch (error) {
      message.textContent = error.message;
      saveButton.disabled = none.disabled = false;
    }
  }

  sheet.addEventListener("close", () => {
    video.pause();
    video.removeAttribute("src");
    video.load();
    if (source) api.revokePlayback(source.id).catch(() => {});
    sheet.remove();
  }, { once: true });
  document.body.append(sheet);
  sheet.showModal();

  (async () => {
    try {
      source = await api.createPlayback(item.id);
      duration = source.progress?.durationMilliseconds ?? 0;
      if (triesDirectPlay(source.contentType)) {
        video.src = source.streamPath;
        await new Promise((resolve) => {
          video.addEventListener("loadedmetadata", resolve, { once: true });
          video.addEventListener("error", resolve, { once: true });
          setTimeout(resolve, 8000);
        });
        if (Number.isFinite(video.duration) && video.duration > 0 && !video.error) {
          duration = Math.round(video.duration * 1000);
          video.hidden = false;
        } else video.removeAttribute("src");
      }
      if (!(duration > 0)) throw new Error("The episode’s length isn’t known yet. Play it once, then try again.");
      picture.querySelector(".trim-loading")?.remove();
      span = segmentTrimSpan(part, duration, intro ? times.introStartMilliseconds : times.creditsStartMilliseconds, times.introEndMilliseconds);
      const known = intro
        ? (times.introStartMilliseconds != null && times.introEndMilliseconds != null ? { start: times.introStartMilliseconds, end: times.introEndMilliseconds } : null)
        : (times.creditsStartMilliseconds != null ? { start: times.creditsStartMilliseconds, end: span.upper } : null);
      const first = segmentTrimClamp((known ?? segmentTrimInitial(part, span)).start, (known ?? segmentTrimInitial(part, span)).end, span);
      start = first.start;
      end = first.end;
      clear(frames);
      for (let index = 0; index < STRIP_FRAMES; index++) {
        const at = span.lower + ((index + 0.5) / STRIP_FRAMES) * (span.upper - span.lower);
        frames.append(canPreview ? h("img", { src: scrubPreviewFrameUrl(item.id, at / 1000, duration / 1000), alt: "", loading: "lazy", decoding: "async" }) : h("div", { class: "trim-frame-empty" }));
      }
      draw();
      show(start);
      if (video.hidden && !canPreview) message.textContent = "This browser can’t play this file and the server has no stills; the handles still set the times.";
    } catch (error) {
      if (!saved) message.textContent = error.message;
    }
  })();
}

/** Server settings › Intros and Credits for the owner, refreshed every five seconds while open. */
export function serverSegmentsSection({ api, section, row, toggle }) {
  const state = h("span", { class: "settings-value" }, "Loading…");
  const bar = h("progress", { class: "segments-progress", max: "1", value: "0" });
  const current = h("p", { class: "muted small" });
  const series = h("div", { class: "settings-card-list" });
  const message = h("p", { class: "muted small", role: "status", "aria-live": "polite" });
  let settings = null;
  const enabled = toggle(false, (on) => change({ enabled: on }), "Find Intros and Credits");
  const pictures = toggle(true, (on) => change({ enabled: settings?.enabled ?? true, usePictures: on }), "Look at Pictures Too");
  const details = h("details", {}, h("summary", {}, "Series"), series);
  const element = section("Intros and Credits", "play",
    "The server finds where episodes’ intros and credits are, in the background and only while nobody watches. Only the times are stored.",
    row("Find Intros and Credits", enabled, "Compares the sound of a season’s episodes."),
    row("Look at Pictures Too", pictures, "Also reads small grey pictures of the episodes, for credits with changing music and intros under narration. Slower, more accurate."),
    row("Progress", h("div", { class: "segments-status" }, bar, state)),
    current,
    details,
    h("div", { class: "button-row" }, button("Re-analyze Everything", () => act(() => api.reanalyzeSeriesSegments(null), "Every episode is examined again in the background."),
      { title: "Has the server examine every episode again. Times set by hand stay." })),
    message);

  async function change(body) {
    try { render(await api.saveServerMediaSegments(body)); }
    catch (error) { message.textContent = error.message; }
  }
  async function act(action, done) {
    try { const value = await action(); if (value) render(value); message.textContent = done; }
    catch (error) { message.textContent = error.message; }
  }
  function render(value) {
    settings = value;
    const input = (wrapper) => wrapper.querySelector?.("input") ?? wrapper;
    input(enabled).checked = value.enabled;
    input(pictures).checked = value.usePictures !== false;
    input(pictures).disabled = !value.enabled;
    bar.value = segmentProgress(value);
    const done = (value.analyzedCount ?? 0) + (value.noResultCount ?? 0);
    const total = Math.max(value.totalCount ?? 0, done + (value.pendingCount ?? 0));
    state.textContent = !value.available ? "Not available on this server"
      : !value.enabled ? "Off"
        : value.pendingCount === 0 ? `All ${total} episodes examined`
          : `${done} of ${total} episodes${value.pausedForPlayback ? " · paused while someone watches" : ""}${segmentRemaining(value.estimatedSecondsRemaining) ? ` · ${segmentRemaining(value.estimatedSecondsRemaining)}` : ""}`;
    current.textContent = value.running && value.currentTitle ? `Now: ${value.currentTitle}${value.currentStep ? ` · ${value.currentStep}` : ""}` : "";
  }
  async function refreshSeries() {
    if (!details.open) return;
    try {
      const list = await api.mediaSegmentSeries();
      clear(series);
      for (const entry of list ?? []) series.append(h("div", { class: "settings-card small" },
        h("div", { class: "settings-card-main" },
          h("div", { class: "settings-card-title" }, entry.title),
          h("div", { class: "muted small" }, `${entry.withIntro} of ${entry.episodeCount} with intro · ${entry.withCredits} with credits${entry.pendingCount ? ` · ${entry.pendingCount} to examine` : ""}`)),
        h("div", { class: "settings-card-actions" }, button("Re-analyze", () => act(() => api.reanalyzeSeriesSegments(entry.seriesId), `${entry.title} is examined again in the background.`),
          { title: `Has the server examine every episode of ${entry.title} again. Times set by hand stay.` }))));
      if (!list?.length) series.append(h("p", { class: "muted small" }, "No series yet."));
    } catch (error) { message.textContent = error.message; }
  }
  details.addEventListener("toggle", refreshSeries);
  const tick = async () => {
    if (!element.isConnected && settings) return;
    try { render(await api.serverMediaSegments()); } catch (error) { message.textContent = error.message; }
    if (element.isConnected || !settings) setTimeout(tick, 5000);
  };
  tick();
  return element;
}

