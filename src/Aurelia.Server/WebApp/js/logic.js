// Rules of the browser app that need no page: they run the same in a browser and in
// `node --test tests/WebApp`.

/** A profile PIN is 4 to 8 digits, as on the server, the Mac and the Apple TV. */
export function isPin(text) {
  return /^[0-9]{4,8}$/.test(text);
}

export const PIN_INCORRECT = "The PIN is incorrect.";

/** Matches the server's owner-only settings and full-library storage policy. */
export function managementPermissions(profile) {
  const owner = profile?.role === "owner";
  const administrator = owner || profile?.role === "admin";
  return { owner, administrator, storage: administrator && (owner || profile.accessMode !== "selectedTitles") };
}

/** A management check that administrators are allowed to make, before optional owner sections. */
export async function loadManagementSections(api, profile, { signal } = {}) {
  const permissions = managementPermissions(profile);
  if (!permissions.administrator) throw new Error("Only the server's owner and administrators manage it.");
  const jobs = await api.metadataJobs({ signal });
  const sections = { jobs, libraries: [], devices: [], users: [], backups: [], issues: [] };
  const readers = { devices: () => api.devices({ signal }) };
  if (typeof api.serverHealth === "function") readers.health = () => api.serverHealth({ signal });
  if (permissions.storage) readers.libraries = () => api.libraries({ signal });
  if (permissions.owner) {
    Object.assign(readers, {
      status: () => api.serverStatus({ signal }), updates: () => api.serverUpdates({ signal }),
      users: () => api.serverUsers({ signal }), power: () => api.serverPower({ signal }), backups: () => api.serverBackups({ signal }),
    });
    if (typeof api.serverScrubPreviews === "function") readers.scrubPreviews = () => api.serverScrubPreviews({ signal });
    if (typeof api.serverTranscoding === "function") readers.transcoding = () => api.serverTranscoding({ signal });
    // Optional extras: an older server without them still shows the rest.
    const optional = (read) => () => read().catch((error) => {
      if (error?.name === "AbortError" || error?.status === 401 || error?.code === "management_locked") throw error;
      return null;
    });
    if (typeof api.metadataProvider === "function") readers.metadataProvider = optional(() => api.metadataProvider({ signal }));
    if (typeof api.subtitleProvider === "function") readers.subtitleProvider = optional(() => api.subtitleProvider({ signal }));
    if (typeof api.serverCapabilities === "function") readers.capabilities = optional(() => api.serverCapabilities({ signal }));
  }
  await Promise.all(Object.entries(readers).map(async ([name, read]) => {
    try { sections[name] = await read(); }
    catch (error) {
      if (error?.name === "AbortError" || error?.status === 401 || error?.code === "management_locked") throw error;
      sections.issues.push({ section: name, message: error.message ?? "This section could not be loaded." });
    }
  }));
  return sections;
}

export function libraryPayload({ name = "", path = "", kind = "automatic" }) {
  // Filesystem existence, permissions, symlinks and overlap are checked by the server.
  if (!path || path.includes("\0") || !(/^(\/|[a-z]:[\\/]|\\\\)/i.test(path)))
    throw new Error("Enter an absolute folder path on the server.");
  if (!["automatic", "movies", "tvShows"].includes(kind)) throw new Error("Choose a valid storage type.");
  if (name.trim().length > 128 || /[\u0000-\u001f\u007f]/.test(name)) throw new Error("Use a storage location name of up to 128 visible characters.");
  return { name: name.trim() || null, path, kind, combineExisting: false, requireImportPreview: false };
}

function abortableDelay(milliseconds, signal) {
  return new Promise((resolve, reject) => {
    const abort = () => { clearTimeout(timer); reject(new DOMException("Cancelled", "AbortError")); };
    const timer = setTimeout(() => { signal?.removeEventListener("abort", abort); resolve(); }, milliseconds);
    if (signal?.aborted) abort();
    else signal?.addEventListener("abort", abort, { once: true });
  });
}

/** Removing a large location is asynchronous. Never report it removed on a mere 202 response. */
export async function waitForLibraryOperation(api, operation, { signal, onProgress = () => {}, wait = abortableDelay, attempts = 300 } = {}) {
  if (!operation) return null; // 204 means completed synchronously.
  for (let attempt = 0; attempt <= attempts; attempt += 1) {
    if (signal?.aborted) throw new DOMException("Cancelled", "AbortError");
    if (operation.state === "completed") return operation;
    if (["failed", "cancelled", "interrupted"].includes(operation.state)) throw new Error(operation.error || "The storage location could not be removed.");
    if (!operation.id || attempt === attempts) throw new Error("Removal is still running on the server. Refresh Storage Locations to check its progress.");
    onProgress(operation);
    await wait(1000, signal);
    operation = await api.libraryOperation(operation.id, { signal });
  }
}

/** The profile editor saves role, PIN, enablement and access together against its revision. */
export function profilePayload(snapshot, draft) {
  const creating = !snapshot;
  const role = draft.role;
  if (!["owner", "admin", "user"].includes(role)) throw new Error("Choose a valid profile role.");
  const pinProtectionEnabled = role !== "user" || Boolean(draft.pinProtectionEnabled);
  const pin = String(draft.pin ?? "");
  const confirmation = String(draft.pinConfirmation ?? "");
  const existingPIN = snapshot?.user.pinProtectionEnabled && !snapshot.user.needsPinSetup;
  if (pinProtectionEnabled && ((pin || confirmation) ? !isPin(pin) || pin !== confirmation : !existingPIN))
    throw new Error("Enter a matching PIN of 4–8 digits in both fields.");
  const accessMode = role === "owner" ? "entireLibrary" : draft.accessMode;
  if (!["entireLibrary", "selectedTitles", "legacyLibraries"].includes(accessMode)
    || (accessMode === "legacyLibraries" && (creating || snapshot.access.mode !== "legacyLibraries")))
    throw new Error("Choose a valid content access mode.");
  const titleIds = accessMode === "selectedTitles" ? [...new Set(draft.titleIds ?? [])].sort() : [];
  const body = { role, isEnabled: Boolean(draft.isEnabled), pinProtectionEnabled, ...(pinProtectionEnabled && pin ? { pin } : {}) };
  if (creating) {
    const username = String(draft.username ?? "").trim();
    if (username.length < 3 || username.length > 64) throw new Error("Use a profile name of 3–64 characters.");
    return { ...body, username, accessMode, titleIds };
  }
  const sameTitles = JSON.stringify(titleIds) === JSON.stringify([...(snapshot.access.titleIds ?? [])].sort());
  if (accessMode !== snapshot.access.mode || (accessMode === "selectedTitles" && !sameTitles)) Object.assign(body, { accessMode, titleIds });
  return { revision: snapshot.revision, ...body };
}

const EDITOR_PROPERTIES = { title: "title", releaseYear: "releaseYear", overview: "overview", runtimeMinutes: "runtimeMinutes", fsk: "fskAge", genres: "genres", studios: "studios", country: "country",
  credits: "credits", poster: "poster", backdrop: "backdrop" };

/** One person in Cast and Crew as the server takes it; names and roles are trimmed and bounded. */
export function editorCredit(credit) {
  const name = String(credit?.name ?? "").trim();
  const department = String(credit?.department ?? "").trim() || "Acting";
  if (!name || name.length > 256) throw new Error("Give every person a name of up to 256 characters.");
  const optional = (text) => { const value = String(text ?? "").trim(); return value ? value.slice(0, 256) : null; };
  return { id: credit.id, name, department: department.slice(0, 64), job: optional(credit.job), character: optional(credit.character),
    profile: credit.profile ?? null, personKey: credit.personKey ?? null };
}

/** A picture choice: an existing picture or a new upload, with an optional crop inside 0…1. */
export function editorArtwork(selection) {
  if (!selection) return null;
  const crop = selection.crop ? normalizedCrop(selection.crop) : null;
  if (Boolean(selection.assetId) === Boolean(selection.uploadId)) throw new Error("Choose one picture.");
  return { assetId: selection.assetId ?? null, uploadId: selection.uploadId ?? null, crop };
}

function normalizedCrop(crop) {
  const round = (value) => Math.round(value * 1e6) / 1e6;
  const x = round(Math.max(0, crop.x)), y = round(Math.max(0, crop.y));
  const width = round(Math.min(1 - x, crop.width)), height = round(Math.min(1 - y, crop.height));
  if (![x, y, width, height].every(Number.isFinite) || width <= 0 || height <= 0) throw new Error("The crop is outside the picture.");
  return { x, y, width, height, rotation: [0, 90, 180, 270].includes(crop.rotation) ? crop.rotation : 0 };
}

