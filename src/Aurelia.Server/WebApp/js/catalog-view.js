// Viewer library screens and actions. Each route owns its reads and dialogs; navigation closes
// them before another profile can use the page. Lists request one bounded page per action.
import { h, icon, clear } from "./dom.js";
import { browseQuery, browseFacets, BROWSE_SORTS, WATCH_FILTERS } from "./logic.js";

const TITLES = { library: "Library", recent: "Recently Added", movies: "Movies", shows: "TV Shows" };
const PAGE_SIZE = 100;

export function createCatalogView({ api, navigate, replaceRoute, posterCard, collectionCard, emptyState, openMenu, menuOption, handleError, toast, onChanged, play, canManage = () => false, editMetadata, isWatchlisted, toggleWatchlist }) {
  let lifetime = new AbortController();
  let dialog = null;
  let debounce;
  let actionWorking = false;
  const current = () => lifetime.signal;
  function close() {
    lifetime.abort();
    lifetime = new AbortController();
    clearTimeout(debounce);
    dialog?.close();
    actionWorking = false;
  }
  const report = (error, signal) => {
    if (signal.aborted || error?.name === "AbortError") return;
    if (!handleError(error)) toast(error.message);
  };

  function pagedList(read, parameters, signal, { collection = false, count = () => {} } = {}) {
    const grid = h("div", { class: "poster-grid" });
    const message = h("p", { class: "muted", role: "status", "aria-live": "polite" });
    const more = h("button", { class: "secondary-button", onclick: () => load() }, "Load More");
    const footer = h("div", { class: "catalog-footer" }, message, more);
    const element = h("div", {}, grid, footer);
    let offset = 0;
    let revision;
    let total = 0;
    let seen = new Set();
    let busy = false;
    let generation = 0;
    let request;
    let query = parameters;
    const reset = () => { offset = 0; revision = undefined; total = 0; seen = new Set(); clear(grid); };
    const abort = () => request?.abort();
    signal.addEventListener("abort", abort, { once: true });
    async function load(restart = false, nextParameters = query) {
      if (signal.aborted || (busy && !restart)) return;
      if (restart) { request?.abort(); query = nextParameters; reset(); }
      const mine = ++generation;
      request = new AbortController();
      const ownRequest = request;
      busy = true;
      more.disabled = true;
      more.hidden = false;
      message.textContent = "Loading…";
      try {
        // A changed catalog invalidates the old offset/revision. Restart once, without mixing
        // pages from different snapshots or retrying indefinitely during a busy scan.
        let page;
        for (let attempt = 0; attempt < 2; attempt++) {
          try {
            page = await read({ ...query, offset, limit: PAGE_SIZE, ...(revision ? { revision } : {}) }, { signal: ownRequest.signal });
            break;
          } catch (error) {
            if (error?.code !== "catalog_changed" || attempt !== 0 || signal.aborted || ownRequest.signal.aborted) throw error;
            reset();
          }
        }
        if (signal.aborted || ownRequest.signal.aborted || mine !== generation) return;
        const items = collection ? page : page?.items;
        if (!Array.isArray(items) || items.length > PAGE_SIZE || (!collection && (!Number.isSafeInteger(page.total) || page.total < 0)))
          throw new Error("The server returned an unreadable page. Try again.");
        if (!collection && revision && page.revision !== revision) throw new Error("The library changed. Reload this page before loading more.");
        revision = collection ? undefined : page.revision;
        const batchOffset = offset;
        for (const item of items) {
          if (!item?.id || seen.has(item.id)) continue;
          seen.add(item.id);
          grid.append(collection ? collectionCard(item, batchOffset) : posterCard(item, seen.size - 1));
        }
        offset += items.length;
        total = collection ? offset : page.total;
        const complete = items.length === 0 || (collection ? items.length < PAGE_SIZE : offset >= total);
        more.hidden = complete;
        message.textContent = collection ? `${seen.size} collections${complete ? "" : " loaded"}` : `${seen.size} of ${total} titles`;
        if (!seen.size) message.textContent = collection ? "No collections available." : "No title matches these filters.";
        more.textContent = "Load More";
        count(collection ? seen.size : total, items);
      } catch (error) {
        if (signal.aborted || ownRequest.signal.aborted || mine !== generation || error?.name === "AbortError") return;
        if (handleError(error)) return;
        message.textContent = error.message;
        more.textContent = "Try Again";
        more.hidden = false;
      } finally {
        if (mine === generation) { busy = false; more.disabled = false; }
      }
    }
    function invalidate() { request?.abort(); generation++; busy = false; more.disabled = true; }
    return { element, load, invalidate };
  }

  function filterDialog(filters, update, { genre = false } = {}) {
    dialog?.close();
    const signal = current();
    const from = h("input", { class: "text-field", type: "number", min: "1", max: "9999", value: filters.yearFrom ?? "", inputmode: "numeric" });
    const to = h("input", { class: "text-field", type: "number", min: "1", max: "9999", value: filters.yearTo ?? "", inputmode: "numeric" });
    const genreInput = h("input", { class: "text-field", maxlength: "128", value: filters.genre ?? "" });
    const field = (label, input) => h("label", { class: "editor-field" }, h("span", { class: "editor-field-title" }, label), input);
    const status = h("p", { class: "error-text", role: "alert" });
    const sheet = h("dialog", { class: "sheet" }, h("h2", {}, genre ? "Genre" : "Release Year"),
      h("form", { class: "editor-form", onsubmit: (event) => {
        event.preventDefault();
        if (signal.aborted) return;
        if (genre) { sheet.close(); update({ genre: genreInput.value.trim() || undefined }); return; }
        const year = (value) => {
          if (!value.trim()) return undefined;
          if (!/^\d{1,4}$/.test(value) || Number(value) < 1) throw new Error("Enter a year from 1 to 9999, or leave the field empty.");
          return Number(value);
        };
        try {
          const yearFrom = year(from.value);
          const end = year(to.value);
          const yearTo = end && yearFrom ? Math.max(yearFrom, end) : end;
          sheet.close(); update({ yearFrom, yearTo });
        } catch (error) { status.textContent = error.message; }
      } }, genre ? field("Genre", genreInput) : h("div", { class: "editor-grid" }, field("From", from), field("To", to)), status,
      h("div", { class: "button-row end" },
        h("button", { class: "text-button", type: "button", onclick: () => { sheet.close(); update(genre ? { genre: undefined } : { yearFrom: undefined, yearTo: undefined }); } }, genre ? "All Genres" : "Any Year"),
        h("button", { class: "secondary-button", type: "button", onclick: () => sheet.close() }, "Cancel"),
        h("button", { class: "primary-button", type: "submit" }, "Apply"))));
    dialog = sheet;
    sheet.addEventListener("close", () => { sheet.remove(); if (dialog === sheet) dialog = null; });
    document.body.append(sheet);
    sheet.showModal();
    (genre ? genreInput : from).focus();
  }

  async function browse(route) {
    const signal = current();
    let filters = { ...route.filters };
    let facets = { genres: [] };
    const section = route.name;
    const update = (change) => { if (!signal.aborted) navigate({ name: section, filters: { ...filters, ...change } }, { replace: true }); };
    const chip = (label, selected, action, extra = {}) => h("button", { class: `chip ${selected ? "selected" : ""}`, "aria-pressed": String(Boolean(selected)), onclick: action, ...extra }, label);
    const menuChip = (label, selected, build) => {
      const button = chip([label, icon("chevronDown", { size: 13 })], selected, (event) => { event.stopPropagation(); openMenu(button, build()); }, { "aria-haspopup": "menu" });
      return button;
    };
    const hasFilters = Boolean(filters.query || (section === "library" && filters.kind) || filters.favorites || filters.watch || filters.genre || filters.yearFrom || filters.yearTo);
    const yearLabel = filters.yearFrom && filters.yearTo ? filters.yearFrom === filters.yearTo ? String(filters.yearFrom) : `${filters.yearFrom}–${filters.yearTo}`
      : filters.yearFrom ? `From ${filters.yearFrom}` : filters.yearTo ? `Through ${filters.yearTo}` : "Release Year";
    const count = h("span", { class: "count" });
    const parameters = () => browseQuery(section, filters);
    const list = pagedList((query, options) => (query.query ? api.search(query, options) : api.catalogPage(query, options)), parameters(), signal, { count: (total, items) => {
      count.textContent = String(total);
      const loaded = browseFacets(items);
      facets.genres = [...new Set([...facets.genres, ...loaded.genres])].slice(0, 256).sort((a, b) => a.localeCompare(b));
    } });
    const search = h("input", { class: "search-field", type: "search", value: filters.query ?? "", placeholder: `Search ${TITLES[section]}`, "aria-label": `Search ${TITLES[section]}`, maxlength: "256", autocomplete: "off", enterkeyhint: "search" });
    search.addEventListener("input", () => {
      if (signal.aborted) return;
      clearTimeout(debounce);
      list.invalidate();
      filters = { ...filters, query: search.value.trim() || undefined };
      replaceRoute({ name: section, filters });
      debounce = setTimeout(() => list.load(true, parameters()), 250);
    });
    const bar = h("div", { class: "filter-bar" }, section === "library" ? [
      chip("All", !filters.kind, () => update({ kind: undefined })),
      chip("Movies", filters.kind === "movie", () => update({ kind: filters.kind === "movie" ? undefined : "movie" })),
      chip("TV Shows", filters.kind === "series", () => update({ kind: filters.kind === "series" ? undefined : "series" })), h("span", { class: "filter-divider" }),
    ] : null,
    chip([icon("starFill", { size: 13 }), "Favorites"], filters.favorites, () => update({ favorites: !filters.favorites })),
    WATCH_FILTERS.map(([value, label]) => chip(label, filters.watch === value, () => update({ watch: filters.watch === value ? undefined : value }))),
    h("span", { class: "filter-divider" }),
    menuChip(filters.genre ?? "Genre", filters.genre, () => [menuOption("All Genres", !filters.genre, () => update({ genre: undefined })),
      ...[...new Set([...(filters.genre ? [filters.genre] : []), ...facets.genres])].map((genre) => menuOption(genre, filters.genre === genre, () => update({ genre }))),
      h("div", { class: "menu-divider" }), h("button", { class: "menu-item", onclick: () => filterDialog(filters, update, { genre: true }) }, "Choose Genre…")]),
    chip([yearLabel, icon("chevronDown", { size: 13 })], filters.yearFrom || filters.yearTo, () => filterDialog(filters, update)),
    hasFilters ? h("button", { class: "text-button", onclick: () => navigate({ name: section, filters: { sort: filters.sort, descending: filters.descending } }, { replace: true }) }, "Clear") : null,
    h("span", { class: "spacer" }),
    menuChip(filters.sort ? BROWSE_SORTS.find(([value]) => value === filters.sort)?.[1] ?? "Default" : section === "recent" ? "Recently Added" : "Default", false, () => [
      menuOption("Default", !filters.sort, () => update({ sort: undefined, descending: undefined })),
      ...BROWSE_SORTS.map(([value, label]) => menuOption(label, filters.sort === value, () => update({ sort: value }))), h("div", { class: "menu-divider" }),
      menuOption("Ascending", filters.sort && !filters.descending, () => update({ descending: undefined }), !filters.sort),
      menuOption("Descending", filters.sort && filters.descending, () => update({ descending: true }), !filters.sort)]));
    await list.load(true);
    return h("div", { class: "library page-enter" }, h("div", { class: "page-header" }, h("h1", {}, TITLES[section]), count,
      section === "library" ? h("a", { class: "text-button", href: "/collections", "data-route": true }, "Collections") : null),
    h("div", { class: "search-bar catalog-search" }, icon("search"), search), bar, list.element);
  }

  async function search(route) {
    const signal = current();
    const input = h("input", { class: "search-field", type: "search", value: route.query ?? "", placeholder: "Movies, shows and episodes", "aria-label": "Search", maxlength: "256", autocomplete: "off", enterkeyhint: "search" });
    const list = pagedList((query, options) => query.query ? api.search(query, options) : Promise.resolve({ items: [], total: 0 }), { query: route.query?.trim() ?? "" }, signal);
    input.addEventListener("input", () => {
      if (signal.aborted) return;
      clearTimeout(debounce);
      list.invalidate();
      replaceRoute({ name: "search", query: input.value });
      debounce = setTimeout(() => list.load(true, { query: input.value.trim() }), 250);
    });
    await list.load(true);
    return h("div", { class: "search" }, h("div", { class: "page-header" }, h("h1", {}, "Search")), h("div", { class: "search-bar" }, icon("search"), input), list.element);
  }

  async function collections() {
    const list = pagedList(api.collections, {}, current(), { collection: true });
    await list.load(true);
    return h("div", { class: "library" }, h("div", { class: "page-header" }, h("h1", {}, "Collections")), list.element);
  }

  async function collection(route) {
    const signal = current();
    const entries = await api.collections({ offset: route.offset ?? 0, limit: PAGE_SIZE }, { signal });
    if (signal.aborted) return null;
    const value = (entries ?? []).find((entry) => entry.id === route.id);
    const indexLink = h("a", { class: "secondary-button", href: "/collections", "data-route": true }, "All Collections");
    if (!value) return emptyState("search", "Collection Not Found", "It may have moved or been removed. Find it in All Collections.", indexLink);
    document.title = `${value.name} · Aurelia`;
    return h("div", { class: "library" }, h("div", { class: "page-header" }, h("h1", {}, value.name), h("span", { class: "count" }, String(value.items.length)), indexLink),
      h("div", { class: "poster-grid" }, value.items.map((item, index) => posterCard(item, index))));
  }

  function confirmWatch(state, watched, signal) {
    dialog?.close();
    return new Promise((resolve) => {
      let confirmed = false;
      const count = state.affectedCount;
      const sheet = h("dialog", { class: "sheet" }, h("h2", {}, `Mark ${count} ${count === 1 ? "episode" : "episodes"} as ${watched ? "watched" : "unwatched"}?`),
        h("p", {}, watched ? "This marks the selected episodes as watched." : "This resets playback positions for the selected episodes."),
        h("div", { class: "button-row end" }, h("button", { class: "secondary-button", onclick: () => sheet.close() }, "Cancel"),
          h("button", { class: "primary-button", onclick: () => { confirmed = true; sheet.close(); } }, watched ? "Mark as Watched" : "Mark as Unwatched")));
      dialog = sheet;
      sheet.addEventListener("close", () => { sheet.remove(); if (dialog === sheet) dialog = null; resolve(confirmed && !signal.aborted); }, { once: true });
      document.body.append(sheet);
      sheet.showModal();
    });
  }

  function watchMenu(item, scope = "title", seasonNumber, { includeContinueWatching = true } = {}) {
    const signal = current();
    const run = async (watched) => {
      if (actionWorking || signal.aborted) return;
      actionWorking = true;
      try {
        const state = await api.watchState(item.id, scope, seasonNumber, { signal });
        if (signal.aborted) return;
        const clientMutationId = crypto.randomUUID();
        if ((scope === "season" || scope === "series" || item.kind === "series") && !await confirmWatch(state, watched, signal)) return;
        if (signal.aborted) return;
        await api.setWatchState(item.id, { isWatched: watched, scope: state.scope, seasonNumber: state.seasonNumber, stateToken: state.stateToken, clientMutationId }, { signal });
        if (!signal.aborted) onChanged();
      } catch (error) { report(error, signal); }
      finally { if (!signal.aborted) actionWorking = false; }
    };
    const label = scope === "season" ? "Season" : "";
    const actions = [
      h("button", { class: "menu-item", onclick: () => run(true) }, icon("checkCircle", { size: 16 }), `Mark ${label ? `${label} ` : ""}as Watched`),
      h("button", { class: "menu-item", onclick: () => run(false) }, icon("circle", { size: 16 }), `Mark ${label ? `${label} ` : ""}as Unwatched`),
    ];
    if (includeContinueWatching && scope !== "season") actions.push(...continueWatchingMenu(item));
    return actions;
  }
  function continueWatchingMenu(item) {
    if (!["movie", "series", "episode"].includes(item.kind)) return [];
    const signal = current();
    const intendedHidden = !item.continueWatchingHidden;
    return [h("button", { class: "menu-item", onclick: async () => {
      if (actionWorking || signal.aborted) return;
      actionWorking = true;
      try {
        const snapshot = await api.watchState(item.id, "title", undefined, { signal });
        if (signal.aborted) return;
        await api.setContinueWatching(item.id, { isHidden: intendedHidden, stateToken: snapshot.stateToken, clientMutationId: crypto.randomUUID() }, { signal });
        if (!signal.aborted) onChanged();
      } catch (error) { report(error, signal); }
      finally { if (!signal.aborted) actionWorking = false; }
    } }, icon(intendedHidden ? "hide" : "eye", { size: 16 }), intendedHidden ? "Remove from Continue Watching" : "Show in Continue Watching")];
  }

  function mediaMenu(item, { seasons, onGoToSeries } = {}) {
    const signal = current();
    const option = (label, symbol, action, disabled = false) => h("button", {
      class: "menu-item", disabled, onclick: () => { if (!signal.aborted) action(); },
    }, icon(symbol, { size: 16 }), label);
    const available = item.kind === "series" || item.availability === "available";
    const actions = [option("Play", "play", () => play?.(item, seasons, { intent: "play" }), !available)];
    if (!item.progress?.isCompleted && item.watchState !== "completed" && (item.progress?.positionMilliseconds > 0 || item.watchState === "inProgress"))
      actions.push(option("Resume", "play", () => play?.(item, seasons, { intent: "resume" }), !available));
    if (item.kind === "episode" && item.parentId)
      actions.push(option("Go to Series", "tv", () => onGoToSeries ? onGoToSeries(item.parentId) : navigate({ name: "title", id: item.parentId })));
    if (["movie", "series", "episode"].includes(item.kind)) actions.push(h("div", { class: "menu-divider" }),
      ...watchMenu(item, item.kind === "series" ? "series" : "title", undefined, { includeContinueWatching: false }));
    // The server supports favorites for movies and series. Episode identity is never sent to that endpoint.
    if (["movie", "series"].includes(item.kind)) {
      actions.push(option(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", item.isFavorite ? "starSlash" : "star", async () => {
        if (actionWorking) return;
        actionWorking = true;
        try { await api.setFavorite(item.id, !item.isFavorite, { signal }); if (!signal.aborted) onChanged(); }
        catch (error) { report(error, signal); }
        finally { if (!signal.aborted) actionWorking = false; }
      }));
      if (typeof toggleWatchlist === "function") {
        const watchlisted = Boolean(isWatchlisted?.(item.id));
        actions.push(option(watchlisted ? "Remove from Watchlist" : "Add to Watchlist", watchlisted ? "bookmarkFill" : "bookmark", async () => {
          if (actionWorking) return;
          actionWorking = true;
          try { await toggleWatchlist(item.id, !watchlisted, { signal }); if (!signal.aborted) onChanged(); }
          catch (error) { report(error, signal); }
          finally { if (!signal.aborted) actionWorking = false; }
        }));
      }
    }
    actions.push(...continueWatchingMenu(item));
    if (canManage() && editMetadata) actions.push(h("div", { class: "menu-divider" }), option("Edit Metadata…", "pencil", () => {
      if (canManage()) editMetadata(item);
    }));
    return actions;
  }
  return { close, browse, search, collections, collection, watchMenu, mediaMenu };

}
