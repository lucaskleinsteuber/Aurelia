// Pure helpers and bounded client state for Family Wishes (wishes-v1).

export const WISHES_CAPABILITY = "wishes-v1";

/** Maximum failed poster URLs remembered per session so memory stays bounded. */
export const MAX_POSTER_FAILURE_CACHE = 128;

export function supportsWishes(server) {
  return Boolean(server?.capabilities?.includes(WISHES_CAPABILITY));
}

export function isWishAdministrator(profile) {
  return profile?.role === "owner" || profile?.role === "admin";
}

/** Number shown on the Wishes badge: open requests for admins, plus own newly fulfilled wishes. */
export function wishBadgeCount(summary, profile) {
  if (!summary || typeof summary !== "object") return 0;
  const open = Number.isFinite(summary.openCount) ? Math.max(0, summary.openCount) : 0;
  const fulfilled = Number.isFinite(summary.newlyFulfilledCount) ? Math.max(0, summary.newlyFulfilledCount) : 0;
  return isWishAdministrator(profile) ? open + fulfilled : fulfilled;
}

/** Computes a local notification message when sync reports an increase in fulfilled or open wishes. */
export function formatWishNotification(prevSummary, nextSummary, profile) {
  if (!prevSummary || !nextSummary) return null;
  const prevFulfilled = prevSummary.newlyFulfilledCount ?? 0;
  const nextFulfilled = nextSummary.newlyFulfilledCount ?? 0;
  if (nextFulfilled > prevFulfilled) {
    const added = nextFulfilled - prevFulfilled;
    return {
      title: "Wish Fulfilled",
      body: added === 1 ? "One of your wished titles is now in the library." : `${added} of your wished titles are now in the library.`,
      route: "/wishes",
    };
  }
  if (isWishAdministrator(profile)) {
    const prevOpen = prevSummary.openCount ?? 0;
    const nextOpen = nextSummary.openCount ?? 0;
    if (nextOpen > prevOpen) {
      const added = nextOpen - prevOpen;
      return {
        title: "New Family Wish",
        body: added === 1 ? "Someone added a new wish to the list." : `${added} new wishes were added to the list.`,
        route: "/wishes",
      };
    }
  }
  return null;
}

/** Server-proxied poster URL; never calls TMDB directly from the browser. */
export function wishPosterUrl(posterPath, width = 342) {
  const path = String(posterPath ?? "").trim();
  if (!path) return null;
  return `/api/v1/wishes/poster?${new URLSearchParams({ path, width: String(width) })}`;
}

export function wishKindLabel(kind) {
  return kind === "series" ? "TV Series" : "Movie";
}

export function wishStateLabel(state) {
  switch (state) {
    case "fulfilled":
      return "In Library";
    case "declined":
      return "Declined";
    default:
      return "Waiting";
  }
}

export function parseYearInput(value) {
  const text = String(value ?? "").trim();
  if (!text) return { year: null };
  if (!/^\d{4}$/.test(text)) return { error: "Enter a four-digit year, or leave it blank." };
  const year = Number(text);
  if (year < 1888 || year > 2100) return { error: "Enter a year between 1888 and 2100." };
  return { year };
}

export function describeWishError(error) {
  if (!error) return { message: "Something went wrong. Try again." };
  if (error.offline) return { message: "The server isn’t answering." };
  if (error.code === "already_in_library") {
    return {
      message: error.message || "This title is already in your library.",
      alreadyInLibrary: error.mediaId ? { mediaId: error.mediaId, title: error.mediaTitle ?? "Open in Library", kind: error.mediaKind ?? "movie" } : null,
    };
  }
  if (error.code === "wish_age_restricted") {
    return { message: error.message || "This profile cannot wish for titles above its age limit." };
  }
  if (error.code === "provider_disabled") {
    return { providerDisabled: true, message: "TMDB search is off on the server. Add your wish manually below." };
  }
  return { message: error.message || "Couldn’t update wishes. Try again." };
}

/** Bounded FIFO/LRU key tracker for failed poster loads so DOM fallback stays memory-safe. */
export class BoundedFailureCache {
  constructor(maxEntries = MAX_POSTER_FAILURE_CACHE) {
    this.maxEntries = Math.max(1, maxEntries);
    this.entries = new Set();
  }

  has(key) {
    if (!this.entries.has(key)) return false;
    this.entries.delete(key);
    this.entries.add(key);
    return true;
  }

  add(key) {
    if (!key) return;
    if (this.entries.has(key)) this.entries.delete(key);
    this.entries.add(key);
    while (this.entries.size > this.maxEntries) {
      const oldest = this.entries.values().next().value;
      this.entries.delete(oldest);
    }
  }

  get size() {
    return this.entries.size;
  }

  clear() {
    this.entries.clear();
  }
}

export function formatWishDate(iso) {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}
