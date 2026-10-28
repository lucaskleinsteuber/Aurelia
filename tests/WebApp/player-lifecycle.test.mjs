// The production Player methods with fake media objects: no decoder, browser or playback runs.
import test from "node:test";
import assert from "node:assert/strict";
import { Player } from "../../src/Aurelia.Server/WebApp/js/player.js";
import { createTrackChoices } from "../../src/Aurelia.Server/WebApp/js/track-choices.js";
import { createApi } from "../../src/Aurelia.Server/WebApp/js/api.js";
import { installDOM } from "./dom-fixture.mjs";
function player(overrides = {}) {
  const instance = Object.create(Player.prototype);
  Object.assign(instance, { closed: false, sleep: { mode: "off" }, video: { currentTime: 0, duration: 600, audioTracks: [], textTracks: [], pause() {} },
    notes: [], embeddedSubtitles: [], subtitleElements: new Map(), trackChoices: createTrackChoices({ item: { id: "film", kind: "movie" } }),
    updatePlayState() {}, close() { this.closed = true; }, preferences: { automaticallyPlayNextEpisode: true }, ...overrides });
  return instance;
}
test("minute expiry and end-of-episode send the existing sleep hint once and prevent autoplay", async () => {
  for (const mode of ["minutes", "end"]) {
    let calls = 0, next = 0;
    const p = player({ api: { sleepTimerEnded: async () => { calls++; } }, sleep: { mode, until: 0 }, next: async () => { next++; return {}; } });
    if (mode === "minutes") { p.checkSleep(); p.checkSleep(); } else { await p.finish(); await p.finish(); }
    assert.equal(calls, 1); assert.equal(p.closed, true); assert.equal(next, 0);
  }
});
test("manual close, inactive timer, or a late ended callback never sends a sleep hint", async () => {
  let calls = 0;
  const p = player({ api: { sleepTimerEnded: async () => { calls++; } } });
  p.checkSleep(); p.sleep = { mode: "end" }; p.close(); await p.finish(); p.checkSleep(); assert.equal(calls, 0);
});
test("sleep signaling stays at most once when the server refuses it", async () => {
  let calls = 0; const p = player({ api: { sleepTimerEnded: async () => { calls++; throw new Error("Synthetic refusal"); } } });
  p.signalSleepEnded(); p.signalSleepEnded(); await Promise.resolve(); assert.equal(calls, 1);
});
test("a native sound-track menu uses browser tracks without starting live conversion or probing", async () => {
  const english = { language: "en", label: "Main", enabled: true }, german = { language: "de", label: "Main", enabled: false };
  let options, remembered;
  const p = player({ video: { audioTracks: { 0: english, 1: german, length: 2 } }, trackChoices: { rememberAudio: (track) => { remembered = track; } },
    menuItems: (entries) => entries, openPopover: (_anchor, entries) => { options = entries; }, preferences: { nightMode: false } });
  p.audioMenu(); assert.equal(options.length, 4); options[1].action();
  assert.equal(german.enabled, true); assert.equal(english.enabled, false); assert.equal(remembered, german);
});
test("live sound changes remember semantic identity and reapply the chosen subtitle after the restart", async () => {
  const track = { index: 7, language: "deu", title: "Main", format: "aac" }; let audio, remembered, restored = 0;
  const p = player({ live: { plan: { audioTracks: [track] }, setAudio: async (index) => { audio = index; } },
    trackChoices: { rememberAudio: (choice) => { remembered = choice; } }, restoreTrackChoices: () => { restored++; } });
  await p.chooseAudio(7); assert.equal(audio, 7); assert.equal(remembered, track); assert.equal(restored, 1);
  p.closed = true; await p.chooseAudio(7); assert.equal(restored, 1);
});
test("remembered subtitles restore only supported semantic matches and explicit Off stays off", () => {
  const text = { language: "en", label: "Main", kind: "subtitles", mode: "showing" };
  const german = { language: "de", label: "Main", kind: "subtitles", mode: "disabled" };
  const p = player({ video: { audioTracks: [], textTracks: [text, german] } });
  p.trackChoices.rememberSubtitle(german); p.restoreTrackChoices(); assert.equal(german.mode, "showing"); assert.equal(text.mode, "disabled");
  p.trackChoices.rememberSubtitle(null); p.restoreTrackChoices(); assert.equal(german.mode, "disabled");
  let chosen;
  const supported = { index: 4, language: "en", title: "Signs", format: "ass", supported: true };
  const bitmap = { index: 9, language: "en", title: "Signs", format: "dvd_subtitle", supported: false };
  p.trackChoices.rememberSubtitle(supported); p.embeddedSubtitles = [bitmap, supported]; p.chooseSubtitle = (track) => { chosen = track; };
  p.restoreTrackChoices(); assert.equal(chosen, supported);
  chosen = null; p.embeddedSubtitles = [bitmap]; p.restoreTrackChoices(); assert.equal(chosen, null);
});
test("switching embedded subtitles keeps one extraction and a stale load failure cannot remove the new selection", (t) => {
  installDOM(t);
  const make = document.createElement;
  document.createElement = (tag) => { const node = make(tag); if (tag === "track") node.track = { mode: "disabled" }; return node; };
  const tracks = []; const elements = [];
  const video = { textTracks: tracks, append(element) { tracks.push(element.track); elements.push(element); element.remove = () => { const index = tracks.indexOf(element.track); if (index >= 0) tracks.splice(index, 1); }; } };
  const notices = [];
  const p = player({ video, source: { streamPath: "/api/v1/streams/ticket" }, showNotice: (message) => notices.push(message) });
  const A = { index: 2, language: "en", supported: true }, B = { index: 3, language: "de", supported: true };
  p.chooseSubtitle(A); const oldA = elements[0]; p.chooseSubtitle(B); p.chooseSubtitle(A); const newA = elements[2];
  assert.equal(p.subtitleElements.size, 1); assert.equal(tracks.length, 1); assert.equal(tracks[0].mode, "showing");
  oldA.dispatchEvent(new Event("error")); assert.equal(p.subtitleElements.get(2), newA); assert.equal(notices.length, 0);
  newA.dispatchEvent(new Event("error")); assert.equal(p.subtitleElements.size, 0); assert.equal(notices.length, 1);
});
test("notes and sleep API wrappers forward revisions, cancellation and cookie authorization", async () => {
  const calls = [], api = createApi(async (path, options) => { calls.push({ path, ...options }); return { status: 204, ok: true }; });
  const controller = new AbortController(); const options = { signal: controller.signal };
  await api.sceneNotes("a/b", options); await api.saveSceneNote("a/b", "n/o", { revision: 7 }, options); await api.removeSceneNote("a/b", "n/o", 7, options); await api.sleepTimerEnded();
  assert.equal(calls[2].path, "/api/v1/media/a%2Fb/notes/n%2Fo?revision=7"); assert.equal(calls[2].method, "DELETE");
  for (const call of calls.slice(0, 3)) assert.equal(call.signal, controller.signal);
  assert.equal(calls[3].path, "/api/v1/playback/sleep-timer-ended"); assert.equal(calls[3].keepalive, true); assert.equal(calls[3].method, "POST");
  for (const call of calls) { assert.equal(call.credentials, "same-origin"); assert.equal(call.headers["X-Aurelia-Web"], "profile"); }
});
test("native subtitle lists may be array-like without an iterator", () => {
  const subtitle = { language: "en", label: "Main", kind: "subtitles", mode: "showing" };
  const p = player({ video: { audioTracks: [], textTracks: { 0: subtitle, length: 1 } } });
  p.trackChoices.rememberSubtitle(null); assert.doesNotThrow(() => p.restoreTrackChoices()); assert.equal(subtitle.mode, "disabled");
});
test("scrub preview hover debounces rapid timeline movement and reuses the bucket URL", async (t) => {
  installDOM(t);
  const preview = document.createElement("div"); preview.hidden = true;
  const previewImg = document.createElement("img");
  const previewTime = document.createElement("span");
  const p = player({
    item: { id: "film-1", kind: "movie" },
    video: { currentTime: 0, duration: 300, audioTracks: [], textTracks: [], pause() {} },
    canScrubPreview: true,
    scrubPreview: preview, previewImg, previewTime,
    requestedPreviewUrl: "",
  });
  p.showScrubPreview(14 / 300);
  p.showScrubPreview(32 / 300);
  assert.equal(preview.hidden, false);
  assert.equal(previewTime.textContent, "0:32");
  assert.equal(p.requestedPreviewUrl, "/api/v1/media/film-1/scrub-previews/30");
  await new Promise((resolve) => setTimeout(resolve, 110));
  assert.equal(previewImg.src, "/api/v1/media/film-1/scrub-previews/30");
  p.hideScrubPreview();
  assert.equal(preview.hidden, true);
});
