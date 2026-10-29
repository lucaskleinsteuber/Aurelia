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

const EDITOR_PROPERTIES = { title: "title", releaseYear: "releaseYear", overview: "overview", runtimeMinutes: "runtimeMinutes", fsk: "fskAge", genres: "genres", studios: "studios", country: "country" };

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
  if (!width) return artwork.path;
  const sizes = [320, 640, 1280, 1920];
  const chosen = sizes.find((size) => size >= width) ?? 1920;
  return `${artwork.path}${artwork.path.includes("?") ? "&" : "?"}width=${chosen}`;
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
  const parts = String(pathname).split("/").filter(Boolean).map(decodeURIComponent);
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
    case "person": {
      const query = new URLSearchParams();
      if (route.personName) query.set("name", route.personName);
      if (route.personKey && !String(route.personKey).startsWith("unidentified:")) query.set("key", route.personKey);
      const search = query.toString();
      return search ? `/person?${search}` : "/";
    }
    case "collections":
      return "/collections";
    case "collection":
      return `/collection/${route.id}${route.offset ? `?offset=${route.offset}` : ""}`;
    default:
      return "/";
  }
}

/** "1234 5678": the code is easier to read and type in two halves. */
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
 * another device saved a newer position meanwhile (409), that position stays and this player
 * stops saving until the title is opened again; no message repeats.
 */
export class ProgressSaver {
  constructor({ mediaId, revision = 0, send, newId = () => crypto.randomUUID() }) {
    this.mediaId = mediaId;
    this.revision = revision;
    this.send = send;
    this.newId = newId;
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
    if (this.inFlight) {
      this.next = { values, options };
      return this.inFlight;
    }
    return this.#run(values, options);
  }

  async #run(values, options) {
    // A save that failed is repeated first, with exactly the same mutation and values: the
    // server may have stored it even though the answer was lost. The newer position follows.
    if (this.pending && !sameValues(this.pending.values, values)) {
      this.next = { values, options };
      values = this.pending.values;
    }
    if (!this.pending) this.pending = { id: this.newId(), values, revision: this.revision };
    const body = {
      ...this.pending.values,
      clientMutationId: this.pending.id,
      enforceRevision: true,
      expectedRevision: this.pending.revision,
    };
    let saved = false;
    this.inFlight = (async () => {
      try {
        const response = await this.send(this.mediaId, body, options);
        if (response && Number.isFinite(response.revision)) this.revision = response.revision;
        this.pending = null;
        saved = true;
      } catch (error) {
        if (error?.status === 409) {
          this.stopped = true;
          this.pending = null;
        }
      }
    })();
    await this.inFlight;
    this.inFlight = null;
    // After a failure the waiting position stays queued for the next save, so an offline
    // player does not retry in a tight loop.
    if (saved && this.next && !this.stopped) {
      const queued = this.next;
      this.next = null;
      return this.#run(queued.values, queued.options);
    }
    return saved;
  }
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
export function playbackStartSeconds(intent, progress, automaticResume = true) {
  return intent === "resume" && automaticResume ? resumeSeconds(progress) : 0;
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
export function showsUpNext({ position, duration, hasNext, autoplay, stopsAtEnd, dismissed }) {
  if (!hasNext || !autoplay || stopsAtEnd || dismissed || !(duration >= 300) || !(position > 0)) return false;
  return duration - position <= UP_NEXT_LEAD;
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
  upNextCountdownSeconds: 15,
  resumeThresholdSeconds: 10,
  markWatchedThresholdPercent: 90,
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
    upNextCountdownSeconds: Math.round(number(merged.upNextCountdownSeconds, 5, 30, 15)),
    resumeThresholdSeconds: Math.round(number(merged.resumeThresholdSeconds, 0, 120, 10)),
    markWatchedThresholdPercent: Math.round(number(merged.markWatchedThresholdPercent, 50, 99, 90)),
    defaultAudioLanguage: typeof merged.defaultAudioLanguage === "string" ? merged.defaultAudioLanguage : "original",
    defaultSubtitleLanguage: typeof merged.defaultSubtitleLanguage === "string" ? merged.defaultSubtitleLanguage : "off",
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
  rescanInterval: "1h",
});

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
    rescanInterval: ["manual", "15m", "1h", "6h", "24h"].includes(merged.rescanInterval) ? merged.rescanInterval : "1h",
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



