// Viewer library screens and actions. Each route owns its reads and dialogs; navigation closes
// them before another profile can use the page. Lists request one bounded page per action.
import { h, icon, clear } from "./dom.js";
import { cropPicture, cropStyle } from "./metadata-extras.js";
import {
  browseQuery, browseFacets, BROWSE_SORTS, WATCH_FILTERS, readSmartRules, smartRulesJson, continueWatchingChoice,
  COLLECTION_SORT_MODES, collectionProviderLabel, collectionStatsLine, collectionPlayLabel, collectionPlayableItems,
  adjacentItem, artworkUrl, progressFraction, seasonTitle, eyebrow, runtime,
} from "./logic.js";

const TITLES = { library: "Library", recent: "Recently Added", movies: "Movies", shows: "TV Shows" };
const PAGE_SIZE = 100;
const COLLECTION_PICTURES = [
  { key: "poster", label: "Poster", aspect: 2 / 3 },
  { key: "backdrop", label: "Background", aspect: 16 / 9 },
];

export function createCatalogView({
  api, navigate, replaceRoute, posterCard, collectionCard, emptyState, openMenu, menuOption, handleError, toast,
  onChanged, play, canManage = () => false, editMetadata, isWatchlisted, toggleWatchlist, showsTitle = () => true,
  artwork = (art, width, className = "poster-art") => art?.path
    ? h("img", { class: className, src: artworkUrl(art, width), alt: "" })
    : h("div", { class: `${className} artwork-missing` }),
  progressBar = (progress) => {
    const f = progressFraction(progress);
    return f > 0 ? h("div", { class: "progress" }, h("div", { class: "progress-fill", style: { width: `${f * 100}%` } })) : null;
  },
}) {
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

  function pagedList(read, parameters, signal, { collection = false, count = () => {}, emptyText = () => "No title matches these filters." } = {}) {
    const grid = h("div", { class: "poster-grid" });
    const message = h("p", { class: "muted", role: "status", "aria-live": "polite" });
    const more = h("button", { class: "secondary-button", onclick: () => load() }, "Load More");
    const footer = h("div", { class: "catalog-footer" }, message, more);
    const element = h("div", {}, grid, footer);
    let offset = 0;
    let revision;
    let total = 0;
    let seen = new Set();
    let hidden = 0;
    let busy = false;
    let generation = 0;
    let request;
    let query = parameters;
    // A new search or filter keeps the old titles on screen until the new ones arrive, so the
    // grid never flashes empty in between.
    let stale = false;
    const reset = () => { offset = 0; revision = undefined; total = 0; seen = new Set(); hidden = 0; stale = true; };
    // Titles hidden by this browser's settings can fill whole pages; a few such pages load on
    // their own so the grid does not look empty while matching titles follow.
    const AUTO_PAGES = 5;
    const abort = () => request?.abort();
    signal.addEventListener("abort", abort, { once: true });
    async function load(restart = false, nextParameters = query, autoPages = 0) {
      if (signal.aborted || (busy && !restart)) return;
      let again = false;
      if (restart) { request?.abort(); query = nextParameters; reset(); }
      const mine = ++generation;
      request = new AbortController();
      const ownRequest = request;
      busy = true;
      more.disabled = true;
      more.hidden = true;
      // "Loading…" only when it takes a moment; a quick answer replaces the page without it.
      const slow = setTimeout(() => { if (mine === generation) message.textContent = "Loading…"; }, 350);
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
        if (stale) { clear(grid); stale = false; }
        const before = seen.size;
        for (const item of items) {
          if (!item?.id || seen.has(item.id)) continue;
          if (!collection && !showsTitle(item)) { hidden += 1; continue; }
          seen.add(item.id);
          grid.append(collection ? collectionCard(item, batchOffset) : posterCard(item, seen.size - 1));
        }
        offset += items.length;
        total = collection ? offset : page.total;
        const complete = items.length === 0 || (collection ? items.length < PAGE_SIZE : offset >= total);
        more.hidden = complete;
        message.textContent = collection ? `${seen.size} collections${complete ? "" : " loaded"}`
          : hidden ? `${seen.size} shown · ${hidden} hidden by this browser’s settings${complete ? "" : ` · ${offset} of ${total} checked`}`
            : `${seen.size} of ${total} titles`;
        if (!seen.size && complete) message.textContent = collection ? "No collections available."
          : hidden ? `No title to show: ${hidden} hidden by this browser’s settings.` : emptyText(query);
        again = !collection && !complete && seen.size === before && autoPages < AUTO_PAGES;
        more.textContent = "Load More";
        count(collection ? seen.size : total, items);
      } catch (error) {
        if (signal.aborted || ownRequest.signal.aborted || mine !== generation || error?.name === "AbortError") return;
        if (handleError(error)) return;
        if (stale) { clear(grid); stale = false; }
        message.textContent = error.message;
        more.textContent = "Try Again";
        more.hidden = false;
      } finally {
        clearTimeout(slow);
        if (mine === generation) { busy = false; more.disabled = false; }
      }
      if (again && mine === generation && !signal.aborted) await load(false, query, autoPages + 1);
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
    // Nothing typed yet shows nothing, not an empty result.
    const list = pagedList((query, options) => query.query ? api.search(query, options) : Promise.resolve({ items: [], total: 0 }), { query: route.query?.trim() ?? "" }, signal,
      { emptyText: (query) => query.query ? `No movies, shows or episodes match “${query.query}”.` : "" });
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

  function memberDisplayTitle(member) {
    if (member.title) return member.title;
    const base = member.item?.parentTitle && member.kind === "episode"
      ? `${member.item.parentTitle} · ${member.item.title}`
      : member.item?.title ?? "Untitled";
    return member.seasonNumber != null ? `${base} · ${seasonTitle(member.seasonNumber)}` : base;
  }

  function attachDragReorder(element, onMove) {
    element.draggable = true;
    element.addEventListener("dragstart", (event) => {
      event.dataTransfer?.setData("text/plain", element.dataset.dragIndex ?? "");
      if (event.dataTransfer) event.dataTransfer.effectAllowed = "move";
      element.classList.add("dragging");
    });
    element.addEventListener("dragend", () => element.classList.remove("dragging"));
    element.addEventListener("dragover", (event) => {
      event.preventDefault();
      if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
    });
    element.addEventListener("drop", (event) => {
      event.preventDefault();
      const from = Number(event.dataTransfer?.getData("text/plain"));
      const to = Number(element.dataset.dragIndex);
      if (Number.isInteger(from) && Number.isInteger(to) && from !== to) onMove(from, to);
    });
  }

  async function openCollectionEditor(target = {}) {
    dialog?.close();
    if (target.id && !target.members && !target.isSmart && typeof api.collection === "function") {
      target = await api.collection(target.id).catch(() => target);
    }
    const isEdit = Boolean(target.id);
    const existingRules = readSmartRules(target.rulesJson);
    const previewUrls = [];

    const nameInput = h("input", { class: "text-field", type: "text", value: target.name ?? "", placeholder: "Collection Name", required: true });
    const overviewInput = h("textarea", {
      class: "text-field", rows: 3, maxlength: 8192, placeholder: "Description (optional)",
    }, target.overview ?? "");
    let isSmart = Boolean(target.isSmart);
    const isShared = Boolean(target.isShared);

    const smartToggle = h("input", { type: "checkbox", checked: isSmart });
    const sharedToggle = h("input", { type: "checkbox", checked: isShared });
    const initialSort = target.sortMode || (isSmart ? "release" : "custom");
    const sortSelect = h("select", { class: "select-input" },
      COLLECTION_SORT_MODES.map(([value, label]) =>
        h("option", { value, selected: initialSort === value, disabled: isSmart && value === "custom" }, label)));

    const artworkChanges = { poster: null, backdrop: null };
    const artworkGrid = h("div", { class: "metadata-artwork-grid" });
    const collectionImageAddress = (key) => {
      const pending = artworkChanges[key];
      if (pending?.kind === "remove") return "";
      if (pending?.previewUrl) return pending.previewUrl;
      if (pending?.uploadId && target.id) {
        return `/api/v1/collections/${encodeURIComponent(target.id)}/editor/uploads/${encodeURIComponent(pending.uploadId)}`;
      }
      return target[key]?.path ? artworkUrl(target[key], key === "poster" ? 640 : 1280) : "";
    };
    const drawArtwork = () => {
      clear(artworkGrid);
      for (const spec of COLLECTION_PICTURES) {
        const address = collectionImageAddress(spec.key);
        const pending = artworkChanges[spec.key];
        const preview = h("div", { class: `artwork-crop-preview ${spec.key}`, role: "img", "aria-label": spec.label });
        if (address) {
          preview.style.setProperty("background-image", `url("${address}")`);
          for (const [prop, val] of Object.entries(cropStyle(pending?.crop ?? null))) preview.style.setProperty(prop, val);
        } else {
          preview.append(h("span", { class: "muted small" }, `Automatic ${spec.label.toLowerCase()}`));
        }
        const file = h("input", { type: "file", accept: "image/png,image/jpeg,image/webp,image/heic", class: "visually-hidden", "aria-label": `Choose ${spec.label}` });
        file.addEventListener("change", async () => {
          const chosen = file.files?.[0];
          file.value = "";
          if (!chosen) return;
          try {
            if (isEdit && typeof api.uploadCollectionEditorImage === "function") {
              const upload = await api.uploadCollectionEditorImage(target.id, chosen);
              const draftUrl = `/api/v1/collections/${encodeURIComponent(target.id)}/editor/uploads/${encodeURIComponent(upload.id)}`;
              const crop = await cropPicture(draftUrl, spec, null);
              if (!crop) {
                api.discardCollectionEditorImage?.(target.id, upload.id).catch(() => {});
                return;
              }
              if (artworkChanges[spec.key]?.uploadId) {
                api.discardCollectionEditorImage?.(target.id, artworkChanges[spec.key].uploadId).catch(() => {});
              }
              artworkChanges[spec.key] = { uploadId: upload.id, crop, previewUrl: draftUrl };
            } else {
              const previewUrl = URL.createObjectURL(chosen);
              previewUrls.push(previewUrl);
              const crop = await cropPicture(previewUrl, spec, null);
              if (!crop) return;
              artworkChanges[spec.key] = { file: chosen, crop, previewUrl };
            }
            drawArtwork();
          } catch (err) {
            toast(err.message);
          }
        });
        artworkGrid.append(h("div", { class: "artwork-choice" },
          h("h4", {}, spec.label),
          preview,
          h("div", { class: "button-row" },
            h("button", { type: "button", class: "secondary-button", onclick: () => file.click() }, "Choose Image…"),
            address ? h("button", { type: "button", class: "secondary-button", onclick: () => {
              if (artworkChanges[spec.key]?.uploadId && target.id) {
                api.discardCollectionEditorImage?.(target.id, artworkChanges[spec.key].uploadId).catch(() => {});
              }
              artworkChanges[spec.key] = { kind: "remove" };
              drawArtwork();
            } }, "Automatic") : null),
          file));
      }
    };
    drawArtwork();

    const initialMembers = Array.isArray(target.members)
      ? target.members.map((m) => ({
          mediaId: m.mediaId,
          seasonNumber: m.seasonNumber ?? null,
          title: memberDisplayTitle(m),
          kind: m.kind ?? m.item?.kind ?? "movie",
        }))
      : target.initialItem
        ? [{
            mediaId: target.initialItem.id,
            seasonNumber: target.initialSeasonNumber ?? null,
            title: target.initialSeasonNumber != null
              ? `${target.initialItem.title} · ${seasonTitle(target.initialSeasonNumber)}`
              : target.initialItem.parentTitle && target.initialItem.kind === "episode"
                ? `${target.initialItem.parentTitle} · ${target.initialItem.title}`
                : target.initialItem.title,
            kind: target.initialItem.kind ?? "movie",
          }]
        : [];
    const members = [...initialMembers];
    const memberListEl = h("div", { class: "box-editor-list" });
    const pickerInput = h("input", { class: "text-field", type: "search", placeholder: "Search movies, shows, seasons, episodes…" });
    const pickerResults = h("div", { class: "box-picker-results" });

    const moveMember = (from, to) => {
      if (to < 0 || to >= members.length || from === to) return;
      const [moved] = members.splice(from, 1);
      members.splice(to, 0, moved);
      sortSelect.value = "custom";
      renderMembers();
    };
    const addMemberEntry = (entry) => {
      if (members.some((m) => m.mediaId === entry.mediaId && (m.seasonNumber ?? null) === (entry.seasonNumber ?? null))) return;
      members.push({ ...entry, seasonNumber: entry.seasonNumber ?? null });
      renderMembers();
    };
    function renderMembers() {
      clear(memberListEl);
      if (!members.length) {
        memberListEl.append(h("p", { class: "muted small" }, "No titles added yet."));
        return;
      }
      members.forEach((m, index) => {
        const row = h("div", { class: "box-editor-member", dataset: { dragIndex: String(index) } },
          h("span", { class: "muted small", style: { minWidth: "24px" } }, String(index + 1)),
          h("span", { style: { flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" } }, m.title),
          h("button", { type: "button", class: "icon-button", "aria-label": "Move Up", disabled: index === 0, onclick: () => moveMember(index, index - 1) }, icon("arrowUp", { size: 15 })),
          h("button", { type: "button", class: "icon-button", "aria-label": "Move Down", disabled: index === members.length - 1, onclick: () => moveMember(index, index + 1) }, icon("arrowDown", { size: 15 })),
          h("button", { type: "button", class: "icon-button", "aria-label": `Remove ${m.title}`, onclick: () => { members.splice(index, 1); renderMembers(); } }, icon("close", { size: 15 })));
        attachDragReorder(row, moveMember);
        memberListEl.append(row);
      });
    }
    renderMembers();

    let searchTimer;
    const runPickerSearch = async () => {
      const term = pickerInput.value.trim();
      clear(pickerResults);
      if (!term || typeof api.catalogPage !== "function") return;
      try {
        const res = await api.catalogPage({ search: term, limit: 15 });
        if (pickerInput.value.trim() !== term) return;
        for (const item of res?.items ?? []) {
          if (!["movie", "series", "episode"].includes(item.kind)) continue;
          const wrap = h("div", { style: { display: "flex", flexDirection: "column", gap: "4px" } });
          const expandArea = h("div", { class: "box-picker-seasons", hidden: true });
          const row = h("div", { class: "box-editor-member" },
            h("span", { style: { flex: 1 } }, `${item.title}${item.year ? ` (${item.year})` : ""} · ${item.kind === "series" ? "Series" : item.kind === "episode" ? "Episode" : "Movie"}`),
            h("button", { type: "button", class: "secondary-button", onclick: () => addMemberEntry({
              mediaId: item.id, seasonNumber: null, title: item.title, kind: item.kind,
            }) }, "+ Add"),
            item.kind === "series" && typeof api.detail === "function" ? h("button", {
              type: "button", class: "secondary-button",
              onclick: async () => {
                if (!expandArea.hidden) { expandArea.hidden = true; return; }
                expandArea.hidden = false;
                if (expandArea.childElementCount) return;
                const d = await api.detail(item.id).catch(() => null);
                for (const season of d?.seasons ?? []) {
                  expandArea.append(h("button", {
                    type: "button", class: "secondary-button",
                    onclick: () => addMemberEntry({
                      mediaId: item.id, seasonNumber: season.number,
                      title: `${item.title} · ${seasonTitle(season.number)}`, kind: "series",
                    }),
                  }, `+ ${seasonTitle(season.number)}`));
                  for (const ep of season.episodes ?? []) {
                    expandArea.append(h("button", {
                      type: "button", class: "secondary-button",
                      onclick: () => addMemberEntry({
                        mediaId: ep.item.id, seasonNumber: null,
                        title: `${item.title} · S${String(season.number).padStart(2, "0")}E${String(ep.episodeNumber).padStart(2, "0")} ${ep.item.title}`,
                        kind: "episode",
                      }),
                    }, `+ S${String(season.number).padStart(2, "0")}E${String(ep.episodeNumber).padStart(2, "0")}`));
                  }
                }
              },
            }, "Seasons / Episodes…") : null);
          wrap.append(row, expandArea);
          pickerResults.append(wrap);
        }
      } catch {}
    };
    pickerInput.addEventListener("input", () => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(runPickerSearch, 200);
    });

    const membersSection = h("div", { class: "smart-rules-form", style: { display: isSmart ? "none" : "flex", flexDirection: "column", gap: "10px", marginTop: "12px" } },
      h("h3", {}, "Items in Collection"),
      memberListEl,
      h("label", { class: "form-row" }, h("span", {}, "Add Title:"), pickerInput),
      pickerResults);

    const kindSelect = h("select", { class: "select-input" },
      h("option", { value: "" }, "All"),
      h("option", { value: "movie", selected: existingRules.kind === "movie" }, "Movies"),
      h("option", { value: "series", selected: existingRules.kind === "series" }, "TV Shows"));
    const genreInput = h("input", { class: "text-field", type: "text", value: existingRules.genres.join(", "), placeholder: "Action, Comedy…" });
    const yearMinInput = h("input", { class: "text-field", type: "number", value: existingRules.yearMin != null ? String(existingRules.yearMin) : "", placeholder: "e.g. 1990" });
    const yearMaxInput = h("input", { class: "text-field", type: "number", value: existingRules.yearMax != null ? String(existingRules.yearMax) : "", placeholder: "e.g. 2025" });
    const watchStateSelect = h("select", { class: "select-input" },
      h("option", { value: "" }, "Any"),
      h("option", { value: "unwatched", selected: existingRules.watchedState === "unwatched" }, "Unwatched"),
      h("option", { value: "inProgress", selected: existingRules.watchedState === "inProgress" }, "In Progress"),
      h("option", { value: "watched", selected: existingRules.watchedState === "watched" }, "Watched"));
    const addedDaysInput = h("input", { class: "text-field", type: "number", value: existingRules.addedWithinDays != null ? String(existingRules.addedWithinDays) : "", placeholder: "e.g. 30" });
    const favoritesOnlyCheck = h("input", { type: "checkbox", checked: Boolean(existingRules.favoritesOnly) });
    const searchInput = h("input", { class: "text-field", type: "text", value: existingRules.textContains, placeholder: "Title contains…" });
    const matchAnyCheck = h("input", { type: "checkbox", checked: existingRules.matchAny });

    const rulesSection = h("div", { class: "smart-rules-form", style: { display: isSmart ? "flex" : "none", flexDirection: "column", gap: "10px", marginTop: "12px" } },
      h("h3", {}, "Smart List Rules"),
      h("label", { class: "form-row" }, h("span", {}, "Media Type:"), kindSelect),
      h("label", { class: "form-row" }, h("span", {}, "Genres:"), genreInput),
      h("div", { class: "form-row-pair", style: { display: "flex", gap: "10px" } },
        h("label", { style: { flex: 1 } }, h("span", {}, "From Year:"), yearMinInput),
        h("label", { style: { flex: 1 } }, h("span", {}, "To Year:"), yearMaxInput)),
      h("label", { class: "form-row" }, h("span", {}, "Watched State:"), watchStateSelect),
      h("label", { class: "form-row" }, h("span", {}, "Added Within (Days):"), addedDaysInput),
      h("label", { class: "checkbox-row", style: { display: "flex", alignItems: "center", gap: "8px" } }, favoritesOnlyCheck, h("span", {}, "Favorites Only")),
      h("label", { class: "form-row" }, h("span", {}, "Search Contains:"), searchInput),
      h("label", { class: "checkbox-row", style: { display: "flex", alignItems: "center", gap: "8px" } }, matchAnyCheck, h("span", {}, "Match Any Rule (OR instead of AND)")));

    smartToggle.addEventListener("change", () => {
      isSmart = smartToggle.checked;
      rulesSection.style.display = isSmart ? "flex" : "none";
      membersSection.style.display = isSmart ? "none" : "flex";
      const customOption = sortSelect.querySelector('option[value="custom"]');
      if (customOption) customOption.disabled = isSmart;
      if (isSmart && sortSelect.value === "custom") sortSelect.value = "release";
    });

    const form = h("form", { class: "editor-form" },
      h("h2", {}, isEdit ? "Edit Collection" : "New Collection"),
      h("label", { class: "form-row" }, h("span", {}, "Name:"), nameInput),
      h("label", { class: "form-row" }, h("span", {}, "Description:"), overviewInput),
      h("label", { class: "form-row" }, h("span", {}, "Sort Order:"), sortSelect),
      h("div", { style: { marginTop: "8px" } }, h("h3", {}, "Artwork"), artworkGrid),
      h("label", { class: "checkbox-row", style: { display: "flex", alignItems: "center", gap: "8px", marginTop: "8px" } }, smartToggle, h("span", {}, "Smart List (Rule-based)")),
      canManage() ? h("label", { class: "checkbox-row", style: { display: "flex", alignItems: "center", gap: "8px", marginTop: "8px" } }, sharedToggle, h("span", {}, "Shared Collection (Visible to all profiles)")) : null,
      membersSection,
      rulesSection,
      h("div", { class: "button-row end", style: { marginTop: "16px" } },
        h("button", { type: "button", class: "secondary-button", onclick: () => sheet.close() }, "Cancel"),
        h("button", { type: "submit", class: "primary-button" }, isEdit ? "Save Changes" : "Create Collection")));

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const name = nameInput.value.trim();
      if (!name) return;
      const overview = overviewInput.value.trim();
      const sortMode = sortSelect.value || (isSmart ? "release" : "custom");
      let rulesJson = null;
      if (isSmart) {
        const genres = genreInput.value.split(",").map((g) => g.trim()).filter(Boolean);
        rulesJson = smartRulesJson({
          kind: kindSelect.value,
          genres,
          yearMin: yearMinInput.value ? Number(yearMinInput.value) : null,
          yearMax: yearMaxInput.value ? Number(yearMaxInput.value) : null,
          watchedState: watchStateSelect.value,
          addedWithinDays: addedDaysInput.value ? Number(addedDaysInput.value) : null,
          favoritesOnly: favoritesOnlyCheck.checked,
          textContains: searchInput.value.trim(),
          matchAny: matchAnyCheck.checked,
        });
      }
      const payload = {
        name,
        isSmart,
        rulesJson,
        isShared: sharedToggle.checked,
        overview,
        sortMode,
        ...(isSmart ? {} : { members: members.map((m) => ({ mediaId: m.mediaId, seasonNumber: m.seasonNumber ?? null })) }),
      };

      try {
        const saved = isEdit
          ? await api.updateCollection(target.id, payload)
          : await api.createCollection(payload);
        for (const spec of COLLECTION_PICTURES) {
          const pending = artworkChanges[spec.key];
          if (!pending) continue;
          if (pending.kind === "remove" && isEdit) {
            await api.deleteCollectionArtwork?.(saved.id, spec.key).catch(() => {});
          } else if (pending.uploadId) {
            await api.saveCollectionArtwork?.(saved.id, spec.key, { uploadId: pending.uploadId, crop: pending.crop });
          } else if (pending.file && typeof api.uploadCollectionEditorImage === "function") {
            const uploaded = await api.uploadCollectionEditorImage(saved.id, pending.file);
            await api.saveCollectionArtwork?.(saved.id, spec.key, { uploadId: uploaded.id, crop: pending.crop });
          }
        }
        toast(isEdit ? `Updated “${name}”` : `Created collection “${name}”`);
        sheet.close();
        onChanged();
      } catch (err) {
        toast(err.message);
      }
    });

    const sheet = h("dialog", { class: "sheet collection-editor-sheet" }, form);
    dialog = sheet;
    sheet.addEventListener("close", () => {
      clearTimeout(searchTimer);
      for (const url of previewUrls) URL.revokeObjectURL(url);
      sheet.remove();
      if (dialog === sheet) dialog = null;
    }, { once: true });
    document.body.append(sheet);
    sheet.showModal();
    nameInput.focus();
  }

  async function openAddToCollectionDialog(item, seasonNumber = null) {
    dialog?.close();
    let collectionsList = [];
    try {
      collectionsList = (await api.collections({ limit: 100 })) ?? [];
    } catch (e) {
      toast("Couldn’t load collections.");
      return;
    }

    const editableCollections = collectionsList.filter((c) => !c.isSmart && c.canEdit !== false);
    const label = seasonNumber != null ? `${item.title} · ${seasonTitle(seasonNumber)}` : item.title;

    const sheet = h("dialog", { class: "sheet add-to-collection-dialog" },
      h("h2", {}, `Add “${label}” to Collection`),
      editableCollections.length ? h("div", { class: "collection-picker-list", style: { display: "flex", flexDirection: "column", gap: "8px", maxHeight: "240px", overflowY: "auto", margin: "16px 0" } },
        editableCollections.map((col) => h("button", {
          class: "menu-item",
          onclick: async () => {
            try {
              await api.addCollectionItem(col.id, item.id, seasonNumber);
              toast(`Added to “${col.name}”`);
              sheet.close();
              onChanged();
            } catch (err) {
              toast(err.message);
            }
          }
        }, col.name))) : h("p", { class: "muted", style: { margin: "16px 0" } }, "No editable collections yet."),
      h("div", { class: "button-row end" },
        h("button", { class: "secondary-button", onclick: () => sheet.close() }, "Cancel"),
        h("button", { class: "primary-button", onclick: () => { sheet.close(); openCollectionEditor({ initialItem: item, initialSeasonNumber: seasonNumber }); } }, "+ New Collection…")));

    dialog = sheet;
    sheet.addEventListener("close", () => { sheet.remove(); if (dialog === sheet) dialog = null; }, { once: true });
    document.body.append(sheet);
    sheet.showModal();
  }

  async function collections() {
    const headerActions = h("div", { class: "button-row" },
      h("button", {
        class: "primary-button",
        onclick: () => openCollectionEditor()
      }, "+ New Collection"));

    const list = pagedList(api.collections, {}, current(), { collection: true });
    await list.load(true);

    const franchisesContainer = h("div", { class: "franchises-section", style: { marginTop: "40px" } });
    if (typeof api.franchises === "function") {
      api.franchises().then((franchises) => {
        if (!franchises || !franchises.length) return;
        const cards = franchises.map((f) => collectionCard(f));
        franchisesContainer.append(
          h("div", { class: "section-header" },
            h("h2", {}, "Franchises in Library"),
            h("span", { class: "count" }, String(franchises.length))),
          h("div", { class: "poster-grid" }, cards));
      }).catch(() => {});
    }

    return h("div", { class: "library page-enter" },
      h("div", { class: "page-header" }, h("h1", {}, "Collections"), headerActions),
      list.element,
      franchisesContainer);
  }

  async function collection(route) {
    const signal = current();
    let value = null;
    if (typeof api.collection === "function") {
      value = await api.collection(route.id, { signal }).catch(() => null);
    } else {
      const entries = await api.collections({ offset: route.offset ?? 0, limit: PAGE_SIZE }, { signal });
      if (signal.aborted) return null;
      value = (entries ?? []).find((entry) => entry.id === route.id) ?? null;
    }
    if (signal.aborted) return null;
    const indexLink = h("a", { class: "secondary-button", href: "/collections", "data-route": true }, "All Collections");
    if (!value) return emptyState("search", "Collection Not Found", "It may have moved or been removed. Find it in All Collections.", indexLink);
    document.title = `${value.name} · Aurelia`;

    const editable = value.canEdit !== false;
    const playlist = collectionPlayableItems(value);
    const nextSnapshot = value.nextItem ?? null;
    const providerLabel = collectionProviderLabel(value.provider);
    const eyebrowParts = [providerLabel || (value.isSmart ? "Smart List" : "Collection"), value.yearRange].filter(Boolean);

    const playBtn = playlist.length ? h("button", {
      class: "primary-button large",
      onclick: async () => {
        try {
          const freshNext = typeof api.collectionNext === "function"
            ? await api.collectionNext(value.id, { signal }).catch(() => nextSnapshot)
            : nextSnapshot;
          const target = freshNext?.item ?? freshNext?.target ?? playlist[0];
          if (!target) return;
          const shouldResume = typeof freshNext?.resume === "boolean" ? freshNext.resume : freshNext?.action === "resume";
          play?.(target, undefined, { intent: shouldResume ? "resume" : "play", playlist });
        } catch (err) {
          report(err, signal);
        }
      },
    }, icon("play", { size: 17 }), collectionPlayLabel(nextSnapshot)) : null;

    const saveAsBtn = value.provider && !editable && typeof api.createCollectionFromFranchise === "function"
      ? h("button", {
          class: "secondary-button large",
          onclick: async () => {
            try {
              const copied = await api.createCollectionFromFranchise(value.id);
              toast(`Saved “${copied.name}” to Collections`);
              navigate({ name: "collection", id: copied.id });
            } catch (err) {
              toast(err.message);
            }
          },
        }, "Save as Collection")
      : null;

    const editBtn = editable ? h("button", { class: "secondary-button", onclick: () => openCollectionEditor(value) }, "Edit…") : null;
    const deleteBtn = editable ? h("button", {
      class: "secondary-button danger",
      onclick: async () => {
        if (!confirm(`Delete collection “${value.name}”? Media files are not affected.`)) return;
        try {
          await api.deleteCollection(value.id);
          toast(`Deleted “${value.name}”`);
          navigate({ name: "collections" });
        } catch (err) {
          toast(err.message);
        }
      }
    }, "Delete") : null;

    const watchedRatio = (value.itemCount ?? 0) > 0 && (value.watchedCount ?? 0) > 0
      ? Math.min(1, value.watchedCount / value.itemCount)
      : 0;

    const heroCoverArt = value.poster ?? value.items?.[0]?.poster;
    const hero = h("section", { class: "detail-hero box-hero" },
      artwork(value.backdrop ?? heroCoverArt, 1920, "hero-art settle", ""),
      h("div", { class: "detail-shade-side" }),
      h("div", { class: "detail-shade-bottom" }),
      h("div", { class: "detail-top" },
        h("button", { class: "player-round glass", "aria-label": "Back", onclick: () => history.length > 1 ? history.back() : navigate({ name: "collections" }) }, icon("back", { size: 20 })),
        h("div", { class: "button-row" }, editBtn, deleteBtn, indexLink)),
      h("div", { class: "box-hero-layout" },
        h("div", { class: "box-hero-cover" },
          artwork(heroCoverArt, 640, "poster-art", ""),
          heroCoverArt ? null : h("div", { class: "poster-fallback" }, value.name)),
        h("div", { class: "detail-hero-content" },
          h("div", { class: "eyebrow" }, eyebrowParts.join("  ·  ")),
          h("h1", { class: "hero-title" }, value.name),
          (value.genres ?? []).length ? h("div", { class: "hero-genres" }, value.genres.slice(0, 4).join("  ·  ")) : null,
          value.overview ? h("p", { class: "hero-overview" }, value.overview) : null,
          h("div", { class: "muted small" }, collectionStatsLine(value)),
          watchedRatio > 0 ? h("div", { class: "box-progress-row" },
            h("div", { class: "box-progress-track", role: "progressbar", "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": String(Math.round(watchedRatio * 100)) },
              h("div", { class: "box-progress-fill", style: { width: `${watchedRatio * 100}%` } })),
            h("span", { class: "muted small" }, `${Math.round(watchedRatio * 100)}%`)) : null,
          h("div", { class: "button-row" }, playBtn, saveAsBtn))));

    if (playBtn && !nextSnapshot && typeof api.collectionNext === "function") {
      api.collectionNext(value.id, { signal }).then((fresh) => {
        if (!signal.aborted && (fresh?.item || fresh?.target)) playBtn.replaceChildren(icon("play", { size: 17 }), collectionPlayLabel(fresh));
      }).catch(() => {});
    }

    const canReorder = editable && !value.isSmart && Array.isArray(value.members);
    let bodyContent;
    if (Array.isArray(value.members) && value.members.length) {
      const memberNodes = value.members.map((member, index) => {
        const episodes = member.episodes ?? [];
        const episodesDrawer = episodes.length ? h("div", { class: "box-member-episodes", hidden: true },
          episodes.map((ep) => h("button", {
            type: "button",
            class: "box-episode-pill",
            disabled: ep.availability !== "available",
            onclick: () => play?.(ep, undefined, { intent: ep.progress?.positionMilliseconds > 0 && !ep.progress?.isCompleted ? "resume" : "play", playlist }),
          },
            icon("play", { size: 13 }),
            h("span", { style: { flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" } },
              `${eyebrow({ ...ep, parentTitle: null }) || "Episode"} · ${ep.title}`),
            ep.watchState === "completed" ? icon("checkCircle", { size: 14 }) : null))) : null;

        const targetHref = `/title/${member.kind === "episode" && member.item?.parentId ? member.item.parentId : member.mediaId}`;
        const thumbArt = member.item?.poster ?? member.item?.backdrop;
        const runtimeMinutes = Math.round((member.totalRuntimeSeconds ?? 0) / 60);
        const persistMove = async (from, to) => {
          const nextOrder = [...value.members];
          const [moved] = nextOrder.splice(from, 1);
          nextOrder.splice(to, 0, moved);
          await api.updateCollectionOrder(value.id, {
            members: nextOrder.map((m) => ({ mediaId: m.mediaId, seasonNumber: m.seasonNumber ?? null })),
            sortMode: "custom",
          });
          onChanged();
        };

        const row = h("div", { class: "box-member-item", dataset: { dragIndex: String(index) } },
          h("div", { class: "box-member-row" },
            h("div", { class: "box-member-index" }, String(index + 1)),
            h("a", { class: "box-member-thumb", href: targetHref, "data-route": true }, artwork(thumbArt, 320, "poster-art", "")),
            h("div", { class: "box-member-info" },
              h("a", { class: "box-member-title", href: targetHref, "data-route": true }, memberDisplayTitle(member)),
              h("div", { class: "box-member-meta" },
                member.seasonNumber != null ? h("span", {}, seasonTitle(member.seasonNumber)) : null,
                member.item?.year ? h("span", {}, String(member.item.year)) : null,
                member.itemCount > 1 ? h("span", {}, `${member.watchedCount} of ${member.itemCount} watched`)
                  : member.watchedCount >= 1 ? h("span", { class: "watched-label small" }, icon("checkCircle", { size: 13 }), "Watched") : null,
                runtimeMinutes > 0 ? h("span", {}, runtime(runtimeMinutes)) : null)),
            h("div", { class: "box-member-actions" },
              episodes.length ? h("button", {
                type: "button", class: "secondary-button",
                onclick: (event) => {
                  const hidden = !episodesDrawer.hidden;
                  episodesDrawer.hidden = hidden;
                  event.currentTarget.textContent = hidden ? `Episodes (${episodes.length})` : "Hide Episodes";
                },
              }, `Episodes (${episodes.length})`) : null,
              h("button", {
                type: "button", class: "secondary-button",
                onclick: () => {
                  const first = episodes[0] ?? member.item;
                  if (first) play?.(first, undefined, { intent: "play", playlist });
                },
              }, "Play"),
              canReorder ? h("button", { type: "button", class: "icon-button", "aria-label": "Move Up", disabled: index === 0, onclick: () => persistMove(index, index - 1) }, icon("arrowUp", { size: 15 })) : null,
              canReorder ? h("button", { type: "button", class: "icon-button", "aria-label": "Move Down", disabled: index === value.members.length - 1, onclick: () => persistMove(index, index + 1) }, icon("arrowDown", { size: 15 })) : null,
              canReorder ? h("button", {
                type: "button", class: "icon-button", "aria-label": `Remove ${memberDisplayTitle(member)}`,
                onclick: async () => {
                  await api.removeCollectionItem(value.id, member.mediaId, member.seasonNumber);
                  onChanged();
                },
              }, icon("close", { size: 15 })) : null)),
          episodesDrawer);
        if (canReorder) attachDragReorder(row, persistMove);
        return row;
      });
      bodyContent = h("div", { class: "box-members" }, memberNodes);
    } else {
      bodyContent = h("div", { class: "poster-grid", style: { padding: "24px var(--gutter)" } },
        (value.items ?? []).map((item, index) => posterCard(item, index)));
    }

    return h("div", { class: "library page-enter" }, hero, bodyContent);
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

  function watchMenu(item, scope = "title", seasonNumber, { includeContinueWatching = true, labelScope = false } = {}) {
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
    const label = scope === "season" ? "Season" : (scope === "series" && (labelScope || item.kind === "episode")) ? "Series" : "";
    const actions = [
      h("button", { class: "menu-item", onclick: () => run(true) }, icon("checkCircle", { size: 16 }), `Mark ${label ? `${label} ` : ""}as Watched`),
      h("button", { class: "menu-item", onclick: () => run(false) }, icon("circle", { size: 16 }), `Mark ${label ? `${label} ` : ""}as Unwatched`),
    ];
    if (includeContinueWatching && scope !== "season") actions.push(...continueWatchingMenu(item));
    return actions;
  }
  function continueWatchingMenu(item) {
    const choice = continueWatchingChoice(item);
    if (!choice) return [];
    const signal = current();
    const intendedHidden = choice === "remove";
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
    // Each menu offers the watch state of its own title only: an episode marks the episode, a show
    // the whole show. A season is marked from the season selector above its episodes.
    if (["movie", "series", "episode"].includes(item.kind)) {
      actions.push(h("div", { class: "menu-divider" }));
      actions.push(...watchMenu(item, item.kind === "series" ? "series" : "title", undefined, {
        includeContinueWatching: false,
        labelScope: item.kind === "series",
      }));
    }
    if (["movie", "series", "episode"].includes(item.kind)) {
      actions.push(h("div", { class: "menu-divider" }));
      actions.push(option("Add to Collection…", "plus", () => openAddToCollectionDialog(item)));
    }
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
  return { close, browse, search, collections, collection, watchMenu, mediaMenu, openAddToCollectionDialog };

}