/**
 * The part of a picture a crop frame of `aspect` (width / height) shows at `zoom` (1 = as large
 * as fits), centred on `centerX`/`centerY` (0…1) and kept inside the picture. All in 0…1.
 */
export function cropFrame({ imageWidth, imageHeight, aspect, zoom = 1, centerX = 0.5, centerY = 0.5 }) {
  const pictureAspect = imageWidth / imageHeight;
  let width = aspect >= pictureAspect ? 1 : aspect / pictureAspect;
  let height = aspect >= pictureAspect ? pictureAspect / aspect : 1;
  const scale = 1 / Math.max(1, Math.min(4, zoom));
  width *= scale;
  height *= scale;
  const x = Math.min(1 - width, Math.max(0, centerX - width / 2));
  const y = Math.min(1 - height, Math.max(0, centerY - height / 2));
  return normalizedCrop({ x, y, width, height, rotation: 0 });
}

function editorNumber(value, label, minimum, maximum) {
  const text = String(value ?? "").trim();
  if (!text) return null;
  if (!/^\d+$/.test(text) || Number(text) < minimum || Number(text) > maximum) throw new Error(`Check ${label}.`);
  return Number(text);
}

function editorList(value) {
  const list = Array.isArray(value) ? value : String(value ?? "").split(/\r?\n/);
  const entries = [...new Set(list.map((entry) => entry.trim()).filter(Boolean))];
  if (entries.length > 50 || entries.some((entry) => entry.length > 128)) throw new Error("Use up to 50 entries, each at most 128 characters.");
  return entries;
}

/** Edits only named fields. Hidden credits, artwork and pre-existing overrides remain intact. */
export function metadataPayload(document, changes = {}, automatic = []) {
  const values = structuredClone(document.values);
  const overrides = new Set(document.overrideFields ?? []);
  for (const field of automatic) {
    if (!EDITOR_PROPERTIES[field]) throw new Error("Unknown metadata field.");
    values[EDITOR_PROPERTIES[field]] = structuredClone(document.automaticValues[EDITOR_PROPERTIES[field]]);
    overrides.delete(field);
  }
  for (const [field, raw] of Object.entries(changes)) {
    const property = EDITOR_PROPERTIES[field];
    if (!property) throw new Error("Unknown metadata field.");
    let value = raw;
    if (field === "releaseYear") value = editorNumber(raw, "the release year (1800–3000)", 1800, 3000);
    else if (field === "runtimeMinutes") value = document.kind === "movie" ? editorNumber(raw, "the runtime (1–14400 minutes)", 1, 14400) : null;
    else if (field === "fsk") {
      value = editorNumber(raw, "the FSK age", 0, 18);
      if (value !== null && ![0, 6, 12, 16, 18].includes(value)) throw new Error("Choose a valid FSK age.");
    } else if (field === "genres" || field === "studios") value = editorList(raw);
    else if (field === "credits") {
      if (!Array.isArray(raw) || raw.length > 200) throw new Error("Use up to 200 people in Cast and Crew.");
      value = raw.map(editorCredit);
    } else if (field === "poster" || field === "backdrop") value = editorArtwork(raw);
    else value = String(raw ?? "").trim();
    values[property] = value;
    overrides.add(field);
  }
  if (!values.title?.trim() || values.title.length > 512) throw new Error("Enter a title of 1–512 characters.");
  if ((values.overview?.length ?? 0) > 8192 || (values.country?.length ?? 0) > 128) throw new Error("Use a shorter description or country name.");
  return { revision: document.revision, values, overrideFields: [...overrides].sort() };
}

