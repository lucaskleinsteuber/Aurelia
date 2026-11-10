import test from "node:test";
import assert from "node:assert/strict";
import {
  GENERAL_DEFAULTS, PLAYBACK_DEFAULTS, SETTINGS_PAGES, libraryPayload, loadManagementSections,
  managementPermissions, metadataPayload, normalizeGeneralPreferences, normalizePreferences,
  profilePayload, scrubPreviewBucketSeconds, scrubPreviewFrameUrl, scrubPreviewUsageText, transcodingSummary, waitForLibraryOperation
} from "../../src/Aurelia.Server/WebApp/js/logic.js";

test("management permissions keep owner settings and selected-title storage restrictions", () => {
  assert.deepEqual(managementPermissions({ role: "owner", accessMode: "selectedTitles" }), { owner: true, administrator: true, storage: true });
  assert.deepEqual(managementPermissions({ role: "admin", accessMode: "entireLibrary" }), { owner: false, administrator: true, storage: true });
  assert.deepEqual(managementPermissions({ role: "admin", accessMode: "selectedTitles" }), { owner: false, administrator: true, storage: false });
  assert.deepEqual(managementPermissions({ role: "user" }), { owner: false, administrator: false, storage: false });
});

function sectionApi() {
  const calls = [];
  const api = {};
  for (const name of ["metadataJobs", "devices", "libraries", "serverStatus", "serverUpdates", "serverUsers", "serverPower", "serverBackups"])
    api[name] = async () => { calls.push(name); return [name]; };
  return { api, calls };
}

test("an unlocked administrator loads its allowed sections without any owner endpoint or password", async () => {
  const { api, calls } = sectionApi();
  api.unlockManagement = () => assert.fail("An unlocked window must never ask for another password");
  const sections = await loadManagementSections(api, { role: "admin", accessMode: "entireLibrary" });
  assert.deepEqual(calls, ["metadataJobs", "devices", "libraries"]);
  assert.deepEqual(sections.libraries, ["libraries"]);
  assert.equal(sections.status, undefined);
  assert.deepEqual(sections.users, []);
});

test("a selected-title administrator can edit metadata without requesting restricted storage", async () => {
  const { api, calls } = sectionApi();
  await loadManagementSections(api, { role: "admin", accessMode: "selectedTitles" });
  assert.deepEqual(calls, ["metadataJobs", "devices"]);
});

