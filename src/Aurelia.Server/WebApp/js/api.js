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
  async function request(path, { method = "GET", body, as = "profile", signal, keepalive = false } = {}) {
    const headers = { Accept: "application/json", "X-Aurelia-Web": as };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    let response;
    try {
      response = await fetchImpl(path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        credentials: "same-origin",
        cache: "no-store",
        signal,
        keepalive,
      });
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      throw new ApiError(0, "offline", "The server isn’t answering.");
    }
    if (response.status === 204 || response.status === 304) return null;
    const text = await response.text();
    let value = null;
    try {
      value = text ? JSON.parse(text) : null;
    } catch {
      value = null;
    }
    if (!response.ok) {
      throw new ApiError(response.status, value?.code ?? `http_${response.status}`, value?.message ?? defaultMessage(response.status));
    }
    return value;
  }

  const id = (value) => encodeURIComponent(value);

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
    catalogPage: (parameters) => request(`/api/v1/catalog/items?${new URLSearchParams(parameters)}`),
    search: (parameters) => request(`/api/v1/catalog/search?${new URLSearchParams(parameters)}`),
    detail: (mediaId) => request(`/api/v1/catalog/items/${id(mediaId)}`),
    collections: () => request("/api/v1/catalog/collections?limit=200"),
    playbackPlan: (mediaId) => request(`/api/v1/media/${id(mediaId)}/playback-plan`),
    setFavorite: (mediaId, isFavorite) => request(`/api/v1/media/${id(mediaId)}/favorite`, { method: "PUT", body: { isFavorite } }),
    watchState: (mediaId, scope = "title", seasonNumber) =>
      request(`/api/v1/media/${id(mediaId)}/watch-state?${new URLSearchParams(seasonNumber == null ? { scope } : { scope, seasonNumber })}`),
    setWatchState: (mediaId, body) => request(`/api/v1/media/${id(mediaId)}/watch-state`, { method: "PUT", body }),

    createPlayback: (mediaId) => request(`/api/v1/media/${id(mediaId)}/playback`, { method: "POST" }),
    revokePlayback: (playbackId) => request(`/api/v1/playback/${id(playbackId)}`, { method: "DELETE", keepalive: true }),
    saveProgress: (mediaId, body, { keepalive = false } = {}) =>
      request(`/api/v1/media/${id(mediaId)}/progress`, { method: "PUT", body, keepalive }),
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
export async function loadAllPages(loadPage, parameters, { limit = 200, restarts = 3 } = {}) {
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
