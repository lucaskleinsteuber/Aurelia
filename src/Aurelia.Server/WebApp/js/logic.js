// Rules of the browser app that need no page: they run the same in a browser and in
// `node --test tests/WebApp`.

/** A profile PIN is 4 to 8 digits, as on the server, the Mac and the Apple TV. */
export function isPin(text) {
  return /^[0-9]{4,8}$/.test(text);
}

export const PIN_INCORRECT = "The PIN is incorrect.";

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

const BROWSE_SECTIONS = ["library", "recent", "movies", "shows"];
const SETTINGS_PAGES = ["general", "playback", "account", "server"];

/** Library filters from an address's query, without the defaults. */
function parseFilters(query) {
  const filters = {};
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
  if (parts.length === 1 && parts[0] === "search") return { name: "search", query: query.get("q") ?? "" };
  if (parts[0] === "settings" && parts.length <= 2) {
    const page = parts[1] ?? "general";
    return SETTINGS_PAGES.includes(page) ? { name: "settings", page } : { name: "settings", page: "general" };
  }
  if (parts.length === 2 && parts[0] === "title" && uuid.test(parts[1])) return { name: "title", id: parts[1].toLowerCase() };
  if (parts.length === 2 && parts[0] === "collection" && uuid.test(parts[1])) return { name: "collection", id: parts[1].toLowerCase() };
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
    case "collection":
      return `/collection/${route.id}`;
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

/** The episode after `current` in a season list, or the first one of the next season. */
export function nextEpisode(seasons, currentId) {
  const episodes = (seasons ?? []).flatMap((season) => season.episodes ?? []).map((entry) => entry.item);
  const index = episodes.findIndex((item) => item.id === currentId);
  if (index < 0) return null;
  return episodes.slice(index + 1).find((item) => item.availability === "available") ?? null;
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
