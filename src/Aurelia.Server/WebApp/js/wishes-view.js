// Family Wishes page (/wishes): browse, search via server TMDB proxy, "Me Too", and admin actions.

import { h, icon, clear } from "./dom.js";
import {
  BoundedFailureCache,
  describeWishError,
  formatWishDate,
  isWishAdministrator,
  parseYearInput,
  wishKindLabel,
  wishPosterUrl,
  wishStateLabel,
} from "./wishes.js";

const PAGE_BATCH = 30;
const FILTERS = [
  ["open", "Open"],
  ["fulfilled", "In Library"],
  ["declined", "Declined"],
  ["all", "All"],
];

export function createWishesView({ api, profile, navigate, toast, handleError, onSummaryChanged }) {
  const failedPosters = new BoundedFailureCache();
  let root = null;
  let filter = null;
  let visibleLimit = PAGE_BATCH;
  let listState = { loading: true, wishes: [], openCount: 0, newlyFulfilledCount: 0, providerEnabled: true, error: null };
  let composerOpen = false;
  let composerKind = "movie";
  let searchQuery = "";
  let searchState = { loading: false, results: [], providerEnabled: true, error: null, manualMode: false };
  let searchTimer = null;
  let searchAbort = null;
  let loadAbort = null;
  let actionError = null;
  let seenSentForFulfilled = 0;

  function isAdmin() {
    return isWishAdministrator(profile());
  }

  function reset() {
    loadAbort?.abort();
    searchAbort?.abort();
    clearTimeout(searchTimer);
    filter = null;
    visibleLimit = PAGE_BATCH;
    composerOpen = false;
    searchQuery = "";
    actionError = null;
    seenSentForFulfilled = 0;
    failedPosters.clear();
    listState = { loading: true, wishes: [], openCount: 0, newlyFulfilledCount: 0, providerEnabled: true, error: null };
    searchState = { loading: false, results: [], providerEnabled: true, error: null, manualMode: false };
  }

  async function load({ quiet = false } = {}) {
    loadAbort?.abort();
    const controller = new AbortController();
    loadAbort = controller;
    const requestedState = filter === "all" || filter == null ? undefined : filter;
    if (!quiet) {
      listState = { ...listState, loading: true, error: null };
      redraw();
    }
    try {
      const response = await api.wishes(requestedState, { signal: controller.signal });
      if (controller.signal.aborted) return;
      const wishes = response?.wishes ?? [];
      const openCount = response?.openCount ?? 0;
      const newlyFulfilledCount = response?.newlyFulfilledCount ?? 0;
      const providerEnabled = response?.providerEnabled !== false;

      // On initial load for non-admins with newly fulfilled wishes and nothing open, jump right to In Library.
      if (filter == null) {
        filter = !isAdmin() && newlyFulfilledCount > 0 && openCount === 0 ? "fulfilled" : "open";
        if (filter !== "all") {
          const filtered = await api.wishes(filter, { signal: controller.signal });
          if (controller.signal.aborted) return;
          applyResponse(filtered);
          return;
        }
      }
      applyResponse({ wishes, openCount, newlyFulfilledCount, providerEnabled });
    } catch (error) {
      if (controller.signal.aborted || error?.name === "AbortError") return;
      if (handleError?.(error)) return;
      listState = { ...listState, loading: false, error: describeWishError(error).message };
      redraw();
    }
  }

  function applyResponse(response) {
    const wishes = response?.wishes ?? [];
    const openCount = response?.openCount ?? 0;
    const newlyFulfilledCount = response?.newlyFulfilledCount ?? 0;
    const providerEnabled = response?.providerEnabled !== false;
    listState = { loading: false, wishes, openCount, newlyFulfilledCount, providerEnabled, error: null };
    onSummaryChanged?.({ openCount, newlyFulfilledCount });

    const showsFulfilled = filter === "fulfilled" || filter === "all";
    if (showsFulfilled && newlyFulfilledCount > 0 && seenSentForFulfilled !== newlyFulfilledCount) {
      seenSentForFulfilled = newlyFulfilledCount;
      api.markWishesSeen().then(() => {
        listState = { ...listState, newlyFulfilledCount: 0 };
        onSummaryChanged?.({ openCount: listState.openCount, newlyFulfilledCount: 0 });
      }, () => {});
    }
    redraw();
  }

  function screen() {
    root = h("div", { class: "wishes-page page-enter" });
    visibleLimit = PAGE_BATCH;
    void load();
    render();
    return root;
  }

  function redraw() {
    if (root?.isConnected) render();
  }

  function posterBox(posterPath, title, width = 342) {
    const url = wishPosterUrl(posterPath, width);
    const frame = h("div", { class: "poster-frame wish-poster" });
    const fallback = h("div", { class: "poster-fallback" }, title || "?");
    if (url && !failedPosters.has(url)) {
      const img = h("img", { class: "poster-art wish-poster-img", src: url, alt: title ?? "", loading: "lazy", decoding: "async" });
      img.addEventListener("load", () => img.classList.add("loaded"), { once: true });
      img.addEventListener("error", () => {
        failedPosters.add(url);
        img.remove();
        frame.append(fallback);
      }, { once: true });
      frame.append(img);
    } else {
      frame.append(fallback);
    }
    return frame;
  }

  function render() {
    if (!root) return;
    clear(root);
    const currentFilter = filter ?? "open";
    const admin = isAdmin();
    const canAskNotify = typeof globalThis.Notification === "function" && globalThis.Notification.permission === "default";

    const header = h("div", { class: "wishes-head" },
      h("div", {},
        h("h1", {}, "Family Wishes"),
        h("p", { class: "muted" }, admin
          ? "See what the family asked for and mark titles added once they arrive."
          : "Wish for movies or TV series you’d like in Aurelia.")),
      h("div", { class: "button-row" },
        canAskNotify ? h("button", { class: "secondary-button", onclick: () => {
          globalThis.Notification.requestPermission?.().then(() => redraw(), () => {});
        } }, "Enable Notifications") : null,
        h("button", { class: "primary-button", onclick: () => {
          composerOpen = !composerOpen;
          actionError = null;
          redraw();
        } }, icon(composerOpen ? "close" : "plus", { size: 16 }), composerOpen ? "Close" : "Add Wish")));

    root.append(header);

    if (listState.newlyFulfilledCount > 0 && currentFilter !== "fulfilled" && currentFilter !== "all") {
      root.append(h("div", { class: "wish-banner", role: "status" },
        h("span", {}, listState.newlyFulfilledCount === 1
          ? "One of your wishes was added to the library."
          : `${listState.newlyFulfilledCount} of your wishes were added to the library.`),
        h("button", { class: "secondary-button", onclick: () => {
          filter = "fulfilled";
          visibleLimit = PAGE_BATCH;
          void load();
        } }, "View Added")));
    }

    if (actionError) {
      root.append(h("div", { class: "wish-alert", role: "alert" },
        h("span", {}, actionError.message),
        actionError.alreadyInLibrary ? h("button", { class: "secondary-button", onclick: () => {
          navigate({ name: "title", id: actionError.alreadyInLibrary.mediaId });
        } }, `Open “${actionError.alreadyInLibrary.title}”`) : null));
    }

    if (composerOpen) root.append(renderComposer());

    const tabs = h("div", { class: "health-tabs wishes-tabs", role: "tablist", "aria-label": "Filter wishes" },
      FILTERS.map(([id, label]) => h("button", {
        class: `health-tab-button ${currentFilter === id ? "selected" : ""}`,
        role: "tab",
        "aria-selected": String(currentFilter === id),
        onclick: () => {
          filter = id;
          visibleLimit = PAGE_BATCH;
          void load();
        },
      }, label, id === "open" && listState.openCount > 0 ? ` (${listState.openCount})` : null)));

    root.append(tabs);

    if (listState.loading) {
      root.append(h("div", { class: "page-loading" }, h("div", { class: "spinner visible" })));
      return;
    }

    if (listState.error) {
      root.append(h("div", { class: "empty-state" },
        icon("warning", { size: 32 }),
        h("h2", {}, "Couldn’t Load Wishes"),
        h("p", { class: "muted" }, listState.error),
        h("button", { class: "secondary-button", onclick: () => void load() }, "Try Again")));
      return;
    }

    if (!listState.wishes.length) {
      root.append(h("div", { class: "empty-state" },
        icon("star", { size: 32 }),
        h("h2", {}, currentFilter === "open" ? "No Open Wishes" : "Nothing Here Yet"),
        h("p", { class: "muted" }, currentFilter === "open"
          ? "Anyone in the family can ask for a movie or TV series."
          : "No wishes in this view right now.")));
      return;
    }

    const shown = listState.wishes.slice(0, visibleLimit);
    root.append(h("div", { class: "wish-list" }, shown.map((wish) => renderWishCard(wish, admin))));

    if (listState.wishes.length > visibleLimit) {
      root.append(h("div", { class: "wishes-more" },
        h("button", { class: "secondary-button", onclick: () => {
          visibleLimit += PAGE_BATCH;
          redraw();
        } }, `Show More (${listState.wishes.length - visibleLimit} remaining)`)));
    }
  }

  function renderComposer() {
    const manual = !listState.providerEnabled || !searchState.providerEnabled || searchState.manualMode;
    const panel = h("section", { class: "wish-composer", "aria-label": "Request a movie or TV series" },
      h("div", { class: "wish-composer-head" },
        h("div", { class: "wish-kind-chips", role: "group", "aria-label": "Title type" },
          [["movie", "Movie"], ["series", "TV Series"]].map(([kind, label]) => h("button", {
            class: `chip ${composerKind === kind ? "selected" : ""}`,
            type: "button",
            "aria-pressed": String(composerKind === kind),
            onclick: () => {
              composerKind = kind;
              if (!manual && searchQuery.trim()) runSearch(searchQuery);
              else redraw();
            },
          }, label))),
        listState.providerEnabled && searchState.providerEnabled ? h("button", {
          class: "secondary-button small",
          type: "button",
          onclick: () => {
            searchState = { ...searchState, manualMode: !manual };
            redraw();
          },
        }, manual ? "Search TMDB Instead" : "Enter Without Search") : null));

    if (manual) {
      const titleInput = h("input", { class: "text-field", type: "text", placeholder: "Title (e.g. Spirited Away)", "aria-label": "Title" });
      const yearInput = h("input", { class: "text-field", type: "text", inputmode: "numeric", maxlength: "4", placeholder: "Year (optional)", "aria-label": "Year" });
      const noteInput = h("input", { class: "text-field", type: "text", placeholder: "Note for admins (optional)", "aria-label": "Note" });
      const formError = h("p", { class: "error-text", role: "alert" });
      const form = h("form", { class: "wish-manual-form", onsubmit: async (event) => {
        event.preventDefault();
        formError.textContent = "";
        const title = titleInput.value.trim();
        if (!title) { formError.textContent = "Enter a title first."; return; }
        const parsedYear = parseYearInput(yearInput.value);
        if (parsedYear.error) { formError.textContent = parsedYear.error; return; }
        await submitWish({
          kind: composerKind,
          title,
          year: parsedYear.year,
          note: noteInput.value.trim() || null,
        }, formError);
      } },
        !listState.providerEnabled || !searchState.providerEnabled
          ? h("p", { class: "muted small" }, "Metadata search isn’t turned on for this server, so enter the title below.")
          : null,
        h("div", { class: "wish-manual-fields" }, titleInput, yearInput),
        noteInput,
        formError,
        h("div", { class: "button-row" },
          h("button", { class: "primary-button", type: "submit" }, "Add Wish")));
      panel.append(form);
      return panel;
    }

    const noteInput = h("input", { class: "text-field", type: "text", placeholder: "Optional note (e.g. language or edition)", "aria-label": "Note for search request" });
    const searchInput = h("input", {
      class: "search-field",
      type: "search",
      value: searchQuery,
      placeholder: composerKind === "series" ? "Search TV series…" : "Search movies…",
      "aria-label": "Search for a title to wish",
    });
    searchInput.addEventListener("input", () => {
      searchQuery = searchInput.value;
      clearTimeout(searchTimer);
      const trimmed = searchQuery.trim();
      if (!trimmed) {
        searchAbort?.abort();
        searchState = { ...searchState, loading: false, results: [], error: null };
        renderSearchResults(resultsHost, noteInput);
        return;
      }
      searchTimer = setTimeout(() => runSearch(trimmed, resultsHost, noteInput), 260);
    });

    const resultsHost = h("div", { class: "wish-search-results" });
    renderSearchResults(resultsHost, noteInput);

    panel.append(
      h("div", { class: "search-bar wish-search-bar" }, icon("search", { size: 18 }), searchInput),
      noteInput,
      resultsHost);
    return panel;
  }

  async function runSearch(query, resultsHost, noteInput) {
    searchAbort?.abort();
    const controller = new AbortController();
    searchAbort = controller;
    searchState = { ...searchState, loading: true, error: null };
    if (resultsHost) renderSearchResults(resultsHost, noteInput);
    try {
      const response = await api.wishSearch(query.trim(), composerKind, { signal: controller.signal });
      if (controller.signal.aborted) return;
      searchState = {
        ...searchState,
        loading: false,
        providerEnabled: response?.providerEnabled !== false,
        results: response?.results ?? [],
        error: null,
      };
      if (!searchState.providerEnabled) { redraw(); return; }
      if (resultsHost) renderSearchResults(resultsHost, noteInput);
      else redraw();
    } catch (error) {
      if (controller.signal.aborted || error?.name === "AbortError") return;
      const described = describeWishError(error);
      if (described.providerDisabled) {
        searchState = { ...searchState, loading: false, providerEnabled: false };
        redraw();
        return;
      }
      if (handleError?.(error)) return;
      searchState = { ...searchState, loading: false, error: described.message };
      if (resultsHost) renderSearchResults(resultsHost, noteInput);
      else redraw();
    }
  }

  function renderSearchResults(container, noteInput) {
    if (!container) return;
    clear(container);
    if (searchState.loading) {
      container.append(h("div", { class: "muted small" }, "Searching…"));
      return;
    }
    if (searchState.error) {
      container.append(h("p", { class: "error-text", role: "alert" }, searchState.error));
      return;
    }
    if (searchQuery.trim() && !searchState.results.length) {
      container.append(h("div", { class: "muted small" }, "No matching titles found."));
      return;
    }
    for (const hit of searchState.results.slice(0, 12)) {
      const action = hit.alreadyInLibrary && hit.existingMediaId
        ? h("button", { class: "secondary-button small", onclick: () => navigate({ name: "title", id: hit.existingMediaId }) }, "In Library")
        : hit.alreadyWished && hit.supportedByCaller
          ? h("span", { class: "badge" }, "Requested")
          : hit.alreadyWished && hit.existingWishId
            ? h("button", { class: "secondary-button small", onclick: () => void toggleSupport(hit.existingWishId, true) }, "Me Too")
            : h("button", { class: "primary-button small", onclick: () => void submitWish({
              kind: hit.kind ?? composerKind,
              title: hit.title,
              year: hit.year ?? null,
              provider: hit.provider,
              providerMediaId: hit.providerMediaId,
              overview: hit.overview ?? null,
              posterPath: hit.posterPath ?? null,
              note: noteInput?.value?.trim() || null,
            }) }, "Wish This");

      container.append(h("div", { class: "wish-hit-row" },
        posterBox(hit.posterPath, hit.title, 185),
        h("div", { class: "wish-hit-info" },
          h("div", { class: "wish-hit-title" }, hit.title, hit.year ? h("span", { class: "muted" }, ` (${hit.year})`) : null),
          h("div", { class: "muted small" }, wishKindLabel(hit.kind ?? composerKind)),
          hit.overview ? h("p", { class: "wish-hit-overview muted small" }, hit.overview) : null),
        h("div", { class: "wish-hit-action" }, action)));
    }
  }

  async function submitWish(payload, inlineErrorEl = null) {
    actionError = null;
    try {
      const result = await api.createWish(payload);
      composerOpen = false;
      searchQuery = "";
      searchState = { ...searchState, results: [], error: null };
      toast?.(result?.mergedIntoExistingSupport ? `Added your “Me Too” vote to “${result.wish?.title ?? payload.title}”.` : `Added “${result?.wish?.title ?? payload.title}” to Family Wishes.`);
      await load({ quiet: true });
    } catch (error) {
      if (handleError?.(error)) return;
      const described = describeWishError(error);
      if (inlineErrorEl) inlineErrorEl.textContent = described.message;
      else actionError = described;
      redraw();
    }
  }

  async function toggleSupport(wishId, supported) {
    actionError = null;
    try {
      await api.setWishSupport(wishId, supported);
      await load({ quiet: true });
    } catch (error) {
      if (handleError?.(error)) return;
      actionError = describeWishError(error);
      redraw();
    }
  }

  async function withdrawWish(wishId) {
    actionError = null;
    try {
      await api.deleteWish(wishId);
      toast?.("Wish removed.");
      await load({ quiet: true });
    } catch (error) {
      if (handleError?.(error)) return;
      actionError = describeWishError(error);
      redraw();
    }
  }

  async function setWishState(wishId, state, extra = {}) {
    actionError = null;
    try {
      await api.updateWishState(wishId, { state, ...extra });
      await load({ quiet: true });
    } catch (error) {
      if (handleError?.(error)) return;
      actionError = describeWishError(error);
      redraw();
    }
  }

  function promptDeclineNote(wish) {
    const input = h("input", { class: "text-field", type: "text", placeholder: "Reason (optional)", "aria-label": "Reason for declining" });
    const dialog = h("dialog", { class: "sheet" },
      h("h2", {}, `Decline “${wish.title}”?`),
      h("p", {}, "Optionally leave a short note for the family."),
      input,
      h("div", { class: "button-row" },
        h("button", { class: "secondary-button", onclick: () => dialog.close() }, "Cancel"),
        h("button", { class: "primary-button", onclick: () => {
          const note = input.value.trim() || null;
          dialog.close();
          void setWishState(wish.id, "declined", { resolutionNote: note });
        } }, "Decline")));
    document.body.append(dialog);
    dialog.addEventListener("close", () => dialog.remove(), { once: true });
    dialog.showModal?.();
  }

  function renderWishCard(wish, admin) {
    const me = profile();
    const isMine = wish.userId && me?.id && String(wish.userId).toLowerCase() === String(me.id).toLowerCase();
    const supporters = wish.supporters ?? [];
    const meta = [wishKindLabel(wish.kind), wish.year ? String(wish.year) : null, wish.ageRating || null, formatWishDate(wish.createdAt)].filter(Boolean).join(" · ");

    const actions = [];
    if (wish.state === "open") {
      if (wish.canSupport) {
        actions.push(h("button", {
          class: `chip ${wish.supportedByCaller ? "selected" : ""}`,
          onclick: () => void toggleSupport(wish.id, !wish.supportedByCaller),
        }, wish.supportedByCaller ? "Me Too ✓" : "Me Too"));
      }
      if (isMine) {
        actions.push(h("button", { class: "secondary-button small", onclick: () => void withdrawWish(wish.id) }, "Withdraw"));
      }
      if (admin) {
        actions.push(h("button", { class: "primary-button small", onclick: () => void setWishState(wish.id, "fulfilled") }, "Mark Added"));
        actions.push(h("button", { class: "secondary-button small", onclick: () => promptDeclineNote(wish) }, "Decline"));
      }
    } else {
      if (wish.fulfilledMediaItemId) {
        actions.push(h("button", { class: "primary-button small", onclick: () => navigate({ name: "title", id: wish.fulfilledMediaItemId }) }, "Open in Library"));
      }
      if (admin) {
        actions.push(h("button", { class: "secondary-button small", onclick: () => void setWishState(wish.id, "open") }, "Reopen"));
        actions.push(h("button", { class: "secondary-button small", onclick: () => void withdrawWish(wish.id) }, "Delete"));
      }
    }

    const suggestions = admin && wish.state === "open" && (wish.suggestions?.length ?? 0) > 0
      ? h("div", { class: "wish-suggestions" },
        h("span", { class: "muted small" }, "In library now — is this that wish?"),
        wish.suggestions.map((suggestion) => h("div", { class: "wish-suggestion-chip" },
          h("span", {}, `${suggestion.title}${suggestion.year ? ` (${suggestion.year})` : ""}`),
          h("button", { class: "primary-button small", onclick: () => void setWishState(wish.id, "fulfilled", { fulfilledMediaItemId: suggestion.mediaId }) }, "Match & Fulfill"))))
      : null;

    return h("article", { class: `wish-card state-${wish.state ?? "open"}` },
      posterBox(wish.posterPath, wish.title, 342),
      h("div", { class: "wish-body" },
        h("div", { class: "wish-top-line" },
          h("h2", { class: "wish-title" }, wish.title),
          h("span", { class: `badge wish-status state-${wish.state ?? "open"}` }, wishStateLabel(wish.state))),
        h("div", { class: "muted small" }, meta),
        h("div", { class: "wish-requester small" },
          `Asked by ${wish.userName}`,
          supporters.length ? ` · +${supporters.length} ${supporters.length === 1 ? "other" : "others"} (${supporters.map((s) => s.name).join(", ")})` : null),
        wish.note ? h("p", { class: "wish-note" }, `“${wish.note}”`) : null,
        wish.overview ? h("p", { class: "wish-overview muted small" }, wish.overview) : null,
        wish.resolvedByUserName || wish.resolutionNote ? h("p", { class: "wish-resolution small" },
          [wish.resolvedByUserName ? `${wishStateLabel(wish.state)} by ${wish.resolvedByUserName}` : null, wish.resolutionNote].filter(Boolean).join(": ")) : null,
        suggestions,
        actions.length ? h("div", { class: "wish-actions button-row" }, actions) : null));
  }

  return { screen, reset, refresh: () => load({ quiet: true }) };
}