/** A readable name for the Mac's device list, such as "Safari on iPhone". */
export function deviceName(userAgent = "", maxTouchPoints = 0) {
  const agent = String(userAgent);
  let browser = "Browser";
  if (/Edg\//.test(agent)) browser = "Edge";
  else if (/OPR\/|Opera/.test(agent)) browser = "Opera";
  else if (/Firefox\/|FxiOS\//.test(agent)) browser = "Firefox";
  else if (/Chrome\/|CriOS\//.test(agent)) browser = "Chrome";
  else if (/Safari\//.test(agent)) browser = "Safari";
  let system = "";
  if (/iPhone/.test(agent)) system = "iPhone";
  else if (/iPad/.test(agent) || (/Macintosh/.test(agent) && maxTouchPoints > 1)) system = "iPad";
  else if (/Android/.test(agent)) system = "Android";
  else if (/Macintosh|Mac OS X/.test(agent)) system = "Mac";
  else if (/Windows/.test(agent)) system = "Windows";
  else if (/CrOS/.test(agent)) system = "Chromebook";
  else if (/Linux/.test(agent)) system = "Linux";
  return system ? `${browser} on ${system}` : browser;
}

/** The same picture color for a profile as on the Mac and the Apple TV: the sum of its UUID bytes. */
export function profileColorIndex(id, count = 7) {
  const hex = String(id ?? "").replace(/[^0-9a-fA-F]/g, "");
  if (hex.length !== 32) return 0;
  let sum = 0;
  for (let index = 0; index < 32; index += 2) sum += parseInt(hex.slice(index, index + 2), 16);
  return sum % count;
}

/** The built-in profile pictures: a symbol on one of the palettes, stored as "symbol:palette". */
export const PICTURE_SYMBOLS = Object.freeze([
  "star", "rocket", "cat", "dog", "heart", "bolt", "leaf", "moon", "music", "gamecontroller", "film", "crown",
]);
/** In the order of the existing profile gradients (palette-0 … palette-6), plus red. */
export const PICTURE_PALETTES = Object.freeze(["blue", "purple", "pink", "orange", "teal", "green", "indigo", "red"]);
export const PHOTO_PICTURE = "photo";
export const MAXIMUM_PHOTO_BYTES = 8 * 1024 * 1024;

/** The symbol and palette of a built-in picture key; null for a photo, no picture or an unknown key. */
export function parsePicture(key) {
  const parts = String(key ?? "").split(":");
  if (parts.length !== 2) return null;
  const [symbol, palette] = parts;
  if (!PICTURE_SYMBOLS.includes(symbol) || !PICTURE_PALETTES.includes(palette)) return null;
  return { symbol, palette, paletteIndex: PICTURE_PALETTES.indexOf(palette) };
}

/** The name a profile shows: its chosen name, else its sign-in name (the picker sends it as `name`). */
export function shownName(user) {
  const chosen = String(user?.displayName ?? "").trim();
  return chosen || user?.username || user?.name || "";
}

/** "Children's profile · up to FSK 6" for a profile with an age limit, null otherwise. */
export function ageLimitSummary(limit) {
  if (limit === null || limit === undefined) return null;
  return limit === 0 ? "Children's profile · FSK 0" : `Children's profile · up to FSK ${limit}`;
}

export const TOUR_SEEN_KEY = "aurelia.tourSeen";

/** The short tour of the browser app on the first sign-in: the place to light up and one sentence. */
export const TOUR_STOPS = Object.freeze([
  { target: ".page .continue-card, .page .poster-card", title: "Open a Title", text: "Click a poster to see its details. Play starts it, and its menu has everything else." },
  { target: ".top-bar .tabs", title: "Your Library", text: "Home, Movies, TV Shows, Collections and your Watchlist." },
  { target: ".top-actions a[href='/search']", title: "Search", text: "Find titles, people and genres. Press / anywhere to start." },
  { target: ".avatar-button", title: "Your Profile", text: "Settings, your name and picture, watch history and switching profiles." },
]);

/**
 * The first tour target that is on screen, else the first one at all. Rectangles are what
 * getBoundingClientRect returns; a target hidden behind the top bar or below the window loses
 * to one the person can see without scrolling.
 */
export function visibleTourTarget(rects, viewport, topInset = 0) {
  const sized = rects.map((rect, index) => ({ rect, index })).filter(({ rect }) => rect && rect.width > 0 && rect.height > 0);
  const onScreen = sized.find(({ rect }) => rect.top >= topInset && rect.bottom <= viewport.height && rect.left >= 0 && rect.right <= viewport.width);
  return (onScreen ?? sized[0])?.index ?? -1;
}

/** The lit place of the tour, kept inside the window so its ring never runs off screen. */
export function tourHole(rect, viewport, padding = 8, margin = 4) {
  if (!rect || rect.width <= 0 || rect.height <= 0) return null;
  const left = Math.max(margin, rect.left - padding);
  const top = Math.max(margin, rect.top - padding);
  const right = Math.min(viewport.width - margin, rect.right + padding);
  const bottom = Math.min(viewport.height - margin, rect.bottom + padding);
  return right - left > 0 && bottom - top > 0 ? { left, top, right, bottom } : null;
}

/**
 * Which Continue Watching choice a title's menu offers: "remove" while it is started and shown
 * there, "show" once it was hidden, nothing for a title that isn't in the row at all.
 */
export function continueWatchingChoice(item) {
  if (!item || !["movie", "series", "episode"].includes(item.kind)) return null;
  if (item.continueWatchingHidden) return "show";
  const completed = item.watchState === "completed" || item.progress?.isCompleted;
  const started = item.watchState === "inProgress" || (item.progress?.positionMilliseconds ?? 0) > 0;
  return started && !completed ? "remove" : null;
}

/** Whether this browser still owes its person the tour. Storage may be missing or refuse access. */
export function tourPending(storage) {
  try {
    return storage?.getItem(TOUR_SEEN_KEY) !== "1";
  } catch {
    return false;
  }
}

export function markTourSeen(storage) {
  try {
    storage?.setItem(TOUR_SEEN_KEY, "1");
  } catch {
    // Without storage the tour may come again; nothing else depends on it.
  }
}

/**
 * Where the tour's note goes beside the lit place: right of it, else below, else left, always
 * inside the window. Without a place it is centered.
 */
export function tourBubblePosition(hole, viewport, bubble = { width: 320, height: 170 }, margin = 16) {
  if (!hole) {
    return { x: Math.max(margin, (viewport.width - bubble.width) / 2), y: Math.max(margin, (viewport.height - bubble.height) / 2) };
  }
  let x;
  let y;
  if (hole.right + margin + bubble.width <= viewport.width) {
    x = hole.right + margin;
    y = hole.top;
  } else if (hole.bottom + margin + bubble.height <= viewport.height) {
    x = hole.left;
    y = hole.bottom + margin;
  } else {
    x = hole.left - margin - bubble.width;
    y = hole.top;
  }
  x = Math.min(Math.max(x, margin), Math.max(margin, viewport.width - bubble.width - margin));
  y = Math.min(Math.max(y, margin), Math.max(margin, viewport.height - bubble.height - margin));
  return { x, y };
}

export function initial(name) {
  const first = String(name ?? "").trim()[0];
  return first ? first.toUpperCase() : "?";
}

/** "1:02:03" or "2:03" for a player's time labels. */
export function clock(seconds) {
  const total = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const rest = String(total % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}` : `${minutes}:${rest}`;
}

/** "1 h 42 min", "42 min" or "" for a runtime. */
export function runtime(minutes) {
  if (!minutes || minutes < 1) return "";
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours === 0) return `${rest} min`;
  return rest === 0 ? `${hours} h` : `${hours} h ${rest} min`;
}

/** Watch time as people say it, like the Mac app: "45 min", "2 h 5 min", "3 days 4 h". */
export function watchTime(seconds) {
  const total = Number.isFinite(seconds) ? Math.max(0, Math.round(seconds)) : 0;
  if (total === 0) return "0 min";
  if (total < 30) return "Under 1 min";
  const minutes = Math.floor((total + 30) / 60);
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  const restMinutes = minutes % 60;
  if (hours < 24) return restMinutes === 0 ? `${hours} h` : `${hours} h ${restMinutes} min`;
  const days = Math.floor(hours / 24);
  const restHours = hours % 24;
  const dayText = days === 1 ? "1 day" : `${days} days`;
  return restHours === 0 ? dayText : `${dayText} ${restHours} h`;
}

/** watchTime for the hours the statistics report. */
/** ISO 8601 week of a date, as the server writes it: "2026-W45". */
export function isoWeek(date) {
  const day = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
  const weekday = day.getUTCDay() || 7;
  day.setUTCDate(day.getUTCDate() + 4 - weekday);
  const yearStart = new Date(Date.UTC(day.getUTCFullYear(), 0, 1));
  const week = Math.ceil(((day - yearStart) / 86400000 + 1) / 7);
  return `${day.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
}

/** The last weeks up to this one, oldest first; weeks without watching have no hours (the server lists only weeks with watching). */
export function lastWeeks(periods, now = new Date(), count = 12) {
  const hours = new Map();
  for (const period of periods ?? []) hours.set(period.period, (hours.get(period.period) ?? 0) + period.hours);
  const weeks = [];
  for (let back = count - 1; back >= 0; back--) {
    const day = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 7 * back);
    const period = isoWeek(day);
    weeks.push({ period, hours: hours.get(period) ?? 0 });
  }
  return weeks;
}

export function watchHours(hours) {
  return watchTime(Number.isFinite(hours) ? hours * 3600 : 0);
}

/** The Monday that starts an ISO week such as "2026-W43", in local time. */
export function weekStart(period) {
  const match = /^(\d{4})-W(\d{2})$/.exec(period ?? "");
  if (!match) return null;
  const year = Number(match[1]);
  const week = Number(match[2]);
  const january4 = new Date(year, 0, 4);
  const weekday = (january4.getDay() + 6) % 7;
  return new Date(year, 0, 4 - weekday + (week - 1) * 7);
}

/** Time left of a started title, such as "38 min left". */
export function remaining(progress) {
  if (!progress || progress.isCompleted || !progress.durationMilliseconds) return "";
  const minutes = Math.ceil((progress.durationMilliseconds - progress.positionMilliseconds) / 60000);
  if (minutes < 1) return "";
  const hours = Math.floor(minutes / 60);
  return hours > 0 ? `${hours} h ${minutes % 60} min left` : `${minutes} min left`;
}

/** How far a title is watched, 0 to 1; completed titles show no bar. */
export function progressFraction(progress) {
  if (!progress || progress.isCompleted || !progress.durationMilliseconds) return 0;
  return Math.min(1, Math.max(0, progress.positionMilliseconds / progress.durationMilliseconds));
}

/** The small capitals line above a title, as on the Mac: "MOVIE · 2019" or "S1 · E3". */
export function eyebrow(item) {
  if (!item) return "";
  if (item.kind === "episode") {
    const parts = [];
    if (item.seasonNumber != null) parts.push(`S${item.seasonNumber}`);
    if (item.episodeNumber != null) parts.push(`E${item.episodeNumber}`);
    return [item.parentTitle, parts.join(" · ")].filter(Boolean).join(" · ");
  }
  const kind = { movie: "Movie", series: "TV Show", extra: "Extra", trailer: "Trailer" }[item.kind] ?? "";
  return [kind, item.year].filter(Boolean).join(" · ");
}

/** Episode cards say which episode they are. */
export function episodeLabel(item) {
  if (item?.kind !== "episode") return item?.title ?? "";
  const number = item.episodeNumber != null ? `${item.episodeNumber}. ` : "";
  return `${number}${item.title}`;
}

/** An artwork address in one of the widths the server prepares (320, 640, 1280, 1920). */
export function artworkUrl(artwork, width) {
  if (!artwork?.path || !artwork.path.startsWith("/api/v1/artwork/")) return "";
  // Naming the revision lets the browser keep the picture; a replaced picture has a new one.
  const revision = Number.isSafeInteger(artwork.revision) && artwork.revision > 0 ? `rev=${artwork.revision}` : "";
  const join = (query) => query ? `${artwork.path}${artwork.path.includes("?") ? "&" : "?"}${query}` : artwork.path;
  if (!width) return join(revision);
  const sizes = [320, 640, 1280, 1920];
  const chosen = sizes.find((size) => size >= width) ?? 1920;
  return join([`width=${chosen}`, revision].filter(Boolean).join("&"));
}

export function scrubPreviewBucketSeconds(seconds, durationSeconds = 0, intervalSeconds = 15) {
  const baseInterval = Math.min(120, Math.max(5, Math.floor(Number(intervalSeconds) || 15)));
  const duration = Math.max(0, Math.floor(Number(durationSeconds) || 0));
  const spread = duration > 0 ? Math.ceil(duration / 720) : baseInterval;
  const effectiveInterval = Math.max(baseInterval, Math.ceil(spread / 5) * 5);
  const clamped = duration > 0 ? Math.min(Math.max(0, Math.floor(Number(seconds) || 0)), Math.max(0, duration - 1)) : Math.max(0, Math.floor(Number(seconds) || 0));
  return Math.floor(clamped / effectiveInterval) * effectiveInterval;
}

export function scrubPreviewFrameUrl(mediaId, seconds, durationSeconds = 0, intervalSeconds = 15) {
  if (!mediaId) return "";
  const bucket = scrubPreviewBucketSeconds(seconds, durationSeconds, intervalSeconds);
  return `/api/v1/media/${encodeURIComponent(mediaId)}/scrub-previews/${bucket}`;
}

export function scrubPreviewUsageText(settings) {
  if (!settings) return "0 titles · 0 MB of 500 MB";
  const count = Number(settings.storedTitleCount) || 0;
  const storedBytes = Math.max(0, Number(settings.storedBytes) || 0);
  const cap = Number(settings.storageCapMegabytes) || 500;
  const mb = storedBytes / (1024 * 1024);
  const usedLabel = storedBytes === 0 ? "0 MB" : mb < 1 ? "< 1 MB" : `${Math.round(mb)} MB`;
  const capLabel = cap >= 1000 && cap % 1000 === 0 ? `${cap / 1000} GB` : `${cap} MB`;
  return `${count} ${count === 1 ? "title" : "titles"} · ${usedLabel} of ${capLabel}`;
}

const BROWSE_SECTIONS = ["library", "recent", "movies", "shows"];
export const SETTINGS_PAGES = ["general", "playback", "library", "metadata", "profiles", "server", "updates", "advanced", "account"];

/** Library filters from an address's query, without the defaults. */
function parseFilters(query) {
  const filters = {};
  if (query.get("q")?.trim()) filters.query = query.get("q").trim().slice(0, 256);
  const kind = query.get("kind");
  if (kind === "movie" || kind === "series") filters.kind = kind;
  if (query.get("favorites") === "1") filters.favorites = true;
  const watch = query.get("watch");
  if (["unplayed", "inProgress", "completed"].includes(watch)) filters.watch = watch;
  if (query.get("genre")) filters.genre = query.get("genre");
  const from = Number.parseInt(query.get("from") ?? "", 10);
  const to = Number.parseInt(query.get("to") ?? "", 10);
  if (from > 0) filters.yearFrom = from;
  if (to > 0) filters.yearTo = to;
  const sort = query.get("sort");
  if (["title", "dateAdded", "releaseYear", "lastPlayed"].includes(sort)) {
    filters.sort = sort;
    if (query.get("order") === "descending") filters.descending = true;
  }
  return filters;
}

function filterQuery(filters = {}) {
  const query = new URLSearchParams();
  if (filters.query?.trim()) query.set("q", filters.query.trim().slice(0, 256));
  if (filters.kind) query.set("kind", filters.kind);
  if (filters.favorites) query.set("favorites", "1");
  if (filters.watch) query.set("watch", filters.watch);
  if (filters.genre) query.set("genre", filters.genre);
  if (filters.yearFrom) query.set("from", String(filters.yearFrom));
  if (filters.yearTo) query.set("to", String(filters.yearTo));
  if (filters.sort) {
    query.set("sort", filters.sort);
    if (filters.descending) query.set("order", "descending");
  }
  return query.toString();
}

/** The screen an address shows. Unknown addresses go Home. */
export function parseRoute(pathname = "/", search = "") {
  const query = new URLSearchParams(search);
  let parts;
  try {
    parts = String(pathname).split("/").filter(Boolean).map(decodeURIComponent);
  } catch {
    // A cut-off or mistyped link ("/title/%E0%A4%A") opens Home instead of a blank page.
    return { name: "home" };
  }
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (parts.length === 0) return { name: "home" };
  if (parts.length === 1 && BROWSE_SECTIONS.includes(parts[0])) return { name: parts[0], filters: parseFilters(query) };
  if (parts.length === 1 && parts[0] === "watchlist") return { name: "watchlist" };
  if (parts.length === 1 && parts[0] === "person") {
    const personName = query.get("name")?.trim() ?? "";
    const rawKey = query.get("key")?.trim() ?? "";
    const personKey = rawKey && !rawKey.startsWith("unidentified:") ? rawKey : "";
    if (personName || personKey) {
      return { name: "person", ...(personName ? { personName } : {}), ...(personKey ? { personKey } : {}) };
    }
  }
  if (parts.length === 1 && parts[0] === "collections") return { name: "collections" };
  if (parts.length === 1 && parts[0] === "history") return { name: "history" };
  if (parts.length === 1 && parts[0] === "statistics") return { name: "statistics" };
  if (parts.length === 1 && parts[0] === "movie-night") return { name: "movie-night" };
  if (parts.length === 1 && parts[0] === "search") return { name: "search", query: query.get("q") ?? "" };
  if (parts[0] === "settings" && parts.length <= 2) {
    let page = parts[1] ?? "general";
    if (page === "account") page = "profiles";
    return SETTINGS_PAGES.includes(page) ? { name: "settings", page } : { name: "settings", page: "general" };
  }
  if (parts.length === 2 && parts[0] === "title" && uuid.test(parts[1])) return { name: "title", id: parts[1].toLowerCase() };
  if (parts.length === 2 && parts[0] === "collection" && uuid.test(parts[1])) {
    const offset = Number(query.get("offset"));
    return { name: "collection", id: parts[1].toLowerCase(), ...(Number.isSafeInteger(offset) && offset > 0 && offset <= 2147483647 ? { offset } : {}) };
  }
  return { name: "home" };
}

export function routePath(route) {
  switch (route?.name) {
    case "library":
    case "recent":
    case "movies":
    case "shows": {
      const query = filterQuery(route.filters);
      return query ? `/${route.name}?${query}` : `/${route.name}`;
    }
    case "search":
      return route.query ? `/search?q=${encodeURIComponent(route.query)}` : "/search";
    case "settings":
      return route.page && route.page !== "general" ? `/settings/${route.page}` : "/settings";
    case "title":
      return `/title/${route.id}`;
    case "watchlist":
      return "/watchlist";
    case "movie-night":
      return "/movie-night";
    case "person": {
      const query = new URLSearchParams();
      if (route.personName) query.set("name", route.personName);
      if (route.personKey && !String(route.personKey).startsWith("unidentified:")) query.set("key", route.personKey);
      const search = query.toString();
      return search ? `/person?${search}` : "/";
    }
    case "collections":
      return "/collections";
    case "history":
      return "/history";
    case "statistics":
      return "/statistics";
    case "collection":
      return `/collection/${route.id}${route.offset ? `?offset=${route.offset}` : ""}`;
    default:
      return "/";
  }
}

/** "1234 5678": the code is easier to read and type in two halves. */
/** The digits of a typed pairing code, at most eight; spaces and other characters drop out. */
export function pairingDigits(value) {
  return String(value ?? "").replace(/[^0-9]/g, "").slice(0, 8);
}

export function formatCode(code) {
  const digits = String(code ?? "");
  return digits.length === 8 ? `${digits.slice(0, 4)} ${digits.slice(4)}` : digits;
}

/** "4:59" until a pairing code expires, or "" once it has. */
export function countdown(expiresAt, now = Date.now()) {
  const seconds = Math.ceil((new Date(expiresAt).getTime() - now) / 1000);
  if (!Number.isFinite(seconds) || seconds <= 0) return "";
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/** Where playback starts: the saved position, unless the title was finished or barely begun. */
export function resumeSeconds(progress) {
  if (!progress || progress.isCompleted) return 0;
  const seconds = progress.positionMilliseconds / 1000;
  const duration = progress.durationMilliseconds / 1000;
  if (seconds < 5 || (duration > 0 && duration - seconds < 15)) return 0;
  return seconds;
}

/**
 * Saves the position of the open title with the protocol's guarded updates: every save names
 * the revision it builds on and a fresh mutation id; a failed save is repeated unchanged. When
 * the revision is outdated (409), the later position wins: this player's while someone watches
 * here (it is sent again on the server's revision, read with `read`), otherwise the position
 * another device saved afterwards stays and this player stops saving until the title is opened
 * again; no message repeats.
 */
export class ProgressSaver {
  constructor({ mediaId, revision = 0, send, read = null, newId = () => crypto.randomUUID(), now = () => Date.now() }) {
    this.mediaId = mediaId;
    this.revision = revision;
    this.send = send;
    this.read = read;
    this.newId = newId;
    this.now = now;
    this.rebases = 0;
    this.stopped = false;
    this.pending = null;
    this.inFlight = null;
    this.next = null;
  }

  /** Queues the latest position; only the newest waiting position is sent after the current one. */
  save(positionMilliseconds, durationMilliseconds, isFinished = false, options = {}) {
    if (this.stopped || !(durationMilliseconds > 0)) return Promise.resolve(false);
    const values = {
      positionMilliseconds: Math.max(0, Math.round(positionMilliseconds)),
      durationMilliseconds: Math.round(durationMilliseconds),
      isFinished: Boolean(isFinished),
    };
    const recordedAt = this.now();
    if (this.inFlight && options.keepalive) {
      // The page is closing: a queued save would never be sent, so the last position goes out
      // now on its own keepalive request instead of waiting for the running one.
      this.next = null;
      const body = { ...values, clientMutationId: this.newId(), enforceRevision: true, expectedRevision: this.revision };
      return Promise.resolve(this.send(this.mediaId, body, options)).then(() => true, () => false);
    }
    if (this.inFlight) {
      this.next = { values, options, recordedAt };
      return this.inFlight;
    }
    return this.#run(values, options, recordedAt);
  }

  async #run(values, options, recordedAt) {
    // A save that failed is repeated first, with exactly the same mutation and values: the
    // server may have stored it even though the answer was lost. The newer position follows.
    if (this.pending && !sameValues(this.pending.values, values)) {
      this.next = { values, options, recordedAt };
      values = this.pending.values;
      recordedAt = this.pending.recordedAt;
    }
    if (!this.pending) this.pending = { id: this.newId(), values, revision: this.revision, recordedAt };
    const body = {
      ...this.pending.values,
      clientMutationId: this.pending.id,
      enforceRevision: true,
      expectedRevision: this.pending.revision,
    };
    let saved = false;
    let rebased = false;
    this.inFlight = (async () => {
      try {
        const response = await this.send(this.mediaId, body, options);
        if (response && Number.isFinite(response.revision)) this.revision = response.revision;
        this.pending = null;
        this.rebases = 0;
        saved = true;
      } catch (error) {
        if (error?.status === 409) {
          const current = this.read && this.rebases < 3
            ? await this.read(this.mediaId).catch(() => null) : null;
          if (current && Number.isFinite(current.revision)
            && keepsLocalProgress(this.pending.recordedAt, current.updatedAt)) {
            this.rebases += 1;
            this.revision = current.revision;
            rebased = true;
          } else {
            this.stopped = true;
          }
          this.pending = null;
        }
      }
    })();
    await this.inFlight;
    this.inFlight = null;
    if (rebased) return this.#run(values, options, recordedAt);
    // After a failure the waiting position stays queued for the next save, so an offline
    // player does not retry in a tight loop.
    if (saved && this.next && !this.stopped) {
      const queued = this.next;
      this.next = null;
      return this.#run(queued.values, queued.options, queued.recordedAt);
    }
    return saved;
  }
}

/** The later position wins; a few seconds of allowance cover clocks that differ slightly. */
export function keepsLocalProgress(recordedAt, serverUpdatedAt) {
  if (!Number.isFinite(recordedAt)) return false;
  const server = serverUpdatedAt ? Date.parse(serverUpdatedAt) : NaN;
  return !Number.isFinite(server) || recordedAt + 5000 >= server;
}

function sameValues(left, right) {
  return left.positionMilliseconds === right.positionMilliseconds
    && left.durationMilliseconds === right.durationMilliseconds
    && left.isFinished === right.isFinished;
}

/** Normal episodes only, in explicit season/episode order; special features stay separate. */
function orderedEpisodes(seasons) {
  return (seasons ?? []).filter((season) => (season.number ?? season.seasonNumber ?? 1) > 0)
    .slice().sort((a, b) => (a.number ?? a.seasonNumber) - (b.number ?? b.seasonNumber))
    .flatMap((season) => (season.episodes ?? []).slice().sort((a, b) =>
      (a.episodeNumber ?? a.item?.episodeNumber ?? 0) - (b.episodeNumber ?? b.item?.episodeNumber ?? 0)))
    .map((entry) => entry.item).filter(Boolean);
}

export function adjacentEpisode(seasons, currentId, direction) {
  const episodes = orderedEpisodes(seasons);
  const index = episodes.findIndex((item) => item.id === currentId);
  if (index < 0) return null;
  const candidates = direction === "previous" ? episodes.slice(0, index).reverse() : episodes.slice(index + 1);
  return candidates.find((item) => item.availability === "available") ?? null;
}

/** The episode after `current`, including the next season and skipping offline files. */
export function nextEpisode(seasons, currentId) { return adjacentEpisode(seasons, currentId, "next"); }
export function previousEpisode(seasons, currentId) { return adjacentEpisode(seasons, currentId, "previous"); }

/** Resume is the only user action allowed to use persisted progress. */
/**
 * Where playback starts: the saved position for "resume" (unless automatic resume is off or
 * the saved position is within the first restartWithinSeconds), otherwise the beginning.
 */
export function playbackStartSeconds(intent, progress, automaticResume = true, restartWithinSeconds = 0) {
  if (intent !== "resume" || !automaticResume) return 0;
  const seconds = resumeSeconds(progress);
  return seconds < restartWithinSeconds ? 0 : seconds;
}

const LANGUAGE_ALIASES = {
  en: ["en", "eng"], de: ["de", "deu", "ger"], fr: ["fr", "fra", "fre"], es: ["es", "spa"],
  it: ["it", "ita"], ja: ["ja", "jpn"], nl: ["nl", "nld", "dut"], pt: ["pt", "por"],
};

/** Whether a track's language ("ger", "de", "de-DE") is the preferred one ("de"). */
export function languageMatches(code, preferred) {
  if (!code || !preferred) return false;
  const base = String(code).toLowerCase().split(/[-_]/)[0];
  return (LANGUAGE_ALIASES[preferred] ?? [preferred]).includes(base);
}

/** The first track in the preferred language, preferring full subtitles over forced ones. */
export function trackForLanguage(tracks, preferred) {
  const matching = (tracks ?? []).filter((track) => languageMatches(track?.language, preferred));
  return matching.find((track) => !track.isForced) ?? matching[0] ?? null;
}

// MARK: Player, as in the Mac app

export const PLAYBACK_RATES = [0.5, 0.75, 1, 1.25, 1.5, 2];
export const SLEEP_MINUTES = [15, 30, 45, 60, 90];
/** "Up Next" appears in the last 20 seconds of an episode-length title, as on the Mac. */
export const UP_NEXT_LEAD = 20;

/** "1x", "1.5x", "0.75x". */
export function rateLabel(rate) {
  return `${Number(rate)}x`;
}

/** "Ends at 2:15" in the viewer's own time format, or "" without a known length. */
export function endsAt(position, duration, rate = 1, now = new Date(), locale = undefined) {
  if (!(duration > 0) || !(rate > 0)) return "";
  const end = new Date(now.getTime() + (Math.max(0, duration - position) / rate) * 1000);
  return `Ends at ${end.toLocaleTimeString(locale, { hour: "numeric", minute: "2-digit" })}`;
}

/** Whether the "Up Next" card shows: an episode-length title in its last seconds with a next one. */
export function showsUpNext({ position, duration, hasNext, autoplay, stopsAtEnd, dismissed, lead = UP_NEXT_LEAD }) {
  if (!hasNext || !autoplay || stopsAtEnd || dismissed || !(duration >= 300) || !(position > 0)) return false;
  return duration - position <= lead;
}

export function upNextSeconds(position, duration) {
  return Math.max(0, Math.ceil(duration - position));
}

/** The small line above the title in the player: "Mr. Robot · Season 1 · Episode 1". */
export function playerSubtitle(item) {
  if (item?.kind === "episode") {
    const parts = [item.parentTitle];
    if (item.seasonNumber != null) parts.push(item.seasonNumber === 0 ? "Specials" : `Season ${item.seasonNumber}`);
    if (item.episodeNumber != null) parts.push(`Episode ${item.episodeNumber}`);
    return parts.filter(Boolean).join(" · ");
  }
  if (item?.kind === "extra" || item?.kind === "trailer") return item.parentTitle ?? "NOW PLAYING";
  return "NOW PLAYING";
}

export const PLAYBACK_DEFAULTS = Object.freeze({
  automaticResume: true,
  defaultPlaybackRate: 1,
  defaultVolume: 1,
  controlsAutoHideDelay: 2,
  seekInterval: 10,
  automaticallyPlayNextEpisode: true,
  keepScreenOn: true,
  nightMode: false,
  dialogueBoost: "off",
  volumeLeveling: "off",
  cinemaMode: false,
  cinemaAds: true,
  cinemaTrailers: 2,
  upNextCountdownSeconds: UP_NEXT_LEAD,
  resumeThresholdSeconds: 0,
  defaultAudioLanguage: "original",
  defaultSubtitleLanguage: "off",
  subtitleSize: "medium",
  subtitleBackground: "transparent",
});

/** Playback preferences of this browser, kept within the same limits as on the Mac. */
export function normalizePreferences(value) {
  const merged = { ...PLAYBACK_DEFAULTS, ...(value && typeof value === "object" ? value : {}) };
  const number = (input, low, high, fallback) => (Number.isFinite(Number(input)) ? Math.min(high, Math.max(low, Number(input))) : fallback);
  return {
    automaticResume: merged.automaticResume !== false,
    defaultPlaybackRate: PLAYBACK_RATES.includes(Number(merged.defaultPlaybackRate)) ? Number(merged.defaultPlaybackRate) : 1,
    defaultVolume: number(merged.defaultVolume, 0, 1, 1),
    controlsAutoHideDelay: number(merged.controlsAutoHideDelay, 1, 10, 2),
    seekInterval: Math.round(number(merged.seekInterval, 5, 60, 10)),
    automaticallyPlayNextEpisode: merged.automaticallyPlayNextEpisode !== false,
    keepScreenOn: merged.keepScreenOn !== false,
    nightMode: merged.nightMode === true,
    dialogueBoost: ["off", "standard", "strong"].includes(merged.dialogueBoost) ? merged.dialogueBoost : "off",
    // An explicit choice wins; before it existed, Night Mode on meant Standard leveling.
    volumeLeveling: ["off", "standard", "sleep"].includes(value?.volumeLeveling) ? value.volumeLeveling : merged.nightMode === true ? "standard" : "off",
    cinemaMode: merged.cinemaMode === true,
    cinemaAds: merged.cinemaAds !== false,
    cinemaTrailers: Math.round(number(merged.cinemaTrailers, 0, 3, 2)),
    upNextCountdownSeconds: Math.round(number(merged.upNextCountdownSeconds, 5, 30, UP_NEXT_LEAD)),
    resumeThresholdSeconds: Math.round(number(merged.resumeThresholdSeconds, 0, 120, 0)),
    defaultAudioLanguage: typeof merged.defaultAudioLanguage === "string" && /^(original|[a-z]{2})$/.test(merged.defaultAudioLanguage) ? merged.defaultAudioLanguage : "original",
    defaultSubtitleLanguage: typeof merged.defaultSubtitleLanguage === "string" && /^(off|[a-z]{2})$/.test(merged.defaultSubtitleLanguage) ? merged.defaultSubtitleLanguage : "off",
    subtitleSize: ["small", "medium", "large"].includes(merged.subtitleSize) ? merged.subtitleSize : "medium",
    subtitleBackground: ["transparent", "semiTransparent", "solid"].includes(merged.subtitleBackground) ? merged.subtitleBackground : "transparent",
  };
}

export const GENERAL_DEFAULTS = Object.freeze({
  defaultStartScreen: "continueWatching",
  posterSize: "standard",
  showWatchedInRows: true,
  reduceHeroMotion: false,
  showMoviesInSidebar: true,
  showSeriesInSidebar: true,
  showWatchlistInSidebar: true,
  showCollectionsInSidebar: true,
  hideOfflineTitles: false,
  sectionOrder: null,
});

/** The top bar's sections after Home, in the Mac sidebar's default order. */
export const TOP_BAR_SECTIONS = Object.freeze([["library", "Library"], ["watchlist", "Watchlist"], ["recent", "Recently Added"], ["shows", "TV Shows"], ["movies", "Movies"], ["collections", "Collections"]]);

/** A saved order with every known section once: unknown names drop out, missing ones go last. */
export function sectionOrder(saved) {
  const known = TOP_BAR_SECTIONS.map(([name]) => name);
  const chosen = Array.isArray(saved) ? [...new Set(saved.filter((name) => known.includes(name)))] : [];
  return [...chosen, ...known.filter((name) => !chosen.includes(name))];
}

/** The order after moving `name` one place earlier (-1) or later (+1). */
export function moveSection(order, name, offset) {
  const list = sectionOrder(order);
  const index = list.indexOf(name);
  const target = index + offset;
  if (index < 0 || target < 0 || target >= list.length) return list;
  [list[index], list[target]] = [list[target], list[index]];
  return list;
}

export function normalizeGeneralPreferences(value) {
  const merged = { ...GENERAL_DEFAULTS, ...(value && typeof value === "object" ? value : {}) };
  return {
    defaultStartScreen: ["movies", "shows", "continueWatching", "watchlist"].includes(merged.defaultStartScreen) ? merged.defaultStartScreen : "continueWatching",
    posterSize: ["compact", "standard", "large"].includes(merged.posterSize) ? merged.posterSize : "standard",
    showWatchedInRows: merged.showWatchedInRows !== false,
    reduceHeroMotion: merged.reduceHeroMotion === true,
    showMoviesInSidebar: merged.showMoviesInSidebar !== false,
    showSeriesInSidebar: merged.showSeriesInSidebar !== false,
    showWatchlistInSidebar: merged.showWatchlistInSidebar !== false,
    showCollectionsInSidebar: merged.showCollectionsInSidebar !== false,
    hideOfflineTitles: merged.hideOfflineTitles === true,
    sectionOrder: sectionOrder(merged.sectionOrder),
  };
}

/** "1:02:03" of a scene note or chapter, from milliseconds. */
export function noteTime(milliseconds) {
  return clock((milliseconds ?? 0) / 1000);
}

// MARK: Details, as in the Mac app

/** The three leading actors for "Starring …", in billing order and without repeats. */
export function starring(credits, limit = 3) {
  const seen = new Set();
  return (credits ?? [])
    .map((credit, index) => ({ credit, index }))
    .filter(({ credit }) => String(credit.department).toLowerCase() === "acting")
    .sort((left, right) => (left.credit.order - right.credit.order) || (left.index - right.index))
    .map(({ credit }) => String(credit.name ?? "").trim())
    .filter((name) => name && !seen.has(name) && seen.add(name))
    .slice(0, limit);
}

/**
 * One card per person for "Cast & Crew": an actor shows their characters, anyone else their jobs,
 * with the first photo found, in billing order.
 */
export function people(credits) {
  const groups = new Map();
  (credits ?? []).forEach((credit, index) => {
    const key = credit.personKey || `unidentified:${credit.id ?? index}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push({ index, credit });
  });
  const cards = [];
  for (const [key, group] of groups) {
    const ordered = [...group].sort((left, right) => (left.credit.order - right.credit.order) || (left.index - right.index));
    const actors = ordered.filter(({ credit }) => String(credit.department).toLowerCase() === "acting");
    const primary = actors[0] ?? ordered[0];
    const descriptions = actors.length ? actors.map(({ credit }) => credit.character) : ordered.map(({ credit }) => credit.job ?? credit.department);
    const labels = [...new Set(descriptions.map((value) => String(value ?? "").trim()).filter(Boolean))];
    cards.push({
      index: primary.index,
      id: key,
      name: primary.credit.name,
      subtitle: labels.join(", ") || null,
      profile: primary.credit.profile ?? ordered.find(({ credit }) => credit.profile)?.credit.profile ?? null,
      order: primary.credit.order,
    });
  }
  return cards.sort((left, right) => (left.order - right.order) || (left.index - right.index)).map(({ index, ...card }) => card);
}

export function personHref(person) {
  const query = new URLSearchParams();
  if (person?.name?.trim()) query.set("name", person.name.trim());
  if (person?.id && !String(person.id).startsWith("unidentified:")) query.set("key", String(person.id));
  const search = query.toString();
  return search ? `/person?${search}` : "/";
}

/** The "Information" fields of a title, in the Mac app's order. */
export function informationFields(detail) {
  const metadata = detail?.metadata ?? {};
  const country = (metadata.countries ?? []).find((value) => String(value).trim());
  const studio = (metadata.studios ?? []).length ? metadata.studios.join(", ") : null;
  const genres = (metadata.genres ?? []).join(", ");
  const year = metadata.year ?? detail?.item?.year ?? null;
  const fsk = metadata.fskAge != null ? `FSK ${metadata.fskAge}` : null;
  if (detail?.item?.kind === "series") {
    const seasons = detail.seasons ?? [];
    return [
      ["Seasons", String(seasons.length)],
      ["Episodes", String(seasons.reduce((sum, season) => sum + (season.episodes?.length ?? 0), 0))],
      ["Studio", studio],
      ["Released", year != null ? String(year) : null],
      ["Country of Origin", country],
      ["Genres", genres],
      ["FSK", fsk],
    ].map(([title, value]) => ({ title, value: value || null }));
  }
  const fields = [
    ["Release Year", year != null ? String(year) : null],
    ["Genres", genres],
    ["Studio", studio],
    ["Country of Origin", country],
    ["FSK", fsk],
  ];
  if (detail?.item?.kind === "movie") fields.unshift(["Runtime", metadata.runtimeMinutes ? `${metadata.runtimeMinutes} min` : null]);
  return fields.map(([title, value]) => ({ title, value: value || null }));
}

/** Trailers first, then everything else as Extras. */
export function supplementGroups(supplements) {
  const list = supplements ?? [];
  const isTrailer = (entry) => entry.item?.kind === "trailer" || /trailer/i.test(entry.category ?? "");
  const trailers = list.filter(isTrailer);
  const extras = list.filter((entry) => !isTrailer(entry));
  return [trailers.length ? { title: "Trailers", items: trailers } : null, extras.length ? { title: "Extras", items: extras } : null].filter(Boolean);
}

export function seasonTitle(number) {
  return number === 0 ? "Specials" : `Season ${number}`;
}

/** "Resume S02 E10", "Play Again" or "Play", as on the Mac. */
export function detailPlayLabel(item, plan) {
  if (!plan) return progressFraction(item?.progress) > 0 ? "Resume" : "Play";
  const action = plan.action === "resume" ? "Resume" : plan.action === "playAgain" ? "Play Again" : "Play";
  const target = plan.target;
  if (item?.kind !== "series" || target?.seasonNumber == null || target?.episodeNumber == null) return action;
  return `${action} S${String(target.seasonNumber).padStart(2, "0")} E${String(target.episodeNumber).padStart(2, "0")}`;
}

/** "MOVIE · 2019 · 132 MIN" or "TV SHOW · 2008" above a title. */
export function detailMetadataLine(item, metadata) {
  const values = [item?.kind === "movie" ? "MOVIE" : item?.kind === "series" ? "TV SHOW" : eyebrow(item).toUpperCase()];
  const year = metadata?.year ?? item?.year;
  if (year) values.push(String(year));
  if (item?.kind === "movie" && metadata?.runtimeMinutes) values.push(`${metadata.runtimeMinutes} MIN`);
  return values.filter(Boolean).join("  ·  ");
}

// MARK: Library browsing, as in the Mac app

export const BROWSE_SORTS = [
  ["title", "Title"],
  ["dateAdded", "Recently Added"],
  ["releaseYear", "Release Year"],
  ["lastPlayed", "Last Watched"],
];
export const WATCH_FILTERS = [
  ["unplayed", "Unwatched"],
  ["inProgress", "In Progress"],
  ["completed", "Watched"],
];

/** The section's fixed kind and defaults, and the query for the server. */
export function browseQuery(section, filters = {}) {
  const kind = section === "movies" ? "movie" : section === "shows" ? "series" : filters.kind ?? null;
  const sort = filters.sort ?? (section === "recent" ? "dateAdded" : null);
  const descending = filters.sort ? Boolean(filters.descending) : section === "recent";
  const query = {};
  if (filters.query?.trim()) query.query = filters.query.trim().slice(0, 256);
  if (kind) query.kind = kind;
  if (filters.favorites) query.favorite = "true";
  if (filters.watch) query.watchState = filters.watch;
  if (filters.genre) query.genre = filters.genre;
  if (filters.yearFrom) query.yearFrom = String(filters.yearFrom);
  if (filters.yearTo) query.yearTo = String(Math.max(filters.yearTo, filters.yearFrom ?? 0));
  if (sort) {
    query.sort = sort;
    query.direction = descending ? "descending" : "ascending";
  }
  return query;
}

/** The genres and years of the loaded titles, for the filter menus. */
export function browseFacets(items) {
  const genres = new Set();
  const years = new Set();
  for (const item of items ?? []) {
    for (const genre of item.genres ?? []) if (genre) genres.add(genre);
    if (item.year) years.add(item.year);
  }
  return { genres: [...genres].sort((a, b) => a.localeCompare(b)), years: [...years].sort((a, b) => b - a) };
}

/** The shortcuts supported by the browser player and navigation. */
export const KEYBOARD_SHORTCUTS = [
  {
    group: "Playback",
    items: [
      { keys: ["Space", "K"], action: "Play or Pause" },
      { keys: ["←", "J"], action: "Seek Back" },
      { keys: ["→", "L"], action: "Seek Forward" },
      { keys: ["N"], action: "Next Episode" },
      { keys: ["P"], action: "Previous Episode" },
      { keys: ["M"], action: "Mute or Unmute" },
      { keys: ["F"], action: "Toggle Full Screen" },
      { keys: ["Escape"], action: "Close Menu or Player" },
    ],
  },
  {
    group: "Navigation & Dialogs",
    items: [
      { keys: ["?"], action: "Keyboard Shortcuts" },
      { keys: ["Escape"], action: "Close Dialog or Menu" },
    ],
  },
];

/** Screen reader value text for the timeline, like "1:23 of 45:00". */
export function timelineValueText(currentSeconds, durationSeconds) {
  const cur = Number.isFinite(currentSeconds) ? Math.max(0, currentSeconds) : 0;
  const dur = Number.isFinite(durationSeconds) ? Math.max(0, durationSeconds) : 0;
  if (!dur) return clock(cur);
  return `${clock(cur)} of ${clock(dur)}`;
}

/** Screen reader value text for the volume slider, like "80%" or "Muted". */
export function volumeValueText(volume, muted) {
  if (muted || volume <= 0) return "Muted";
  const percent = Math.round(Math.min(1, Math.max(0, volume)) * 100);
  return `${percent}%`;
}

/** Bounded memory of scroll positions by route path. */
export class ScrollMemory {
  constructor(limit = 64) {
    this.limit = limit;
    this.positions = new Map();
  }

  remember(path, scrollY) {
    if (!path || typeof path !== "string" || !Number.isFinite(scrollY) || scrollY < 0) return;
    if (this.positions.has(path)) this.positions.delete(path);
    this.positions.set(path, Math.floor(scrollY));
    if (this.positions.size > this.limit) {
      const first = this.positions.keys().next().value;
      this.positions.delete(first);
    }
  }

  recall(path) {
    if (!path || typeof path !== "string") return 0;
    return this.positions.get(path) ?? 0;
  }

  clear() {
    this.positions.clear();
  }
}

/** Notice displayed on title detail pages when the media file is offline. */
export const OFFLINE_FILE_NOTICE = "This file is offline; its details and progress are kept.";

/** Whether a title or its playback target is currently missing or unavailable. */
export function isTitleOffline(item, target) {
  if (target && target.availability !== "available") return true;
  if (item && item.kind !== "series" && item.availability !== "available") return true;
  return false;
}

/**
 * A smart list's rules for the editor. They travel in the protocol's names (`kind: "movie"`,
 * `watchedState`, `textContains`, `combination: "or"`); lists that earlier versions saved as
 * `watchState`, `matchAny`, or the Mac app's `watched`, `search`, `match` and `"movies"` still open.
 */
export function readSmartRules(json) {
  let rules = {};
  try { rules = json ? JSON.parse(json) ?? {} : {}; } catch { rules = {}; }
  const kind = rules.kind === "movies" ? "movie" : ["movie", "series"].includes(rules.kind) ? rules.kind : "";
  const state = String(rules.watchedState ?? rules.watchState ?? rules.watched ?? "").toLowerCase();
  const watchedState = state === "unwatched" || state === "unplayed" ? "unwatched"
    : state === "inprogress" || state === "in_progress" ? "inProgress"
      : state === "watched" || state === "completed" ? "watched" : "";
  const combination = String(rules.combination ?? rules.match ?? "").toLowerCase();
  return {
    kind,
    genres: Array.isArray(rules.genres) ? rules.genres.filter((genre) => typeof genre === "string") : [],
    yearMin: Number.isFinite(rules.yearMin) ? rules.yearMin : null,
    yearMax: Number.isFinite(rules.yearMax) ? rules.yearMax : null,
    watchedState,
    addedWithinDays: Number.isFinite(rules.addedWithinDays) ? rules.addedWithinDays : null,
    favoritesOnly: rules.favoritesOnly === true,
    textContains: rules.textContains ?? rules.search ?? "",
    matchAny: rules.matchAny === true || combination === "or" || combination === "any",
  };
}

/** The editor's choices as the rules the server stores. */
export function smartRulesJson(form) {
  const rules = {
    kind: form.kind || null,
    genres: form.genres?.length ? form.genres : null,
    yearMin: form.yearMin ?? null,
    yearMax: form.yearMax ?? null,
    watchedState: form.watchedState || null,
    addedWithinDays: form.addedWithinDays ?? null,
    favoritesOnly: form.favoritesOnly ? true : null,
    textContains: form.textContains || null,
    combination: form.matchAny ? "or" : "and",
  };
  return JSON.stringify(Object.fromEntries(Object.entries(rules).filter(([, value]) => value !== null)));
}

/** Offline answers in a row after which the change feed reports the server as off. */
export const SYNC_OFFLINE_LIMIT = 3;

/**
 * What the change feed does after a failed request: end the session when it was refused,
 * report the server as off after a few offline answers in a row, else wait and try again.
 */
export function syncFailure(error, failures, offlineInRow) {
  if (error?.status === 401 || error?.status === 403) return { action: "sessionEnded" };
  const delay = Math.min(30_000, 2_000 * 2 ** Math.min(failures, 4));
  return { action: error?.offline && offlineInRow >= SYNC_OFFLINE_LIMIT ? "offline" : "wait", delay };
}

/**
 * Whether the server refused the browser's profile or device: 401, or 403 with a session,
 * profile or device code (such as profile_session_revoked). Every screen and the player use it.
 */
export function sessionRefused(status, code) {
  return status === 401 || (status === 403 && /session|profile|device/.test(String(code ?? "")));
}

/**
 * The owner's lines about video conversion: the encoder ("Nvidia NVENC · decodes on the chip"),
 * the running conversions and each one's quality and speed.
 */
export function transcodingSummary(status) {
  if (!status) return { encoder: "Not available", running: "None", sessions: [] };
  const encoder = !status.available
    ? "Not available"
    : [
      status.encoderName + (status.device ? ` (${status.device.replace(/^\/dev\/dri\//, "")})` : ""),
      status.hardwareDecoding ? "decodes on the chip" : null,
      status.hardwareResting ? "the processor stands in after a chip error" : null,
    ].filter(Boolean).join(" · ");
  const sessions = (status.sessions ?? []).map((session) => ({
    title: session.title,
    detail: [session.quality, session.converting ? (session.speed ? `${session.speed.toFixed(1)}× real time` : "starting") : "ready"].join(" · "),
  }));
  const converting = (status.sessions ?? []).filter((session) => session.converting).length;
  return {
    encoder,
    running: converting === 0 ? "None" : `${converting} of ${status.videoLimit} at once`,
    sessions,
  };
}

// MARK: Remembered pages

/**
 * Remembers what the server answered for a few pages, so Back and a second visit show at once.
 * A remembered answer is returned right away and, once it is older than `freshMs`, asked again in
 * the background; `onChanged` runs when the new answer differs. `clear()` forgets everything, and
 * an answer still on its way when that happens is not kept. Every read gets its own copy.
 */
export function createReadCache({ max = 24, freshMs = 4000, now = () => Date.now() } = {}) {
  const entries = new Map();
  let generation = 0;
  const keep = (key, text) => {
    entries.delete(key);
    entries.set(key, { text, at: now(), refreshing: false });
    while (entries.size > max) entries.delete(entries.keys().next().value);
  };
  return {
    get size() { return entries.size; },
    has: (key) => entries.has(key),
    clear() {
      generation += 1;
      entries.clear();
    },
    async read(key, load, onChanged) {
      const entry = entries.get(key);
      if (entry) {
        entries.delete(key);
        entries.set(key, entry);
        if (now() - entry.at >= freshMs && !entry.refreshing) {
          entry.refreshing = true;
          const started = generation;
          Promise.resolve().then(load).then((value) => {
            if (started !== generation) return;
            const text = JSON.stringify(value ?? null);
            const changed = text !== entry.text;
            keep(key, text);
            if (changed) onChanged?.();
          }, () => { entry.refreshing = false; });
        }
        return JSON.parse(entry.text);
      }
      const started = generation;
      const value = await load();
      if (started === generation) keep(key, JSON.stringify(value ?? null));
      return value;
    },
  };
}

/**
 * Starts at most `limit` warm-up loads at a time and each key only once until `forget`; a load
 * that is not wanted any more is simply not started. Returns whether this call started one.
 */
export function createPrefetcher({ limit = 2 } = {}) {
  const started = new Set();
  let running = 0;
  return {
    get running() { return running; },
    forget: () => started.clear(),
    start(key, load) {
      if (started.has(key) || running >= limit) return false;
      started.add(key);
      running += 1;
      Promise.resolve().then(load).catch(() => started.delete(key)).finally(() => { running -= 1; });
      return true;
    },
  };
}

// MARK: Administration

/** "4:59 left" until a pairing code expires, or null once it has. */
export function codeCountdown(expiresAt, now = Date.now()) {
  const left = Math.floor((new Date(expiresAt).getTime() - now) / 1000);
  if (!(left > 0)) return null;
  return `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")} left`;
}

/** The folders on the way to `path`, for the server folder picker: "/", "/mnt", "/mnt/media". */
export function folderCrumbs(path) {
  if (!path) return [];
  const windows = /^[a-z]:[\\/]/i.test(path);
  const separator = windows ? "\\" : "/";
  const parts = path.split(/[\\/]+/).filter(Boolean);
  const crumbs = [];
  let built = "";
  for (const [index, part] of parts.entries()) {
    built = windows ? (index === 0 ? `${part}${separator}` : `${built}${built.endsWith(separator) ? "" : separator}${part}`) : `${built}/${part}`;
    crumbs.push({ name: part, path: built });
  }
  return windows ? crumbs : [{ name: "/", path: "/" }, ...crumbs];
}

export const SUBTITLE_LANGUAGE_CHOICES = Object.freeze(["en", "de", "fr", "es", "it", "nl", "pt", "pl", "sv", "da", "no", "fi", "tr", "ru", "ja", "ko", "zh", "ar"]);

/** "en, DE ,fr,en" → ["en", "de", "fr"]: two-letter codes, once each, at most ten. */
export function subtitleLanguages(text) {
  const codes = String(text ?? "").toLowerCase().split(/[\s,;]+/).filter((code) => /^[a-z]{2}$/.test(code));
  return [...new Set(codes)].slice(0, 10);
}

// MARK: Sound

export const DIALOGUE_BOOST_CHOICES = Object.freeze([["off", "Off"], ["standard", "Standard"], ["strong", "Strong"]]);
export const VOLUME_LEVELING_CHOICES = Object.freeze([["off", "Off"], ["standard", "Standard"], ["sleep", "Sleep"]]);
const BOOST_FREQUENCIES = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000];
const BOOST_GAINS = { standard: [-3, -2, -1, 0, 2, 3, 1, 0, -1, -2], strong: [-6, -4, -2, 0, 3, 5, 2, 0, -2, -3] };

/**
 * The same Dialogue Boost and Volume Leveling presets as the other apps (docs/AUDIO_PROCESSING.md),
 * as numbers for the browser's Web Audio nodes: equalizer bands with a preamp, then a compressor
 * with makeup gain. Web Audio's compressor has no RMS detection, so both levels use its peak.
 */
export function audioProfile(preferences = {}) {
  const boost = BOOST_GAINS[preferences.dialogueBoost] ?? null;
  const leveling = { standard: { threshold: -24, knee: 6, ratio: 4, attack: 0.015, release: 0.3, makeupDb: 12 },
    sleep: { threshold: -30, knee: 6, ratio: 12, attack: 0.0015, release: 0.65, makeupDb: 16 } }[preferences.volumeLeveling] ?? null;
  return {
    equalizer: boost ? BOOST_FREQUENCIES.map((frequency, index) => ({ frequency, gain: boost[index] })) : null,
    preampDb: boost ? (preferences.dialogueBoost === "strong" ? -5 : -3) : 0,
    compressor: leveling,
    active: Boolean(boost || leveling),
  };
}

export const decibels = (value) => 10 ** (value / 20);
