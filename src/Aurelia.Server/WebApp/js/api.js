// Talks to the Aurelia server that served this page. The browser holds no token: the server's
// HttpOnly cookies carry the sign-in, and the X-Aurelia-Web header says which one a request
// uses ("device" before a profile is open, "profile" afterwards).

export class ApiError extends Error {
  constructor(status, code, message) {
    super(message || "Something went wrong.");
    this.status = status;
    this.code = code;
  }

  /** The server did not answer at all: it is off, asleep or out of reach. */
  get offline() {
    return this.status === 0;
  }
}

export function createApi(fetchImpl = (...args) => globalThis.fetch(...args)) {
  async function request(path, { method = "GET", body, as = "profile", signal, keepalive = false, approval } = {}) {
    const headers = { Accept: "application/json", "X-Aurelia-Web": as };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (approval) headers["X-Aurelia-Approval"] = approval;
    let response;
    let text;
    try {
      response = await fetchImpl(path, {
        method,
        headers,
        body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
        credentials: "same-origin",
        cache: "no-store",
        signal,
        keepalive,
      });
      if (response.status !== 204 && response.status !== 304) text = await response.text();
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      throw new ApiError(0, "offline", "The server isn’t answering.");
    }
    if (response.status === 204 || response.status === 304) return null;
    let value = null;
    try {
      value = text ? JSON.parse(text) : null;
    } catch {
      if (response.ok) throw new ApiError(response.status, "invalid_response", "The server returned an unreadable answer. Try again.");
    }
    if (!response.ok) {
      throw new ApiError(response.status, value?.code ?? `http_${response.status}`, value?.message ?? defaultMessage(response.status));
    }
    return value;
  }

  const id = (value) => encodeURIComponent(value);

  /**
   * A guarded server change: while server management is unlocked, the
   * server issues a one-time approval for exactly this method, address and body.
   */
  async function approved(path, { method = "POST", body, signal } = {}) {
    const text = body === undefined ? "" : JSON.stringify(body);
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    const payloadHash = [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
    const grant = await request("/api/v1/management/approval", { method: "POST", body: { action: `${method} ${path}`, payloadHash }, signal });
    if (!grant?.token) throw new ApiError(200, "invalid_response", "The server did not authorize this change. Try again.");
    return request(path, { method, body: body === undefined ? undefined : text, approval: grant.token, signal });
  }

  return {
    request,
    serverInfo: () => request("/api/v1/server/info", { as: "device" }),

    startPairing: (deviceName) => request("/api/v1/web/pairing", { method: "POST", body: { deviceName }, as: "device" }),
    pairingStatus: () => request("/api/v1/web/pairing/status", { method: "POST", as: "device" }),
    cancelPairing: () => request("/api/v1/web/pairing/cancel", { method: "POST", as: "device" }),
    profiles: () => request("/api/v1/profiles", { as: "device" }),
    unlockProfile: (profileId, pin) =>
      request(`/api/v1/web/profiles/${id(profileId)}/unlock`, { method: "POST", body: pin ? { pin } : {}, as: "device" }),
    endProfile: () => request("/api/v1/web/profile/end", { method: "POST", as: "profile" }),
    signOut: () => request("/api/v1/web/sign-out", { method: "POST", as: "device" }),

    home: () => request("/api/v1/home"),
    catalogPage: (parameters, options = {}) => request(`/api/v1/catalog/items?${new URLSearchParams(parameters)}`, options),
    search: (parameters, options = {}) => request(`/api/v1/catalog/search?${new URLSearchParams(parameters)}`, options),
    detail: (mediaId) => request(`/api/v1/catalog/items/${id(mediaId)}`),
    person: ({ name, key } = {}, options = {}) =>
      request(`/api/v1/catalog/person?${new URLSearchParams({ ...(name ? { name } : {}), ...(key ? { key } : {}) })}`, options),
    collections: (parameters = { limit: 200 }, options = {}) => request(`/api/v1/catalog/collections?${new URLSearchParams(parameters)}`, options),
    createCollection: (body) => request("/api/v1/collections", { method: "POST", body }),
    updateCollection: (collectionId, body) => request(`/api/v1/collections/${id(collectionId)}`, { method: "PUT", body }),
    deleteCollection: (collectionId) => request(`/api/v1/collections/${id(collectionId)}`, { method: "DELETE" }),
    addCollectionItem: (collectionId, mediaId) => request(`/api/v1/collections/${id(collectionId)}/items/${id(mediaId)}`, { method: "POST" }),
    removeCollectionItem: (collectionId, mediaId) => request(`/api/v1/collections/${id(collectionId)}/items/${id(mediaId)}`, { method: "DELETE" }),
    franchises: (options = {}) => request("/api/v1/franchises", options),
    createCollectionFromFranchise: (franchiseId) => request(`/api/v1/collections/from-franchise/${id(franchiseId)}`, { method: "POST" }),
    streamSubtitles: (ticket) => request(`/api/v1/streams/${id(ticket)}/subtitles`),
    history: (parameters = { offset: 0, limit: 50 }, options = {}) => request(`/api/v1/history?${new URLSearchParams(parameters)}`, options),
    deleteHistoryItem: (historyId) => request(`/api/v1/history/${id(historyId)}`, { method: "DELETE" }),
    clearHistory: () => request("/api/v1/history", { method: "DELETE" }),
    statistics: (options = {}) => request("/api/v1/statistics", options),
    yearInReview: (year, options = {}) => request(`/api/v1/statistics/year/${id(year)}`, options),
    healthDuplicates: (parameters = { offset: 0, limit: 50 }, options = {}) => request(`/api/v1/library/health/duplicates?${new URLSearchParams(parameters)}`, options),
    healthOffline: (parameters = { days: 30, offset: 0, limit: 50 }, options = {}) => request(`/api/v1/library/health/offline?${new URLSearchParams(parameters)}`, options),
    healthUnmatched: (parameters = { offset: 0, limit: 50 }, options = {}) => request(`/api/v1/library/health/unmatched?${new URLSearchParams(parameters)}`, options),
    mergeHealthDuplicates: (sourceMediaId, targetMediaId) => request("/api/v1/library/health/merge", { method: "POST", body: { sourceMediaId, targetMediaId } }),
    setPreferredHealthVersion: (preferredMediaId) => request("/api/v1/library/health/preferred", { method: "PUT", body: { preferredMediaId } }),
    removeHealthEntry: (mediaId) => request(`/api/v1/library/health/entries/${id(mediaId)}`, { method: "DELETE" }),
    watchlist: (options = {}) => request("/api/v1/watchlist", options),
    setWatchlist: (mediaId, isWatchlisted, options = {}) =>
      request(`/api/v1/media/${id(mediaId)}/watchlist`, { method: "PUT", body: { isWatchlisted }, signal: options.signal }),
    playbackPlan: (mediaId) => request(`/api/v1/media/${id(mediaId)}/playback-plan`),
    setFavorite: (mediaId, isFavorite, options = {}) => request(`/api/v1/media/${id(mediaId)}/favorite`, { method: "PUT", body: { isFavorite }, signal: options.signal }),
    watchState: (mediaId, scope = "title", seasonNumber, options = {}) =>
      request(`/api/v1/media/${id(mediaId)}/watch-state?${new URLSearchParams(seasonNumber == null ? { scope } : { scope, seasonNumber })}`, options),
    setWatchState: (mediaId, body, options = {}) => request(`/api/v1/media/${id(mediaId)}/watch-state`, { ...options, method: "PUT", body }),
    setContinueWatching: (mediaId, body, options = {}) => request(`/api/v1/media/${id(mediaId)}/continue-watching`, { ...options, method: "PUT", body }),

    createPlayback: (mediaId) => request(`/api/v1/media/${id(mediaId)}/playback`, { method: "POST" }),
    conversionPlan: (mediaId, codecs) => request(`/api/v1/media/${id(mediaId)}/conversion`, { method: "POST", body: codecs }),
    sceneNotes: (mediaId, options = {}) => request(`/api/v1/media/${id(mediaId)}/notes`, options),
    saveSceneNote: (mediaId, noteId, body, options = {}) => request(`/api/v1/media/${id(mediaId)}/notes/${id(noteId)}`, { ...options, method: "PUT", body }),
    removeSceneNote: (mediaId, noteId, revision, options = {}) =>
      request(`/api/v1/media/${id(mediaId)}/notes/${id(noteId)}?${new URLSearchParams({ revision })}`, { ...options, method: "DELETE" }),
    sleepTimerEnded: () => request("/api/v1/playback/sleep-timer-ended", { method: "POST", keepalive: true }),
    revokePlayback: (playbackId) => request(`/api/v1/playback/${id(playbackId)}`, { method: "DELETE", keepalive: true }),
    saveProgress: (mediaId, body, { keepalive = false } = {}) =>
      request(`/api/v1/media/${id(mediaId)}/progress`, { method: "PUT", body, keepalive }),
    approved,
    unlockManagement: (password) => request("/api/v1/management/unlock", { method: "POST", body: { password } }),
    lockManagement: () => request("/api/v1/management/lock", { method: "POST" }),
    serverStatus: (options = {}) => request("/api/v1/server/status", options),
    serverHealth: (options = {}) => request("/api/v1/server/health", options),
    serverUpdates: (options = {}) => request("/api/v1/server/updates", options),
    checkForUpdates: (options = {}) => request("/api/v1/server/updates/check", { ...options, method: "POST" }),
    serverPower: (options = {}) => request("/api/v1/server/power", options),
    saveServerPower: (body) => request("/api/v1/server/power", { method: "PUT", body }),
    serverScrubPreviews: (options = {}) => request("/api/v1/server/scrub-previews", options),
    saveServerScrubPreviews: (body) => request("/api/v1/server/scrub-previews", { method: "PUT", body }),
    deleteServerScrubPreviews: () => request("/api/v1/server/scrub-previews", { method: "DELETE" }),
    scrubPreviewManifest: (mediaId, options = {}) => request(`/api/v1/media/${id(mediaId)}/scrub-previews`, options),
    serverUsers: (options = {}) => request("/api/v1/server/users", options),
    serverBackups: (options = {}) => request("/api/v1/server/backups", options),
    libraries: (options = {}) => request("/api/v1/libraries", options),
    addLibrary: (body, options = {}) => approved("/api/v1/libraries", { ...options, body }),
    removeLibrary: (libraryId, options = {}) => approved(`/api/v1/libraries/${id(libraryId)}`, { ...options, method: "DELETE" }),
    libraryOperation: (operationId, options = {}) => request(`/api/v1/library-operations/${id(operationId)}`, options),
    profileEditor: (userId, options = {}) => request(`/api/v1/users/${id(userId)}/profile`, options),
    createProfile: (body, options = {}) => approved("/api/v1/users", { ...options, body }),
    updateProfile: (userId, body, options = {}) => approved(`/api/v1/users/${id(userId)}/profile`, { ...options, method: "PUT", body }),
    mediaEditor: (mediaId, options = {}) => request(`/api/v1/media/${id(mediaId)}/editor`, options),
    saveMediaEditor: (mediaId, body, options = {}) => request(`/api/v1/media/${id(mediaId)}/editor`, { ...options, method: "PUT", body }),
    metadataSearch: (mediaId, query, options = {}) => request(`/api/v1/media/${id(mediaId)}/metadata/search?${new URLSearchParams({ query })}`, options),
    selectMetadataMatch: (mediaId, body, options = {}) => request(`/api/v1/media/${id(mediaId)}/metadata/match`, { ...options, method: "PUT", body }),
    clearMetadataMatch: (mediaId, options = {}) => request(`/api/v1/media/${id(mediaId)}/metadata/match`, { ...options, method: "DELETE" }),
    scanLibrary: (libraryId) => request(`/api/v1/libraries/${id(libraryId)}/scans`, { method: "POST" }),
    scanAllLibraries: () => request("/api/v1/libraries/scans", { method: "POST" }),
    setLibraryMonitoring: (libraryId, enabled) => request(`/api/v1/libraries/${id(libraryId)}/monitoring`, { method: "PUT", body: { enabled } }),
    metadataJobs: (options = {}) => request("/api/v1/metadata/jobs", options),
    startMetadataJob: (body) => request("/api/v1/metadata/jobs", { method: "POST", body }),
    devices: (options = {}) => request("/api/v1/auth/sessions", options),
    changes: (after, generation, signal) =>
      request(`/api/v1/sync/changes?${new URLSearchParams(generation ? { after, waitSeconds: 25, generation } : { after, waitSeconds: 25 })}`, { signal }),
  };
}

function defaultMessage(status) {
  if (status === 401 || status === 403) return "This browser needs to sign in again.";
  if (status === 429) return "Too many tries. Wait a moment, then try again.";
  if (status >= 500) return "The server had a problem. Try again.";
  return "Something went wrong.";
}

/** Loads every page of a catalog list against one revision, restarting if the library changed meanwhile. */
// 500 is the most the server sends per page ("catalog-pages-500-v1"): fewer round trips for a
// slow server.
export async function loadAllPages(loadPage, parameters, { limit = 500, restarts = 3 } = {}) {
  for (let attempt = 0; attempt <= restarts; attempt += 1) {
    const items = [];
    const seen = new Set();
    let revision;
    try {
      for (let offset = 0; ; ) {
        const page = await loadPage({ ...parameters, offset, limit, ...(revision ? { revision } : {}) });
        revision ??= page.revision;
        for (const item of page.items ?? []) {
          if (!seen.has(item.id)) {
            seen.add(item.id);
            items.push(item);
          }
        }
        const fetched = (page.items ?? []).length;
        offset += fetched;
        if (fetched === 0 || offset >= page.total) return items;
      }
    } catch (error) {
      if (error instanceof ApiError && error.status === 409 && error.code === "catalog_changed" && attempt < restarts) continue;
      throw error;
    }
  }
  return [];
}
