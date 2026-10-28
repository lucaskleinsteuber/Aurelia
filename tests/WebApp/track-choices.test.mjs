import test from "node:test";
import assert from "node:assert/strict";
import { createTrackChoices, matchingTrack, trackIdentity } from "../../src/Aurelia.Server/WebApp/js/track-choices.js";
const storage = () => { let value = null; return { getItem: () => value, setItem: (_key, next) => { value = next; } }; };
const episode = (id, parentId = "show") => ({ id, parentId, kind: "episode" });
const english = { index: 2, language: "eng", title: "Main", format: "aac", channels: 2 };
const german = { index: 4, language: "deu", title: "Main", format: "ac3", channels: 6 };
test("track choices identify semantic metadata and never persist stream indices or credentials", () => {
  const store = storage(), choices = createTrackChoices({ scope: "server:profile", item: episode("one"), storage: store });
  choices.rememberAudio(english); choices.rememberSubtitle({ index: 9, language: "eng", title: "Signs", format: "ass", isForced: true });
  const raw = store.getItem(); assert.equal(raw.includes('"index"'), false); assert.equal(raw.includes("token"), false);
  assert.deepEqual(choices.audio(), { language: "en", title: "main", format: "aac", channels: 2, forced: false });
  assert.equal(choices.subtitle().track.forced, true);
});
test("new episodes restore their series choice despite stream indices changing", () => {
  const store = storage(); createTrackChoices({ scope: "s:p", item: episode("one"), storage: store }).rememberAudio(german);
  const next = createTrackChoices({ scope: "s:p", item: episode("two"), storage: store });
  const tracks = [{ ...english, index: 4 }, { ...german, language: "ger", index: 8 }];
  assert.equal(matchingTrack(tracks, next.audio()), tracks[1]);
});
test("per-series and movie choices override the last global choice without leaking across profiles or servers", () => {
  const store = storage(), options = { scope: "s:p", storage: store };
  createTrackChoices({ ...options, item: episode("one", "A") }).rememberAudio(german);
  createTrackChoices({ ...options, item: episode("two", "B") }).rememberAudio(english);
  assert.equal(createTrackChoices({ ...options, item: episode("three", "A") }).audio().language, "de");
  assert.equal(createTrackChoices({ ...options, item: episode("four", "new") }).audio().language, "en");
  const movie = { id: "movie", kind: "movie" }; createTrackChoices({ ...options, item: movie }).rememberAudio(german);
  createTrackChoices({ ...options, item: episode("five", "B") }).rememberAudio(english);
  assert.equal(createTrackChoices({ ...options, item: movie }).audio().language, "de");
  for (const scope of ["s:other", "different:p"]) assert.equal(createTrackChoices({ scope, storage: store, item: movie }).audio(), null);
});
test("explicit subtitle Off survives another series selecting captions and differs from never chosen", () => {
  const store = storage(), options = { scope: "s:p", storage: store };
  assert.deepEqual(createTrackChoices({ ...options, item: episode("one", "A") }).subtitle(), { chosen: false, track: null });
  createTrackChoices({ ...options, item: episode("one", "A") }).rememberSubtitle(null);
  createTrackChoices({ ...options, item: episode("two", "B") }).rememberSubtitle({ language: "eng", title: "Signs", format: "ass" });
  assert.deepEqual(createTrackChoices({ ...options, item: episode("three", "A") }).subtitle(), { chosen: true, track: null });
});
test("missing, commentary, forced and ambiguous tracks never substitute a different semantic choice", () => {
  const preference = trackIdentity(english);
  assert.equal(matchingTrack([german], preference), null);
  assert.equal(matchingTrack([{ ...english, title: "Commentary" }], preference), null);
  assert.equal(matchingTrack([{ ...english, isForced: true }], preference), null);
  assert.equal(matchingTrack([{ ...english, index: 10 }, { ...english, index: 11 }], preference), null);
  const specific = [{ ...english, channels: 6 }, english]; assert.equal(matchingTrack(specific, preference), english);
  assert.equal(trackIdentity({ index: 5, language: "und" }), null);
});
test("storage is bounded to 300 titles and 32 profile contexts and rejects oversized/corrupt snapshots", () => {
  const store = storage();
  for (let i = 0; i < 310; i++) createTrackChoices({ scope: `server:p${i % 35}`, item: { id: `movie${i}`, kind: "movie" }, storage: store }).rememberAudio(english);
  const saved = JSON.parse(store.getItem()); assert.equal(saved.titles.length, 300); assert.equal(saved.profiles.length, 32);
  assert.equal(saved.titles.some((entry) => entry.id === "title:movie0"), false);
  for (const raw of ["invalid json", " ".repeat(512 * 1024 + 1), '{"profiles":[null],"titles":[42]}']) {
    const bad = { getItem: () => raw, setItem() {} };
    assert.doesNotThrow(() => createTrackChoices({ scope: "never-used", item: episode("a"), storage: bad }));
  }
});
test("unavailable storage keeps this page's bounded choices, while an anonymous Player cannot share a profile", () => {
  const privateStore = { getItem() { throw new Error("blocked"); }, setItem() { throw new Error("blocked"); } };
  createTrackChoices({ scope: "private:p", item: episode("one"), storage: privateStore }).rememberAudio(english);
  assert.equal(createTrackChoices({ scope: "private:p", item: episode("two"), storage: privateStore }).audio().language, "en");
  createTrackChoices({ item: episode("one"), storage: privateStore }).rememberAudio(german);
  assert.equal(createTrackChoices({ item: episode("two"), storage: privateStore }).audio(), null);
});

test("bitmap subtitles that browser cannot display are skipped during track matching", () => {
  const pgsGerman = { index: 1, language: "deu", title: "Full", format: "hdmv_pgs_subtitle", supported: false };
  const vttGerman = { index: 2, language: "deu", title: "Full", format: "webvtt", supported: true };
  const store = storage(), choices = createTrackChoices({ scope: "server:profile", item: episode("one"), storage: store });
  choices.rememberSubtitle(vttGerman);

  const available = [pgsGerman, vttGerman];
  // Filtering supported tracks ensures PGS bitmap subtitles are never picked
  const supportedOnly = available.filter((t) => t.supported !== false);
  const matched = matchingTrack(supportedOnly, choices.subtitle().track);
  assert.equal(matched, vttGerman);

  // If only unsupported bitmap subtitle is present, selection falls back to null (defaults)
  assert.equal(matchingTrack([pgsGerman].filter((t) => t.supported !== false), choices.subtitle().track), null);
});
