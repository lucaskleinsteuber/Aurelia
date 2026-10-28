// Track choices are local metadata, scoped to the server/profile and series or film. Stream
// indices and credentials never enter storage; an ambiguous or missing match leaves defaults.
const KEY = "aurelia.trackChoices.v1";
const MAX_TITLES = 300;
const MAX_PROFILES = 32;
const MAX_BYTES = 512 * 1024;
let memory = { profiles: [], titles: [] };
const unavailableStores = new WeakSet();
const aliases = { eng: "en", deu: "de", ger: "de", fra: "fr", fre: "fr", spa: "es", ita: "it", por: "pt", jpn: "ja", zho: "zh", chi: "zh", kor: "ko", nld: "nl", dut: "nl", rus: "ru" };
const clean = (value) => String(value ?? "").normalize("NFKC").trim().toLowerCase().replace(/\s+/g, " ").slice(0, 128);
export function trackIdentity(track) {
  if (!track) return null;
  const code = clean(track.language).replace(/_/g, "-");
  const language = aliases[code] ?? code;
  const title = clean(track.title ?? track.label);
  if ((!language || language === "und") && !title) return null;
  return { language: language === "und" ? "" : language, title, format: clean(track.format), channels: Number.isInteger(track.channels) && track.channels > 0 && track.channels <= 64 ? track.channels : 0, forced: track.isForced === true };
}
function identity(value) { return value && typeof value === "object" ? trackIdentity({ ...value, isForced: value.forced }) : null; }
export function matchingTrack(tracks, preference) {
  if (!preference) return null;
  const candidates = [...tracks].filter((track) => {
    const value = trackIdentity(track);
    return value && value.language === preference.language && value.title === preference.title && value.forced === preference.forced;
  });
  if (candidates.length === 1) return candidates[0];
  const specific = candidates.filter((track) => {
    const value = trackIdentity(track);
    return (!preference.format || value.format === preference.format) && (!preference.channels || value.channels === preference.channels);
  });
  return specific.length === 1 ? specific[0] : null;
}
function normalize(value) {
  const entry = (record) => {
    if (!record || typeof record.scope !== "string" || record.scope.length > 200) return null;
    return { scope: record.scope, ...(typeof record.id === "string" && record.id.length <= 150 ? { id: record.id } : {}),
      audio: identity(record.audio), subtitleChosen: record.subtitleChosen === true, subtitle: identity(record.subtitle) };
  };
  return { profiles: (Array.isArray(value?.profiles) ? value.profiles : []).slice(-MAX_PROFILES).map(entry).filter(Boolean),
    titles: (Array.isArray(value?.titles) ? value.titles : []).slice(-MAX_TITLES).map(entry).filter((record) => record?.id) };
}
function read(storage) {
  try {
    if (!storage || unavailableStores.has(storage)) return normalize(memory);
    const raw = storage.getItem(KEY);
    if (raw == null) return { profiles: [], titles: [] };
    if (raw != null && raw.length <= MAX_BYTES) return normalize(JSON.parse(raw));
  } catch { /* Storage can be unavailable in private browsing. */ }
  return normalize(memory);
}
export function createTrackChoices({ scope, item, storage } = {}) {
  if (storage === undefined) { try { storage = globalThis.localStorage; } catch { /* Private origin. */ } }
  // No identity means this Player stays private to itself; never share an anonymous profile.
  const persist = typeof scope === "string" && scope.length > 0 && scope.length <= 200;
  const ownScope = persist ? scope : "anonymous";
  const id = item?.kind === "episode" && item.parentId ? `series:${item.parentId}` : `title:${item?.id ?? ""}`;
  let state = persist ? read(storage) : { profiles: [], titles: [] };
  const selected = () => ({ global: state.profiles.find((entry) => entry.scope === ownScope), title: state.titles.find((entry) => entry.scope === ownScope && entry.id === id) });
  function remember(kind, track) {
    const choice = trackIdentity(track);
    if (kind === "audio" && !choice) return;
    if (persist) state = read(storage);
    const found = selected();
    const update = (old) => ({ ...old, scope: ownScope, ...(kind === "audio" ? { audio: choice } : { subtitle: choice, subtitleChosen: true }) });
    state.profiles = [...state.profiles.filter((entry) => entry.scope !== ownScope), update(found.global)].slice(-MAX_PROFILES);
    state.titles = [...state.titles.filter((entry) => entry.scope !== ownScope || entry.id !== id), { ...update(found.title), id }].slice(-MAX_TITLES);
    if (persist) {
      memory = state;
      try { storage?.setItem(KEY, JSON.stringify(state)); } catch { if (storage && typeof storage === "object") unavailableStores.add(storage); }
    }
  }
  return {
    audio: () => { const choice = selected(); return choice.title?.audio ?? choice.global?.audio ?? null; },
    subtitle: () => { const choice = selected(); const value = choice.title?.subtitleChosen ? choice.title : choice.global; return { chosen: value?.subtitleChosen === true, track: value?.subtitle ?? null }; },
    rememberAudio: (track) => remember("audio", track),
    rememberSubtitle: (track) => remember("subtitle", track),
  };
}