test("locked management stops before section reads and is explicitly reported to the unlock form", async () => {
  const { api, calls } = sectionApi();
  const locked = Object.assign(new Error("Unlock management"), { status: 403, code: "management_locked" });
  api.metadataJobs = async () => { throw locked; };
  await assert.rejects(loadManagementSections(api, { role: "admin" }), (error) => error === locked);
  assert.deepEqual(calls, []);
  await assert.rejects(loadManagementSections(api, { role: "user" }), /Only the server's owner/);
});

test("owner sections load independently but expiry during the load is never hidden as an empty list", async () => {
  const { api, calls } = sectionApi();
  api.serverUsers = async () => { throw Object.assign(new Error("Cannot load profiles"), { status: 500 }); };
  const sections = await loadManagementSections(api, { role: "owner" });
  assert.ok(calls.includes("serverStatus"));
  assert.deepEqual(sections.libraries, ["libraries"]);
  assert.deepEqual(sections.issues, [{ section: "users", message: "Cannot load profiles" }]);
  api.serverBackups = async () => { throw Object.assign(new Error("Expired"), { code: "management_locked" }); };
  await assert.rejects(loadManagementSections(api, { role: "owner" }), /Expired/);
});

test("storage forms pass an absolute server path unchanged and never combine existing locations", () => {
  const payload = libraryPayload({ name: " Archive ", path: "/server/Invented Media/ ", kind: "tvShows" });
  assert.deepEqual(payload, { name: "Archive", path: "/server/Invented Media/ ", kind: "tvShows", combineExisting: false, requireImportPreview: false });
  assert.equal(libraryPayload({ path: "/server/Films" }).name, null);
  assert.throws(() => libraryPayload({ path: "~/Movies" }), /absolute/);
  assert.throws(() => libraryPayload({ path: "relative/path" }), /absolute/);
  assert.throws(() => libraryPayload({ path: "/server/Films\0other" }), /absolute/);
  assert.throws(() => libraryPayload({ path: "/server/Films", kind: "unknown" }), /type/);
  assert.throws(() => libraryPayload({ path: "/server/Films", name: "bad\nname" }), /visible/);
});

test("an asynchronous removal waits for completion and reports a failed operation instead of success", async () => {
  const events = [];
  let reads = 0;
  const api = { libraryOperation: async (id) => { assert.equal(id, "invented-operation"); reads += 1; return { id, state: reads === 1 ? "running" : "completed" }; } };
  const result = await waitForLibraryOperation(api, { id: "invented-operation", state: "queued" }, { wait: async () => {}, onProgress: (operation) => events.push(operation.state) });
  assert.equal(result.state, "completed");
  assert.deepEqual(events, ["queued", "running"]);
  assert.equal(reads, 2);
  assert.equal(await waitForLibraryOperation(api, null), null);
  await assert.rejects(waitForLibraryOperation(api, { state: "failed", error: "Location still in use" }), /still in use/);
  const controller = new AbortController(); controller.abort();
  await assert.rejects(waitForLibraryOperation(api, { id: "op", state: "running" }, { signal: controller.signal }), { name: "AbortError" });
});

const snapshot = {
  revision: 7,
  user: { username: "Invented Profile", role: "user", pinProtectionEnabled: true, needsPinSetup: false },
  isEnabled: true,
  access: { mode: "legacyLibraries", titleIds: [] },
};
const draft = { username: "Invented Profile", role: "user", pinProtectionEnabled: true, isEnabled: true, pin: "", pinConfirmation: "", accessMode: "legacyLibraries", titleIds: [] };

test("profile edits preserve the existing PIN and legacy grants while saving against the snapshot revision", () => {
  assert.deepEqual(profilePayload(snapshot, draft), { revision: 7, role: "user", isEnabled: true, pinProtectionEnabled: true });
  const changed = profilePayload(snapshot, { ...draft, accessMode: "selectedTitles", titleIds: ["title-b", "title-a", "title-a"] });
  assert.deepEqual(changed.titleIds, ["title-a", "title-b"]);
  assert.equal(changed.accessMode, "selectedTitles");
  assert.equal("username" in changed, false);
  assert.equal("password" in changed, false);
});

test("profile creation and role changes enforce matching PINs, owner access and explicit enablement", () => {
  const created = profilePayload(null, { ...draft, username: " New Profile ", accessMode: "selectedTitles", pin: "1234", pinConfirmation: "1234", isEnabled: false });
  assert.equal(created.username, "New Profile");
  assert.equal(created.isEnabled, false);
  assert.equal(created.pin, "1234");
  const owner = profilePayload(snapshot, { ...draft, role: "owner", pinProtectionEnabled: false, accessMode: "selectedTitles", titleIds: ["title-a"] });
  assert.equal(owner.pinProtectionEnabled, true);
  assert.equal(owner.accessMode, "entireLibrary");
  assert.deepEqual(owner.titleIds, []);
  for (const values of [{ pin: "123", pinConfirmation: "123" }, { pin: "1234", pinConfirmation: "4321" }, { pin: "1234", pinConfirmation: "" }])
    assert.throws(() => profilePayload(snapshot, { ...draft, ...values }), /matching PIN/);
  assert.throws(() => profilePayload({ ...snapshot, user: { ...snapshot.user, needsPinSetup: true } }, draft), /matching PIN/);
  assert.throws(() => profilePayload(null, { ...draft, pinProtectionEnabled: false }), /access mode/);
  assert.throws(() => profilePayload(null, { ...draft, accessMode: "entireLibrary", pin: "1234", pinConfirmation: "1234", username: "ab" }), /profile name/);
  assert.equal(profilePayload(null, { ...draft, accessMode: "selectedTitles", pinProtectionEnabled: false }).pinProtectionEnabled, false);
});

const document = {
  revision: 19, kind: "movie", overrideFields: ["title", "poster", "credits"],
  values: { title: "Invented Film", releaseYear: 2025, overview: "Existing description", runtimeMinutes: 123, fskAge: 12, genres: ["Drama"], studios: ["Studio, Inc."], country: "US", credits: [{ id: "person", name: "Invented Actor", profile: { assetId: "portrait" } }], poster: { assetId: "poster", crop: { x: 0, y: 0, width: 1, height: 1 } }, backdrop: { assetId: "backdrop" } },
  automaticValues: { title: "Automatic Title", releaseYear: 2024, overview: "Automatic description", runtimeMinutes: 120, fskAge: 6, genres: ["Comedy"], studios: ["Other Studio"], country: "GB" },
};

test("metadata edits preserve hidden artwork, cast and overrides and never mutate the server snapshot", () => {
  const before = structuredClone(document);
  const saved = metadataPayload(document, { overview: "New description", releaseYear: "2026", fsk: "16" });
  assert.equal(saved.revision, 19);
  assert.equal(saved.values.title, "Invented Film");
  assert.equal(saved.values.overview, "New description");
  assert.equal(saved.values.releaseYear, 2026);
  assert.equal(saved.values.fskAge, 16);
  assert.deepEqual(saved.values.poster, document.values.poster);
  assert.deepEqual(saved.values.credits, document.values.credits);
  assert.deepEqual(saved.values.studios, ["Studio, Inc."]);
  assert.deepEqual(saved.overrideFields, ["credits", "fsk", "overview", "poster", "releaseYear", "title"]);
  assert.equal("relativeSourcePath" in saved, false);
  assert.deepEqual(document, before);
});

test("automatic reset removes only its field's override and list editing preserves commas within names", () => {
  const saved = metadataPayload(document, { studios: ["Studio, Inc.", " Second Studio ", "Studio, Inc."] }, ["title"]);
  assert.equal(saved.values.title, "Automatic Title");
  assert.equal(saved.overrideFields.includes("title"), false);
  assert.equal(saved.overrideFields.includes("poster"), true);
  assert.deepEqual(saved.values.studios, ["Studio, Inc.", "Second Studio"]);
  assert.deepEqual(metadataPayload(document, { studios: "Studio, Inc.\nSecond Studio" }).values.studios, ["Studio, Inc.", "Second Studio"]);
  const cleared = metadataPayload(document, { overview: "", releaseYear: "", fsk: "", runtimeMinutes: "" });
  assert.equal(cleared.values.overview, "");
  assert.equal(cleared.values.releaseYear, null);
  assert.equal(cleared.values.runtimeMinutes, null);
  assert.equal(cleared.values.fskAge, null);
});

test("metadata validation rejects invalid years, runtimes, FSK, long lists and empty titles before a write", () => {
  for (const changes of [{ title: " " }, { releaseYear: "2025tail" }, { releaseYear: "1799" }, { releaseYear: "3001" }, { runtimeMinutes: "1.5" }, { runtimeMinutes: "0" }, { runtimeMinutes: "14401" }, { fsk: "7" }, { genres: Array.from({ length: 51 }, (_, index) => `Genre ${index}`) }, { overview: "a".repeat(8193) }])
    assert.throws(() => metadataPayload(document, changes));
  assert.throws(() => metadataPayload(document, { unknownField: "value" }), /Unknown/);
  assert.throws(() => metadataPayload(document, {}, ["credits"]), /Unknown/);
});

test("scrub preview helpers bucketize timeline seconds, build cacheable URLs and format storage usage", async () => {
  assert.equal(scrubPreviewBucketSeconds(0, 600, 15), 0);
  assert.equal(scrubPreviewBucketSeconds(14.9, 600, 15), 0);
  assert.equal(scrubPreviewBucketSeconds(15, 600, 15), 15);
  assert.equal(scrubPreviewBucketSeconds(44.2, 600, 15), 30);
  assert.equal(scrubPreviewBucketSeconds(999, 600, 15), 585);
  assert.equal(scrubPreviewFrameUrl("title/1", 44.2, 600, 15), "/api/v1/media/title%2F1/scrub-previews/30");
  assert.match(scrubPreviewUsageText({ storedTitleCount: 3, storedBytes: 2 * 1024 * 1024, storageCapMegabytes: 500 }), /3 titles · 2 MB of 500 MB/);
  const { api, calls } = sectionApi();
  api.serverScrubPreviews = async () => { calls.push("serverScrubPreviews"); return { mode: "onOpenOrPlay", intervalSeconds: 15, storageCapMegabytes: 500 }; };
  const sections = await loadManagementSections(api, { role: "owner" });
  assert.ok(calls.includes("serverScrubPreviews"));
  assert.equal(sections.scrubPreviews.mode, "onOpenOrPlay");
});

test("server health loads metrics and background jobs for administrators", async () => {
  const { api, calls } = sectionApi();
  api.serverHealth = async () => {
    calls.push("serverHealth");
    return {
      uptimeSeconds: 3600,
      freeDiskBytes: 50 * 1024 * 1024 * 1024,
      databaseBytes: 15 * 1024 * 1024,
      scrubPreviewTitleCount: 5,
      scrubPreviewBytes: 10 * 1024 * 1024,
      scrubPreviewPendingCount: 0,
      activeLiveConversions: 0,
      activeStreams: 1,
      offlineMediaCount: 0,
      lastScan: null,
      backgroundJobs: { activeScans: 0, activeMetadataJobs: 0, activeScrubPreviewJobs: 0 },
      recentIssues: [],
      backup: {
        enabled: true,
        lastAttemptFailed: false,
        lastSucceededAt: "2026-10-28T22:00:00Z",
        totalBackups: 3,
        totalBackupBytes: 45 * 1024 * 1024,
        latestDailyAt: "2026-10-28T22:00:00Z",
        latestWeeklyAt: null
      }
    };
  };
  const sections = await loadManagementSections(api, { role: "admin", accessMode: "entireLibrary" });
  assert.ok(calls.includes("serverHealth"));
  assert.equal(sections.health.uptimeSeconds, 3600);
  assert.equal(sections.health.activeStreams, 1);
  assert.equal(sections.health.backup.totalBackups, 3);
});

test("playback and general preferences normalization preserves valid settings and applies defaults", () => {
  const playback = normalizePreferences({});
  assert.equal(playback.upNextCountdownSeconds, 20, "the previous Up Next lead stays the default");
  assert.equal(playback.resumeThresholdSeconds, 0);
  assert.equal("markWatchedThresholdPercent" in playback, false, "the server decides when a title is finished");
  assert.equal(playback.defaultAudioLanguage, "original");
  assert.equal(playback.defaultSubtitleLanguage, "off");
  assert.equal(playback.subtitleSize, "medium");
  assert.equal(playback.subtitleBackground, "transparent");

  const customPlayback = normalizePreferences({
    upNextCountdownSeconds: 25,
    resumeThresholdSeconds: 60,
    defaultAudioLanguage: "de",
    defaultSubtitleLanguage: "en",
    subtitleSize: "large",
    subtitleBackground: "solid",
  });
  assert.equal(customPlayback.upNextCountdownSeconds, 25);
  assert.equal(customPlayback.resumeThresholdSeconds, 60);
  assert.equal(customPlayback.defaultAudioLanguage, "de");
  assert.equal(customPlayback.defaultSubtitleLanguage, "en");
  assert.equal(customPlayback.subtitleSize, "large");
  assert.equal(customPlayback.subtitleBackground, "solid");
  assert.equal(normalizePreferences({ defaultSubtitleLanguage: "auto" }).defaultSubtitleLanguage, "off");

  const general = normalizeGeneralPreferences({});
  assert.equal(general.defaultStartScreen, "continueWatching");
  assert.equal(general.posterSize, "standard");
  assert.equal(general.showWatchedInRows, true);
  assert.equal(general.reduceHeroMotion, false);
  assert.equal("rescanInterval" in general, false, "rescanning is the server's Watch for Changes");

  const customGeneral = normalizeGeneralPreferences({
    defaultStartScreen: "watchlist",
    posterSize: "compact",
    showWatchedInRows: false,
    reduceHeroMotion: true,
  });
  assert.equal(customGeneral.defaultStartScreen, "watchlist");
  assert.equal(customGeneral.posterSize, "compact");
  assert.equal(customGeneral.showWatchedInRows, false);
  assert.equal(customGeneral.reduceHeroMotion, true);
});

test("general settings decide which titles, sidebar sections and start page show", async () => {
  const { visibleTitles, startPath, sidebarShows } = await import("../../src/Aurelia.Server/WebApp/js/preferences.js");
  const titles = [
    { id: "a", kind: "movie", availability: "available", watchState: "completed" },
    { id: "b", kind: "movie", availability: "missing", watchState: "unplayed" },
    { id: "c", kind: "series", availability: "available", watchState: "inProgress" },
  ];
  const all = normalizeGeneralPreferences({});
  assert.deepEqual(visibleTitles(titles, all).map((item) => item.id), ["a", "b", "c"]);
  const strict = normalizeGeneralPreferences({ showWatchedInRows: false, hideOfflineTitles: true });
  assert.deepEqual(visibleTitles(titles, strict).map((item) => item.id), ["c"]);
  assert.deepEqual(visibleTitles(titles, strict, { keepWatched: true }).map((item) => item.id), ["a", "c"]);

  assert.equal(startPath(normalizeGeneralPreferences({})), "/");
  assert.equal(startPath(normalizeGeneralPreferences({ defaultStartScreen: "movies" })), "/movies");
  const sparse = normalizeGeneralPreferences({ showMoviesInSidebar: false });
  assert.equal(sidebarShows("movies", sparse), false);
  assert.equal(sidebarShows("home", sparse), true);
});

test("playback settings choose the start position, Up Next lead and default languages", async () => {
  const logic = await import("../../src/Aurelia.Server/WebApp/js/logic.js");
  const progress = { positionMilliseconds: 45_000, durationMilliseconds: 2_400_000, isCompleted: false };
  assert.equal(logic.playbackStartSeconds("resume", progress, true, 0), 45);
  assert.equal(logic.playbackStartSeconds("resume", progress, true, 60), 0);
  assert.equal(logic.playbackStartSeconds("play", progress, true, 0), 0);

  const base = { duration: 2400, hasNext: true, autoplay: true };
  assert.equal(logic.showsUpNext({ ...base, position: 2385, lead: 10 }), false);
  assert.equal(logic.showsUpNext({ ...base, position: 2385, lead: 20 }), true);

  const tracks = [
    { index: 1, language: "eng", isForced: false },
    { index: 2, language: "ger", isForced: true },
    { index: 3, language: "deu", isForced: false },
  ];
  assert.equal(logic.trackForLanguage(tracks, "de").index, 3, "full subtitles win over forced ones");
  assert.equal(logic.trackForLanguage(tracks, "en").index, 1);
  assert.equal(logic.trackForLanguage(tracks, "ja"), null);
  assert.equal(logic.languageMatches("de-DE", "de"), true);
});

test("settings pages include all 8 structured categories and account alias", () => {
  const expected = ["general", "playback", "library", "metadata", "profiles", "server", "updates", "advanced", "account"];
  for (const page of expected) {
    assert.ok(SETTINGS_PAGES.includes(page), `Page ${page} should be present in SETTINGS_PAGES`);
  }
});

test("video conversion reads the encoder, the hint and the running conversions for the owner", async () => {
  const { api, calls } = sectionApi();
  api.serverTranscoding = async () => { calls.push("serverTranscoding"); return { available: true }; };
  const sections = await loadManagementSections(api, { role: "owner" });
  assert.ok(calls.includes("serverTranscoding"));
  assert.equal(sections.transcoding.available, true);

  const summary = transcodingSummary({
    available: true, encoderName: "VA-API", device: "/dev/dri/renderD128", hardwareDecoding: true, hardwareResting: false, videoLimit: 3,
    sessions: [
      { title: "Invented Film.mkv", quality: "720p", converting: true, speed: 4.25 },
      { title: "Invented Show.mkv", quality: "480p", converting: false, speed: null },
    ],
  });
  assert.equal(summary.encoder, "VA-API (renderD128) · decodes on the chip");
  assert.equal(summary.running, "1 of 3 at once");
  assert.deepEqual(summary.sessions.map((session) => session.detail), ["720p · 4.3× real time", "480p · ready"]);
  assert.equal(transcodingSummary({ available: false, sessions: [] }).encoder, "Not available");
  assert.equal(transcodingSummary({ available: true, encoderName: "Processor (x264)", hardwareResting: true, sessions: [], videoLimit: 1 }).encoder,
    "Processor (x264) · the processor stands in after a chip error");
  assert.equal(transcodingSummary(null).running, "None");
});
