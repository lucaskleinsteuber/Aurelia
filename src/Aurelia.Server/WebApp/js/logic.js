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

/** The screen an address shows. Unknown addresses go Home. */
export function parseRoute(pathname = "/", search = "") {
  const query = new URLSearchParams(search);
  const parts = String(pathname).split("/").filter(Boolean).map(decodeURIComponent);
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (parts.length === 0) return { name: "home" };
  if (parts.length === 1 && parts[0] === "movies") return { name: "movies", sort: query.get("sort") ?? "title" };
  if (parts.length === 1 && parts[0] === "shows") return { name: "shows", sort: query.get("sort") ?? "title" };
  if (parts.length === 1 && parts[0] === "search") return { name: "search", query: query.get("q") ?? "" };
  if (parts.length === 2 && parts[0] === "title" && uuid.test(parts[1])) return { name: "title", id: parts[1].toLowerCase() };
  if (parts.length === 2 && parts[0] === "collection" && uuid.test(parts[1])) return { name: "collection", id: parts[1].toLowerCase() };
  return { name: "home" };
}

export function routePath(route) {
  switch (route?.name) {
    case "movies":
    case "shows":
      return route.sort && route.sort !== "title" ? `/${route.name}?sort=${encodeURIComponent(route.sort)}` : `/${route.name}`;
    case "search":
      return route.query ? `/search?q=${encodeURIComponent(route.query)}` : "/search";
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
