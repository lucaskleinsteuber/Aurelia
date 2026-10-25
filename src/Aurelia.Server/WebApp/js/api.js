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

  /**
   * A server change that needs the owner's approval: while server management is unlocked, the
   * server issues a one-time approval for exactly this method, address and body.
   */
  async function approved(path, { method = "POST", body } = {}) {
    const text = body === undefined ? "" : JSON.stringify(body);
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    const payloadHash = [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
    const grant = await request("/api/v1/server/approval", { method: "POST", body: { action: `${method} ${path}`, payloadHash } });
    return request(path, { method, body: body === undefined ? undefined : text, approval: grant.token });
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
    conversionPlan: (mediaId, codecs) => request(`/api/v1/media/${id(mediaId)}/conversion`, { method: "POST", body: codecs }),
    sceneNotes: (mediaId) => request(`/api/v1/media/${id(mediaId)}/notes`),
    saveSceneNote: (mediaId, noteId, body) => request(`/api/v1/media/${id(mediaId)}/notes/${id(noteId)}`, { method: "PUT", body }),
    removeSceneNote: (mediaId, noteId, revision) =>
      request(`/api/v1/media/${id(mediaId)}/notes/${id(noteId)}?${new URLSearchParams({ revision })}`, { method: "DELETE" }),
    revokePlayback: (playbackId) => request(`/api/v1/playback/${id(playbackId)}`, { method: "DELETE", keepalive: true }),
    saveProgress: (mediaId, body, { keepalive = false } = {}) =>
      request(`/api/v1/media/${id(mediaId)}/progress`, { method: "PUT", body, keepalive }),
    approved,
    unlockManagement: (password) => request("/api/v1/management/unlock", { method: "POST", body: { password } }),
    lockManagement: () => request("/api/v1/management/lock", { method: "POST" }),
    serverStatus: () => request("/api/v1/server/status"),
    serverUpdates: () => request("/api/v1/server/updates"),
    checkForUpdates: () => request("/api/v1/server/updates/check", { method: "POST" }),
    serverPower: () => request("/api/v1/server/power"),
    saveServerPower: (body) => request("/api/v1/server/power", { method: "PUT", body }),
    serverUsers: () => request("/api/v1/server/users"),
    serverBackups: () => request("/api/v1/server/backups"),
    libraries: () => request("/api/v1/libraries"),
    scanLibrary: (libraryId) => request(`/api/v1/libraries/${id(libraryId)}/scans`, { method: "POST" }),
    scanAllLibraries: () => request("/api/v1/libraries/scans", { method: "POST" }),
    setLibraryMonitoring: (libraryId, enabled) => request(`/api/v1/libraries/${id(libraryId)}/monitoring`, { method: "PUT", body: { enabled } }),
    metadataJobs: () => request("/api/v1/metadata/jobs"),
    startMetadataJob: (body) => request("/api/v1/metadata/jobs", { method: "POST", body }),
    devices: () => request("/api/v1/auth/sessions"),
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
