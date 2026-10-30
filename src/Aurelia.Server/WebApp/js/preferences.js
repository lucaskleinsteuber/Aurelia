// This browser's General settings and how they show: poster size, start screen, sidebar,
// which titles appear in rows and grids, and the subtitle look. Playback settings live in
// player.js; both are kept in this browser only.

import { normalizeGeneralPreferences, isTitleOffline } from "./logic.js";
import { loadPreferences } from "./player.js";

const GENERAL_KEY = "aurelia.general";

export function loadGeneral() {
  try {
    return normalizeGeneralPreferences(JSON.parse(localStorage.getItem(GENERAL_KEY) ?? "null"));
  } catch {
    return normalizeGeneralPreferences(null);
  }
}

export function saveGeneral(value) {
  const normalized = normalizeGeneralPreferences(value);
  try {
    localStorage.setItem(GENERAL_KEY, JSON.stringify(normalized));
  } catch { /* Private browsing: the setting lasts for this page only. */ }
  applyAppearance(normalized);
  return normalized;
}

/** Poster size, hero motion and the subtitle look, as attributes the stylesheet reads. */
export function applyAppearance(general = loadGeneral(), playback = loadPreferences(), root = document.body) {
  if (!root) return;
  root.dataset.posterSize = general.posterSize;
  root.dataset.heroMotion = general.reduceHeroMotion ? "reduced" : "full";
  root.dataset.subtitleSize = playback.subtitleSize;
  root.dataset.subtitleBackground = playback.subtitleBackground;
}

/** The titles a row or grid shows: offline and watched ones only when the settings allow it. */
export function visibleTitles(items, general = loadGeneral(), { keepWatched = false } = {}) {
  return (items ?? []).filter((item) => !(general.hideOfflineTitles && isTitleOffline(item))
    && (keepWatched || general.showWatchedInRows || item?.watchState !== "completed"));
}

/** The page the app opens on, when it starts at Home. */
export function startPath(general = loadGeneral()) {
  return { watchlist: "/watchlist", movies: "/movies", shows: "/shows" }[general.defaultStartScreen] ?? "/";
}

/** The sidebar sections this browser shows. */
export function sidebarShows(id, general = loadGeneral()) {
  return {
    movies: general.showMoviesInSidebar,
    shows: general.showSeriesInSidebar,
    watchlist: general.showWatchlistInSidebar,
    collections: general.showCollectionsInSidebar,
  }[id] ?? true;
}
