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

/**
 * @param {Function} [fetchImpl]
 * @param {object} [hooks]
 * @param {(path: string, method: string) => void} [hooks.onChange]  called before each request that
 *   may change something on the server (everything but GET and HEAD), so remembered pages can be dropped
 */
export function createApi(fetchImpl = (...args) => globalThis.fetch(...args), { onChange } = {}) {
  async function request(path, { method = "GET", body, as = "profile", signal, keepalive = false, approval } = {}) {
    if (method !== "GET" && method !== "HEAD") onChange?.(path, method);
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

  /** Sends a file as it is (a picture or an encrypted backup); the answer is JSON or nothing. */
  async function send(path, blob, { method = "POST", contentType = blob?.type || "application/octet-stream", signal } = {}) {
    onChange?.(path, method);
    let response;
    try {
      response = await fetchImpl(path, { method, body: blob, headers: { Accept: "application/json", "Content-Type": contentType, "X-Aurelia-Web": "profile" },
        credentials: "same-origin", cache: "no-store", signal });
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      throw new ApiError(0, "offline", "The server isn’t answering.");
    }
    const text = response.status === 204 ? "" : await response.text();
    let value = null;
    try { value = text ? JSON.parse(text) : null; } catch { /* A plain answer has no details. */ }
    if (!response.ok) throw new ApiError(response.status, value?.code ?? `http_${response.status}`, value?.message ?? defaultMessage(response.status));
    return value;
  }

  /** Reads a file from the server, such as a backup or a diagnostics report, as a Blob. */
  async function receive(path, { signal } = {}) {
    let response;
    try {
      response = await fetchImpl(path, { headers: { "X-Aurelia-Web": "profile" }, credentials: "same-origin", cache: "no-store", signal });
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      throw new ApiError(0, "offline", "The server isn’t answering.");
    }
    if (!response.ok) {
      let value = null;
      try { value = JSON.parse(await response.text()); } catch { /* No details. */ }
      throw new ApiError(response.status, value?.code ?? `http_${response.status}`, value?.message ?? defaultMessage(response.status));
    }
    return response.blob();
  }

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
    serverInfo: (options = {}) => request("/api/v1/server/info", { as: "device", ...options }),

    /** Signs this browser in with the code from the main device; the credential stays in a cookie. */
    webSetupStatus: () => request("/api/v1/web/setup", { as: "device" }),
    webSetup: (body) => request("/api/v1/web/setup", { method: "POST", body, as: "device" }),
    redeemPairingCode: (code, deviceName) => request("/api/v1/web/pair", { method: "POST", body: { code, deviceName }, as: "device" }),
    profiles: () => request("/api/v1/profiles", { as: "device" }),
    unlockProfile: (profileId, pin) =>
      request(`/api/v1/web/profiles/${id(profileId)}/unlock`, { method: "POST", body: pin ? { pin } : {}, as: "device" }),
    endProfile: () => request("/api/v1/web/profile/end", { method: "POST", as: "profile" }),
    /** A profile's photo as a Blob. Images cannot send the credential header, so it is fetched. */
    profilePhoto: async (profileId, revision) => {
      let response;
      try {
        response = await fetchImpl(`/api/v1/profiles/${id(profileId)}/picture?rev=${encodeURIComponent(revision ?? 0)}`, {
          headers: { Accept: "image/jpeg", "X-Aurelia-Web": "device" },
          credentials: "same-origin",
        });
      } catch {
        throw new ApiError(0, "offline", "The server isn’t answering.");
      }
      if (!response.ok) throw new ApiError(response.status, `http_${response.status}`, defaultMessage(response.status));
      return response.blob();
    },
    renameProfile: (name) => request("/api/v1/profile/name", { method: "PUT", body: { name } }),
    setPicture: (builtin) => request("/api/v1/profile/picture", { method: "PUT", body: { builtin } }),
    /** An own photo; the server keeps a small square copy. */
    uploadPhoto: async (file) => {
      let response;
      let text;
      try {
        response = await fetchImpl("/api/v1/profile/picture/photo", {
          method: "PUT",
          headers: { Accept: "application/json", "X-Aurelia-Web": "profile", "Content-Type": file.type || "application/octet-stream" },
          body: file,
          credentials: "same-origin",
          cache: "no-store",
        });
        text = await response.text();
      } catch {
        throw new ApiError(0, "offline", "The server isn’t answering.");
      }
      let value = null;
      try {
        value = text ? JSON.parse(text) : null;
      } catch {
        value = null;
      }
      if (!response.ok) throw new ApiError(response.status, value?.code ?? `http_${response.status}`, value?.message ?? defaultMessage(response.status));
      return value;
    },
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
    wrapped: (year, month = null, options = {}) => request(month
      ? `/api/v1/statistics/year/${id(year)}/month/${id(month)}/wrapped`
      : `/api/v1/statistics/year/${id(year)}/wrapped`, options),
    healthDuplicates: (parameters = { offset: 0, limit: 50 }, options = {}) => request(`/api/v1/library/health/duplicates?${new URLSearchParams(parameters)}`, options),
    healthOffline: (parameters = { days: 30, offset: 0, limit: 50 }, options = {}) => request(`/api/v1/library/health/offline?${new URLSearchParams(parameters)}`, options),
    healthUnmatched: (parameters = { offset: 0, limit: 50 }, options = {}) => request(`/api/v1/library/health/unmatched?${new URLSearchParams(parameters)}`, options),
    mergeHealthDuplicates: (sourceMediaId, targetMediaId) => request("/api/v1/library/health/merge", { method: "POST", body: { sourceMediaId, targetMediaId } }),
    removeHealthEntry: (mediaId) => request(`/api/v1/library/health/entries/${id(mediaId)}`, { method: "DELETE" }),
    activePlayers: (currentDeviceId) => request(`/api/v1/devices/players${currentDeviceId ? `?currentDeviceId=${encodeURIComponent(currentDeviceId)}` : ""}`),
    playerStatus: (deviceId) => request(`/api/v1/devices/players/${id(deviceId)}/status`),
    sendPlayerCommand: (deviceId, body) => request(`/api/v1/devices/players/${id(deviceId)}/commands`, { method: "POST", body }),
    playerCommands: (deviceId, waitMs = 0) => request(`/api/v1/devices/player/commands?deviceId=${encodeURIComponent(deviceId)}&waitMs=${waitMs}`),
    watchParties: (mediaId) => request(`/api/v1/watch-together${mediaId ? `?mediaId=${id(mediaId)}` : ""}`),
    createWatchParty: (body) => request("/api/v1/watch-together", { method: "POST", body }),
    joinWatchParty: (partyId, body) => request(`/api/v1/watch-together/${id(partyId)}/join`, { method: "POST", body }),
    watchParty: (partyId, after, waitMs, options = {}) =>
      request(`/api/v1/watch-together/${id(partyId)}${after == null ? "" : `?after=${encodeURIComponent(after)}&waitMs=${encodeURIComponent(waitMs)}`}`, options),
    watchPartyCommand: (partyId, body) => request(`/api/v1/watch-together/${id(partyId)}/commands`, { method: "POST", body }),
    leaveWatchParty: (partyId) => request(`/api/v1/watch-together/${id(partyId)}/members/me`, { method: "DELETE" }),
    movieNights: () => request("/api/v1/movie-night"),
    createMovieNight: (body) => request("/api/v1/movie-night", { method: "POST", body }),
    joinMovieNight: (nightId, body) => request(`/api/v1/movie-night/${id(nightId)}/join`, { method: "POST", body }),
    movieNight: (nightId, after, deckVersion, waitMs, options = {}) =>
      request(`/api/v1/movie-night/${id(nightId)}${after == null ? "" : `?after=${encodeURIComponent(after)}&deckVersion=${encodeURIComponent(deckVersion)}&waitMs=${encodeURIComponent(waitMs)}`}`, options),
    movieNightSettings: (nightId, body) => request(`/api/v1/movie-night/${id(nightId)}/settings`, { method: "POST", body }),
    dealMovieNight: (nightId) => request(`/api/v1/movie-night/${id(nightId)}/deal`, { method: "POST" }),
    movieNightVote: (nightId, body) => request(`/api/v1/movie-night/${id(nightId)}/votes`, { method: "POST", body }),
    keepSwiping: (nightId) => request(`/api/v1/movie-night/${id(nightId)}/keep-swiping`, { method: "POST" }),
    movieNightRole: (nightId, body) => request(`/api/v1/movie-night/${id(nightId)}/role`, { method: "POST", body }),
    leaveMovieNight: (nightId) => request(`/api/v1/movie-night/${id(nightId)}/members/me`, { method: "DELETE" }),
    playerHeartbeat: (body) => request("/api/v1/devices/player/heartbeat", { method: "POST", body }),
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
    progress: (mediaId) => request(`/api/v1/media/${id(mediaId)}/progress`),
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
    serverTranscoding: (options = {}) => request("/api/v1/server/transcoding", options),
    saveServerPower: (body) => request("/api/v1/server/power", { method: "PUT", body }),
    // Speech recognition on the server ("server-speech-v1")
    mediaSpeech: (mediaId, options = {}) => request(`/api/v1/media/${id(mediaId)}/speech`, options),
    startSpeech: (mediaId, body) => request(`/api/v1/media/${id(mediaId)}/speech`, { method: "POST", body }),
    cancelSpeech: (mediaId) => request(`/api/v1/media/${id(mediaId)}/speech`, { method: "DELETE" }),
    serverSpeech: (options = {}) => request("/api/v1/server/speech", options),
    downloadSpeechModel: (name) => request("/api/v1/server/speech/model", { method: "POST", body: { name } }),
    removeSpeechModel: () => request("/api/v1/server/speech/model", { method: "DELETE" }),

    // Intro and credits ("media-segments-v2")
    mediaSegments: (mediaId, options = {}) => request(`/api/v1/media/${id(mediaId)}/segments`, options),
    saveMediaSegments: (mediaId, body) => request(`/api/v1/media/${id(mediaId)}/segments`, { method: "PUT", body }),
    resetMediaSegments: (mediaId) => request(`/api/v1/media/${id(mediaId)}/segments`, { method: "DELETE" }),
    reanalyzeMediaSegments: (mediaId) => request(`/api/v1/media/${id(mediaId)}/segments/reanalyze`, { method: "POST" }),
    serverMediaSegments: (options = {}) => request("/api/v1/server/media-segments", options),
    saveServerMediaSegments: (body) => request("/api/v1/server/media-segments", { method: "PUT", body }),
    mediaSegmentSeries: (options = {}) => request("/api/v1/server/media-segments/series", options),
    reanalyzeSeriesSegments: (seriesId) => request("/api/v1/server/media-segments/reanalyze", { method: "POST", body: seriesId ? { seriesId } : {} }),
    reanalyzeMovieSegments: () => request("/api/v1/server/media-segments/reanalyze", { method: "POST", body: { movies: true } }),

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

    // Devices and people (Settings › Profiles and Devices)
    createPairingCode: () => request("/api/v1/auth/pairings", { method: "POST" }),
    lookupDevicePairing: (code, options = {}) => request("/api/v1/server/device-pairings/lookup", { ...options, method: "POST", body: { code } }),
    approveDevicePairing: (pairingId) => request(`/api/v1/server/device-pairings/${id(pairingId)}/approve`, { method: "POST" }),
    denyDevicePairing: (pairingId) => request(`/api/v1/server/device-pairings/${id(pairingId)}/deny`, { method: "POST" }),
    userSessions: (userId, options = {}) => request(`/api/v1/server/sessions/${id(userId)}`, options),
    revokeUserSession: (sessionId) => request(`/api/v1/server/sessions/${id(sessionId)}`, { method: "DELETE" }),
    revokeAllUserSessions: (userId) => request(`/api/v1/users/${id(userId)}/sessions`, { method: "DELETE" }),
    resetUserPassword: (userId, password) => approved(`/api/v1/users/${id(userId)}/password`, { method: "PUT", body: { password } }),
    updateUserAccess: (userId, body) => request(`/api/v1/users/${id(userId)}/access`, { method: "PUT", body }),

    // Metadata services
    metadataProvider: (options = {}) => request("/api/v1/metadata/provider", options),
    saveMetadataProvider: (body) => request("/api/v1/metadata/provider", { method: "PUT", body }),
    removeMetadataToken: () => request("/api/v1/metadata/provider/token", { method: "DELETE" }),
    subtitleProvider: (options = {}) => request("/api/v1/metadata/subtitles", options),
    saveSubtitleProvider: (body) => request("/api/v1/metadata/subtitles", { method: "PUT", body }),
    removeSubtitleKey: () => request("/api/v1/metadata/subtitles/key", { method: "DELETE" }),
    removeSubtitleAccount: () => request("/api/v1/metadata/subtitles/account", { method: "DELETE" }),
    metadataReviews: (options = {}) => request("/api/v1/metadata/reviews", options),
    pruneArtwork: () => request("/api/v1/metadata/artwork/prune", { method: "POST" }),
    rebuildSearch: () => request("/api/v1/catalog/search/rebuild", { method: "POST" }),

    // A title's subtitles from OpenSubtitles
    downloadedSubtitles: (mediaId, options = {}) => request(`/api/v1/media/${id(mediaId)}/subtitles`, options),
    searchSubtitles: (mediaId, language, options = {}) => request(`/api/v1/media/${id(mediaId)}/subtitles/search?${new URLSearchParams({ language })}`, options),
    downloadSubtitle: (mediaId, body, options = {}) => request(`/api/v1/media/${id(mediaId)}/subtitles`, { ...options, method: "POST", body }),
    removeSubtitle: (mediaId, subtitleId) => request(`/api/v1/media/${id(mediaId)}/subtitles/${id(subtitleId)}`, { method: "DELETE" }),

    // Edit Metadata: pictures and files
    uploadEditorImage: (mediaId, file, options = {}) => send(`/api/v1/media/${id(mediaId)}/editor/uploads`, file, options),
    discardEditorImage: (mediaId, uploadId) => request(`/api/v1/media/${id(mediaId)}/editor/uploads/${id(uploadId)}`, { method: "DELETE" }),
    editorFiles: (mediaId, path, options = {}) => request(`/api/v1/media/${id(mediaId)}/editor/files?${new URLSearchParams({ path })}`, options),
    removeTitle: (mediaId) => approved(`/api/v1/media/${id(mediaId)}`, { method: "DELETE" }),

    // Library
    serverFolders: (path, options = {}) => request(`/api/v1/libraries/folders${path ? `?${new URLSearchParams({ path })}` : ""}`, options),
    libraryExclusions: (libraryId, options = {}) => request(`/api/v1/libraries/${id(libraryId)}/exclusions`, options),
    restoreExclusion: (libraryId, exclusionId) => request(`/api/v1/libraries/${id(libraryId)}/exclusions/${id(exclusionId)}`, { method: "DELETE" }),
    analyzeImport: (libraryId, options = {}) => request(`/api/v1/libraries/${id(libraryId)}/import-preview`, { ...options, method: "POST" }),
    importPreviewItems: (libraryId, previewId, offset = 0, options = {}) =>
      request(`/api/v1/libraries/${id(libraryId)}/import-preview/${id(previewId)}/items?${new URLSearchParams({ offset: String(offset), limit: "500" })}`, options),
    importAssignments: (libraryId, options = {}) => request(`/api/v1/libraries/${id(libraryId)}/import-assignments`, options),
    updateImportPreview: (libraryId, previewId, revision, assignments, options = {}) =>
      request(`/api/v1/libraries/${id(libraryId)}/import-preview/${id(previewId)}/assignments`, { ...options, method: "PUT", body: { revision, assignments } }),
    confirmImportPreview: (libraryId, previewId, revision, options = {}) =>
      request(`/api/v1/libraries/${id(libraryId)}/import-preview/${id(previewId)}/confirm`, { ...options, method: "POST", body: { revision } }),

    // Server
    serverCapabilities: (options = {}) => request("/api/v1/server/capabilities", options),
    restartServer: () => request("/api/v1/server/operations/restart", { method: "POST" }),
    hosting: (options = {}) => request("/api/v1/server/hosting", options),
    changeHosting: (body) => request("/api/v1/server/operations/hosting", { method: "POST", body }),
    confirmOperation: (operationId) => request(`/api/v1/server/operations/${id(operationId)}/confirm`, { method: "POST" }),
    diagnosticsReport: (options = {}) => receive("/api/v1/server/diagnostics/export", options),
    verifyBackup: (name) => request(`/api/v1/server/backups/${id(name)}/verify`, { method: "POST" }),
    exportBackup: (passphrase) => request("/api/v1/server/backups/export", { method: "POST", body: { passphrase } }),
    backupTransfer: (transferId, options = {}) => receive(`/api/v1/server/backups/transfers/${id(transferId)}`, options),
    discardBackupTransfer: (transferId) => request(`/api/v1/server/backups/transfers/${id(transferId)}`, { method: "DELETE" }),
    uploadBackup: (uploadId, file, options = {}) => send(`/api/v1/server/backups/uploads/${id(uploadId)}`, file, { ...options, method: "PUT", contentType: "application/octet-stream" }),
    prepareRestore: (body) => approved("/api/v1/server/backups/restore/prepare", { body }),
    applyRestore: (restoreId) => approved(`/api/v1/server/backups/restore/${id(restoreId)}/apply`),
    cinemaTrailers: (mediaId, count, options = {}) => request(`/api/v1/media/${id(mediaId)}/cinema-trailers?${new URLSearchParams({ count })}`, options),
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
